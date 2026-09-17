import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:seance_core/seance_core.dart';

import '../browse/unicode_simple_fold.dart';
import '../connection/connection_manager.dart';
import '../connection/pool_policy.dart';
import '../fs/local_file_system.dart';
import '../fs/local_fs_safety.dart';
import 'bandwidth_limiter.dart';
import 'bounded_transfer_sink.dart';
import 'conflict_policy.dart';
import 'transfer_journal.dart';
import 'transfer_task.dart';

/// The engine-side transfer queue (03 §4).
///
/// One [enqueue] call creates one [TransferTask]: the scan phase walks the
/// source incrementally and appends plan entries while the executor already
/// dispatches earlier ones — the first byte may flow before the scan
/// completes (03 §4.2), and aggregate totals grow as files are discovered
/// (02 §5.3's `12 of 34+ files` surface).
///
/// Dispatch is strict queue order (a task's files go before the next
/// task's), bounded by [PoolPolicy]'s per-server channel leases and the
/// process-wide `maxGlobalInFlightTransfers` cap (03 §4.3). Leases are
/// released deterministically on completion, cancellation, failure, and
/// dispose.
///
/// Cancellation semantics follow the pinned VFS reality (03 §4.4):
/// cancelling a task trips a sticky token that stops new work; in-flight
/// VFS reads may complete engine-side and their partial bytes are thrown
/// away; nothing wedges. Pausing a task cancels each in-flight attempt
/// with a per-attempt token — the item returns to `pending` and restarts
/// from byte zero on resume, which is why the sticky task token is
/// reserved for real cancel.
///
/// Persistence (03 §4.6) rides the [persistence] seam: when it is null
/// the queue keeps exactly the in-memory behavior above; when a store is
/// injected, lifecycle and item transitions are journaled before they
/// take effect, terminal tasks append history records, and [restore]
/// rebuilds a crashed session's queue under a forced pause.
///
/// Conflicts follow 02 §5.2's five-verb model: an `ask` (or a `merge`
/// that cannot recurse) parks the item — [TransferItemState
/// .conflictPending] — holding no dispatch slot and no lease, and
/// surfaces a [PendingConflict] through [pendingConflicts] and
/// [TransferQueueConflictEvent] until [resolveConflict] answers it.
/// Answers are session-scoped (03 §4.6: prompt state never survives
/// restart): a restored task re-dispatches the still-pending item, which
/// re-stats and re-surfaces the conflict fresh.
///
/// Deferred to later M4 slices: the D14 produce-on-demand hook, the D15
/// delete story (a `replace` that must remove an occupant fails the item
/// honestly rather than deleting unguarded), and all UI.
class TransferQueue {
  TransferQueue({
    required this.connections,
    RemoteFileSystem? localFileSystem,
    this.poolPolicy = const PoolPolicy(),
    bool Function(FsLocation destination)? isCaseInsensitiveDestination,
    int maxInFlightFiles = maxGlobalInFlightTransfers,
    int maxPendingConflicts = maxSurfacedPendingConflicts,
    this.pipeBufferBytes = 4 * 1024 * 1024,
    BandwidthLimiter? downloadLimiter,
    BandwidthLimiter? uploadLimiter,
    this.persistence,
  }) : _localFileSystem = localFileSystem ?? LocalFileSystem(),
       _isCaseInsensitiveDestination =
           isCaseInsensitiveDestination ?? _defaultCaseSensitivity,
       _maxInFlightFiles = maxInFlightFiles,
       _maxPendingConflicts = maxPendingConflicts,
       downloadLimiter = downloadLimiter ?? BandwidthLimiter(),
       uploadLimiter = uploadLimiter ?? BandwidthLimiter() {
    if (maxInFlightFiles < 1) {
      throw ArgumentError.value(
        maxInFlightFiles,
        'maxInFlightFiles',
        'must be at least 1',
      );
    }
    if (maxPendingConflicts < 1) {
      throw ArgumentError.value(
        maxPendingConflicts,
        'maxPendingConflicts',
        'must be at least 1',
      );
    }
  }

  /// The engine's channel pool — transfer workers borrow transfer
  /// channels through `leaseTransferChannel` (03 §4.3).
  final ConnectionManager connections;
  final RemoteFileSystem _localFileSystem;

  /// The budget constants the queue enforces — today only
  /// `taskRetryLimit` (the §3.3 reconnect-cycle bound per task).
  final PoolPolicy poolPolicy;
  final bool Function(FsLocation destination) _isCaseInsensitiveDestination;
  final int _maxInFlightFiles;

  /// High-water mark for the in-memory pipe buffer between a source
  /// `download` and a destination `upload` (03 §4.5's small-buffer rule).
  final int pipeBufferBytes;

  /// The engine-global token buckets, one per direction (03 §4.3): every
  /// remote-bound file hop charges them per chunk. A null rate is
  /// unlimited; the future throttle UI (02 §6) drives the
  /// [BandwidthLimiter.bytesPerSecond] setters — those setters are the
  /// dynamic rate-change API. Queue and task pause never reset them:
  /// §4.4 lets in-flight work finish at the set rate.
  final BandwidthLimiter downloadLimiter;
  final BandwidthLimiter uploadLimiter;

  /// The no-op bucket a local leg rides: the acquires still run (the
  /// pipe path stays literal) but unlimited, so a local→local hop never
  /// pays into the network budgets.
  final BandwidthLimiter _localLimiter = BandwidthLimiter();

  /// The surfaced-conflict bound (the task's "bounded pending-conflict
  /// storage"): at most this many parked items sit in [pendingConflicts]
  /// queue-wide. Further collisions wait unsurfaced — still holding no
  /// slot or lease — until an answer frees capacity, so a pathological
  /// mass-collision cannot grow the surface without bound.
  final int _maxPendingConflicts;
  int _pendingConflictCount = 0;

  /// The write-ahead journal + history seam (03 §4.6). Null means the
  /// queue runs purely in memory — the #147 behavior, unchanged.
  final TransferPersistence? persistence;

  /// Insertion order is queue order — dispatch scans this map front to back.
  final LinkedHashMap<String, _TaskRuntime> _tasks = LinkedHashMap();
  final StreamController<TransferQueueEvent> _events =
      StreamController.broadcast();

  /// The shared destination-key registry (03 §4.2): (endpoint, case-folded
  /// planned path) → in-flight claim. One claim per key across all tasks;
  /// waiters hold no dispatch slot and no lease.
  final Map<(String, String), _RegistryClaim> _registry = {};

  int _inFlightFiles = 0;
  bool _paused = false;
  bool _disposed = false;

  /// Set once [restore] ran — repeat calls are no-ops so the engine host
  /// can fire it unconditionally at startup.
  bool _restored = false;
  Completer<void> _notPaused = Completer()..complete();

  /// Queue-order snapshot of tasks (unmodifiable).
  List<TransferTask> get tasks =>
      List.unmodifiable(_tasks.values.map((rt) => rt.task));

  bool get isPaused => _paused;

  /// Lifecycle, item-state, and byte-progress events for mirrors/UI.
  Stream<TransferQueueEvent> get events => _events.stream;

  /// The parked conflicts awaiting an answer — the future conflict UI's
  /// list (02 §5.2's dialog, 03 §4.1's ask-park). Surfaced entries are
  /// bounded by `_maxPendingConflicts`; collisions beyond the cap wait
  /// unsurfaced and are promoted in queue order as answers free slots.
  List<PendingConflict> get pendingConflicts => List.unmodifiable([
    for (final runtime in _tasks.values)
      ...runtime.pendingConflicts.values.map((parked) => parked.conflict),
  ]);

  /// The conflict the future UI is asking about, or null when the item
  /// is not parked.
  PendingConflict? pendingConflictFor(String taskId, String itemId) =>
      _tasks[taskId]?.pendingConflicts[itemId]?.conflict;

  /// Answers one parked conflict (the resolution-submission API the
  /// conflict dialog drives — 02 §5.2, 03 §4.1's prompt round-trip).
  /// The answer is recorded session-scoped, the item re-dispatches, and
  /// the executor re-stats the destination before applying the verb — a
  /// conflict that disappeared while parked simply proceeds, and a
  /// changed one resolves against fresh reality, never the stale stat.
  ///
  /// [scope] is 02 §5.2's "apply to all remaining conflicts in this
  /// task" checkbox: [ConflictResolutionScope.task] installs the verb's
  /// [taskScopePolicy] analogs for every later conflict in the task.
  ///
  /// Returns false when no conflict is parked for (taskId, itemId) —
  /// including one already answered, invalidated by a reconnect, or
  /// cleared by cancel — which is §4.1's ignored-late-reply rule.
  /// `ask` is never a valid answer; `merge` on a file item throws —
  /// 02 §5.2 restricts it to folders.
  bool resolveConflict(
    String taskId,
    String itemId,
    ConflictResolution verb, {
    ConflictResolutionScope scope = ConflictResolutionScope.item,
  }) {
    final runtime = _tasks[taskId];
    final parked = runtime?.pendingConflicts[itemId];
    if (runtime == null || parked == null) return false;
    if (verb == ConflictResolution.ask) {
      throw ArgumentError.value(
        verb,
        'verb',
        'ask is the prompt, not an answer',
      );
    }
    if (verb == ConflictResolution.merge && !parked.conflict.isDirectory) {
      throw ArgumentError.value(
        verb,
        'verb',
        'merge is valid for folders only (02 §5.2)',
      );
    }
    runtime.resolvedAnswers[itemId] = verb;
    if (scope == ConflictResolutionScope.task) {
      runtime.applyToAll = taskScopePolicy(verb);
    }
    runtime.pendingConflicts.remove(itemId);
    _pendingConflictCount--;
    _emit(
      TransferQueueConflictEvent(
        taskId,
        itemId,
        conflict: parked.conflict,
        pending: false,
      ),
    );
    if (parked.item.state == TransferItemState.conflictPending) {
      parked.item.state = TransferItemState.pending;
      _emit(TransferQueueItemEvent(taskId, itemId, parked.item.state));
    }
    _requeueParkedWork(runtime, parked.work);
    _promoteConflictWaiters();
    _pump();
    _maybeFinishTask(runtime);
    return true;
  }

  /// Enqueues one task and starts its scan. Returns the task; progress is
  /// observed through [events] and the task's mutable fields.
  ///
  /// Duplicate roots are deduped and roots nested inside another root are
  /// dropped (the parent already transfers them), keeping a task's planned
  /// destination paths unique.
  TransferTask enqueue(TransferTaskSpec spec) {
    if (_disposed) {
      throw StateError('the transfer queue is disposed');
    }
    final roots = _normalizeRoots(spec.rootPaths, spec.source);
    if (roots.isEmpty) {
      throw ArgumentError.value(
        spec.rootPaths,
        'rootPaths',
        'must contain at least one source path',
      );
    }
    final task = TransferTask(
      TransferTaskSpec(
        source: spec.source,
        destination: spec.destination,
        rootPaths: roots,
        destinationDir: spec.destinationDir,
        policy: spec.policy,
        operation: spec.operation,
      ),
    );
    final runtime = _TaskRuntime(task);
    // Journal the enqueue before the task becomes visible to dispatch —
    // the write-ahead rule that makes a crash between "the user hit
    // transfer" and the first scan recoverable (03 §4.6).
    persistence?.appendJournal(
      TaskEnqueuedRecord(
        taskId: task.id,
        spec: task.spec,
        enqueuedAt: task.enqueuedAt,
      ),
    );
    _tasks[task.id] = runtime;
    _emit(TransferQueueTaskEvent(task.id, task.state));
    unawaited(_runTask(runtime));
    return task;
  }

  /// Queue-level pause (03 §4.4): stops new work admission; in-flight VFS
  /// work may complete. Runtime-only — not journaled.
  void pauseQueue() {
    if (_disposed || _paused) return;
    _paused = true;
    // Invariant: notPaused is complete iff the queue is unpaused — a
    // still-open completer here means a state/completer drift bug, not
    // something to paper over.
    assert(_notPaused.isCompleted, 'notPaused was incomplete pre-pause');
    _notPaused = Completer();
  }

  void resumeQueue() {
    if (_disposed || !_paused) return;
    _paused = false;
    if (!_notPaused.isCompleted) _notPaused.complete();
    _pump();
  }

  /// Per-task pause (03 §4.4): cancels each in-flight attempt so the item
  /// returns to `pending` and restarts from byte zero on resume. Already
  /// committed work stays committed.
  void pauseTask(String taskId) {
    final runtime = _tasks[taskId];
    if (runtime == null) return;
    final task = runtime.task;
    if (task.state != TransferTaskState.queued &&
        task.state != TransferTaskState.scanning &&
        task.state != TransferTaskState.running) {
      return;
    }
    _journalState(task, TransferTaskState.paused);
    task.state = TransferTaskState.paused;
    _emit(TransferQueueTaskEvent(task.id, task.state));
    assert(
      runtime.notPaused.isCompleted,
      'notPaused was incomplete pre-pause',
    );
    runtime.notPaused = Completer();
    for (final attempt in runtime.attempts.values) {
      attempt.cancel();
    }
  }

