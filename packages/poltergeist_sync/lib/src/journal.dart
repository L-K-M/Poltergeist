// The run journal (05 §8 rail 9): one JSONL file per run at
// `<app-support>/sync_runs/<runId>.jsonl`. A `SyncRunRecord` header line,
// one line per executed item, one `trash` line per file a rule-4
// pre-delete removed, one `rmdir` line per emptied directory, one
// `remove` line per permanent file deletion, a summary line, and the
// `purged` marker rail 5's purge stamps. Every append flushes
// immediately — no userspace buffering — so a killed process loses at
// most the line it was mid-writing; replay drops a torn final line
// (03 §4.6's recovery pattern). The journal is the package's one
// legitimate `dart:io` user (05 §11): the JSONL file under app-support
// is local-disk bookkeeping, while every sync filesystem operation
// flows through the two injected RemoteFileSystems (D3).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';

import 'plan.dart';

/// Schema version stamped on every line; replay refuses a newer major
/// version rather than silently misreading it.
const int syncJournalSchemaVersion = 1;

/// Directory name under app-support (05 §8 rail 9).
const String syncRunsDirectoryName = 'sync_runs';

/// Journals are pruned to the newest [syncJournalRetention] per pair —
/// except a run whose journal records trash entries without a `purged`
/// marker: Undo must never lose its source while the trash it reverses
/// is still there (05 §8 rail 9).
const int syncJournalRetention = 20;

/// One executed-item line. [attempt] starts at 1 and increments on any
/// re-execution of the same (runId, relativePath, side, action) key —
/// `Retry Failed` or crash-resume (05 §11's uniqueness contract).
final class SyncJournalItemLine {
  const SyncJournalItemLine({
    required this.relativePath,
    required this.side,
    required this.action,
    required this.outcome,
    required this.attempt,
    this.bytes = 0,
    this.durationMs = 0,
    this.userOverridden = false,
    this.trashLocation,
    this.trashBytes,
    this.trashContentSha256,
    this.observedMtimeAfterWrite,
    this.setstatIgnored = false,
    this.error,
  });

  final String relativePath;
  final SyncSide side;
  final SyncActionType action;
  final SyncItemStatus outcome;
  final int attempt;
  final int bytes;
  final int durationMs;
  final bool userOverridden;

  /// Where this item's previous version went (update backups, and
  /// delete-phase file/symlink removals under `deletions: trash`).
  final String? trashLocation;

  /// The size of the file that went to [trashLocation] — distinct from
  /// [bytes] on update lines, where [bytes] is the new version's
  /// payload. Restore size-checks the trash entry against this.
  final int? trashBytes;

  /// Only for rail 5's copy-fallback trash entries — the restore path
  /// hash-verifies those (a rename cannot truncate; an interrupted copy
  /// can).
  final String? trashContentSha256;

  /// The destination's mtime re-stat after `setTimes` (whole seconds).
  final int? observedMtimeAfterWrite;
  final bool setstatIgnored;
  final String? error;
}

/// One file a rule-4 pre-delete moved to trash (05 §6 rule 4: one line
/// per removed file under the parent item).
final class SyncJournalTrashLine {
  const SyncJournalTrashLine({
    required this.parentPath,
    required this.relativePath,
    required this.side,
    required this.trashLocation,
    required this.bytes,
    this.trashContentSha256,
  });

  /// The plan item whose removal step produced this line.
  final String parentPath;
  final String relativePath;
  final SyncSide side;
  final String trashLocation;
  final int bytes;
  final String? trashContentSha256;
}

/// One file permanently removed (under `deletions: permanent`, or a
/// rule-4 pre-delete in a Mirror-permanent pair). Recorded so the run
/// history stays complete — there is nothing to restore.
final class SyncJournalRemoveLine {
  const SyncJournalRemoveLine({
    required this.parentPath,
    required this.relativePath,
    required this.side,
    required this.bytes,
  });

  /// The plan item whose removal step produced this line; equal to
  /// [relativePath] for delete-phase items.
  final String parentPath;
  final String relativePath;
  final SyncSide side;
  final int bytes;
}

/// One emptied directory removed during a run — pre-delete trees and
/// delete-phase cleanup alike. The restore path recreates these chains
/// shallowest-first (05 §8 rail 9).
final class SyncJournalRmdirLine {
  const SyncJournalRmdirLine({
    required this.relativePath,
    required this.side,
    required this.parentPath,
  });

  final String relativePath;
  final SyncSide side;

  /// The plan item the removal ran under; equal to [relativePath] for
  /// delete-phase cleanup items.
  final String parentPath;
}

