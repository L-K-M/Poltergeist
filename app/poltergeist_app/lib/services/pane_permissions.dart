import 'package:poltergeist_core/poltergeist_core.dart';

import 'engine_session.dart';

/// POSIX mode-bit helpers and the D28 "Apply to enclosed items…" walks
/// for the Get Info permissions editor (02 §2.6).
///
/// The editor's octal field is exactly four digits: the leading digit
/// carries setuid/setgid/sticky, so the mode domain is `0..0xFFF` — the
/// same range the VFS's `setMode` contract accepts.
const int permissionsModeMask = 0xFFF;

/// The nine rwx bits the editor's checkbox grid drives, in grid order:
/// owner, group, others × read, write, execute.
const int permissionOwnerRead = 0x100;
const int permissionOwnerWrite = 0x80;
const int permissionOwnerExecute = 0x40;
const int permissionGroupRead = 0x20;
const int permissionGroupWrite = 0x10;
const int permissionGroupExecute = 0x8;
const int permissionOtherRead = 0x4;
const int permissionOtherWrite = 0x2;
const int permissionOtherExecute = 0x1;

/// A name that cannot go back over the wire unchanged (02 §13's
/// flagged-name rule): U+FFFD means the listing's decode already lost
/// bytes, and any path built from it would name a different file.
bool nameIsFlagged(String name) => name.contains('\uFFFD');

/// The Get Info inspector's open permissions draft (02 §2.6, D28): the
/// octal field's text, the parsed mode the rwx checkboxes reflect, the
/// last apply refusal, and a revision the field watches so a
/// programmatic re-seed (a checkbox edit, a revert) never lands
/// mid-keystroke. The controller owns one per target and keys it on
/// the target's path and listed mode — a retarget or a refresh-landed
/// mode change re-mints it instead of carrying a stale draft.
final class PermissionsEditSession {
  PermissionsEditSession({required this.targetPath, required this.originalMode})
    : mode = originalMode,
      octalText = octalTextFor(originalMode);

  /// The entry the draft edits — identity for the target-keyed lookup.
  final String targetPath;

  /// The mode the target listed with — the baseline the draft diffs
  /// against; a successful apply rebaselines it.
  int originalMode;

  /// The draft's parsed mode — the checkbox grid's source of truth.
  int mode;

  /// The octal field's text — verbatim while the user types (invalid
  /// text stays for correction), re-seeded from [mode] on checkbox
  /// edits and reverts.
  String octalText;

  /// The text failed [parsePermissionsOctal] — the field's inline error.
  bool octalInvalid = false;

  /// Bumped whenever [octalText] was assigned programmatically — the
  /// view's field re-seeds on a new revision, never while typing.
  int octalRevision = 0;

  /// The last apply's typed refusal, rendered under the editor —
  /// cleared by the next edit or apply.
  RemoteFileException? applyError;

  /// A single-entry chmod is in flight.
  bool applying = false;

  /// The draft differs from the applied baseline — Apply's enablement.
  bool get dirty => mode != originalMode;

  /// The mode's canonical field spelling: four octal digits, the
  /// leading special-bits digit included — nothing the symbolic render
  /// folds into its execute slots is lost.
  static String octalTextFor(int mode) =>
      (mode & permissionsModeMask).toRadixString(8).padLeft(4, '0');
}

/// Why the inspector's permissions row stays display-only for the
/// current target (02 §13's disabled-with-reason rule) — the view maps
/// each value to its ARB-authored note.
enum PermissionsReadOnly {
  /// The name is undecodable: a path built from it cannot cross the
  /// wire losslessly, so no chmod may be issued against it (02 §13).
  flaggedName,

  /// The target is a symbolic link: the VFS lstat-guards every chmod
  /// and refuses links typed — the affordance is never offered a
  /// guaranteed refusal.
  symbolicLink,

  /// The pane's filesystem has no POSIX chmod — a Windows local pane.
  unsupportedFilesystem,
}

/// Parses the octal field: exactly four octal digits `0000`–`7777`,
/// nothing else. The leading digit is the special-bits digit — setuid,
/// setgid, sticky — never silently dropped. Returns null for anything
/// invalid (the field's inline error state, never an exception).
int? parsePermissionsOctal(String text) {
  if (text.length != 4) return null;
  var value = 0;
  for (final codeUnit in text.codeUnits) {
    final digit = codeUnit - 0x30; // '0'
    if (digit < 0 || digit > 7) return null;
    value = (value << 3) | digit;
  }
  return value;
}