  /// Resume one task. For a task restored from the journal in `paused`
  /// state this ends its surviving journaled pause; the queue-level
  /// restore pause still gates admission until `resumeQueue` (03 §4.6).
  void resumeTask(String taskId) {
    final runtime = _tasks[taskId];
    if (runtime == null) return;
    final task = runtime.task;
    if (task.state != TransferTaskState.paused) return;
    final next = task.scanComplete
        ? TransferTaskState.queued
        : TransferTaskState.scanning;
    _journalState(task, next);
    task.state = next;
    _emit(TransferQueueTaskEvent(task.id, task.state));
    if (!runtime.notPaused.isCompleted) runtime.notPaused.complete();
    _pump();
    // A restored task whose every item already finished (its terminal
    // record was the torn tail) drains to its terminal state here.
    _maybeFinishTask(runtime);
  }

  /// Per-task cancel (03 §4.4): stops new work via the sticky token and
  /// aborts in-flight attempts; pending items flip to `cancelled`
  /// immediately and the task drains once in-flight work unwinds.
  /// Cancelling a terminal task is a no-op.
  void cancelTask(String taskId) {
    final runtime = _tasks[taskId];
    if (runtime == null) return;
    final task = runtime.task;
    if (task.isTerminal) return;
    task.cancellation.cancel();
    _journalState(task, TransferTaskState.cancelled);
    task.state = TransferTaskState.cancelled;
    task.finishedAt ??= DateTime.now();
    _emit(TransferQueueTaskEvent(task.id, task.state));
    if (!runtime.notPaused.isCompleted) runtime.notPaused.complete();
    for (final attempt in runtime.attempts.values) {
      attempt.cancel();
    }
    for (final item in task.items) {
      if (!item.isTerminal) {
        item.state = TransferItemState.cancelled;
        _emit(TransferQueueItemEvent(task.id, item.id, item.state));
      }
    }
    _clearConflicts(runtime);
    runtime.eligible.clear();
    for (final directory in runtime.directories.values) {
      if (!directory.ready.isCompleted) directory.ready.complete();
    }
    _releaseRegistryClaims(task.id);
    _maybeFinishTask(runtime);
  }