/// The run's closing line.
final class SyncJournalSummary {
  const SyncJournalSummary({
    required this.counts,
    required this.bytesTransferred,
    required this.cancelled,
    required this.mtimeUnreliableLeft,
    required this.mtimeUnreliableRight,
  });

  /// Items per terminal status.
  final Map<SyncItemStatus, int> counts;
  final int bytesTransferred;
  final bool cancelled;

  /// The §4 flags as they stand at run end — the sync_state writer
  /// persists them.
  final bool mtimeUnreliableLeft;
  final bool mtimeUnreliableRight;
}

/// One parsed JSONL run journal: the append target during a run and the
/// replay source for the report, `Retry Failed`, and
/// `Restore Trashed Files…`.
final class SyncRunJournal {
  SyncRunJournal._(this.path, this.record);

  /// Absolute path of the JSONL file.
  final String path;

  /// The header line's record.
  final SyncRunRecord record;

  final List<SyncJournalItemLine> items = [];
  final List<SyncJournalTrashLine> trashLines = [];
  final List<SyncJournalRemoveLine> removeLines = [];
  final List<SyncJournalRmdirLine> rmdirLines = [];
  SyncJournalSummary? summary;

  /// Set by a `purged` marker line — rail 5's purge stamps it into every
  /// journal it matched, and it is what releases the journal for
  /// pruning (05 §8 rail 9).
  var purged = false;

  File get _file => File(path);

  /// Whether any recorded trash entry is still unrestored — the
  /// live-trash retention exception (05 §8 rail 9). Evaluated locally,
  /// no existence probe of the trash itself.
  bool get hasUnpurgedTrash =>
      !purged &&
      (trashLines.isNotEmpty ||
          items.any((line) => line.trashLocation != null));

  /// Creates the journal file for a run and writes its header line.
  static Future<SyncRunJournal> create(
    String syncRunsDirectory,
    SyncRunRecord record,
  ) async {
    final journal = SyncRunJournal._(
      '$syncRunsDirectory/${record.runId}.jsonl',
      record,
    );
    await Directory(syncRunsDirectory).create(recursive: true);
    await journal._append(<String, Object?>{
      'type': 'header',
      ..._recordToJson(record),
    });
    return journal;
  }

  /// Replays a journal file. A torn final line — the one a kill can
  /// leave mid-write — is dropped, never misparsed.
  static Future<SyncRunJournal> open(String path) async {
    final file = File(path);
    final lines = await file.readAsLines();
    SyncRunRecord? record;
    SyncRunJournal? journal;
    for (final raw in lines) {
      if (raw.trim().isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        // The torn tail: a killed process lost the line it was writing.
        break;
      }
      if (decoded is! Map<String, Object?>) break;
      final version = decoded['v'];
      if (version != syncJournalSchemaVersion) {
        throw FormatException(
          'unsupported sync journal schema version $version in $path',
        );
      }
      switch (decoded['type']) {
        case 'header':
          record = _recordFromJson(decoded);
          journal = SyncRunJournal._(path, record);
        case 'item':
          journal?.items.add(_itemFromJson(decoded));
        case 'trash':
          journal?.trashLines.add(_trashFromJson(decoded));
        case 'remove':
          journal?.removeLines.add(_removeFromJson(decoded));
        case 'rmdir':
          journal?.rmdirLines.add(_rmdirFromJson(decoded));
        case 'summary':
          journal?.summary = _summaryFromJson(decoded);
        case 'purged':
          journal?.purged = true;
        default:
          // Unknown line kinds are skipped so a newer writer never
          // wedges an older reader's restore path.
          break;
      }
    }
    if (record == null || journal == null) {
      throw FormatException('sync journal at $path has no header line');
    }
    return journal;
  }

  /// The highest attempt number journaled for one
  /// (relativePath, side, action) key — `Retry Failed` journals the
  /// re-execution at attempt n+1 (05 §11's uniqueness contract).
  int lastAttempt(String relativePath, SyncSide side, SyncActionType action) {
    var last = 0;
    for (final line in items) {
      if (line.relativePath == relativePath &&
          line.side == side &&
          line.action == action &&
          line.attempt > last) {
        last = line.attempt;
      }
    }
    return last;
  }

