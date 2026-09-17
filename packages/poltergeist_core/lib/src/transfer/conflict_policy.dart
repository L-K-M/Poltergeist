/// 02 §5.2's conflict model — the settings-level per-direction/per-kind
/// matrix, the pure decision function the executor resolves collisions
/// through, and the pending-conflict record the future UI renders
/// (03 §4.1's ask-park, §5's `EnginePromptKind.conflict` seam).
///
/// Everything in this file is metadata-in/metadata-out: no VFS calls, no
/// queue state. The executor re-stats the destination at commit time and
/// calls [resolveTransferConflict] against that fresh reality — the
/// scan-time `existing` on a plan entry stays a UI hint, never the
/// decision basis (03 §4.2).
library;

import 'package:seance_core/seance_core.dart';

import 'transfer_task.dart';

/// The mtime comparison window (02 §5.2, D6's ±2 s rule): SFTP v3
/// truncates mtimes to whole seconds, cross-machine clocks skew, and
/// FAT-class filesystems quantize to 2 s — an exact comparison would
/// silently invert under drift, so "newer" means newer by MORE than this.
const conflictMtimeTolerance = Duration(seconds: 2);

/// 02 §5.2's per-direction/per-kind defaults matrix (Transmit's matrix,
/// verbatim). `merge` is valid only in the `*Folders` fields — file
/// fields normalize it to `ask` at construction and on decode, the same
/// constraint [ResolvedConflictPolicy] enforces per task.
class ConflictPolicy {
  ConflictPolicy({
    ConflictResolution uploadFiles = ConflictResolution.ask,
    this.uploadFolders = ConflictResolution.ask,
    ConflictResolution downloadFiles = ConflictResolution.ask,
    this.downloadFolders = ConflictResolution.ask,
    ConflictResolution localFiles = ConflictResolution.ask,
    this.localFolders = ConflictResolution.ask,
    ConflictResolution remoteToRemoteFiles = ConflictResolution.ask,
    this.remoteToRemoteFolders = ConflictResolution.ask,
  }) : uploadFiles = _fileVerb(uploadFiles),
       downloadFiles = _fileVerb(downloadFiles),
       localFiles = _fileVerb(localFiles),
       remoteToRemoteFiles = _fileVerb(remoteToRemoteFiles);

  /// local→remote transfers (and external sources onto a remote pane —
  /// the bucket follows the destination, 02 §5.2).
  final ConflictResolution uploadFiles;
  final ConflictResolution uploadFolders;

  /// remote→local transfers (`Download to…` included).
  final ConflictResolution downloadFiles;
  final ConflictResolution downloadFolders;

  /// Both endpoints local: pane↔pane copies/moves and external sources
  /// (OS drop-in, cross-app paste) onto a local pane.
  final ConflictResolution localFiles;
  final ConflictResolution localFolders;

  /// remote→remote: cross-server pipes and same-server server-side moves
  /// share one bucket (02 §5.2 — one bucket covers both mechanisms).
  final ConflictResolution remoteToRemoteFiles;
  final ConflictResolution remoteToRemoteFolders;

  static ConflictResolution _fileVerb(ConflictResolution verb) =>
      verb == ConflictResolution.merge ? ConflictResolution.ask : verb;

  /// Resolves the direction pair into the per-task policy the queue
  /// consumes at enqueue time (03 §4.1's one-bucket-pair-per-task rule).
  /// Every direction that can collide maps to exactly one bucket.
  ResolvedConflictPolicy policyFor(
    FsLocation source,
    FsLocation destination,
  ) {
    final sourceRemote = source is ServerFsLocation;
    final destinationRemote = destination is ServerFsLocation;
    if (sourceRemote && destinationRemote) {
      return ResolvedConflictPolicy(
        files: remoteToRemoteFiles,
        folders: remoteToRemoteFolders,
      );
    }
    if (destinationRemote) {
      return ResolvedConflictPolicy(
        files: uploadFiles,
        folders: uploadFolders,
      );
    }
    if (sourceRemote) {
      return ResolvedConflictPolicy(
        files: downloadFiles,
        folders: downloadFolders,
      );
    }
    return ResolvedConflictPolicy(files: localFiles, folders: localFolders);
  }

  /// The persisted settings shape (settings.json's conflict matrix —
  /// enums by name, never booleans). Unknown strings and `merge` in a
  /// file field decode to `ask` per 02 §5.2's settings rule: load/save
  /// rejects `merge` outside the folder fields by falling back.
  Map<String, Object?> toJson() => {
    'uploadFiles': uploadFiles.name,
    'uploadFolders': uploadFolders.name,
    'downloadFiles': downloadFiles.name,
    'downloadFolders': downloadFolders.name,
    'localFiles': localFiles.name,
    'localFolders': localFolders.name,
    'remoteToRemoteFiles': remoteToRemoteFiles.name,
    'remoteToRemoteFolders': remoteToRemoteFolders.name,
  };