  /// Cancels every non-terminal task, waits for the in-flight drain, then
  /// closes the event stream.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_notPaused.isCompleted) _notPaused.complete();
    for (final runtime in _tasks.values.toList()) {
      cancelTask(runtime.task.id);
    }
    await Future.wait(_tasks.values.map((rt) => rt.done.future));
    // Every lifecycle append is already queued on the writer chain —
    // shutdown runs the clean-shutdown compaction and final fsync behind
    // them (03 §4.6). The events stream closes even when a foreign
    // persistence implementation lets shutdown throw.
    try {
      await persistence?.shutdown();
    } finally {
      await _events.close();
    }
  }

  // ---------------------------------------------------------------------
  // Scan phase (03 §4.2)
  // ---------------------------------------------------------------------

  Future<void> _runTask(_TaskRuntime runtime) async {
    final task = runtime.task;
    task.startedAt ??= DateTime.now();
    _setTaskState(runtime, TransferTaskState.scanning);
    try {
      await _scan(runtime);
    } on RemoteFileException catch (error) {
      if (error.kind == RemoteFileErrorKind.cancelled ||
          task.cancellation.isCancelled) {
        // No-op when cancelTask already ran; otherwise the scan's own
        // cancel surfaces here and the token was tripped by dispose.
        cancelTask(task.id);
      } else {
        _failTask(runtime, error);
      }
    } catch (error) {
      _failTask(runtime, error);
    }
    _maybeFinishTask(runtime);
  }

  /// Walks the source under a pair of scan leases held for the scan's
  /// duration. Mid-scan `disconnected` errors re-lease through the pool —
  /// blocking while the reference reconnects, throwing when it is gone
  /// for good — so the scan keeps its position instead of restarting
  /// (03 §3.3/§4.1).
  Future<void> _scan(_TaskRuntime runtime) async {
    final task = runtime.task;
    task.plan ??= TransferPlan();
    task.totalBytes = 0;
    runtime.scanning = true;
    try {
      // Gate before leasing: a task restored in its journaled `paused`
      // state (03 §4.6) parks here holding no channels instead of
      // acquiring scan leases and then sitting on them.
      await _scanPauseGate(runtime);
      runtime.scanLeases = await _leaseEndpoints(task.spec, task.cancellation);
      await _ensureDestinationRoot(runtime);
      await _walkRoots(runtime);
      persistence?.appendJournal(
        ScanCompleteRecord(
          taskId: task.id,
          totalBytes: task.totalBytes ?? 0,
          skippedSymlinks: task.plan?.skippedSymlinks ?? 0,
        ),
      );
      task.scanComplete = true;
      // A state-refresh event so mirrors learn totals are now final even
      // when no progress event ever fires (an empty transfer).
      _emit(TransferQueueTaskEvent(task.id, task.state));
    } finally {
      await _releaseLeases(runtime.scanLeases);
      runtime.scanLeases = null;
      runtime.scanning = false;
    }
  }

  /// Runs one VFS operation under the scan leases, re-leasing after a
  /// `disconnected` failure. [destination] picks the destination channel
  /// for scan-time destination stats; source is the default.
  Future<T> _scanOp<T>(
    _TaskRuntime runtime,
    Future<T> Function(RemoteFileSystem fs) operation, {
    bool destination = false,
  }) {
    return _retryDisconnected(runtime, () async {
      final leases = runtime.scanLeases;
      if (leases == null) {
        throw const RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'transfer-scan',
          message: 'the scan lost its channel leases',
        );
      }
      return operation(
        _fsFor(
          destination ? runtime.task.destination : runtime.task.source,
          leases,
        ),
      );
    });
  }

  /// Retries [body] while it throws `disconnected`, re-leasing the scan
  /// channels each cycle and bounding consecutive losses by
  /// `PoolPolicy.taskRetryLimit` (03 §3.3's reconnect-cycle budget,
  /// surfaced as `TransferTask.retryCount`). Any success resets the count.
  Future<T> _retryDisconnected<T>(
    _TaskRuntime runtime,
    Future<T> Function() body,
  ) async {
    final task = runtime.task;
    while (true) {
      _throwIfTaskCancelled(task);
      try {
        final result = await body();
        task.retryCount = 0;
        return result;
      } on RemoteFileException catch (error) {
        if (error.kind != RemoteFileErrorKind.disconnected) rethrow;
        task.retryCount++;
        if (task.retryCount > poolPolicy.taskRetryLimit) rethrow;
        await _releaseLeases(runtime.scanLeases);
        // Null before the re-lease so a throwing acquire can't leave the
        // released leases in the field for _scan's finally to release a
        // second time.
        runtime.scanLeases = null;
        // A pause landing mid-cycle parks the retry lease-free until
        // resume; cancelTask completes the gate, so cancel still unwinds.
        await _scanPauseGate(runtime);
        _throwIfTaskCancelled(task);
        _setTaskState(runtime, TransferTaskState.queued);
        runtime.scanLeases = await _leaseEndpoints(
          task.spec,
          task.cancellation,
        );
        _setTaskState(runtime, TransferTaskState.scanning);
      }
    }
  }

  Future<void> _walkRoots(_TaskRuntime runtime) async {
    final task = runtime.task;
    final pendingListings = <_DirState>[];

    for (final rootPath in task.rootPaths) {
      _throwIfTaskCancelled(task);
      await _scanPauseGate(runtime);
      try {
        final entry = await _scanOp(
          runtime,
          (fs) => fs.stat(rootPath, followLinks: false),
        );
        await _scanEntry(
          runtime,
          entry,
          containerKey: null,
          containerPlanned: task.destinationDir,
          pendingListings: pendingListings,
        );
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.disconnected ||
            error.kind == RemoteFileErrorKind.cancelled) {
          rethrow;
        }
        _addTerminalItem(
          runtime,
          sourcePath: rootPath,
          destinationPath: _joinDest(
            task.destination,
            task.destinationDir,
            _leafName(task.source, rootPath),
          ),
          state: TransferItemState.failed,
          error: error.message,
          failureKind: error.kind,
        );
      }
    }

    var next = 0;
    while (next < pendingListings.length) {
      _throwIfTaskCancelled(task);
      await _scanPauseGate(runtime);
      final directory = pendingListings[next++];
      List<RemoteFileEntry> children;
      try {
        children = await _scanOp(
          runtime,
          (fs) => fs.listDirectory(directory.planned.source.path),
        );
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.disconnected ||
            error.kind == RemoteFileErrorKind.cancelled) {
          rethrow;
        }
        // The listing failed atomically: the directory item fails and no
        // children were ever discovered.
        _finishDirectory(
          runtime,
          directory,
          outcome: _DirOutcome.failed,
          error: error.message,
          failureKind: error.kind,
        );
        continue;
      }
      for (final child in children) {
        _throwIfTaskCancelled(task);
        await _scanPauseGate(runtime);
        await _scanEntry(
          runtime,
          child,
          containerKey: directory.planned.itemId,
          containerPlanned: directory.planned.destinationPath,
          pendingListings: pendingListings,
        );
      }
      // The listing closed: this directory's mkdir and its file children
      // become usable now (03 §4.2).
      _scheduleDirectory(runtime, directory);
    }
  }

  /// Parks the scan while its task is paused (03 §4.4): pauseTask swaps
  /// in an incomplete gate, resumeTask and cancelTask both complete it —
  /// the surrounding loop's `_throwIfTaskCancelled` handles the cancel
  /// case, so this returns on either.
  Future<void> _scanPauseGate(_TaskRuntime runtime) async {
    final task = runtime.task;
    while (task.state == TransferTaskState.paused &&
        !task.cancellation.isCancelled) {
      await runtime.notPaused.future;
    }
  }

  Future<void> _scanEntry(
    _TaskRuntime runtime,
    RemoteFileEntry entry, {
    required String? containerKey,
    required String containerPlanned,
    required List<_DirState> pendingListings,
  }) async {
    final task = runtime.task;
    final plannedDest = _joinDest(
      task.destination,
      containerPlanned,
      entry.name,
    );
    if (entry.isSymbolicLink) {
      task.plan!.skippedSymlinks++;
      _addTerminalItem(
        runtime,
        sourcePath: entry.path,
        destinationPath: plannedDest,
        size: entry.size,
        state: TransferItemState.skipped,
        error: 'symbolic links are not transferred',
      );
      return;
    }
    String name;
    try {
      name = _validatedDestinationName(task.destination, entry.name);
    } on FormatException catch (error) {
      _addTerminalItem(
        runtime,
        sourcePath: entry.path,
        destinationPath: plannedDest,
        size: entry.size,
        state: TransferItemState.failed,
        error: error.message,
        failureKind: RemoteFileErrorKind.other,
      );
      return;
    }
    final existing = await _scanStatDestination(runtime, plannedDest);
    switch (entry.type) {
      case RemoteFileType.file:
        // A restored mid-scan task merges onto its journaled item by
        // destination path: the re-scan reuses the itemId and an
        // already-terminal outcome suppresses re-dispatch (03 §4.6).
        final restored = runtime.takeRestored(plannedDest, entry.path);
        final planned = PlannedFile(
          source: entry,
          name: name,
          containerKey: containerKey,
          destinationPath: plannedDest,
          existing: existing,
          itemId: restored?.itemId,
        );
        // A still-pending restored item re-journals with fresh fields;
        // a terminal one's pre-crash planEntry already stands — a repeat
        // would be churn at best and an outcome reset at worst.
        if (restored?.outcome == null) {
          _journalPlanEntry(
            task,
            itemId: planned.itemId,
            isDirectory: false,
            source: entry,
            name: name,
            containerKey: containerKey,
            destinationPath: plannedDest,
            existing: existing,
          );
        }
        task.plan!.files.add(planned);
        task.totalBytes = (task.totalBytes ?? 0) + (entry.size ?? 0);
        if (restored?.outcome != null) {
          _addRestoredTerminalItem(
            runtime,
            restored!,
            entry,
            plannedDest,
            isDirectory: false,
          );
          return;
        }
        final item = _addPendingItem(
          runtime,
          id: planned.itemId,
          entry: entry,
          destinationPath: plannedDest,
        );
        _armFile(runtime, _FileWork(item: item, file: planned));
      case RemoteFileType.directory:
        final restored = runtime.takeRestored(plannedDest, entry.path);
        final planned = PlannedDirectory(
          source: entry,
          name: name,
          containerKey: containerKey,
          destinationPath: plannedDest,
          existing: existing,
          itemId: restored?.itemId,
        );
        if (restored?.outcome == null) {
          _journalPlanEntry(
            task,
            itemId: planned.itemId,
            isDirectory: true,
            source: entry,
            name: name,
            containerKey: containerKey,
            destinationPath: plannedDest,
            existing: existing,
          );
        }
        task.plan!.directoriesInOrder.add(planned);
        final item = restored?.outcome != null
            ? _addRestoredTerminalItem(
                runtime,
                restored!,
                entry,
                plannedDest,
                isDirectory: true,
              )
            : _addPendingItem(
                runtime,
                id: planned.itemId,
                entry: entry,
                destinationPath: plannedDest,
                isDirectory: true,
              );
        final dirState = _DirState(planned: planned, item: item);
        runtime.directories[planned.itemId] = dirState;
        // A journaled terminal outcome carries the mkdir result forward:
        // `_scheduleDirectory` skips the op, but the listing still walks
        // so children merge onto their own journaled records.
        if (restored?.outcome != null) {
          dirState.outcome = restored!.outcome == RestoredItemOutcome.completed
              ? _DirOutcome.ready
              : restored.outcome == RestoredItemOutcome.failed
                  ? _DirOutcome.failed
                  : _DirOutcome.skipped;
          dirState.resolvedPath = restored.resolvedPath;
          dirState.ready.complete();
        }
        pendingListings.add(dirState);
      case RemoteFileType.symbolicLink || RemoteFileType.other:
        // symbolicLink already returned above; `other` (fifos, sockets)
        // has no bytes to move and fails honestly.
        _addTerminalItem(
          runtime,
          sourcePath: entry.path,
          destinationPath: plannedDest,
          size: entry.size,
          state: TransferItemState.failed,
          error: 'unsupported source entry type ${entry.type.name}',
          failureKind: RemoteFileErrorKind.unsupported,
        );
    }
  }

  /// The scan-time `existing` hint (03 §4.1): best-effort — the executor
  /// re-stats before every commit and never trusts this value.
  Future<DestinationStat?> _scanStatDestination(
    _TaskRuntime runtime,
    String path,
  ) async {
    try {
      final entry = await _scanOp(
        runtime,
        (fs) => fs.stat(path, followLinks: false),
        destination: true,
      );
      return DestinationStat.fromEntry(entry);
    } on RemoteFileException catch (error) {
      if (error.kind == RemoteFileErrorKind.disconnected ||
          error.kind == RemoteFileErrorKind.cancelled) {
        rethrow;
      }
      return null;
    }
  }

  Future<void> _ensureDestinationRoot(_TaskRuntime runtime) async {
    final task = runtime.task;
    if (task.destination is LocalFsLocation) {
      await ensureSafeLocalDirectory(task.destinationDir);
      return;
    }
    final existing = await _scanOp(
      runtime,
      (fs) async {
        try {
          return await fs.stat(task.destinationDir, followLinks: false);
        } on RemoteFileException catch (error) {
          if (error.kind == RemoteFileErrorKind.notFound) return null;
          rethrow;
        }
      },
      destination: true,
    );
    if (existing == null) {
      await _scanOp(
        runtime,
        (fs) async {
          try {
            await fs.createDirectory(task.destinationDir);
          } on RemoteFileException catch (error) {
            // A concurrent creator won the stat→mkdir race: merging is
            // correct when the occupant is a directory — the same
            // classification _materializeDirectory applies per entry.
            if (error.kind != RemoteFileErrorKind.conflict) rethrow;
            final raced = await fs.stat(
              task.destinationDir,
              followLinks: false,
            );
            if (!raced.isDirectory) rethrow;
          }
        },
        destination: true,
      );
    } else if (!existing.isDirectory) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'transfer-scan',
        path: task.destinationDir,
        message:
            'the destination path exists and is not a directory: '
            '${task.destinationDir}',
      );
    }
  }

  // ---------------------------------------------------------------------
  // Directory executor (03 §4.2 — mkdir only after the listing closes,
  // serialized per task so a parent always precedes its children)
  // ---------------------------------------------------------------------

  void _scheduleDirectory(_TaskRuntime runtime, _DirState directory) {
    // A restored directory whose journaled outcome is already terminal
    // runs no mkdir — the listing above still walked its children.
    if (directory.outcome != _DirOutcome.pending) return;
    runtime.directoryOpsPending++;
    runtime.directoryChain = runtime.directoryChain.then(
      (_) => _runDirectory(runtime, directory),
    );
    unawaited(runtime.directoryChain.catchError((_) {}));
  }

  Future<void> _runDirectory(
    _TaskRuntime runtime,
    _DirState directory,
  ) async {
    final task = runtime.task;
    try {
      await _waitForAdmission(runtime);
      final containerPath = _resolvedContainer(runtime, directory.planned.containerKey);
      if (containerPath == null) {
        // The containing directory was skipped or failed: the subtree is
        // skipped with the reason recorded.
        _finishDirectory(runtime, directory, outcome: _DirOutcome.skipped);
        return;
      }
      final leases = await _leaseServerIds(
        _serverIds({task.destination}),
        task.cancellation,
      );
      try {
        final dstFs = _fsFor(task.destination, leases);
        await _materializeDirectory(runtime, directory, dstFs, containerPath);
        // A completed op proves connectivity — the retry budget bounds
        // consecutive losses, not lifetime cumulative ones (03 §3.3).
        task.retryCount = 0;
      } finally {
        await _releaseLeases(leases);
      }
    } on RemoteFileException catch (error) {
      if (error.kind == RemoteFileErrorKind.cancelled ||
          task.cancellation.isCancelled) {
        _finishDirectory(runtime, directory, outcome: _DirOutcome.cancelled);
      } else if (error.kind == RemoteFileErrorKind.disconnected) {
        // A dead channel mid-mkdir retries through a fresh lease, bounded
        // by the task's reconnect budget.
        task.retryCount++;
        if (task.retryCount > poolPolicy.taskRetryLimit) {
          _finishDirectory(
            runtime,
            directory,
            outcome: _DirOutcome.failed,
            error: error.message,
            failureKind: error.kind,
          );
        } else {
          // Re-run at the chain's tail; pending-count stays balanced
          // because the retry's own finally decrements once more.
          runtime.directoryOpsPending++;
          runtime.directoryChain = runtime.directoryChain.then(
            (_) => _runDirectory(runtime, directory),
          );
          unawaited(runtime.directoryChain.catchError((_) {}));
        }
      } else {
        _finishDirectory(
          runtime,
          directory,
          outcome: _DirOutcome.failed,
          error: error.message,
          failureKind: error.kind,
        );
      }
    } catch (error) {
      _finishDirectory(
        runtime,
        directory,
        outcome: _DirOutcome.failed,
        error: '$error',
        failureKind: RemoteFileErrorKind.other,
      );
    } finally {
      runtime.directoryOpsPending--;
      _maybeFinishTask(runtime);
    }
  }

  Future<void> _materializeDirectory(
    _TaskRuntime runtime,
    _DirState directory,
    RemoteFileSystem dstFs,
    String containerPath,
  ) async {
    final task = runtime.task;
    final destination = _joinDest(
      task.destination,
      containerPath,
      directory.planned.name,
    );
    final existing = await _statOrNull(dstFs, destination);
    // 02 §5.2's folder semantics at the decision level: `merge` recurses
    // (the directory resolves to its existing destination and children
    // land under the file policy), `keepBoth` creates the source under
    // the first free numbered name, and a non-directory occupant routes
    // through the same folder verb — `merge` there falls back to `ask`
    // (03 §4.1) rather than pretending recursion is possible.
    switch (resolveTransferConflict(
      verb: _effectiveFolderVerb(runtime, directory.item.id),
      sourceIsDirectory: true,
      existing: existing == null
          ? null
          : DestinationStat.fromEntry(existing),
      sourceModifiedAt: directory.planned.source.modifiedAt,
    )) {
      case ConflictProceed():
        await _createDirectoryOrClassify(dstFs, destination);
        _finishDirectory(
          runtime,
          directory,
          outcome: _DirOutcome.ready,
          resolvedPath: destination,
        );
      case ConflictMerge():
        _finishDirectory(
          runtime,
          directory,
          outcome: _DirOutcome.ready,
          resolvedPath: destination,
        );
      case ConflictSkip(:final reason):
        _finishDirectory(
          runtime,
          directory,
          outcome: _DirOutcome.skipped,
          error: reason,
        );
      case ConflictKeepBoth():
        await _materializeNumbered(runtime, directory, dstFs, containerPath);
      case ConflictReplace():
        // Dir→dir wholesale replace and dir→non-dir occupant removal both
        // delete through the D15 story — a later M4 slice; the item fails
        // honestly rather than deleting unguarded.
        _finishDirectory(
          runtime,
          directory,
          outcome: _DirOutcome.failed,
          error:
              'replacing $destination removes the existing occupant, '
              'which requires the D15 delete story (a later M4 slice)',
          failureKind: RemoteFileErrorKind.conflict,
        );
      case ConflictAsk():
        _parkDirectoryConflict(runtime, directory, existing!);
    }
  }

  Future<void> _materializeNumbered(
    _TaskRuntime runtime,
    _DirState directory,
    RemoteFileSystem dstFs,
    String containerPath,
  ) async {
    for (var attempt = 2; attempt <= _maxKeepBothAttempts; attempt++) {
      final candidate = _joinDest(
        runtime.task.destination,
        containerPath,
        numberedConflictName(
          directory.planned.name,
          attempt,
          isDirectory: true,
        ),
      );
      final existing = await _statOrNull(dstFs, candidate);
      if (existing != null) continue;
      try {
        await dstFs.createDirectory(candidate);
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.conflict) continue;
        rethrow;
      }
      _finishDirectory(
        runtime,
        directory,
        outcome: _DirOutcome.ready,
        resolvedPath: candidate,
      );
      return;
    }
    _finishDirectory(
      runtime,
      directory,
      outcome: _DirOutcome.failed,
      error:
          'no free keep-both name after $_maxKeepBothAttempts attempts for '
          '${directory.planned.name}',
      failureKind: RemoteFileErrorKind.conflict,
    );
  }

  /// `createDirectory` plus the exists-race classification: a remote mkdir
  /// can lose to a concurrent creator, which is success when the occupant
  /// is a directory (03 §4.2).
  Future<void> _createDirectoryOrClassify(
    RemoteFileSystem dstFs,
    String path,
  ) async {
    try {
      await dstFs.createDirectory(path);
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.conflict) rethrow;
      final existing = await _statOrNull(dstFs, path);
      if (existing != null && existing.isDirectory) return;
      rethrow;
    }
  }

  /// Resolves the item's terminal state and releases its children.
  void _finishDirectory(
    _TaskRuntime runtime,
    _DirState directory, {
    required _DirOutcome outcome,
    String? resolvedPath,
    String? error,
    RemoteFileErrorKind? failureKind,
  }) {
    final task = runtime.task;
    final item = directory.item;
    if (item.isTerminal) {
      // An externally terminalized directory (cancel/fail sweep) still
      // owes its armed children the ready signal.
      if (!directory.ready.isCompleted) directory.ready.complete();
      return;
    }
    directory.resolvedPath = resolvedPath;
    directory.outcome = outcome;
    if (resolvedPath != null) item.destinationPath = resolvedPath;
    // Journal the directory's terminal record before the item state
    // takes effect — a completed mkdir's resolvedPath is what rebases
    // restored children after a crash (03 §4.6).
    _journalItemOutcome(
      task,
      item,
      switch (outcome) {
        _DirOutcome.ready => TransferItemState.completed,
        _DirOutcome.skipped => TransferItemState.skipped,
        _DirOutcome.failed => TransferItemState.failed,
        _DirOutcome.cancelled => TransferItemState.cancelled,
        _DirOutcome.pending =>
          throw StateError('a directory cannot finish pending'),
      },
      error: error,
      failureKind: failureKind,
      resolvedPath: resolvedPath,
    );
    switch (outcome) {
      case _DirOutcome.ready:
        item.state = TransferItemState.completed;
      case _DirOutcome.skipped:
        item.state = TransferItemState.skipped;
        item.error = error ?? 'the containing directory was skipped';
        task.skippedItems++;
      case _DirOutcome.failed:
        item.state = TransferItemState.failed;
        item.error = error;
        item.failureKind = failureKind;
        task.failedItems++;
      case _DirOutcome.cancelled:
        item.state = TransferItemState.cancelled;
      case _DirOutcome.pending:
        throw StateError('a directory cannot finish pending');
    }
    _emit(
      TransferQueueItemEvent(task.id, item.id, item.state, error: item.error),
    );
    if (!directory.ready.isCompleted) directory.ready.complete();
  }

  // ---------------------------------------------------------------------
  // File executor (03 §4.3) — registry claim, leases, conflict decision,
  // bounded pipe, post-commit
  // ---------------------------------------------------------------------

  void _armFile(_TaskRuntime runtime, _FileWork work) {
    final containerKey = work.file.containerKey;
    if (containerKey == null) {
      runtime.eligible.addLast(work);
      _pump();
      return;
    }
    final directory = runtime.directories[containerKey]!;
    unawaited(
      directory.ready.future.then((_) => _fileContainerReady(runtime, work)),
    );
  }

  void _fileContainerReady(_TaskRuntime runtime, _FileWork work) {
    if (work.item.isTerminal) return;
    final directory = runtime.directories[work.file.containerKey];
    if (directory == null || directory.outcome != _DirOutcome.ready) {
      _finishItem(
        runtime,
        work.item,
        TransferItemState.skipped,
        error: 'the containing directory was skipped or failed',
      );
      _maybeFinishTask(runtime);
      return;
    }
    runtime.eligible.addLast(work);
    _pump();
  }

  /// Dispatches while a global slot is free, walking tasks in queue order
  /// (03 §4.3's strict queue order — cross-server round-robin is a
  /// declared non-goal for v1).
  void _pump() {
    if (_paused || _disposed) return;
    while (_inFlightFiles < _maxInFlightFiles) {
      final next = _nextDispatchable();
      if (next == null) return;
      _inFlightFiles++;
      unawaited(
        _runFile(next.runtime, next.work).whenComplete(() {
          _inFlightFiles--;
          _pump();
        }),
      );
    }
  }

  ({_TaskRuntime runtime, _FileWork work})? _nextDispatchable() {
    for (final runtime in _tasks.values) {
      if (runtime.eligible.isEmpty) continue;
      final task = runtime.task;
      if (task.state == TransferTaskState.paused || task.isTerminal) {
        continue;
      }
      return (runtime: runtime, work: runtime.eligible.removeFirst());
    }
    return null;
  }

  Future<void> _runFile(_TaskRuntime runtime, _FileWork work) async {
    final task = runtime.task;
    final item = work.item;
    final file = work.file;

    // Resolve the actual destination through the container key so a
    // keep-both-renamed ancestor rebases this item (03 §4.1).
    final containerPath = _resolvedContainer(runtime, file.containerKey);
    if (containerPath == null) {
      _finishItem(
        runtime,
        item,
        TransferItemState.skipped,
        error: 'the containing directory was skipped or failed',
      );
      _maybeFinishTask(runtime);
      return;
    }
    final destinationPath = _joinDest(
      task.destination,
      containerPath,
      file.name,
    );
    item.destinationPath = destinationPath;

    // The shared destination-key registry serializes commits onto one
    // (endpoint, folded path). A waiter holds no slot and no lease: it
    // re-queues behind the holder's commit instead.
    final key = (
      _endpointKey(task.destination),
      _fold(task, destinationPath),
    );
    final holder = _registry[key];
    if (holder != null && !holder.committed.isCompleted) {
      unawaited(
        holder.committed.future.then((_) {
          if (!item.isTerminal && !task.isTerminal) {
            runtime.eligible.addFirst(work);
            _pump();
          }
        }),
      );
      return;
    }
    final claim = _RegistryClaim(task.id);
    _registry[key] = claim;

    var attempt = RemoteTransferCancellation();
    runtime.attempts[item.id] = attempt;
    item.transferredBytes = 0;
    item.state = TransferItemState.active;
    _emit(TransferQueueItemEvent(task.id, item.id, item.state));
    if (task.state == TransferTaskState.queued ||
        task.state == TransferTaskState.scanning) {
      _setTaskState(runtime, TransferTaskState.running);
    }

    try {
      _throwIfTaskCancelled(task);
      // Lease both endpoints in sorted server-id order (deadlock-free when
      // the remote→remote slice arrives); local endpoints need no lease.
      final leases = await _leaseEndpoints(task.spec, attempt);
      try {
        final srcFs = _fsFor(task.source, leases);
        final dstFs = _fsFor(task.destination, leases);
        for (var commitTry = 0; ; commitTry++) {
          // The token is one-shot: a dead upload or a pause in the gap
          // cancelled it — never feed a cancelled token to the next pipe.
          if (attempt.isCancelled) throw _cancelledException();
          final decision = await _decideFile(
            runtime,
            dstFs,
            work,
            containerPath,
          );
          switch (decision) {
            case _FileAsk(:final existing):
              // The §4.1 ask-park: the finally below releases the lease
              // and the registry claim, so the parked item holds no slot
              // and no channel while it awaits an answer.
              _parkFileConflict(runtime, work, existing);
              return;
            case _FileSkip(:final detail):
              _finishItem(
                runtime,
                item,
                TransferItemState.skipped,
                error: detail,
              );
              return;
            case _FileError(:final message):
              _finishItem(
                runtime,
                item,
                TransferItemState.failed,
                error: message,
                failureKind: RemoteFileErrorKind.conflict,
              );
              return;
            case _FileCommit(
              destinationPath: final commitPath,
              overwrite: final overwrite,
              expectedTarget: final expectedTarget,
            ):
              // Point at the actual commit target before the pipe so a
              // keep-both item reports its numbered path mid-transfer.
              item.destinationPath = commitPath;
              try {
                await _pipe(
                  source: srcFs,
                  destination: dstFs,
                  readLimiter: task.source is ServerFsLocation
                      ? downloadLimiter
                      : _localLimiter,
                  writeLimiter: task.destination is ServerFsLocation
                      ? uploadLimiter
                      : _localLimiter,
                  sourcePath: file.source.path,
                  destinationPath: commitPath,
                  length: file.source.size,
                  overwrite: overwrite,
                  expectedTarget: expectedTarget,
                  preserveMode: file.source.mode,
                  cancellation: attempt,
                  onProgress: (transferred, total) =>
                      _onFileProgress(runtime, item, transferred, total),
                );
              } on RemoteFileException catch (error) {
                // A stat-checked destination that appeared between decide
                // and commit re-runs the policy on fresh reality — for
                // keep-both that is simply the next number (03 §4.2).
                if (error.kind == RemoteFileErrorKind.conflict &&
                    commitTry < _maxCommitRetries) {
                  // A pause that landed while the pipe unwound already
                  // cancelled the attempt — requeue, don't restart on a
                  // fresh token the pause could never reach.
                  if (task.cancellation.isCancelled ||
                      task.state == TransferTaskState.paused) {
                    throw _cancelledException();
                  }
                  // _pipe cancelled the token when its upload died —
                  // retry on a fresh one or the next pipe aborts
                  // instantly. Keep runtime.attempts pointing at the
                  // live token so pause/cancel still reach it.
                  attempt = RemoteTransferCancellation();
                  runtime.attempts[item.id] = attempt;
                  continue;
                }
                rethrow;
              }
              item.destinationPath = commitPath;
              await _postCommit(
                runtime,
                srcFs,
                dstFs,
                file,
                commitPath,
              );
              // A landed file proves connectivity — the retry budget
              // bounds consecutive losses, not cumulative ones (03 §3.3).
              task.retryCount = 0;
              _finishItem(runtime, item, TransferItemState.completed);
              return;
          }
        }
      } finally {
        await _releaseLeases(leases);
      }
    } on RemoteFileException catch (error) {
      _handleFileError(runtime, work, error);
    } catch (error) {
      _finishItem(
        runtime,
        item,
        TransferItemState.failed,
        error: '$error',
        failureKind: RemoteFileErrorKind.other,
      );
    } finally {
      runtime.attempts.remove(item.id);
      // Complete any waiters, then drop the claim: a completed claim
      // serializes nothing (the holder check requires an incomplete
      // completer), so retaining it would grow the registry per unique
      // destination key for the task's lifetime. Requeued items simply
      // re-claim on their next dispatch.
      _releaseClaim(key, claim);
      _maybeFinishTask(runtime);
    }
  }

  /// Post-commit fixups (03 §4.1): mtime restore is best-effort (a server
  /// without setStat reports `unsupported`, which is absorbed); the move
  /// verb then deletes the source file — a delete failure fails the item
  /// because a move that leaves its source is not complete (02 §5.2).
  Future<void> _postCommit(
    _TaskRuntime runtime,
    RemoteFileSystem srcFs,
    RemoteFileSystem dstFs,
    PlannedFile file,
    String destinationPath,
  ) async {
    final modifiedAt = file.source.modifiedAt;
    if (modifiedAt != null) {
      try {
        await dstFs.setTimes(destinationPath, modifiedAt: modifiedAt);
      } on RemoteFileException catch (error) {
        if (error.kind != RemoteFileErrorKind.unsupported) rethrow;
      }
    }
    if (runtime.task.operation == TransferOperation.move) {
      await srcFs.delete(file.source);
    }
  }

  void _handleFileError(
    _TaskRuntime runtime,
    _FileWork work,
    RemoteFileException error,
  ) {
    final task = runtime.task;
    final item = work.item;
    if (error.kind == RemoteFileErrorKind.cancelled ||
        task.cancellation.isCancelled) {
      if (task.cancellation.isCancelled) {
        _finishItem(runtime, item, TransferItemState.cancelled);
      } else {
        // The attempt token was cancelled by pauseTask: the item returns
        // to pending and restarts from byte zero on resume (03 §4.4).
        _debitItemProgress(runtime, item);
        item.state = TransferItemState.pending;
        _emit(TransferQueueItemEvent(task.id, item.id, item.state));
        runtime.eligible.addFirst(work);
      }
      return;
    }
    if (error.kind == RemoteFileErrorKind.disconnected) {
      // §3.3: the task flips back to queued; the item re-dispatches after
      // the pool reconnects, bounded by the task's reconnect budget.
      task.retryCount++;
      _debitItemProgress(runtime, item);
      item.state = TransferItemState.pending;
      _emit(TransferQueueItemEvent(task.id, item.id, item.state));
      if (task.retryCount > poolPolicy.taskRetryLimit) {
        _finishItem(
          runtime,
          item,
          TransferItemState.failed,
          error: error.message,
          failureKind: error.kind,
        );
        return;
      }
      _setTaskState(runtime, TransferTaskState.queued);
      runtime.eligible.addFirst(work);
      return;
    }
    _finishItem(
      runtime,
      item,
      TransferItemState.failed,
      error: error.message,
      failureKind: error.kind,
    );
  }

  /// Removes bytes an aborted attempt already reported so the task's
  /// aggregate never overstates (02 §5.3's floor rule).
  void _debitItemProgress(_TaskRuntime runtime, TransferItem item) {
    runtime.task.transferredBytes -= item.transferredBytes;
    item.transferredBytes = 0;
  }

  void _onFileProgress(
    _TaskRuntime runtime,
    TransferItem item,
    int transferred,
    int? total,
  ) {
    final task = runtime.task;
    task.transferredBytes += transferred - item.transferredBytes;
    item.transferredBytes = transferred;
    _emit(
      TransferQueueProgressEvent(
        task.id,
        itemId: item.id,
        transferred: transferred,
        total: total,
        taskTransferredBytes: task.transferredBytes,
        taskTotalBytes: task.totalBytes ?? 0,
        scanComplete: task.scanComplete,
      ),
    );
  }

  /// Stats the planned destination and resolves the effective file verb
  /// (a prior per-item answer, the apply-to-all scope, else the task
  /// policy) through [resolveTransferConflict] — 02 §5.2's decision table
  /// applied to fresh reality, never the scan-time hint. `keepBoth`
  /// stat-checks each numbered candidate (03 §4.2: a pre-existing
  /// `report (2).pdf` is itself a name collision, never a silent
  /// overwrite); `ask` parks the item for an answer.
  Future<_FileDecision> _decideFile(
    _TaskRuntime runtime,
    RemoteFileSystem dstFs,
    _FileWork work,
    String containerPath,
  ) async {
    final task = runtime.task;
    final file = work.file;
    final candidate = _joinDest(task.destination, containerPath, file.name);
    final existing = await _statOrNull(dstFs, candidate);
    switch (resolveTransferConflict(
      verb: _effectiveFileVerb(runtime, work.item.id),
      sourceIsDirectory: false,
      existing: existing == null
          ? null
          : DestinationStat.fromEntry(existing),
      sourceModifiedAt: file.source.modifiedAt,
    )) {
      case ConflictProceed():
        return _FileCommit(
          destinationPath: candidate,
          overwrite: false,
          expectedTarget: null,
        );
      case ConflictSkip(:final reason):
        return _FileSkip(reason);
      case ConflictAsk():
        // `existing` is non-null — ask only arises on a real collision.
        return _FileAsk(existing!);
      case ConflictReplace(:final removesOccupant):
        if (removesOccupant) {
          return _FileError(
            'a directory occupies $candidate; replacing it requires the '
            'D15 delete story, which is a later M4 slice',
          );
        }
        return _FileCommit(
          destinationPath: candidate,
          overwrite: true,
          expectedTarget: existing,
        );
      case ConflictKeepBoth():
        for (var n = 2; n <= _maxKeepBothAttempts; n++) {
          final numbered = _joinDest(
            task.destination,
            containerPath,
            numberedConflictName(file.name, n, isDirectory: false),
          );
          // Another in-flight item may already hold this candidate's key;
          // rather than wait with a slot held, take the next number.
          final numberedKey = (
            _endpointKey(task.destination),
            _fold(task, numbered),
          );
          final claimed = _registry[numberedKey];
          if (claimed != null && !claimed.committed.isCompleted) continue;
          if (await _statOrNull(dstFs, numbered) != null) continue;
          return _FileCommit(
            destinationPath: numbered,
            overwrite: false,
            expectedTarget: null,
          );
        }
        return _FileError(
          'no free keep-both name after $_maxKeepBothAttempts attempts for '
          '${file.name}',
        );
      case ConflictMerge():
        // Unreachable — a file verb can never be `merge` (the policy
        // normalizes it to ask, and resolveConflict rejects merge
        // answers on file items) — but ask is the honest degradation.
        return _FileAsk(existing!);
    }
  }

  /// The file hop: `download` into a bounded sink feeding `upload`
  /// (03 §4.5's pipe; both sides honour the attempt token). An upload
  /// that dies early aborts the source read through the sink so it cannot
  /// buffer unboundedly or wedge.
  ///
  /// Throttling rides the sink's chunk gates: a remote source charges
  /// [readLimiter], a remote destination [writeLimiter] — for
  /// remote→remote that is one acquire per chunk on each directional
  /// bucket (03 §4.3). Both VFS calls report cumulative progress; the
  /// max-of-sides combiner counts each byte once even when the two
  /// sides report in lockstep, and still progresses when one side
  /// stays silent.
  Future<void> _pipe({
    required RemoteFileSystem source,
    required RemoteFileSystem destination,
    required BandwidthLimiter readLimiter,
    required BandwidthLimiter writeLimiter,
    required String sourcePath,
    required String destinationPath,
    int? length,
    required bool overwrite,
    RemoteFileEntry? expectedTarget,
    int? preserveMode,
    required RemoteTransferCancellation cancellation,
    required RemoteTransferProgress onProgress,
  }) async {
    final controller = StreamController<List<int>>();
    final sink = BoundedTransferSink(
      controller,
      maxBufferedBytes: pipeBufferBytes,
      readGate: (bytes, token) =>
          readLimiter.acquire(bytes, cancellation: token),
      writeGate: (bytes, token) =>
          writeLimiter.acquire(bytes, cancellation: token),
      cancellation: cancellation,
    );
    // Bytes flow through the pipe once; whichever side reports the
    // larger cumulative figure is the truth so far.
    var reported = 0;
    int? reportedTotal;
    void pipeProgress(int transferred, int? total) {
      if (total != null) reportedTotal = total;
      if (transferred <= reported) return;
      reported = transferred;
      onProgress(transferred, total ?? reportedTotal);
    }

    Object? uploadError;
    final uploadFuture = destination.upload(
      destinationPath,
      sink.stream,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      cancellation: cancellation,
      onProgress: pipeProgress,
      computeHash: false,
    );
    unawaited(
      uploadFuture.then((_) {}, onError: (Object error) {
        // An attempt token already cancelled (pause/cancel) owns the
        // outcome — the upload's incidental unwinding error must not
        // masquerade as the failure reason.
        if (cancellation.isCancelled) return;
        // The sink relays source errors into the upload stream — once a
        // source failure is recorded, anything the upload surfaces is
        // downstream noise (or an adapter's wrapped copy of it), not an
        // independent upload failure; treating it as one would cancel
        // the attempt and launder the real error into a silent requeue.
        if (sink.sourceError != null) return;
        uploadError = error;
        // Early upload death stops the source read; without this a fast
        // producer would buffer the whole file in memory.
        sink.abort();
        cancellation.cancel();
      }),
    );
    unawaited(
      cancellation.whenCancelled.then(
        (_) => sink.abort(),
        // abort() is pure cleanup — fail closed: even an errored
        // cancellation signal must still release the sink.
        onError: (Object _) => sink.abort(),
      ),
    );
    try {
      await source.download(
        sourcePath,
        sink,
        onProgress: pipeProgress,
        cancellation: cancellation,
        computeHash: false,
      );
    } catch (error) {
      if (uploadError == null) sink.abort(error);
      try {
        await uploadFuture;
      } catch (_) {}
      // Attribution order matters: an early upload death cancels the
      // attempt token, so without the first branch every upload failure
      // would surface as "cancelled" and requeue forever; and a pause's
      // abort errors the upload stream, so without the second branch a
      // paused item would fail on a StateError instead of requeueing.
      // `uploadError` is only ever a genuine upload failure — the
      // handler above skips errors relayed from the source side.
      if (uploadError != null) {
        throw _sideError('destination', uploadError!);
      }
      if (cancellation.isCancelled) throw _cancelledException();
      throw _sideError('source', error);
    }
    try {
      await sink.close();
      await uploadFuture;
    } catch (error) {
      // A real upload failure beats the sink's incidental close error on
      // an already-aborted sink — surface the remote cause, not the
      // unwind artifact.
      if (uploadError != null) throw _sideError('destination', uploadError!);
      rethrow;
    }
  }

  /// 03 §4.5: a piped failure fails the file with the failing side
  /// named. The typed kind survives the wrap so conflict-retry and
  /// cancelled-requeue classification above still apply.
  RemoteFileException _sideError(String side, Object error) {
    if (error is RemoteFileException) {
      return RemoteFileException(
        kind: error.kind,
        operation: error.operation,
        path: error.path,
        message: 'transfer $side: ${error.message}',
        cause: error,
      );
    }
    return RemoteFileException(
      kind: RemoteFileErrorKind.other,
      operation: 'transfer',
      message: 'transfer $side: $error',
      cause: error,
    );
  }

  // ---------------------------------------------------------------------
  // Conflict park/resolve — 03 §4.1's ask-park behind 02 §5.2's verbs
  // ---------------------------------------------------------------------

  /// The verb an item's next decision applies: a per-item answer wins,
  /// then the apply-to-all scope, then the task policy (02 §5.2 — earlier
  /// per-item answers outrank a later "apply to all REMAINING").
  ConflictResolution _effectiveFileVerb(_TaskRuntime runtime, String itemId) =>
      runtime.resolvedAnswers[itemId] ??
      runtime.applyToAll?.files ??
      runtime.task.policy.files;

  ConflictResolution _effectiveFolderVerb(
    _TaskRuntime runtime,
    String itemId,
  ) =>
      runtime.resolvedAnswers[itemId] ??
      runtime.applyToAll?.folders ??
      runtime.task.policy.folders;

  /// Parks a file on its collision: the work leaves `eligible` (it was
  /// already dequeued) and sits in [pendingConflicts] — or, past the
  /// surfaced cap, in [conflictWaiters] — holding no slot, lease, or
  /// registry claim (the caller's finally releases all three). Nothing
  /// is journaled: a parked item replays as still-pending and re-surfaces
  /// fresh on resume (03 §4.4/§4.6).
  void _parkFileConflict(
    _TaskRuntime runtime,
    _FileWork work,
    RemoteFileEntry existing,
  ) {
    final task = runtime.task;
    final item = work.item;
    if (_pendingConflictCount >= _maxPendingConflicts) {
      item.state = TransferItemState.pending;
      _emit(TransferQueueItemEvent(task.id, item.id, item.state));
      runtime.conflictWaiters.addLast(work);
      return;
    }
    final conflict = PendingConflict(
      taskId: task.id,
      itemId: item.id,
      isDirectory: false,
      sourcePath: work.file.source.path,
      destinationPath: item.destinationPath,
      source: work.file.source,
      existing: DestinationStat.fromEntry(existing),
    );
    runtime.pendingConflicts[item.id] = _ParkedConflict(conflict, item, work);
    _pendingConflictCount++;
    item.state = TransferItemState.conflictPending;
    _emit(TransferQueueItemEvent(task.id, item.id, item.state));
    _emit(
      TransferQueueConflictEvent(
        task.id,
        item.id,
        conflict: conflict,
        pending: true,
      ),
    );
  }

  /// Parks a directory on its collision — same posture as a parked file:
  /// no slot, no lease, no journal record. Children keep waiting on the
  /// directory's `ready` gate, so the subtree holds until the answer.
  void _parkDirectoryConflict(
    _TaskRuntime runtime,
    _DirState directory,
    RemoteFileEntry existing,
  ) {
    final task = runtime.task;
    final item = directory.item;
    if (_pendingConflictCount >= _maxPendingConflicts) {
      runtime.conflictWaiters.addLast(directory);
      return;
    }
    final conflict = PendingConflict(
      taskId: task.id,
      itemId: item.id,
      isDirectory: true,
      sourcePath: directory.planned.source.path,
      destinationPath: item.destinationPath,
      source: directory.planned.source,
      existing: DestinationStat.fromEntry(existing),
    );
    runtime.pendingConflicts[item.id] =
        _ParkedConflict(conflict, item, directory);
    _pendingConflictCount++;
    item.state = TransferItemState.conflictPending;
    _emit(TransferQueueItemEvent(task.id, item.id, item.state));
    _emit(
      TransferQueueConflictEvent(
        task.id,
        item.id,
        conflict: conflict,
        pending: true,
      ),
    );
  }

  /// Returns a parked item to the dispatch path — a file re-enters
  /// `eligible` (re-statting before its verb applies), a directory
  /// re-chains its mkdir op.
  void _requeueParkedWork(_TaskRuntime runtime, Object work) {
    if (work is _FileWork) {
      runtime.eligible.addFirst(work);
    } else if (work is _DirState) {
      runtime.directoryOpsPending++;
      runtime.directoryChain = runtime.directoryChain.then(
        (_) => _runDirectory(runtime, work),
      );
      unawaited(runtime.directoryChain.catchError((_) {}));
    }
  }

  /// Frees a surfaced slot into the oldest queued waiter — it
  /// re-dispatches through the normal path, so a still-colliding waiter
  /// surfaces its own fresh [PendingConflict] (stats are re-read; nothing
  /// stale is ever presented or answered against).
  void _promoteConflictWaiters() {
    while (_pendingConflictCount < _maxPendingConflicts) {
      _TaskRuntime? next;
      for (final runtime in _tasks.values) {
        if (runtime.conflictWaiters.isNotEmpty) {
          next = runtime;
          break;
        }
      }
      if (next == null) return;
      _requeueParkedWork(next, next.conflictWaiters.removeFirst());
    }
    _pump();
  }

  /// Drops a task's parked conflicts and surfaces their dismissal — the
  /// cancel/fail sweeps' half of §4.1's ask-park teardown. Waiters are
  /// dropped with them: their items are already terminal under the sweep.
  void _clearConflicts(_TaskRuntime runtime) {
    final task = runtime.task;
    if (runtime.pendingConflicts.isNotEmpty) {
      for (final parked in runtime.pendingConflicts.values) {
        _emit(
          TransferQueueConflictEvent(
            task.id,
            parked.conflict.itemId,
            conflict: parked.conflict,
            pending: false,
          ),
        );
      }
      _pendingConflictCount -= runtime.pendingConflicts.length;
      runtime.pendingConflicts.clear();
    }
    runtime.conflictWaiters.clear();
    _promoteConflictWaiters();
  }

  /// §4.1's reconnect invalidation: a task flipping back to `queued`
  /// (a §3.3 disconnect) discards its outstanding conflict surface —
  /// the prompts are stale because the plan may no longer match reality.
  /// Parked items return to `pending` and re-dispatch; they re-stat and
  /// re-park fresh, and a reply arriving for an invalidated entry finds
  /// no parked conflict and is ignored. Recorded answers (per-item and
  /// apply-to-all) stay — they are the session's decisions, not prompts.
  void _invalidateConflicts(_TaskRuntime runtime) {
    if (runtime.pendingConflicts.isEmpty) return;
    final task = runtime.task;
    final parked = runtime.pendingConflicts.values.toList();
    runtime.pendingConflicts.clear();
    _pendingConflictCount -= parked.length;
    for (final entry in parked) {
      _emit(
        TransferQueueConflictEvent(
          task.id,
          entry.conflict.itemId,
          conflict: entry.conflict,
          pending: false,
        ),
      );
      final item = entry.item;
      if (item.state == TransferItemState.conflictPending &&
          !item.isTerminal &&
          !task.isTerminal) {
        item.state = TransferItemState.pending;
        _emit(TransferQueueItemEvent(task.id, item.id, item.state));
        _requeueParkedWork(runtime, entry.work);
      }
    }
    _promoteConflictWaiters();
  }

  // ---------------------------------------------------------------------
  // Task lifecycle, pause gating, registry, leases
  // ---------------------------------------------------------------------

  /// Blocks while the queue or the task is paused; cancellation and
  /// dispose always unblock it (jobs never wedge on pause).
  Future<void> _waitForAdmission(_TaskRuntime runtime) async {
    final task = runtime.task;
    while ((_paused || task.state == TransferTaskState.paused) &&
        !task.cancellation.isCancelled &&
        !_disposed) {
      // Wait only on the gate that is actually pending — a completed
      // completer in a Future.any resolves instantly and would spin the
      // loop forever.
      final waits = <Future<void>>[task.cancellation.whenCancelled];
      if (_paused) waits.add(_notPaused.future);
      if (task.state == TransferTaskState.paused) {
        waits.add(runtime.notPaused.future);
      }
      await Future.any(waits);
    }
    _throwIfTaskCancelled(task);
    if (_disposed) throw _cancelledException();
  }

  void _maybeFinishTask(_TaskRuntime runtime) {
    final task = runtime.task;
    if (task.isTerminal) {
      _completeIfDrained(runtime);
      return;
    }
    if (!task.scanComplete || runtime.scanning || runtime.finishing) return;
    if (runtime.attempts.isNotEmpty ||
        runtime.eligible.isNotEmpty ||
        runtime.directoryOpsPending > 0) {
      return;
    }
    for (final item in task.items) {
      if (!item.isTerminal) return;
    }
    runtime.finishing = true;
    unawaited(_finishTask(runtime));
  }

  Future<void> _finishTask(_TaskRuntime runtime) async {
    final task = runtime.task;
    if (task.isTerminal) {
      _completeIfDrained(runtime);
      return;
    }
    final failures = task.items
        .where((item) => item.state == TransferItemState.failed)
        .toList();
    if (failures.isEmpty && task.operation == TransferOperation.move) {
      try {
        await _removeMovedDirectories(runtime);
      } on RemoteFileException catch (error) {
        task.error = "the move's source cleanup failed: ${error.message}";
        task.failureKind = error.kind;
      } catch (error) {
        task.error = "the move's source cleanup failed: $error";
        task.failureKind = RemoteFileErrorKind.other;
      }
    }
    if (failures.isNotEmpty) {
      final failure = failures.first;
      task.error = failure.error;
      task.failureKind = failure.failureKind;
      _setTaskState(
        runtime,
        TransferTaskState.failed,
        error: failure.error,
        failureKind: failure.failureKind,
      );
    } else if (task.error != null) {
      _setTaskState(
        runtime,
        TransferTaskState.failed,
        error: task.error,
        failureKind: task.failureKind,
      );
    } else {
      _setTaskState(runtime, TransferTaskState.completed);
    }
    _releaseRegistryClaims(task.id);
    _completeIfDrained(runtime);
    _pump();
  }

  /// The move verb's source-folder disposition (02 §5.2): directories are
  /// removed deepest-first once every entry transferred; a directory still
  /// holding skipped/failed children is left alone, and a delete that
  /// fails for another reason fails the task — a move that leaves its
  /// source behind is not complete.
  Future<void> _removeMovedDirectories(_TaskRuntime runtime) async {
    final task = runtime.task;
    final directories = task.plan?.directoriesInOrder ?? const [];
    if (directories.isEmpty) return;
    final ordered = directories.toList()
      ..sort((a, b) => b.source.path.length.compareTo(a.source.path.length));
    final leases = await _leaseServerIds(
      _serverIds({task.source}),
      task.cancellation,
    );
    try {
      final srcFs = _fsFor(task.source, leases);
      for (final directory in ordered) {
        // A cancel landing mid-cleanup stops source mutation — the loop
        // must not keep deleting directories for an abandoned task.
        if (task.cancellation.isCancelled) break;
        final dirState = runtime.directories[directory.itemId];
        if (dirState == null || dirState.outcome != _DirOutcome.ready) {
          continue;
        }
        if (!_subtreeFullyCompleted(runtime, directory)) continue;
        try {
          await srcFs.delete(directory.source);
        } on RemoteFileException catch (error) {
          if (error.kind == RemoteFileErrorKind.notFound) continue;
          dirState.item.error =
              'copied, but the source directory could not be removed: '
              '${error.message}';
          _emit(
            TransferQueueItemEvent(
              task.id,
              dirState.item.id,
              dirState.item.state,
              error: dirState.item.error,
            ),
          );
          task.error ??= dirState.item.error;
          task.failureKind ??= error.kind;
        }
      }
    } finally {
      await _releaseLeases(leases);
    }
  }

  bool _subtreeFullyCompleted(
    _TaskRuntime runtime,
    PlannedDirectory directory,
  ) {
    final prefix = _sourceChildPrefix(
      runtime.task.source,
      directory.source.path,
    );
    for (final item in runtime.task.items) {
      if (!item.sourcePath.startsWith(prefix)) continue;
      if (item.state != TransferItemState.completed) return false;
    }
    return true;
  }

  void _completeIfDrained(_TaskRuntime runtime) {
    if (runtime.done.isCompleted) return;
    if (runtime.scanning ||
        runtime.attempts.isNotEmpty ||
        runtime.directoryOpsPending > 0) {
      return;
    }
    _releaseRegistryClaims(runtime.task.id);
    final task = runtime.task;
    if (task.isTerminal) {
      // The task's journal records precede this append on the writer
      // chain, and the store fsyncs the journal before the history line
      // lands (03 §4.6's ordering rule).
      task.finishedAt ??= DateTime.now();
      persistence?.appendHistory(TransferHistoryEntry.fromTask(task));
    }
    runtime.done.complete();
  }

  void _setTaskState(
    _TaskRuntime runtime,
    TransferTaskState state, {
    String? error,
    RemoteFileErrorKind? failureKind,
  }) {
    final task = runtime.task;
    // Terminal and paused states are owned by their own entry points
    // (cancelTask/_failTask, pauseTask/resumeTask); the engine never
    // overrides them implicitly.
    if (task.isTerminal || task.state == TransferTaskState.paused) return;
    // Terminal transitions journal before they take effect; the
    // transient queued/scanning/running churn is replay-neutral (a live
    // task restores as paused-pending regardless) and stays unjournaled.
    if (state == TransferTaskState.completed ||
        state == TransferTaskState.failed ||
        state == TransferTaskState.cancelled) {
      _journalState(task, state, error: error, failureKind: failureKind);
      task.finishedAt ??= DateTime.now();
    }
    task.state = state;
    if (error != null) task.error = error;
    if (failureKind != null) task.failureKind = failureKind;
    _emit(
      TransferQueueTaskEvent(
        task.id,
        state,
        error: error,
        failureKind: failureKind,
      ),
    );
    // A §3.3 disconnect flipping the task back to `queued` invalidates
    // its outstanding conflicts (03 §4.1): the prompt against them may no
    // longer match reality, so parked items re-dispatch, re-stat, and
    // re-surface fresh — a late answer to a stale conflict is ignored.
    if (state == TransferTaskState.queued) _invalidateConflicts(runtime);
  }

  void _failTask(_TaskRuntime runtime, Object error) {
    final task = runtime.task;
    if (task.isTerminal) {
      _completeIfDrained(runtime);
      return;
    }
    final kind = error is RemoteFileException
        ? error.kind
        : RemoteFileErrorKind.other;
    _journalState(
      task,
      TransferTaskState.failed,
      error: '$error',
      failureKind: kind,
    );
    task.error = '$error';
    task.failureKind = kind;
    task.state = TransferTaskState.failed;
    task.finishedAt ??= DateTime.now();
    _emit(
      TransferQueueTaskEvent(
        task.id,
        task.state,
        error: task.error,
        failureKind: kind,
      ),
    );
    for (final item in task.items) {
      if (!item.isTerminal) {
        item.state = TransferItemState.failed;
        item.error ??= task.error;
        item.failureKind ??= kind;
        _emit(TransferQueueItemEvent(task.id, item.id, item.state));
      }
    }
    _clearConflicts(runtime);
    runtime.eligible.clear();
    for (final directory in runtime.directories.values) {
      if (!directory.ready.isCompleted) directory.ready.complete();
    }
    _releaseRegistryClaims(task.id);
    _completeIfDrained(runtime);
  }

  void _finishItem(
    _TaskRuntime runtime,
    TransferItem item,
    TransferItemState state, {
    String? error,
    RemoteFileErrorKind? failureKind,
  }) {
    if (item.isTerminal) return;
    _journalItemOutcome(
      runtime.task,
      item,
      state,
      error: error,
      failureKind: failureKind,
    );
    item.state = state;
    item.error = error;
    item.failureKind = failureKind;
    final task = runtime.task;
    if (state == TransferItemState.completed && !item.isDirectory) {
      task.completedFiles++;
    }
    if (state == TransferItemState.failed) task.failedItems++;
    if (state == TransferItemState.skipped) task.skippedItems++;
    _emit(TransferQueueItemEvent(task.id, item.id, state, error: error));
  }

  TransferItem _addPendingItem(
    _TaskRuntime runtime, {
    required String id,
    required RemoteFileEntry entry,
    required String destinationPath,
    bool isDirectory = false,
  }) {
    final item = TransferItem(
      id: id,
      sourcePath: entry.path,
      isDirectory: isDirectory,
      destinationPath: destinationPath,
      size: entry.size,
    );
    runtime.task.items.add(item);
    _emit(TransferQueueItemEvent(runtime.task.id, item.id, item.state));
    return item;
  }

  // ---------------------------------------------------------------------
  // Persistence (03 §4.6) — journal calls always precede the in-memory
  // transition they describe; a null store keeps the #147 behavior.
  // ---------------------------------------------------------------------

  /// Removes a terminal task from the queue listing (the activity
  /// panel's clear-finished gesture). Journaled as `taskRemoved` so a
  /// restart neither restores a dismissed task nor rewrites its journal
  /// prefix — the task's history record is unaffected.
  bool removeTask(String taskId) {
    final runtime = _tasks[taskId];
    if (runtime == null || !runtime.task.isTerminal) return false;
    persistence?.appendJournal(TaskRemovedRecord(taskId: taskId));
    _tasks.remove(taskId);
    return true;
  }

  /// Rebuilds the crashed session's queue from the journal (03 §4.6):
  /// every non-terminal journaled task re-enters with its journaled
  /// state — a per-task `paused` survives, `running`/`scanning` map to
  /// `queued` — and restoration forces §4.4's queue-level pause flag on
  /// (runtime-only, never journaled), so no restored work can dispatch
  /// before the user resumes the queue. Pending items re-dispatch from
  /// byte zero; journaled terminal items never resurrect. Prompt state
  /// does not survive. No-op without a store and idempotent on repeat
  /// calls.
  Future<void> restore() async {
    if (_disposed || _restored) return;
    _restored = true;
    final store = persistence;
    if (store == null) return;
    // The forced pause lands before any adoption so a mid-scan task's
    // `_runTask` and a rebuilt plan's `_pump` both see it. An empty
    // replay has no restored queue to pause — flagging it would wedge
    // fresh enqueues behind a Resume nobody is waiting for.
    if (store.replay.tasks.isNotEmpty) pauseQueue();
    final adoptedAt = DateTime.now();
    for (final restored in store.replay.tasks) {
      final task = _adoptRestored(restored);
      // Best-effort hygiene — never serialized into startup latency:
      // an unreachable server's sweep retries on next launch (03 §4.6).
      unawaited(_sweepRestoredTemps(restored, task, adoptedAt));
    }
  }

  /// Adopts one replayed task: rebuilds its plan, items, and dispatch
  /// state under the journaled-or-mapped state (03 §4.6).
  TransferTask _adoptRestored(RestoredTransferTask restored) {
    final task = TransferTask.restored(
      restored.spec,
      id: restored.taskId,
      enqueuedAt: restored.enqueuedAt,
    );
    // Work began before the crash — the history record's duration and
    // the user's sense of "when did I start this" both span it.
    task.startedAt = restored.enqueuedAt;
    final runtime = _TaskRuntime(task);
    _tasks[task.id] = runtime;

    // The state mapping lands BEFORE any dispatch state is built —
    // `_rebuildScannedPlan` arms eligible work and `_pump` must see the
    // task already in its journaled state.
    final mapped = restored.wasPaused
        ? TransferTaskState.paused
        : TransferTaskState.queued;
    _journalState(task, mapped);
    task.state = mapped;
    if (mapped == TransferTaskState.paused) {
      runtime.notPaused = Completer();
    }

    if (restored.scanComplete) {
      // Totals land BEFORE the rebuild: terminal-item bookkeeping inside
      // `_rebuildScannedPlan` can finish the task, and the finish path
      // needs scanComplete + totalBytes for an honest history row.
      task.scanComplete = true;
      task.totalBytes = restored.totalBytes;
      _rebuildScannedPlan(runtime, restored);
      task.plan!.skippedSymlinks = restored.skippedSymlinks;
    } else {
      // A mid-scan crash re-scans on resume; the merge index suppresses
      // re-dispatch of journaled terminal items by destination path.
      final index = <String, List<RestoredPlanItem>>{};
      for (final item in restored.items) {
        (index[item.destinationPath] ??= []).add(item);
      }
      runtime.restoredIndex = index;
    }
    _emit(TransferQueueTaskEvent(task.id, task.state));
    // A queued restore whose every journaled item already ended
    // terminal (its task-terminal record was the torn tail) drains to
    // its honest terminal state here; a paused restore still waits for
    // resumeTask to end the surviving pause (03 §4.6).
    if (mapped != TransferTaskState.paused) _maybeFinishTask(runtime);

    if (!restored.scanComplete) {
      // The re-scan waits out both pauses — the queue-level restore
      // flag (resumeQueue) and a surviving per-task pause (resumeTask)
      // — so nothing surfaces `scanning` or acquires scan leases before
      // the user resumes.
      unawaited(() async {
        await _notPaused.future;
        await runtime.notPaused.future;
        if (!_disposed && !task.isTerminal) unawaited(_runTask(runtime));
      }());
    }
    return task;
  }

  /// Rebuilds a fully-scanned task's plan and dispatch state from the
  /// journaled records (no re-scan — `scanComplete` survived).
  void _rebuildScannedPlan(
    _TaskRuntime runtime,
    RestoredTransferTask restored,
  ) {
    final task = runtime.task;
    task.plan = TransferPlan();
    final pendingDirs = <_DirState>[];
    final pendingFiles = <_FileWork>[];
    for (final entry in restored.items) {
      final item = TransferItem(
        id: entry.itemId,
        sourcePath: entry.sourcePath,
        isDirectory: entry.isDirectory,
        destinationPath: entry.resolvedPath ?? entry.destinationPath,
        size: entry.source?.size,
      );
      task.items.add(item);
      if (entry.isDirectory) {
        final planned = PlannedDirectory(
          source:
              entry.source ??
              _placeholderEntry(entry, RemoteFileType.directory),
          name:
              entry.name ?? _leafName(task.destination, entry.destinationPath),
          containerKey: entry.containerKey,
          destinationPath: entry.destinationPath,
          existing: entry.existing,
          itemId: entry.itemId,
        );
        task.plan!.directoriesInOrder.add(planned);
        final dirState = _DirState(planned: planned, item: item);
        runtime.directories[planned.itemId] = dirState;
        switch (entry.outcome) {
          case RestoredItemOutcome.completed:
            dirState.outcome = _DirOutcome.ready;
            dirState.resolvedPath =
                entry.resolvedPath ?? entry.destinationPath;
            dirState.ready.complete();
            item.state = TransferItemState.completed;
          case RestoredItemOutcome.failed:
            dirState.outcome = _DirOutcome.failed;
            dirState.ready.complete();
            item.state = TransferItemState.failed;
            item.error = entry.error;
            item.failureKind = entry.failureKind;
            task.failedItems++;
          case RestoredItemOutcome.removed:
            dirState.outcome = _DirOutcome.skipped;
            dirState.ready.complete();
            item.state = TransferItemState.skipped;
            item.error = entry.error;
            task.skippedItems++;
          case null:
            if (entry.source == null) {
              // The planEntry's source detail was lost (a quarantined
              // journal tail) — the mkdir cannot re-run, so the item
              // fails honestly rather than dispatching blind.
              dirState.outcome = _DirOutcome.failed;
              dirState.ready.complete();
              item.state = TransferItemState.failed;
              item.error = 'the journal lost this item\'s source detail';
              item.failureKind = RemoteFileErrorKind.other;
              task.failedItems++;
            } else {
              pendingDirs.add(dirState);
            }
        }
      } else {
        switch (entry.outcome) {
          case RestoredItemOutcome.completed:
            item.state = TransferItemState.completed;
            task.completedFiles++;
            task.transferredBytes += entry.source?.size ?? 0;
          case RestoredItemOutcome.failed:
            item.state = TransferItemState.failed;
            item.error = entry.error;
            item.failureKind = entry.failureKind;
            task.failedItems++;
          case RestoredItemOutcome.removed:
            item.state = TransferItemState.skipped;
            item.error = entry.error;
            task.skippedItems++;
          case null:
            final source = entry.source;
            if (source == null) {
              item.state = TransferItemState.failed;
              item.error = 'the journal lost this item\'s source detail';
              item.failureKind = RemoteFileErrorKind.other;
              task.failedItems++;
            } else {
              final planned = PlannedFile(
                source: source,
                name: entry.name ??
                    _leafName(task.destination, entry.destinationPath),
                containerKey: entry.containerKey,
                destinationPath: entry.destinationPath,
                existing: entry.existing,
                itemId: entry.itemId,
              );
              task.plan!.files.add(planned);
              pendingFiles.add(_FileWork(item: item, file: planned));
            }
        }
      }
    }
    // Directories arm before files so a pending file can look its
    // container up in `runtime.directories`.
    for (final dirState in pendingDirs) {
      _scheduleDirectory(runtime, dirState);
    }
    for (final work in pendingFiles) {
      _armRestoredFile(runtime, work);
    }
  }

  /// `_armFile` with the journal-loss guard: a pending file whose
  /// container's planEntry never survived cannot wait on a `ready` that
  /// never completes — it skips honestly.
  void _armRestoredFile(_TaskRuntime runtime, _FileWork work) {
    final containerKey = work.file.containerKey;
    if (containerKey != null &&
        !runtime.directories.containsKey(containerKey)) {
      _finishItem(
        runtime,
        work.item,
        TransferItemState.skipped,
        error: 'the journal lost the item\'s containing directory',
      );
      _maybeFinishTask(runtime);
      return;
    }
    _armFile(runtime, work);
  }

  /// Deletes abandoned upload temps (the `.poltergeist-*.tmp` /
  /// `.seance-upload-*.tmp` siblings the VFS writes before rename),
  /// scoped to the directories the journal names — never a general
  /// sweep (03 §4.6). Entries modified at/after [adoptedAt] are left
  /// alone: a user resuming mid-sweep may have just minted them.
  Future<void> _sweepRestoredTemps(
    RestoredTransferTask restored,
    TransferTask task,
    DateTime adoptedAt,
  ) async {
    if (restored.sweepDirectories.isEmpty) return;
    final Map<String, TransferChannelLease> leases;
    try {
      leases = await _leaseServerIds(
        _serverIds({task.destination}),
        task.cancellation,
      );
    } on Object {
      // No channels — the sweep retries on next launch.
      return;
    }
    try {
      final fs = _fsFor(task.destination, leases);
      for (final directory in restored.sweepDirectories) {
        final List<RemoteFileEntry> entries;
        try {
          entries = await fs.listDirectory(directory);
        } on Object {
          continue;
        }
        for (final entry in entries) {
          if (!_isTransferTemp(entry.name)) continue;
          final modified = entry.modifiedAt;
          if (modified != null && !modified.isBefore(adoptedAt)) continue;
          try {
            await fs.delete(entry);
          } on Object {
            // Best-effort hygiene — a stubborn temp is retried next time.
          }
        }
      }
    } on Object {
      // Sweeps are fire-and-forget from restore() — nothing may throw.
    } finally {
      await _releaseLeases(leases);
    }
  }

  static bool _isTransferTemp(String name) =>
      (name.startsWith('.poltergeist-') || name.startsWith('.seance-upload-')) &&
      name.endsWith('.tmp');

  /// Journals a lifecycle transition before its caller mutates
  /// `task.state` (write-before-effect, 03 §4.6).
  void _journalState(
    TransferTask task,
    TransferTaskState state, {
    String? error,
    RemoteFileErrorKind? failureKind,
  }) {
    persistence?.appendJournal(
      TaskStateRecord(
        taskId: task.id,
        state: state,
        error: error,
        failureKind: failureKind,
      ),
    );
  }

  /// Journals one scanned plan entry before it lands in the plan — a
  /// crash mid-scan must find every dispatched item in the journal.
  void _journalPlanEntry(
    TransferTask task, {
    required String itemId,
    required bool isDirectory,
    required RemoteFileEntry source,
    required String name,
    required String? containerKey,
    required String destinationPath,
    DestinationStat? existing,
  }) {
    persistence?.appendJournal(
      PlanEntryRecord(
        taskId: task.id,
        itemId: itemId,
        isDirectory: isDirectory,
        sourcePath: source.path,
        destinationPath: destinationPath,
        sourceType: source.type,
        sourceSize: source.size,
        sourceModifiedAt: source.modifiedAt,
        sourceMode: source.mode,
        name: name,
        containerKey: containerKey,
        existing: existing,
      ),
    );
  }

  /// Journals an item's terminal outcome before `item.state` mutates.
  /// Skipped and cancelled both record `itemRemoved` (03 §4.6's
  /// vocabulary) — the item must not re-dispatch after a restart.
  void _journalItemOutcome(
    TransferTask task,
    TransferItem item,
    TransferItemState state, {
    String? error,
    RemoteFileErrorKind? failureKind,
    String? resolvedPath,
  }) {
    final store = persistence;
    if (store == null) return;
    switch (state) {
      case TransferItemState.completed:
        store.appendJournal(
          FileCompletedRecord(
            taskId: task.id,
            itemId: item.id,
            resolvedPath: resolvedPath ?? item.destinationPath,
          ),
        );
      case TransferItemState.failed:
        store.appendJournal(
          FileFailedRecord(
            taskId: task.id,
            itemId: item.id,
            error: error,
            failureKind: failureKind,
          ),
        );
      case TransferItemState.skipped || TransferItemState.cancelled:
        store.appendJournal(
          ItemRemovedRecord(
            taskId: task.id,
            itemId: item.id,
            error: error,
          ),
        );
      case TransferItemState.pending ||
          TransferItemState.active ||
          TransferItemState.conflictPending:
        break;
    }
  }

  /// A re-scanned entry whose journaled outcome is already terminal
  /// enters as a finished row — never re-dispatched (03 §4.6's
  /// no-resurrection rule).
  TransferItem _addRestoredTerminalItem(
    _TaskRuntime runtime,
    RestoredPlanItem restored,
    RemoteFileEntry entry,
    String destinationPath, {
    required bool isDirectory,
  }) {
    final task = runtime.task;
    final item = TransferItem(
      id: restored.itemId,
      sourcePath: entry.path,
      isDirectory: isDirectory,
      destinationPath: restored.resolvedPath ?? destinationPath,
      size: entry.size,
    );
    switch (restored.outcome!) {
      case RestoredItemOutcome.completed:
        item.state = TransferItemState.completed;
        if (!isDirectory) task.completedFiles++;
      case RestoredItemOutcome.failed:
        item.state = TransferItemState.failed;
        item.error = restored.error;
        item.failureKind = restored.failureKind;
        task.failedItems++;
      case RestoredItemOutcome.removed:
        item.state = TransferItemState.skipped;
        item.error = restored.error;
        task.skippedItems++;
    }
    task.items.add(item);
    _emit(
      TransferQueueItemEvent(task.id, item.id, item.state, error: item.error),
    );
    return item;
  }

  /// A placeholder `RemoteFileEntry` for a journaled directory whose
  /// source detail was lost — the item is terminal either way, so the
  /// entry is never dispatched, only carried for the plan record.
  RemoteFileEntry _placeholderEntry(
    RestoredPlanItem item,
    RemoteFileType type,
  ) => RemoteFileEntry(
    path: item.sourcePath,
    name: item.name ?? item.sourcePath,
    type: type,
    size: item.source?.size,
  );

  void _addTerminalItem(
    _TaskRuntime runtime, {
    required String sourcePath,
    required String destinationPath,
    required TransferItemState state,
    int? size,
    String? error,
    RemoteFileErrorKind? failureKind,
  }) {
    final task = runtime.task;
    final item = TransferItem(
      id: uuidV4(),
      sourcePath: sourcePath,
      isDirectory: false,
      destinationPath: destinationPath,
      size: size,
    );
    // Journal the entry and its terminal outcome before the row exists —
    // a scan-time terminal item (skipped symlink, failed root stat) is
    // part of the task's record like any other (03 §4.6).
    persistence?.appendJournal(
      PlanEntryRecord(
        taskId: task.id,
        itemId: item.id,
        isDirectory: false,
        sourcePath: sourcePath,
        destinationPath: destinationPath,
        sourceSize: size,
      ),
    );
    _journalItemOutcome(
      task,
      item,
      state,
      error: error,
      failureKind: failureKind,
    );
    item.state = state;
    item.error = error;
    item.failureKind = failureKind;
    task.items.add(item);
    if (state == TransferItemState.failed) runtime.task.failedItems++;
    if (state == TransferItemState.skipped) runtime.task.skippedItems++;
    _emit(
      TransferQueueItemEvent(runtime.task.id, item.id, state, error: error),
    );
  }

  void _emit(TransferQueueEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  // ---------------------------------------------------------------------
  // Lease and registry helpers
  // ---------------------------------------------------------------------

  /// Leases every server endpoint of [spec] in sorted server-id order so
  /// two concurrent dispatches can never deadlock over lease order.
  Future<Map<String, TransferChannelLease>> _leaseEndpoints(
    TransferTaskSpec spec,
    RemoteTransferCancellation token,
  ) {
    return _leaseServerIds(
      _serverIds({spec.source, spec.destination}),
      token,
    );
  }

  Future<Map<String, TransferChannelLease>> _leaseServerIds(
    List<String> serverIds,
    RemoteTransferCancellation token,
  ) async {
    final leases = <String, TransferChannelLease>{};
    try {
      for (final serverId in serverIds) {
        leases[serverId] = await _leaseCancellable(serverId, token);
      }
      return leases;
    } catch (_) {
      await _releaseLeases(leases);
      rethrow;
    }
  }

  /// `leaseTransferChannel` blocks while the pool is at capacity or a
  /// reconnect is in flight — so the wait races the attempt token, and a
  /// lease that lands after cancellation is released immediately (03
  /// §4.3's deterministic-release rule).
  Future<TransferChannelLease> _leaseCancellable(
    String serverId,
    RemoteTransferCancellation token,
  ) async {
    if (token.isCancelled) throw _cancelledException();
    final leaseFuture = connections.leaseTransferChannel(serverId);
    final result = await Future.any(<Future<Object?>>[
      leaseFuture.then<Object?>((lease) => lease),
      token.whenCancelled.then<Object?>((_) => null),
    ]);
    if (result is TransferChannelLease) {
      if (token.isCancelled) {
        await _releaseLeases({'': result});
        throw _cancelledException();
      }
      return result;
    }
    // Cancelled while waiting: the pending lease may still land — release
    // it (or swallow its error) instead of leaking a pool slot.
    unawaited(
      leaseFuture.then<void>((lease) async {
        try {
          await lease.release();
        } catch (_) {}
      }, onError: (_) {}),
    );
    throw _cancelledException();
  }

  Future<void> _releaseLeases(
    Map<String, TransferChannelLease>? leases,
  ) async {
    if (leases == null) return;
    for (final lease in leases.values) {
      try {
        await lease.release();
      } catch (_) {}
    }
  }

  void _releaseClaim((String, String) key, _RegistryClaim claim) {
    if (identical(_registry[key], claim)) _registry.remove(key);
    if (!claim.committed.isCompleted) claim.committed.complete();
  }

  void _releaseRegistryClaims(String taskId) {
    final released = <_RegistryClaim>[];
    _registry.removeWhere((_, claim) {
      if (claim.taskId != taskId) return false;
      released.add(claim);
      return true;
    });
    // A dropped claim must still release its waiters — they re-stat
    // reality on dispatch anyway (03 §4.2).
    for (final claim in released) {
      if (!claim.committed.isCompleted) claim.committed.complete();
    }
  }

  // ---------------------------------------------------------------------
  // Small pure helpers
  // ---------------------------------------------------------------------

  /// A plan item's actual containing path: the task's `destinationDir` for
  /// top-level entries, else the containing directory's *resolved* path —
  /// which tracks keep-both renames. Null when the container was skipped
  /// or failed (the item then skips itself).
  String? _resolvedContainer(_TaskRuntime runtime, String? containerKey) {
    if (containerKey == null) return runtime.task.destinationDir;
    final parent = runtime.directories[containerKey];
    if (parent == null || parent.outcome != _DirOutcome.ready) return null;
    return parent.resolvedPath;
  }

  RemoteFileSystem _fsFor(
    FsLocation location,
    Map<String, TransferChannelLease> leases,
  ) => location is ServerFsLocation
      ? leases[location.serverId]!.fs
      : _localFileSystem;

  /// Server ids are deduped: FsLocation has no value equality, so a
  /// same-server transfer (two ServerFsLocation instances naming one
  /// server) would otherwise double-lease — the map overwrite would then
  /// strand the first lease forever.
  List<String> _serverIds(Set<FsLocation> locations) => [
    ...{
      for (final location in locations)
        if (location is ServerFsLocation) location.serverId,
    },
  ]..sort();

  String _endpointKey(FsLocation location) =>
      location is ServerFsLocation ? 'srv:${location.serverId}' : 'local';

  String _joinDest(FsLocation destination, String directory, String name) =>
      destination is ServerFsLocation
          ? remoteJoin(directory, name)
          : p.join(directory, name);

  /// The registry's case-fold rule (03 §4.2): destinations resolved
  /// case-insensitive fold with the browse layer's Unicode simple fold.
  String _fold(TransferTask task, String path) =>
      _isCaseInsensitiveDestination(task.destination)
          ? simpleCaseFold(path)
          : path;

  String _validatedDestinationName(FsLocation destination, String name) {
    if (destination is ServerFsLocation) {
      validatePathComponent(name);
    } else {
      validateLocalName(name);
    }
    return name;
  }

  String _leafName(FsLocation location, String path) =>
      location is ServerFsLocation
          ? path.replaceAll(RegExp(r'/+$'), '').split('/').last
          : p.basename(path.replaceAll(RegExp(r'[/\\]+$'), ''));

  String _sourceChildPrefix(FsLocation location, String directory) =>
      location is ServerFsLocation
          ? '$directory/'
          : '$directory${p.separator}';

  Future<RemoteFileEntry?> _statOrNull(RemoteFileSystem fs, String path) async {
    try {
      return await fs.stat(path, followLinks: false);
    } on RemoteFileException catch (error) {
      if (error.kind == RemoteFileErrorKind.notFound) return null;
      rethrow;
    }
  }

  /// Trailing separators are stripped and exact duplicates plus roots
  /// nested inside an already-kept root are dropped. Separator handling is
  /// source-aware: a remote path may legitimately contain a backslash in a
  /// name, so `\\` only counts as a separator for local sources.
  List<String> _normalizeRoots(List<String> roots, FsLocation source) {
    final separators = source is LocalFsLocation && Platform.isWindows
        ? '/\\'
        : '/';
    final normalized = <String>[];
    for (final root in roots) {
      var path = root;
      while (path.length > 1 &&
          separators.contains(path[path.length - 1])) {
        final trimmed = path.substring(0, path.length - 1);
        // Never strip a drive root to its bare letter (`C:` is a
        // different, relative path on Windows).
        if (trimmed.length == 2 && trimmed.endsWith(':')) break;
        path = trimmed;
      }
      if (normalized.contains(path)) continue;
      var nested = false;
      for (final kept in normalized) {
        // A kept root ending in a separator ('/' or 'C:\') already
        // carries the boundary — a bare prefix test is the containment
        // check there. An empty kept root is inert: left in the else
        // branch it would wrongly prefix-match every absolute path.
        if (kept.isEmpty) continue;
        if (separators.contains(kept[kept.length - 1])) {
          nested = path.startsWith(kept);
        } else {
          for (final separator in separators.split('')) {
            if (path.startsWith('$kept$separator')) {
              nested = true;
              break;
            }
          }
        }
        if (nested) break;
      }
      if (!nested) normalized.add(path);
    }
    return normalized;
  }

  static bool _defaultCaseSensitivity(FsLocation destination) =>
      destination is LocalFsLocation &&
      (Platform.isMacOS || Platform.isWindows);

  void _throwIfTaskCancelled(TransferTask task) {
    if (task.cancellation.isCancelled) throw _cancelledException();
  }

  RemoteFileException _cancelledException() => const RemoteFileException(
    kind: RemoteFileErrorKind.cancelled,
    operation: 'transfer',
    message: 'transfer cancelled',
  );
}