  Future<void> appendItem(SyncJournalItemLine line) async {
    items.add(line);
    await _append(<String, Object?>{
      'type': 'item',
      'path': line.relativePath,
      'side': line.side.name,
      'action': line.action.name,
      'outcome': line.outcome.name,
      'attempt': line.attempt,
      'bytes': line.bytes,
      'durationMs': line.durationMs,
      'userOverridden': line.userOverridden,
      if (line.trashLocation != null) 'trashLocation': line.trashLocation,
      if (line.trashBytes != null) 'trashBytes': line.trashBytes,
      if (line.trashContentSha256 != null)
        'trashContentSha256': line.trashContentSha256,
      if (line.observedMtimeAfterWrite != null)
        'observedMtimeAfterWrite': line.observedMtimeAfterWrite,
      if (line.setstatIgnored) 'setstatIgnored': true,
      if (line.error != null) 'error': line.error,
    });
  }

  Future<void> appendTrash(SyncJournalTrashLine line) async {
    trashLines.add(line);
    await _append(<String, Object?>{
      'type': 'trash',
      'parent': line.parentPath,
      'path': line.relativePath,
      'side': line.side.name,
      'trashLocation': line.trashLocation,
      'bytes': line.bytes,
      if (line.trashContentSha256 != null)
        'trashContentSha256': line.trashContentSha256,
    });
  }

  Future<void> appendRemove(SyncJournalRemoveLine line) async {
    removeLines.add(line);
    await _append(<String, Object?>{
      'type': 'remove',
      'parent': line.parentPath,
      'path': line.relativePath,
      'side': line.side.name,
      'bytes': line.bytes,
    });
  }

  Future<void> appendRmdir(SyncJournalRmdirLine line) async {
    rmdirLines.add(line);
    await _append(<String, Object?>{
      'type': 'rmdir',
      'path': line.relativePath,
      'side': line.side.name,
      'parent': line.parentPath,
    });
  }

  Future<void> appendSummary(SyncJournalSummary value) async {
    summary = value;
    await _append(<String, Object?>{
      'type': 'summary',
      'counts': {
        for (final entry in value.counts.entries) entry.key.name: entry.value,
      },
      'bytesTransferred': value.bytesTransferred,
      'cancelled': value.cancelled,
      'mtimeUnreliableLeft': value.mtimeUnreliableLeft,
      'mtimeUnreliableRight': value.mtimeUnreliableRight,
    });
  }

  /// Rail 5's purge marker — releases the journal for pruning and makes
  /// the retention exception locally evaluable.
  Future<void> markPurged() async {
    purged = true;
    await _append(const <String, Object?>{'type': 'purged'});
  }

  /// Appends one complete line with an immediate flush. A fresh open
  /// per append is deliberate (03 §4.6's pattern): no userspace
  /// buffering, so a kill loses at most the line it was mid-writing.
  Future<void> _append(Map<String, Object?> fields) {
    final line = jsonEncode(<String, Object?>{
      'v': syncJournalSchemaVersion,
      ...fields,
    });
    return _file.writeAsString('$line\n', mode: FileMode.append);
  }

  /// Prunes [syncRunsDirectory] to the newest [keep] journals per pair —
  /// except any journal still guarding live trash (trash entries, no
  /// `purged` marker), which is retained no matter its age (05 §8
  /// rail 9's locally-evaluable exception). Unparseable files are left
  /// alone.
  static Future<void> prune(
    String syncRunsDirectory,
    String pairId, {
    int keep = syncJournalRetention,
  }) async {
    final directory = Directory(syncRunsDirectory);
    if (!await directory.exists()) return;
    final journals = <SyncRunJournal>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
      try {
        final journal = await open(entity.path);
        if (journal.record.pairId == pairId) journals.add(journal);
      } on Object {
        // A foreign or corrupt file is never prunable by pattern.
        continue;
      }
    }
    journals.sort(
      (a, b) => a.record.startedAt.compareTo(b.record.startedAt),
    );
    // Live-trash journals are exempt from the cap entirely — the
    // newest `keep` applies only to the prunable population.
    final prunable =
        journals.where((j) => !j.hasUnpurgedTrash).length - keep;
    if (prunable <= 0) return;
    var removed = 0;
    for (final journal in journals) {
      if (removed >= prunable) break;
      if (journal.hasUnpurgedTrash) continue;
      try {
        await File(journal.path).delete();
        removed++;
      } on Object {
        // Best-effort hygiene — a stubborn file retries next run.
      }
    }
  }
}

/// One entry the restore path must put back.
final class _TrashedEntry {
  _TrashedEntry({
    required this.relativePath,
    required this.side,
    required this.trashLocation,
    required this.bytes,
    required this.sha256,
    required this.parentPath,
  });

  final String relativePath;
  final SyncSide side;
  final String trashLocation;
  final int bytes;
  final String? sha256;
  final String parentPath;
}

