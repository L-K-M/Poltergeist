/// The transfer queue's task model (03 §4.1).
///
/// One user gesture = one task: N roots from one source filesystem into one
/// destination directory. Recursive contents ride inside the task's plan —
/// built incrementally by the scan phase (03 §4.2), which is why every plan
/// record here is plain data the scan can append to while the executor
/// already dispatches earlier entries.
library;

import 'package:seance_core/seance_core.dart';

/// The transfer verb of a task (02 §5.1). `copy` never touches the source;
/// `move` deletes each source only after its copy committed (02 §5.2's
/// per-verb source disposition — the engine, never the UI, owns it so no
/// entry point can silently degrade a move into a copy).
///
/// `delete` is the D15 destructive verb: the source entries are trashed or
/// permanently removed by the trash layer (`trash_service.dart`), in
/// post-order under the walker's delete enumeration. A delete task has no
/// transfer destination — its spec's `destination` mirrors `source` (the
/// endpoint the delete acts within) and `destinationDir` carries the
/// remote trash's run directory (remote-trash disposition) or the roots'
/// common parent (display).
enum TransferOperation { copy, move, delete }

/// The delete story's requested disposition (00 D15, 02 §2.6): the
/// standard delete prefers [trash] — OS trash locally,
/// `.poltergeist-trash/` remotely when the server opted in — and the
/// permanent shortcut (⌥⌘⌫ / Shift+Delete) asks for [permanent] and
/// carries its own confirmation.
enum DeleteDisposition { trash, permanent }

/// How one deleted item actually ended — the journal/history vocabulary.
/// `osTrash` is a local OS-trash delivery; `remoteTrash` a
/// `.poltergeist-trash/` rename; `permanent` a VFS `delete`.
enum ItemDisposition { osTrash, remoteTrash, permanent }

/// Per-task state (03 §4.1).
///
/// No task-level `skipped`: skips are per-item; a task whose every item was
/// skipped ends [completed]. There is no `cancelling` state — the sticky
/// task token trips instantly, and in-flight attempts drain asynchronously
/// into [cancelled] item outcomes.
enum TransferTaskState {
  queued,
  scanning,
  running,
  paused,
  completed,
  failed,
  cancelled,
}

/// Per-item state inside a task. `pending` covers every not-yet-dispatched
/// shape: waiting on its container directory's mkdir, on the shared
/// destination-key registry, or on a §4.3 dispatch slot — the plan's
/// "holds no slot and no leased channel" waits all read as pending here.
/// `conflictPending` is the §4.1 ask-park: the item holds no dispatch
/// slot and no lease while it waits on a resolution answer, and it is
/// non-terminal — the task cannot finish beneath it. A parked item
/// journals nothing (03 §4.4): on replay it is simply still pending and
/// re-prompts fresh on resume.
enum TransferItemState {
  pending,
  active,
  conflictPending,
  completed,
  skipped,
  failed,
  cancelled,
}

/// 02 §5.2's conflict verbs, used verbatim by the resolved per-task policy.
/// `merge` is meaningful for folders only (stat-else-mkdir and recurse);
/// [ResolvedConflictPolicy] normalizes a `merge` file field to `ask`,
/// mirroring 02 §5.2's settings constraint.
enum ConflictResolution { ask, replace, replaceIfNewer, keepBoth, skip, merge }

/// Per-task conflict policy, resolved at enqueue time from 02 §5.2's
/// canonical settings matrix (03 §4.1).
class ResolvedConflictPolicy {
  ResolvedConflictPolicy({
    ConflictResolution files = ConflictResolution.ask,
    this.folders = ConflictResolution.merge,
  }) : files = files == ConflictResolution.merge
           ? ConflictResolution.ask
           : files;

  final ConflictResolution files;
  final ConflictResolution folders;
}

/// A transfer endpoint. Sealed rather than a `{kind, serverId?}` pair so the
/// invalid states (`server` without an id, `local` carrying one) are
/// unrepresentable instead of defended at every consumer (03 §4.1).
sealed class FsLocation {
  const FsLocation();
}

/// The local filesystem — the `LocalFileSystem` half of the one VFS (D3).
final class LocalFsLocation extends FsLocation {
  const LocalFsLocation();
}

/// A remote endpoint identified by its bookmark-derived server id (03 §3.5).
final class ServerFsLocation extends FsLocation {
  final String serverId;

  const ServerFsLocation(this.serverId);
}

/// The shared read-only view of a destination entry (03 §4.1): the shape
/// both a local `FileStat` and a remote `RemoteFileEntry` populate, so a
/// plan record works for all four direction pairs.
class DestinationStat {
  final RemoteFileType type;
  final int? size;
  final DateTime? modifiedAt;

  const DestinationStat({required this.type, this.size, this.modifiedAt});