/// Queue-wide cap on surfaced [PendingConflict] entries — the "bounded
/// pending-conflict storage" rule. Collisions past the cap sit in
/// `conflictWaiters` instead; they cost a queue entry, not a surface.
const maxSurfacedPendingConflicts = 256;

/// Upper bound for keep-both numbering so a pathological destination
/// cannot spin the candidate loop forever.
const _maxKeepBothAttempts = 99;

/// How often a commit-level conflict re-runs the decision on fresh
/// reality before the item fails honestly.
const _maxCommitRetries = 8;

/// Per-task runtime state the public [TransferTask] model doesn't carry.
class _TaskRuntime {
  _TaskRuntime(this.task);

  final TransferTask task;

  /// Plan-directory state by `PlannedDirectory.itemId`.
  final Map<String, _DirState> directories = {};

  /// itemId → per-attempt token (03 §4.4: pause cancels attempts, never
  /// the sticky task token).
  final Map<String, RemoteTransferCancellation> attempts = {};

  /// Queue-ordered dispatch backlog for this task's discovered files.
  final ListQueue<_FileWork> eligible = ListQueue();

  /// Serializes this task's directory operations parents-first.
  Future<void> directoryChain = Future.value();
  int directoryOpsPending = 0;

  /// Channels held for the scan's duration; swapped by the
  /// reconnect-retry path.
  Map<String, TransferChannelLease>? scanLeases;
  bool scanning = false;