/// One restore outcome line for a skipped entry — the path and why.
final class SyncRestoreSkip {
  const SyncRestoreSkip(this.relativePath, this.reason);

  final String relativePath;
  final String reason;
}

/// The result of `Restore Trashed Files…` (05 §8 rail 9).
final class SyncRestoreReport {
  const SyncRestoreReport({required this.restored, required this.skipped});

  /// Origins successfully restored.
  final List<String> restored;

  /// Entries skipped with reasons — post-state changed, a truncated
  /// copy-fallback trash entry, or a blocked parent chain.
  final List<SyncRestoreSkip> skipped;
}

/// `Restore Trashed Files…` (05 §8 rail 9): reverses the recorded
/// renames for every trashed/backed-up file in [journal], restoring
/// each to its origin — after a per-file conflict check against the
/// run's recorded post-state, never the pre-run snapshot. A destination
/// that no longer matches is skipped and listed; Undo never overwrites
/// newer changes. `fsFor`/`rootFor` resolve each side's filesystem and
/// canonical sync root.
Future<SyncRestoreReport> restoreTrashedFiles(
  SyncRunJournal journal, {
  required RemoteFileSystem Function(SyncSide side) fsFor,
  required String Function(SyncSide side) rootFor,
}) async {
  // The recorded post-state for every path the run created or updated:
  // size + observedMtimeAfterWrite for files. Deletions expect absence.
  final created = <String, SyncJournalItemLine>{};
  for (final line in journal.items) {
    switch (line.action) {
      case SyncActionType.copyLeftToRight ||
          SyncActionType.copyRightToLeft ||
          SyncActionType.updateLeftToRight ||
          SyncActionType.updateRightToLeft ||
          SyncActionType.makeDirLeft ||
          SyncActionType.makeDirRight:
        if (line.outcome == SyncItemStatus.done) {
          created['${line.side.name}:${line.relativePath}'] = line;
        }
      default:
        break;
    }
  }

  final trashed = <_TrashedEntry>[
    for (final line in journal.items)
      if (line.trashLocation != null)
        _TrashedEntry(
          relativePath: line.relativePath,
          side: line.side,
          trashLocation: line.trashLocation!,
          bytes: line.trashBytes ?? line.bytes,
          sha256: line.trashContentSha256,
          parentPath: line.relativePath,
        ),
    for (final line in journal.trashLines)
      _TrashedEntry(
        relativePath: line.relativePath,
        side: line.side,
        trashLocation: line.trashLocation,
        bytes: line.bytes,
        sha256: line.trashContentSha256,
        parentPath: line.parentPath,
      ),
  ];

  final restored = <String>[];
  final skipped = <SyncRestoreSkip>[];

  /// One decision per rule-4 replace parent: null = the replacement
  /// entry was verified against its post-state and removed; a reason
  /// = every child line under it is skipped (a created directory's
  /// post-state is its whole recorded set — any member that no longer
  /// matches skips the replace revert as a unit).
  final parentDecisions = <String, String?>{};

  for (final entry in trashed) {
    final fs = fsFor(entry.side);
    final root = rootFor(entry.side);
    final origin = remoteJoin(root, entry.relativePath);
    final outcome = await _restoreOne(
      journal: journal,
      entry: entry,
      fs: fs,
      root: root,
      origin: origin,
      created: created,
      parentDecisions: parentDecisions,
    );
    if (outcome == null) {
      restored.add(entry.relativePath);
    } else {
      skipped.add(SyncRestoreSkip(entry.relativePath, outcome));
    }
  }

  // Directories emptied and rmdir'd by the run that hold no restored
  // file — recreate them shallowest-first. EEXIST is fine; a path now
  // occupied by a file stays reported via its children's skips.
  final emptiedDirs = journal.rmdirLines.toList()
    ..sort(
      (a, b) =>
          a.relativePath.split('/').length -
          b.relativePath.split('/').length,
    );
  for (final line in emptiedDirs) {
    final fs = fsFor(line.side);
    final abs = remoteJoin(rootFor(line.side), line.relativePath);
    if (await _statOrNull(fs, abs) != null) continue;
    try {
      await fs.createDirectory(abs);
    } on RemoteFileException {
      // Best-effort — an unplaceable level leaves its children skipped.
    }
  }
  return SyncRestoreReport(
    restored: List.unmodifiable(restored),
    skipped: List.unmodifiable(skipped),
  );
}