/// Where one enclosed-apply operation stands (02 §2.6, D28): a count
/// pass fills the confirmation's quantified copy, the confirmed walk
/// chmods, and the terminal snapshots keep their tallies — a cancelled
/// run that already changed items must never read as clean.
enum EnclosedApplyStage {
  /// The count pass is still listing directories; the confirmation's
  /// progress line is showing.
  counting,

  /// The count pass settled (or timed out); the confirmation dialog is
  /// awaiting the user's answer.
  confirming,

  /// The user confirmed; the chmod walk is running.
  applying,

  /// The walk visited every reachable entry.
  done,

  /// The caller's cancellation token fired; the tallies hold the
  /// partial run — already-applied items stay changed.
  cancelled,

  /// The walk could not finish: the root's listing refused, the root's
  /// own chmod refused, or an untyped fault reached the walk. [error]
  /// carries the typed refusal when one exists.
  failed,
}

/// One enclosed-apply operation's snapshot: the controller swaps the
/// whole value per update so a stale read can never observe a
/// half-mutated counter set — the same contract as [FolderSizeProgress].
final class EnclosedApplyProgress {
  const EnclosedApplyProgress({
    required this.targetPath,
    required this.targetName,
    required this.mode,
    required this.stage,
    this.counted = 0,
    this.countedFlagged = 0,
    this.countedLinks = 0,
    this.flagPassComplete = false,
    this.visited = 0,
    this.applied = 0,
    this.skippedUndecodable = 0,
    this.linksSkipped = 0,
    this.unreadable = 0,
    this.failed = 0,
    this.error,
  });

  /// The directory the operation applies to — the inspector matches it
  /// against its current target, so a retarget never displays an
  /// operation started for a different folder.
  final String targetPath;

  /// The target's display name — the confirmation dialog names the
  /// folder, and a retarget must never render a stale one.
  final String targetName;

  /// The exact twelve-bit mode being applied to every reachable entry —
  /// snapshot at request time, so editing the draft mid-run cannot
  /// change what the running operation writes.
  final int mode;

  final EnclosedApplyStage stage;

  /// Changeable enclosed items the count pass saw — directories, files,
  /// and other non-link entries, flagged names excluded (02 §13: the
  /// confirmed count matches what the operation will do).
  final int counted;

  /// Enclosed entries the count pass skipped for an undecodable name —
  /// the confirmation discloses them verbatim when [flagPassComplete]
  /// holds, hedged otherwise.
  final int countedFlagged;

  /// Enclosed symbolic links the count pass saw — always skipped at
  /// apply time (the VFS refuses to chmod a link), so they are excluded
  /// from [counted] and disclosed separately.
  final int countedLinks;

  /// The count pass visited every reachable directory without a refused
  /// listing: the flagged/link disclosures may use their counted forms.
  /// When false — timeout or an unreadable subtree — the confirmation
  /// hedges, because unlisted subtrees could hide flagged names.
  final bool flagPassComplete;

  /// Enclosed entries visited during the apply walk (directories
  /// included) — the progress line's denominator-free total.
  final int visited;

  /// Entries whose chmod completed — the target directory itself
  /// included (the enclosed apply covers the folder and its contents).
  final int applied;

  /// Entries skipped because their listed name is undecodable (02 §13):
  /// no path built from it may cross the wire.
  final int skippedUndecodable;

  /// Symbolic links skipped without a chmod call — the VFS refuses them
  /// typed, and following a link's target would escape the tree.
  final int linksSkipped;

  /// Directories whose listing refused mid-walk: their subtrees were
  /// never reached, so the tally keeps the run honest about being
  /// partial.
  final int unreadable;

  /// Entries whose chmod refused typed — counted, and the walk
  /// continues past them: one unowned file must not void the rest.
  final int failed;

  /// The failure behind a [EnclosedApplyStage.failed] run — the root
  /// listing's or the root chmod's typed refusal. Untyped faults never
  /// land here: they propagate to the caller.
  final Object? error;

  /// The run is still doing work the user can cancel — the tab-close
  /// guard's trigger (02 §2.6: in-flight enclosed apply keeps the tab).
  bool get inFlight =>
      stage == EnclosedApplyStage.counting ||
      stage == EnclosedApplyStage.confirming ||
      stage == EnclosedApplyStage.applying;
}

/// What the pre-confirmation count pass learned. Kept separate from
/// [EnclosedApplyProgress] so the walk's return is the count itself —
/// the controller folds it into the session snapshot.
final class EnclosedApplyCount {
  const EnclosedApplyCount({
    required this.items,
    required this.flagged,
    required this.links,
    required this.clean,
    required this.cancelled,
  });

  /// Enclosed entries a chmod would target: everything listed except
  /// flagged names and symbolic links. The target directory itself is
  /// not counted — the confirmation names it directly.
  final int items;