  /// Mid-scan-restart merge index (03 §4.6): a restored task that crashed
  /// mid-scan re-scans, and each rediscovered entry pops its journaled
  /// record by planned destination path — reusing the itemId and letting
  /// an already-terminal outcome suppress re-dispatch.
  Map<String, List<RestoredPlanItem>>? restoredIndex;

  /// itemId → the session's answer for a once-parked conflict. Re-read on
  /// every re-dispatch, so a re-parked item keeps its user's verb. Never
  /// journaled — 03 §4.6: prompt state does not survive restart.
  final Map<String, ConflictResolution> resolvedAnswers = {};

  /// The task-scoped answer installed by a "apply to all remaining"
  /// resolution (02 §5.2's checkbox), via [taskScopePolicy]'s per-kind
  /// analogs. Session-scoped for the same reason as [resolvedAnswers].
  ResolvedConflictPolicy? applyToAll;

  /// itemId → parked work behind a surfaced [PendingConflict] — bounded
  /// queue-wide by [maxSurfacedPendingConflicts].
  final Map<String, _ParkedConflict> pendingConflicts = {};

  /// Collisions that arrived while the surface was at cap: they hold no
  /// slot, lease, or pending entry until [TransferQueue
  /// ._promoteConflictWaiters] re-dispatches them to re-stat fresh.
  final ListQueue<Object> conflictWaiters = ListQueue();