  factory DestinationStat.fromEntry(RemoteFileEntry entry) => DestinationStat(
    type: entry.type,
    size: entry.size,
    modifiedAt: entry.modifiedAt,
  );

  bool get isDirectory => type == RemoteFileType.directory;
}

/// One scanned directory, recorded parents-first (03 §4.1). The queue
/// emits a directory to the executor only after its planned parent is
/// already present — enforced at append time because the executor
/// dispatches before `scanComplete`.
class PlannedDirectory {
  PlannedDirectory({
    required this.source,
    required this.name,
    required this.containerKey,
    required this.destinationPath,
    this.existing,
    String? itemId,
  }) : itemId = itemId ?? uuidV4();

  /// Identity of this plan item (a scan-minted uuid — 03 §4.6 keys journal
  /// records on it, never on the destination path). Journal restore passes
  /// the journaled id back in so a re-scan merges onto the records the
  /// crashed scan wrote (03 §4.6's upsert rule).
  final String itemId;

  /// The source directory entry as the scan saw it.
  final RemoteFileEntry source;

  /// The leaf name this directory occupies at the destination.
  final String name;

  /// The [PlannedDirectory.itemId] of the containing planned directory, or
  /// null when this entry sits directly in the task's `destinationDir`.
  /// The executor resolves the container's *actual* path through this key
  /// so a keep-both-renamed ancestor rebases the whole subtree.
  final String? containerKey;

  /// The destination path as scanned — a display hint. The executor's
  /// conflict decision may relocate it (keep-both numbering on this
  /// directory or an ancestor).
  final String destinationPath;

  /// Destination stat at scan time; null = absent. A UI hint only — the
  /// executor re-stats and decides on the fresh stat, never this field.
  final DestinationStat? existing;
}

/// One scanned file (03 §4.1). [itemId], not [destinationPath], is the
/// record's identity — overlapping roots can plan two different source
/// files onto one destination, so a bare-path key would collapse them.
class PlannedFile {
  PlannedFile({
    required this.source,
    required this.name,
    required this.containerKey,
    required this.destinationPath,
    this.existing,
    String? itemId,
  }) : itemId = itemId ?? uuidV4();

  /// See [PlannedDirectory.itemId] — journal restore reuses the journaled
  /// id so re-scanned entries collapse onto their crashed-scan records.
  final String itemId;
  final RemoteFileEntry source;
  final String name;
  final String? containerKey;
  final String destinationPath;
  final DestinationStat? existing;
}

/// The work plan a task's scan builds incrementally (03 §4.1). Both lists
/// grow while `scanComplete` is false; the executor consumes entries as
/// they land.
class TransferPlan {
  /// Parents first — a child's planned parent always sorts earlier.
  final List<PlannedDirectory> directoriesInOrder = [];

  final List<PlannedFile> files = [];

  /// Source entries skipped because they were symbolic links — symlinks
  /// are never transferred (03 §4.2).
  int skippedSymlinks = 0;
}

/// The enqueue-time task description — plain data (03 §4.6 journals this
/// shape verbatim; no plan contents, which are runtime state).
class TransferTaskSpec {
  const TransferTaskSpec({
    required this.source,
    required this.destination,
    required this.rootPaths,
    required this.destinationDir,
    required this.policy,
    this.operation = TransferOperation.copy,
    this.disposition,
  }) : assert(
         (operation == TransferOperation.delete) == (disposition != null),
         'disposition must be set exactly when operation is delete',
       );

  final FsLocation source;
  final FsLocation destination;

  /// Absolute source paths — the roots of one user gesture. Enqueue
  /// dedupes exact duplicates and drops roots nested inside another root,
  /// so a task's destination paths are unique within the task.
  final List<String> rootPaths;

  /// Absolute path of the destination directory. For
  /// [TransferOperation.delete] this is the remote trash run directory
  /// (`<common parent>/.poltergeist-trash/<runId>`) under a `trash`
  /// disposition on a server source, else the roots' common parent for
  /// display/history.
  final String destinationDir;

  final ResolvedConflictPolicy policy;
  final TransferOperation operation;

  /// The delete story's disposition (D15): required iff [operation] is
  /// [TransferOperation.delete], null otherwise.
  final DeleteDisposition? disposition;
}

/// One queued transfer task (03 §4.1). Mutable fields are engine-owned:
/// created by `TransferQueue.enqueue`, advanced by the queue, and reported
/// through `TransferQueue.events`.
class TransferTask {
  TransferTask(this.spec)
    : id = uuidV4(),
      enqueuedAt = DateTime.now(),
      wasRestored = false;

  /// Journal restore (03 §4.6): a replayed task keeps its journaled
  /// identity so its records still key on it.
  TransferTask.restored(
    this.spec, {
    required this.id,
    required this.enqueuedAt,
  }) : wasRestored = true;