/// Restores one trashed entry; returns null on success or the skip
/// reason. [parentDecisions] carries each replace parent's revert
/// outcome so its per-file trash lines share one decision.
Future<String?> _restoreOne({
  required SyncRunJournal journal,
  required _TrashedEntry entry,
  required RemoteFileSystem fs,
  required String root,
  required String origin,
  required Map<String, SyncJournalItemLine> created,
  required Map<String, String?> parentDecisions,
}) async {
  // Verify the trashed entry itself: size always; the recorded digest
  // for copy-fallback entries (05 §8 rail 9 — a rename cannot
  // truncate, an interrupted copy can, and Undo must never resurrect a
  // truncated "previous version" over a good file).
  final RemoteFileEntry trashedEntry;
  try {
    trashedEntry = await fs.stat(entry.trashLocation, followLinks: false);
  } on RemoteFileException catch (error) {
    return error.kind == RemoteFileErrorKind.notFound
        ? 'the trashed copy is gone'
        : 'could not inspect the trashed copy: ${error.message}';
  }
  if (trashedEntry.size != entry.bytes) {
    return 'the trashed copy changed size since the run';
  }
  final expectedHash = entry.sha256;
  if (expectedHash != null) {
    final digest = await _hashFile(fs, entry.trashLocation);
    if (digest != expectedHash) {
      return 'the trashed copy is truncated or changed';
    }
  }

  if (entry.parentPath != entry.relativePath) {
    // A file a rule-4 pre-delete removed: the run's replacement entry
    // at parentPath must still match its recorded post-state before it
    // is removed and the original tree rebuilt.
    final parentKey = '${entry.side.name}:${entry.parentPath}';
    if (!parentDecisions.containsKey(parentKey)) {
      parentDecisions[parentKey] = await _clearReplaceParent(
        journal: journal,
        side: entry.side,
        parentRelativePath: entry.parentPath,
        fs: fs,
        root: root,
        created: created,
      );
    }
    final decision = parentDecisions[parentKey];
    if (decision != null) return decision;
  } else {
    // Conflict-check the destination against the run's recorded
    // post-state, then clear it: absent for a deletion, the written
    // file's size + observedMtimeAfterWrite for an update or a
    // same-path replace.
    final clearError = await _clearOwnPostState(
      entry: entry,
      fs: fs,
      origin: origin,
      createdLine: created['${entry.side.name}:${entry.relativePath}'],
      created: created,
      journal: journal,
    );
    if (clearError != null) return clearError;
  }

  // Recreate the origin's directory chain shallowest-first; a chain
  // level now occupied by a file makes the child unplaceable — Undo
  // never overwrites what took the directory's place.
  final chainError = await _ensureChain(fs, root, entry.relativePath);
  if (chainError != null) return chainError;

  try {
    await fs.rename(entry.trashLocation, origin);
  } on RemoteFileException catch (error) {
    return 'could not move the trashed copy back: ${error.message}';
  }
  return null;
}

/// Confirms the live entry at [origin] still matches the run's recorded
/// post-state for a self-path trash entry (deletion, update backup, or
/// same-path single-file replace) and removes it so the trashed
/// original can return. A mismatch is reported, never overwritten.
Future<String?> _clearOwnPostState({
  required _TrashedEntry entry,
  required RemoteFileSystem fs,
  required String origin,
  required SyncJournalItemLine? createdLine,
  required Map<String, SyncJournalItemLine> created,
  required SyncRunJournal journal,
}) async {
  final live = await _statOrNull(fs, origin);
  if (createdLine == null) {
    // A deletion's post-state is absence — anything present now is
    // newer work Undo must not touch.
    if (live != null) {
      return '"${entry.relativePath}" exists again and was changed '
          'since the run';
    }
    return null;
  }
  return _clearCreated(
    entry: entry,
    fs: fs,
    live: live,
    createdLine: createdLine,
    created: created,
    journal: journal,
    displayPath: entry.relativePath,
  );
}

/// Verifies the run-created entry at [parentRelativePath] against its
/// recorded post-state and removes it (file → delete; directory → the
/// whole recorded entry set, per 05 §8 rail 9). Returns the skip
/// reason shared by every child trash line, or null when the parent
/// cleared.
Future<String?> _clearReplaceParent({
  required SyncRunJournal journal,
  required SyncSide side,
  required String parentRelativePath,
  required RemoteFileSystem fs,
  required String root,
  required Map<String, SyncJournalItemLine> created,
}) async {
  final createdLine = created['${side.name}:$parentRelativePath'];
  if (createdLine == null) {
    // A pre-delete parent always journaled its creation — a missing
    // line means the journal itself diverged; refuse the revert.
    return 'the replacement for "$parentRelativePath" is not journaled';
  }
  final live = await _statOrNull(fs, remoteJoin(root, parentRelativePath));
  final probe = _TrashedEntry(
    relativePath: parentRelativePath,
    side: SyncSide.left, // unused by _clearCreated's messages
    trashLocation: '',
    bytes: 0,
    sha256: null,
    parentPath: parentRelativePath,
  );
  return _clearCreated(
    entry: probe,
    fs: fs,
    live: live,
    createdLine: createdLine,
    created: created,
    journal: journal,
    displayPath: parentRelativePath,
  );
}