  /// Pops the journaled record for [destinationPath], preferring the
  /// entry whose [sourcePath] also matches — two plan items can share
  /// a destination — but falling back to the bucket head so a terminal
  /// outcome still suppresses re-dispatch when the source moved (the
  /// no-resurrection rule outranks an exact match, 03 §4.6).
  RestoredPlanItem? takeRestored(String destinationPath, String sourcePath) {
    final queue = restoredIndex?[destinationPath];
    if (queue == null || queue.isEmpty) return null;
    var index = 0;
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].sourcePath == sourcePath) {
        index = i;
        break;
      }
    }
    final item = queue.removeAt(index);
    if (queue.isEmpty) restoredIndex!.remove(destinationPath);
    return item;
  }

  /// Set once `_finishTask` starts so concurrent `_maybeFinishTask` calls
  /// cannot double-run the terminal path.
  bool finishing = false;

  /// Completed whenever the task is not paused; recreated on pause.
  Completer<void> notPaused = Completer()..complete();

  /// Completes when the task is terminal and every in-flight attempt and
  /// scan operation has drained.
  final Completer<void> done = Completer();
}

class _DirState {
  _DirState({required this.planned, required this.item});

  final PlannedDirectory planned;
  final TransferItem item;

  /// Completes when this directory's mkdir resolved (any outcome), which
  /// releases its file children to dispatch — or skips them.
  final Completer<void> ready = Completer();
  String? resolvedPath;
  _DirOutcome outcome = _DirOutcome.pending;
}