  /// Enclosed entries skipped for an undecodable name (02 §13).
  final int flagged;

  /// Enclosed symbolic links — never chmodded, disclosed separately.
  final int links;

  /// Every reachable directory listed without a refusal — the counted
  /// disclosures may use their unhedged forms.
  final bool clean;

  /// The cancellation token fired mid-count (the deadline or the user's
  /// cancel): the confirmation falls back to unquantified, hedged copy.
  final bool cancelled;
}

/// The confirmation the "Apply to enclosed items…" operation asks before
/// touching anything — the presenter renders the live
/// [EnclosedApplyProgress] from the controller, so the dialog shows the
/// count pass's progress and settles into the quantified (or hedged
/// fallback) copy. Resolves true to run the chmod walk, false (or on a
/// dismiss/error) to drop the operation untouched — destructive-class
/// means unconfirmed never mutates (02 §10).
typedef EnclosedApplyConfirmation = Future<bool> Function();

/// Counts the changeable enclosed items under [path] — the
/// confirmation's quantified copy (02 §10's quantify-then-confirm rule
/// for destructive verbs). Read-only: the pass only lists.
///
/// Depth-first over an explicit stack, cancelled cooperatively before
/// every listing — a held answer settles and the loop exits on the next
/// check. A nested listing refusal keeps counting the rest but marks
/// the result not-[EnclosedApplyCount.clean] so the confirmation
/// hedges its flagged-name disclosure; only the ROOT listing's refusal
/// propagates (there is nothing to count) — and even that answers the
/// typed error rather than throwing untyped. Flagged names (02 §13) and
/// symbolic links count their own buckets and are excluded from
/// [EnclosedApplyCount.items]: the headline always matches what the
/// apply walk would touch.
Future<EnclosedApplyCount> countEnclosedApplyItems(
  AppBrowseChannel channel,
  String path, {
  required RemoteTransferCancellation cancellation,
  void Function(EnclosedApplyCount count)? onProgress,
}) async {
  var items = 0;
  var flagged = 0;
  var links = 0;
  var clean = true;
  EnclosedApplyCount snapshot({required bool cancelled}) =>
      EnclosedApplyCount(
        items: items,
        flagged: flagged,
        links: links,
        clean: clean,
        cancelled: cancelled,
      );

  final visited = <String>{_dedupeKey(path)};
  final pending = <String>[path];
  var first = true;
  while (pending.isNotEmpty) {
    if (cancellation.isCancelled) return snapshot(cancelled: true);
    final next = pending.removeLast();
    final List<RemoteFileEntry> listed;
    try {
      listed = await channel.listDirectory(next);
    } on RemoteFileException {
      if (first) rethrow;
      // A nested refusal only loses that subtree — the count stays, the
      // flag pass is incomplete, and the confirmation hedges (02 §13's
      // never-silent rule).
      clean = false;
      continue;
    }
    first = false;
    for (final entry in listed) {
      // Defensive: a server that echoes '.'/'..' must not recurse.
      if (entry.name == '.' || entry.name == '..') continue;
      if (nameIsFlagged(entry.name)) {
        flagged++;
        continue;
      }
      if (entry.isSymbolicLink) {
        links++;
        continue;
      }
      items++;
      if (entry.isDirectory &&
          visited.add(_dedupeKey(entry.path))) {
        pending.add(entry.path);
      }
    }
    onProgress?.call(snapshot(cancelled: false));
  }
  return snapshot(cancelled: false);
}