/// The shared post-state check for a run-created entry: file → size +
/// observedMtimeAfterWrite; directory → the recorded end-of-run entry
/// set. Removes the entry once verified.
Future<String?> _clearCreated({
  required _TrashedEntry entry,
  required RemoteFileSystem fs,
  required RemoteFileEntry? live,
  required SyncJournalItemLine createdLine,
  required Map<String, SyncJournalItemLine> created,
  required SyncRunJournal journal,
  required String displayPath,
}) async {
  if (live == null) {
    return '"$displayPath" is missing since the run';
  }
  switch (createdLine.action) {
    case SyncActionType.makeDirLeft || SyncActionType.makeDirRight:
      // A rule-4 replace that created a directory: the recorded
      // post-state is its end-of-run entry set. Verify the whole set,
      // then remove entry+set, then the caller's chain recreation and
      // reverse renames restore the original tree.
      if (!live.isDirectory) {
        return '"$displayPath" changed since the run';
      }
      final mismatch = await _dirPostStateMismatch(
        created,
        live,
        fs,
        createdLine.side,
        displayPath,
      );
      if (mismatch != null) return mismatch;
      await _removeCreatedTree(fs, live);
      return null;
    default:
      // Update/copy replace: the written file must still match its
      // recorded size + observed mtime.
      if (live.type != RemoteFileType.file ||
          live.size != createdLine.bytes ||
          _seconds(live.modifiedAt) != createdLine.observedMtimeAfterWrite) {
        return '"$displayPath" changed since the run';
      }
      await fs.delete(live);
      return null;
  }
}

/// Whether the created directory's live contents diverge from the
/// run's recorded end-of-run entry set — any file that no longer
/// matches its post-state, or anything present the run did not
/// record, skips the whole revert (05 §8 rail 9).
Future<String?> _dirPostStateMismatch(
  Map<String, SyncJournalItemLine> created,
  RemoteFileEntry live,
  RemoteFileSystem fs,
  SyncSide side,
  String relativePath,
) async {
  final prefix = '$relativePath/';
  final expected = <String, SyncJournalItemLine>{
    for (final e in created.entries)
      if (e.key.startsWith('${side.name}:$prefix'))
        e.key.substring(side.name.length + 1): e.value,
  };
  final liveEntries = <String, RemoteFileEntry>{};
  final queue = <String>[live.path];
  while (queue.isNotEmpty) {
    final dir = queue.removeLast();
    final List<RemoteFileEntry> listing;
    try {
      listing = await fs.listDirectory(dir);
    } on RemoteFileException catch (error) {
      return 'could not list "$relativePath": ${error.message}';
    }
    for (final child in listing) {
      final relative = child.path.substring(
        live.path.length - relativePath.length,
      );
      liveEntries[relative] = child;
      if (child.isDirectory) queue.add(child.path);
    }
  }
  for (final expectedEntry in expected.entries) {
    final liveChild = liveEntries[expectedEntry.key];
    if (liveChild == null) {
      return '"${expectedEntry.key}" is missing since the run';
    }
    final line = expectedEntry.value;
    final isDirAction =
        line.action == SyncActionType.makeDirLeft ||
        line.action == SyncActionType.makeDirRight;
    if (isDirAction) {
      if (!liveChild.isDirectory) {
        return '"${expectedEntry.key}" changed kind since the run';
      }
    } else if (liveChild.type != RemoteFileType.file ||
        liveChild.size != line.bytes ||
        _seconds(liveChild.modifiedAt) != line.observedMtimeAfterWrite) {
      return '"${expectedEntry.key}" changed since the run';
    }
  }
  for (final path in liveEntries.keys) {
    if (!expected.containsKey(path)) {
      return '"$path" is new since the run';
    }
  }
  return null;
}