enum _DirOutcome { pending, ready, skipped, failed, cancelled }

class _FileWork {
  const _FileWork({required this.item, required this.file});

  final TransferItem item;
  final PlannedFile file;
}

/// One in-flight commit's hold on a (endpoint, folded path) registry key.
/// [committed] completes when the holder reaches any terminal state so a
/// waiter always re-stats reality (03 §4.2).
class _RegistryClaim {
  _RegistryClaim(this.taskId);

  final String taskId;
  final Completer<void> committed = Completer();
}

/// The executor's conflict-decision outcomes.
sealed class _FileDecision {
  const _FileDecision();
}

final class _FileSkip extends _FileDecision {
  const _FileSkip(this.detail);

  final String detail;
}

/// The decision needs an answer: park the item (03 §4.1's ask-park) and
/// surface the collision through the conflict seam. Carries the live
/// occupant so the [PendingConflict] records fresh destination stats.
final class _FileAsk extends _FileDecision {
  const _FileAsk(this.existing);

  final RemoteFileEntry existing;
}

final class _FileError extends _FileDecision {
  const _FileError(this.message);

  final String message;
}

final class _FileCommit extends _FileDecision {
  const _FileCommit({
    required this.destinationPath,
    required this.overwrite,
    required this.expectedTarget,
  });