  factory ConflictPolicy.fromJson(Map<String, Object?> json) =>
      ConflictPolicy(
        uploadFiles: _decodeVerb(json['uploadFiles']),
        uploadFolders: _decodeVerb(json['uploadFolders']),
        downloadFiles: _decodeVerb(json['downloadFiles']),
        downloadFolders: _decodeVerb(json['downloadFolders']),
        localFiles: _decodeVerb(json['localFiles']),
        localFolders: _decodeVerb(json['localFolders']),
        remoteToRemoteFiles: _decodeVerb(json['remoteToRemoteFiles']),
        remoteToRemoteFolders: _decodeVerb(json['remoteToRemoteFolders']),
      );

  /// Absent or unrecognized values fall back to `ask` — a hand-edited or
  /// forward-versioned settings file degrades to prompting, never to a
  /// silent overwrite (the same posture the journal's strict decode takes
  /// for corruption: never guess a destructive default).
  static ConflictResolution _decodeVerb(Object? value) {
    if (value is! String) return ConflictResolution.ask;
    for (final verb in ConflictResolution.values) {
      if (verb.name == value) return verb;
    }
    return ConflictResolution.ask;
  }
}

/// What a resolved collision should do — the executor's typed answer to
/// "the destination path is occupied". `proceed`/`replace`/`skip`/
/// `keepBoth`/`merge` are the executable outcomes; [ConflictAsk] is the
/// park-and-prompt outcome 03 §4.1 routes through the conflict seam.
sealed class ConflictDisposition {
  const ConflictDisposition();
}

/// No occupant (or a verb that does not consult one) — commit at the
/// planned path with `overwrite: false`.
final class ConflictProceed extends ConflictDisposition {
  const ConflictProceed();
}

/// Overwrite the destination. [existing] is the stat the commit pins as
/// `expectedTarget`; [removesOccupant] marks the cases the copy cannot
/// satisfy alone — a kind mismatch, or dir→dir wholesale replace — which
/// route through the D15 delete story before the entry lands.
final class ConflictReplace extends ConflictDisposition {
  const ConflictReplace({
    required this.existing,
    required this.removesOccupant,
  });

  final DestinationStat existing;
  final bool removesOccupant;
}

/// Leave the destination; the item ends `skipped` (02 §5.2: continue the
/// task; a move leaves its source untouched).
final class ConflictSkip extends ConflictDisposition {
  const ConflictSkip(this.reason);

  /// The user-facing detail (e.g. 'the destination is not older').
  final String reason;
}

/// Commit under the first free `name (n)` target — the candidate loop
/// (stat-check + registry check per number) lives in the executor; this
/// disposition only elects the verb.
final class ConflictKeepBoth extends ConflictDisposition {
  const ConflictKeepBoth();
}

/// Folders only: the directory resolves to its existing destination
/// (stat-else-mkdir) and children recurse under the task's file policy —
/// 02 §5.2's "recurse, resolving per-file conflicts by the file policy".
final class ConflictMerge extends ConflictDisposition {
  const ConflictMerge();
}

/// No policy covers this collision — park the item and surface a
/// [PendingConflict] for a resolution answer (03 §4.1's ask-park). Also
/// the fallback for `merge` where recursion is impossible (a directory
/// planned onto a non-directory occupant).
final class ConflictAsk extends ConflictDisposition {
  const ConflictAsk();
}