/// Removes a verified created directory together with its recorded
/// entry set — the one place v1 undo removes run-created copies
/// (05 §8 rail 9).
Future<void> _removeCreatedTree(
  RemoteFileSystem fs,
  RemoteFileEntry live,
) async {
  final entries = await fs.listDirectory(live.path);
  for (final child in entries) {
    if (child.isDirectory) {
      await _removeCreatedTree(fs, child);
    } else {
      await fs.delete(child);
    }
  }
  await fs.delete(live);
}

/// Recreates every missing ancestor of [relativePath] under [root],
/// shallowest-first. A missing level is created; an existing directory
/// is fine (EEXIST-tolerant per 05 §8 rail 9); a file in the chain
/// blocks the restore.
Future<String?> _ensureChain(
  RemoteFileSystem fs,
  String root,
  String relativePath,
) async {
  final segments = relativePath.split('/');
  var current = root;
  for (var i = 0; i < segments.length - 1; i++) {
    current = remoteJoin(current, segments[i]);
    final existing = await _statOrNull(fs, current);
    if (existing == null) {
      try {
        await fs.createDirectory(current);
      } on RemoteFileException catch (error) {
        if (error.kind != RemoteFileErrorKind.conflict) {
          return 'could not recreate "${segments.take(i + 1).join('/')}"'
              ': ${error.message}';
        }
        // EEXIST is success — something recreated the level already.
      }
      continue;
    }
    if (!existing.isDirectory) {
      return '"${segments.take(i + 1).join('/')}" is a file now; '
          'cannot restore inside it';
    }
  }
  return null;
}

Future<RemoteFileEntry?> _statOrNull(
  RemoteFileSystem fs,
  String path,
) async {
  try {
    return await fs.stat(path, followLinks: false);
  } on RemoteFileException catch (error) {
    if (error.kind == RemoteFileErrorKind.notFound) return null;
    rethrow;
  }
}

/// Streams a file through the VFS's own hashing download and returns
/// its digest — the restore-side verify for copy-fallback trash
/// entries.
Future<String?> _hashFile(RemoteFileSystem fs, String path) async {
  final sink = _HashNullSink();
  final entry = await fs.download(path, sink);
  return entry.contentSha256;
}

final class _HashNullSink implements StreamSink<List<int>> {
  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();
}

int? _seconds(DateTime? time) =>
    time == null ? null : time.millisecondsSinceEpoch ~/ 1000;

// ── Serialization ──────────────────────────────────────────────────────

Map<String, Object?> _recordToJson(SyncRunRecord record) =>
    <String, Object?>{
      'runId': record.runId,
      'pairId': record.pairId,
      'startedAt': record.startedAt.toIso8601String(),
      'rules': _rulesToJson(record.rules),
      'totals': _totalsToJson(record.totals),
      'warnings': [
        for (final warning in record.warnings)
          <String, Object?>{
            'path': warning.relativePath,
            'side': warning.side.name,
            'message': warning.message,
          },
      ],
    };

SyncRunRecord _recordFromJson(Map<String, Object?> json) => SyncRunRecord(
  runId: json['runId']! as String,
  pairId: json['pairId']! as String,
  startedAt: DateTime.parse(json['startedAt']! as String),
  rules: _rulesFromJson(json['rules']! as Map<String, Object?>),
  totals: _totalsFromJson(json['totals']! as Map<String, Object?>),
  warnings: [
    for (final warning in json['warnings']! as List<Object?>)
      ScanWarning(
        relativePath:
            (warning! as Map<String, Object?>)['path']! as String,
        side: SyncSide.values.byName(
          (warning as Map<String, Object?>)['side']! as String,
        ),
        message: warning['message']! as String,
      ),
  ],
);

Map<String, Object?> _rulesToJson(SyncRuleSet rules) => <String, Object?>{
  'direction': rules.direction.name,
  'deletions': rules.deletions.name,
  'backups': rules.backups.name,
  'comparison': rules.comparison.name,
  'mtimeToleranceSecs': rules.mtimeToleranceSecs,
  'acceptedTimeShifts': rules.acceptedTimeShifts,
  'conflictDefault': rules.conflictDefault.name,
  'excludeGlobs': rules.excludeGlobs,
  'includeHidden': rules.includeHidden,
  'symlinks': rules.symlinks.name,
  'trashPathLeft': rules.trashPathLeft,
  'trashPathRight': rules.trashPathRight,
  'maxDelete': rules.maxDelete,
  'deleteFractionWarn': rules.deleteFractionWarn,
  'preserveMtime': rules.preserveMtime,
  'transferConcurrency': rules.transferConcurrency,
};