  final String destinationPath;
  final bool overwrite;
  final RemoteFileEntry? expectedTarget;
}

/// A surfaced conflict plus the work it parks — [work] is a `_FileWork`
/// or a `_DirState`, requeued by `_requeueParkedWork` on answer,
/// promotion, or invalidation. [item] is the parked row so invalidation
/// can flip its state without re-resolving the work's shape.
final class _ParkedConflict {
  const _ParkedConflict(this.conflict, this.item, this.work);

  final PendingConflict conflict;
  final TransferItem item;
  final Object work;
}

/// In-process queue events — the engine host maps these onto the §5 wire
/// events (`TransferProgressBatchEvent` and friends) in the host slice.
sealed class TransferQueueEvent {
  const TransferQueueEvent(this.taskId);

  final String taskId;
}

/// A task's lifecycle transition.
final class TransferQueueTaskEvent extends TransferQueueEvent {
  const TransferQueueTaskEvent(
    super.taskId,
    this.state, {
    this.error,
    this.failureKind,
  });

  final TransferTaskState state;
  final String? error;
  final RemoteFileErrorKind? failureKind;
}

/// An item's state transition.
final class TransferQueueItemEvent extends TransferQueueEvent {
  const TransferQueueItemEvent(
    super.taskId,
    this.itemId,
    this.state, {
    this.error,
  });

  final String itemId;
  final TransferItemState state;
  final String? error;
}

/// A conflict entered or left the parked surface (02 §5.2, 03 §4.1).
/// `pending: true` carries the fresh [PendingConflict] to render;
/// `pending: false` dismisses it — answered, invalidated by a reconnect
/// (a fresh `pending: true` event follows if the collision still stands),
/// or cleared by cancel/fail. This is the registered seam the future
/// `EnginePromptKind.conflict` prompt maps onto; no UI lives here.
final class TransferQueueConflictEvent extends TransferQueueEvent {
  const TransferQueueConflictEvent(
    super.taskId,
    this.itemId, {
    required this.conflict,
    required this.pending,
  });

  final String itemId;
  final PendingConflict conflict;
  final bool pending;
}

/// Byte progress on one item plus the task rollups (02 §5.3's growing
/// totals — `taskTotalBytes` is a floor while `scanComplete` is false).
final class TransferQueueProgressEvent extends TransferQueueEvent {
  const TransferQueueProgressEvent(
    super.taskId, {
    required this.itemId,
    required this.transferred,
    required this.total,
    required this.taskTransferredBytes,
    required this.taskTotalBytes,
    required this.scanComplete,
  });

  final String itemId;
  final int transferred;
  final int? total;
  final int taskTransferredBytes;
  final int taskTotalBytes;
  final bool scanComplete;
}