/// Applies [mode] to [path] and every changeable item inside it — D28's
/// "Apply to enclosed items…" behind the pane's browse channel, so local
/// and remote trees apply identically and no widget touches a
/// filesystem (D8). The mode applies verbatim to directories and files
/// alike: the octal the user confirmed is what every entry gets.
///
/// Directories are chmodded POST-order: a mode that removes the
/// owner's execute bit must not strand its own subtree mid-walk — each
/// directory's chmod lands only after its subtree is fully processed
/// (the target directory itself is last).
///
/// Per [countEnclosedApplyItems]'s rules: flagged names are skipped
/// without a wire call (02 §13), symbolic links are skipped without a
/// chmod call (the VFS refuses them typed — and a followed link would
/// escape the tree), and a nested listing refusal counts [unreadable]
/// and continues. A nested CHMOD refusal counts [failed] and continues
/// — one unowned file must not void the rest — while the root listing's
/// or the root chmod's refusal ends the run as
/// [EnclosedApplyStage.failed]. Cancellation is cooperative: the token
/// is checked before every channel call, so a held answer settles and
/// the loop exits on the next check with the partial tallies.
Future<EnclosedApplyProgress> applyModeToEnclosed(
  AppBrowseChannel channel,
  String path, {
  required String targetName,
  required int mode,
  required RemoteTransferCancellation cancellation,
  void Function(EnclosedApplyProgress progress)? onProgress,
}) async {
  var visited = 0;
  var applied = 0;
  var skippedUndecodable = 0;
  var linksSkipped = 0;
  var unreadable = 0;
  var failed = 0;
  EnclosedApplyProgress snapshot(
    EnclosedApplyStage stage, {
    Object? error,
  }) => EnclosedApplyProgress(
    targetPath: path,
    targetName: targetName,
    mode: mode,
    stage: stage,
    visited: visited,
    applied: applied,
    skippedUndecodable: skippedUndecodable,
    linksSkipped: linksSkipped,
    unreadable: unreadable,
    failed: failed,
    error: error,
  );

  // Directories wait for post-order chmod in discovery order — a
  // parent's listing always precedes its descendants', so replaying the
  // list reversed puts every directory after its subtree.
  final directories = <String>[];
  final seen = <String>{_dedupeKey(path)};
  final pending = <String>[path];
  var first = true;

  while (pending.isNotEmpty) {
    if (cancellation.isCancelled) {
      return snapshot(EnclosedApplyStage.cancelled);
    }
    final next = pending.removeLast();
    final List<RemoteFileEntry> listed;
    try {
      listed = await channel.listDirectory(next);
    } on RemoteFileException catch (error) {
      if (first) return snapshot(EnclosedApplyStage.failed, error: error);
      unreadable++;
      // The directory itself was listed by its parent — the count pass
      // counted it changeable, so its own chmod is still attempted
      // post-order even though its subtree is unreachable.
      directories.add(next);
      continue;
    }
    first = false;
    directories.add(next);
    for (final entry in listed) {
      if (entry.name == '.' || entry.name == '..') continue;
      if (nameIsFlagged(entry.name)) {
        skippedUndecodable++;
        continue;
      }
      if (entry.isSymbolicLink) {
        linksSkipped++;
        continue;
      }
      visited++;
      if (entry.isDirectory) {
        if (seen.add(_dedupeKey(entry.path))) pending.add(entry.path);
        // A directory-only stretch emits no file chmods — keep the
        // progress line moving through the discovery phase.
        onProgress?.call(snapshot(EnclosedApplyStage.applying));
        continue;
      }
      if (cancellation.isCancelled) {
        return snapshot(EnclosedApplyStage.cancelled);
      }
      try {
        await channel.setPermissions(entry.path, mode);
        applied++;
      } on RemoteFileException {
        failed++;
      }
      onProgress?.call(snapshot(EnclosedApplyStage.applying));
    }
  }

  // Post-order: children first, the target directory last.
  for (final directory in directories.reversed) {
    if (cancellation.isCancelled) {
      return snapshot(EnclosedApplyStage.cancelled);
    }
    try {
      await channel.setPermissions(directory, mode);
      applied++;
    } on RemoteFileException catch (error) {
      failed++;
      // The target's own chmod refusing is the run's headline failure —
      // like the root listing's refusal, it ends the operation typed.
      if (directory == path) {
        return snapshot(EnclosedApplyStage.failed, error: error);
      }
    }
    onProgress?.call(snapshot(EnclosedApplyStage.applying));
  }
  return snapshot(EnclosedApplyStage.done);
}

/// Matches an unambiguously Windows absolute spelling: a drive letter
/// immediately followed by a separator. Compiled once — `_dedupeKey`
/// runs per directory inside both walks.
final RegExp _windowsAbsoluteHead = RegExp(r'^[A-Za-z]:[\\/]');

/// The visited-set's dedupe key: strips trailing separators so a server
/// spelling one directory two ways cannot process it twice. Only dedupe
/// — the stripped key never reaches the channel.
String _dedupeKey(String path) {
  var key = path;
  // '\' is a separator only in unambiguously Windows spellings — a
  // drive letter immediately followed by one, or a UNC head. On POSIX
  // it is a legal filename character, and a bare relative spelling
  // stays ambiguous rather than guessed: under-stripping can double-
  // process a misspelled directory, but over-stripping silently merges
  // distinct names and loses a subtree.
  final windowsStyle = _windowsAbsoluteHead.hasMatch(key) ||
      key.startsWith(r'\\');
  while (key.length > 1 &&
      (key.endsWith('/') || (windowsStyle && key.endsWith(r'\')))) {
    key = key.substring(0, key.length - 1);
  }
  return key;
}