SyncRuleSet _rulesFromJson(Map<String, Object?> json) => SyncRuleSet(
  direction: SyncDirection.values.byName(json['direction']! as String),
  deletions: DeletionPolicy.values.byName(json['deletions']! as String),
  backups: BackupPolicy.values.byName(json['backups']! as String),
  comparison: ComparisonMode.values.byName(json['comparison']! as String),
  mtimeToleranceSecs: json['mtimeToleranceSecs']! as int,
  acceptedTimeShifts: [
    for (final value in json['acceptedTimeShifts']! as List<Object?>)
      value! as int,
  ],
  conflictDefault: ConflictDefault.values.byName(
    json['conflictDefault']! as String,
  ),
  excludeGlobs: [
    for (final value in json['excludeGlobs']! as List<Object?>)
      value! as String,
  ],
  includeHidden: json['includeHidden']! as bool,
  symlinks: SymlinkPolicy.values.byName(json['symlinks']! as String),
  trashPathLeft: json['trashPathLeft'] as String?,
  trashPathRight: json['trashPathRight'] as String?,
  maxDelete: json['maxDelete']! as int,
  deleteFractionWarn: json['deleteFractionWarn']! as double,
  preserveMtime: json['preserveMtime']! as bool,
  transferConcurrency: json['transferConcurrency']! as int,
);

Map<String, Object?> _totalsToJson(PlanTotals totals) => <String, Object?>{
  'counts': {
    for (final entry in totals.counts.entries) entry.key.name: entry.value,
  },
  'bytes': {
    for (final entry in totals.bytes.entries) entry.key.name: entry.value,
  },
  'replacedFiles': totals.replacedFiles,
  'replacedBytes': totals.replacedBytes,
};

PlanTotals _totalsFromJson(Map<String, Object?> json) => PlanTotals(
  counts: {
    for (final entry
        in (json['counts']! as Map<String, Object?>).entries)
      SyncActionType.values.byName(entry.key): entry.value! as int,
  },
  bytes: {
    for (final entry in (json['bytes']! as Map<String, Object?>).entries)
      SyncActionType.values.byName(entry.key): entry.value! as int,
  },
  replacedFiles: json['replacedFiles']! as int,
  replacedBytes: json['replacedBytes']! as int,
);

SyncJournalItemLine _itemFromJson(Map<String, Object?> json) =>
    SyncJournalItemLine(
      relativePath: json['path']! as String,
      side: SyncSide.values.byName(json['side']! as String),
      action: SyncActionType.values.byName(json['action']! as String),
      outcome: SyncItemStatus.values.byName(json['outcome']! as String),
      attempt: json['attempt']! as int,
      bytes: json['bytes']! as int,
      durationMs: json['durationMs']! as int,
      userOverridden: json['userOverridden']! as bool,
      trashLocation: json['trashLocation'] as String?,
      trashBytes: json['trashBytes'] as int?,
      trashContentSha256: json['trashContentSha256'] as String?,
      observedMtimeAfterWrite: json['observedMtimeAfterWrite'] as int?,
      setstatIgnored: json['setstatIgnored'] == true,
      error: json['error'] as String?,
    );

SyncJournalTrashLine _trashFromJson(Map<String, Object?> json) =>
    SyncJournalTrashLine(
      parentPath: json['parent']! as String,
      relativePath: json['path']! as String,
      side: SyncSide.values.byName(json['side']! as String),
      trashLocation: json['trashLocation']! as String,
      bytes: json['bytes']! as int,
      trashContentSha256: json['trashContentSha256'] as String?,
    );

SyncJournalRemoveLine _removeFromJson(Map<String, Object?> json) =>
    SyncJournalRemoveLine(
      parentPath: json['parent']! as String,
      relativePath: json['path']! as String,
      side: SyncSide.values.byName(json['side']! as String),
      bytes: json['bytes']! as int,
    );

SyncJournalRmdirLine _rmdirFromJson(Map<String, Object?> json) =>
    SyncJournalRmdirLine(
      relativePath: json['path']! as String,
      side: SyncSide.values.byName(json['side']! as String),
      parentPath: json['parent']! as String,
    );

SyncJournalSummary _summaryFromJson(Map<String, Object?> json) =>
    SyncJournalSummary(
      counts: {
        for (final entry
            in (json['counts']! as Map<String, Object?>).entries)
          SyncItemStatus.values.byName(entry.key): entry.value! as int,
      },
      bytesTransferred: json['bytesTransferred']! as int,
      cancelled: json['cancelled']! as bool,
      mtimeUnreliableLeft: json['mtimeUnreliableLeft']! as bool,
      mtimeUnreliableRight: json['mtimeUnreliableRight']! as bool,
    );