  /// `uuidV4()` from seance_protocol.
  final String id;

  /// True when this task was adopted from the journal at startup (03
  /// §4.6) — the activity panel's restored-queue banner (02 §6) keys on
  /// it, since journaled provenance is what makes "from your last
  /// session" honest.
  final bool wasRestored;

  final TransferTaskSpec spec;

  FsLocation get source => spec.source;
  FsLocation get destination => spec.destination;
  List<String> get rootPaths => spec.rootPaths;
  String get destinationDir => spec.destinationDir;
  ResolvedConflictPolicy get policy => spec.policy;
  TransferOperation get operation => spec.operation;

  final DateTime enqueuedAt;

  /// When work on the task actually started (the scan phase's launch) —
  /// the history record's `startedAt` (03 §4.6). Null until then.
  DateTime? startedAt;

  /// When the task reached a terminal state — the history record's
  /// `finishedAt`. Null while live.
  DateTime? finishedAt;

  TransferTaskState state = TransferTaskState.queued;

  /// Attached when scanning starts; the scan appends to it concurrently
  /// (03 §4.2). Null until then.
  TransferPlan? plan;

  /// Flips when the source walk finishes; [totalBytes] is final from then.
  bool scanComplete = false;

  /// The live per-item rows (directories and files), in discovery order.
  final List<TransferItem> items = [];

  /// Work-item counts discovered by the §3.5 walker so far — floors that
  /// only grow while the scan runs and are final once [scanComplete]
  /// flips (02 §5.3's `N of M+` surface). Terminal-at-scan rows (rejected
  /// names, §13-flagged entries, symlink skips) count too: they are rows
  /// the user sees.
  int totalFiles = 0;
  int totalDirectories = 0;

  int completedFiles = 0;
  int completedDirectories = 0;
  int failedItems = 0;

  /// Items that ended `skipped` — conflict-policy skips, subtree skips
  /// under a failed/skipped container, and per-item safety skips. The
  /// symlink subset is counted separately in [TransferPlan.skippedSymlinks].
  int skippedItems = 0;
  int transferredBytes = 0;

  /// Bytes discovered so far — a running total while scanning (the UI's
  /// growing `N+` form, 02 §5.3); null until the scan starts.
  int? totalBytes;

  /// 03 §3.3's reconnect-cycle counter ONLY: per-item generic failures
  /// never read or write it (03 §4.1).
  int retryCount = 0;

  /// The first failed item's user-facing message, when any.
  String? error;

  /// True while any item sits parked on an unresolved conflict (02 §5.2's
  /// "the queue pauses that item"; 03 §4.1's ask-park). The task stays
  /// `running`/`scanning` — its other items still dispatch — but it cannot
  /// reach a terminal state until every parked conflict is answered.
  bool get hasPendingConflicts =>
      items.any((item) => item.state == TransferItemState.conflictPending);

  /// The first failed item's error kind, when any.
  RemoteFileErrorKind? failureKind;

  /// Sticky token reserved for whole-task cancel (03 §4.4): each file
  /// dispatch mints its own per-attempt token so pause stays resumable —
  /// a consumed sticky token would abort every later dispatch.
  final RemoteTransferCancellation cancellation = RemoteTransferCancellation();

  bool get isTerminal =>
      state == TransferTaskState.completed ||
      state == TransferTaskState.failed ||
      state == TransferTaskState.cancelled;
}

/// One live item row inside a task — a planned file or directory plus its
/// execution state (02 §6's per-file sub-rows).
class TransferItem {
  TransferItem({
    required this.id,
    required this.sourcePath,
    required this.isDirectory,
    required this.destinationPath,
    this.size,
  });

  /// The plan item's uuid identity (03 §4.6), unique within the task.
  final String id;
  final String sourcePath;
  final bool isDirectory;

  /// The planned destination, rebased if a keep-both decision renamed an
  /// ancestor (or this item) during execution.
  String destinationPath;
  final int? size;

  TransferItemState state = TransferItemState.pending;
  int transferredBytes = 0;

  /// D15: how a completed delete item ended — os-trash delivery, a
  /// `.poltergeist-trash/` rename, or a permanent unlink. Null on
  /// copy/move items and on non-terminal items; the journal's
  /// `fileCompleted` record carries the same value.
  ItemDisposition? disposition;

  /// Item failure text — or, on a `skipped`/`completed` row, a detail
  /// worth showing (e.g. why a move's source directory stayed behind).
  String? error;
  RemoteFileErrorKind? failureKind;

  bool get isTerminal =>
      state == TransferItemState.completed ||
      state == TransferItemState.skipped ||
      state == TransferItemState.failed ||
      state == TransferItemState.cancelled;
}