/// The pure decision function behind every destination collision
/// (02 §5.2's verb semantics at the DECISION level — execution detail
/// like keep-both numbering or the merge recursion lives in the queue).
///
/// [verb] is the effective policy for this item's kind (the resolved
/// per-task policy, possibly narrowed by a prior answer or the
/// apply-to-all scope); [existing] is the fresh destination stat, null
/// when absent; [sourceModifiedAt] feeds replace-if-newer. Size never
/// participates — §5.2 compares mtime only.
ConflictDisposition resolveTransferConflict({
  required ConflictResolution verb,
  required bool sourceIsDirectory,
  required DestinationStat? existing,
  DateTime? sourceModifiedAt,
}) {
  if (existing == null) return const ConflictProceed();
  final occupantIsDirectory = existing.isDirectory;
  switch (verb) {
    case ConflictResolution.ask:
      return const ConflictAsk();
    case ConflictResolution.skip:
      return const ConflictSkip('the destination already exists');
    case ConflictResolution.keepBoth:
      return const ConflictKeepBoth();
    case ConflictResolution.replace:
      // File onto file overwrites in place; every other shape needs the
      // occupant gone first — a directory's subtree (wholesale replace)
      // or a kind mismatch — which is the D15 delete story's job.
      return ConflictReplace(
        existing: existing,
        removesOccupant: sourceIsDirectory || occupantIsDirectory,
      );
    case ConflictResolution.replaceIfNewer:
      final existingMtime = existing.modifiedAt;
      final newer =
          sourceModifiedAt != null &&
          existingMtime != null &&
          sourceModifiedAt.isAfter(
            existingMtime.add(conflictMtimeTolerance),
          );
      if (sourceIsDirectory) {
        // 03 §4.1: unknown or equal directory mtime is never "newer" —
        // directory mtimes are an unreliable freshness proxy and the
        // destructive replace they gate must not fire on a coin flip.
        // Not-newer degrades to merge — or to ask when the occupant is
        // not a directory and there is nothing to recurse into.
        if (newer) {
          return ConflictReplace(existing: existing, removesOccupant: true);
        }
        return occupantIsDirectory
            ? const ConflictMerge()
            : const ConflictAsk();
      }
      if (!newer) {
        return const ConflictSkip('the destination is not older');
      }
      return ConflictReplace(
        existing: existing,
        removesOccupant: occupantIsDirectory,
      );
    case ConflictResolution.merge:
      // Folders only, and only against a directory occupant: merging a
      // directory into a file is impossible, so §4.1 falls back to ask;
      // a file-source `merge` is a normalization leak — ask, never guess.
      if (!sourceIsDirectory || !occupantIsDirectory) {
        return const ConflictAsk();
      }
      return const ConflictMerge();
  }
}

/// `report (2).pdf` numbering (02 §5.2): the counter inserts before the
/// extension (last dot — `archive.tar.gz` becomes `archive.tar (2).gz`),
/// a leading-dot name counts as extensionless, directories never split a
/// trailing dot, and an existing ` (n)` suffix strips first so retries
/// never stack (`report (2).pdf` numbers to `report (3).pdf`, never
/// `report (2) (2).pdf`).
String numberedConflictName(
  String name,
  int attempt, {
  required bool isDirectory,
}) {
  var stem = name;
  var extension = '';
  if (!isDirectory) {
    final dot = name.lastIndexOf('.');
    if (dot > 0) {
      stem = name.substring(0, dot);
      extension = name.substring(dot);
    }
  }
  stem = stem.replaceFirst(RegExp(r' \(\d+\)$'), '');
  return '$stem ($attempt)$extension';
}

/// The task-wide policy an `apply to all remaining conflicts` answer
/// installs (02 §5.2's checkbox): the chosen verb applies per kind —
/// `merge` keeps folders merging while its file analog is `replace`
/// ("colliding files overwrite-the-match"), so a merge-scoped answer
/// never degenerates into folder-level replace, the outcome the user
/// chose merge to avoid.
ResolvedConflictPolicy taskScopePolicy(ConflictResolution verb) =>
    verb == ConflictResolution.merge
    ? ResolvedConflictPolicy(
        files: ConflictResolution.replace,
        folders: ConflictResolution.merge,
      )
    : ResolvedConflictPolicy(files: verb, folders: verb);

/// How far one resolution answer reaches (02 §5.2): [item] resolves just
/// the surfaced conflict; [task] additionally installs [taskScopePolicy]
/// as the answer for every remaining conflict in the task — the
/// "apply to all N remaining conflicts in this task" checkbox.
enum ConflictResolutionScope { item, task }

/// One parked collision, surfaced for the future conflict UI (02 §5.2's
/// dialog payload: name/size/mtime on both sides, and the verbs the item
/// may take). Plain data — it crosses the engine seam as-is.
class PendingConflict {
  PendingConflict({
    required this.taskId,
    required this.itemId,
    required this.isDirectory,
    required this.sourcePath,
    required this.destinationPath,
    required this.source,
    required this.existing,
    DateTime? queuedAt,
  }) : queuedAt = queuedAt ?? DateTime.now();

  final String taskId;

  /// The plan item's uuid — resolutions key on (taskId, itemId), never
  /// the destination path (03 §4.1's no-bare-path-keys rule).
  final String itemId;
  final bool isDirectory;
  final String sourcePath;

  /// The colliding destination path as last statted.
  final String destinationPath;

  /// The source entry as the scan saw it (name, size, mtime).
  final RemoteFileEntry source;

  /// The destination occupant as last statted — the dialog's "Existing:"
  /// side.
  final DestinationStat existing;

  final DateTime queuedAt;

  /// The verbs a reply may carry — `merge` is folders-only (02 §5.2).
  /// `ask` is the prompt, never an answer.
  List<ConflictResolution> get availableVerbs => [
    ConflictResolution.replace,
    ConflictResolution.replaceIfNewer,
    ConflictResolution.keepBoth,
    ConflictResolution.skip,
    if (isDirectory) ConflictResolution.merge,
  ];
}
