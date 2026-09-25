import 'dart:async';
import 'dart:collection';
import 'dart:io' show File, Platform;

import 'package:path/path.dart' as p;
import 'package:seance_core/seance_core.dart';

import '../browse/unicode_simple_fold.dart';
import '../checkout/managed_checkout_spec.dart';
import '../connection/connection_manager.dart';
import '../connection/pool_policy.dart';
import '../editor/built_in_text_document.dart';
import '../fs/local_file_system.dart';
import '../fs/local_fs_safety.dart';
import '../preview/preview_kinds.dart';
import '../preview/preview_produce.dart';
import 'bandwidth_limiter.dart';
import 'bounded_transfer_sink.dart';
import 'conflict_policy.dart';
import 'recursive_walker.dart';
import 'transfer_journal.dart';
import 'transfer_task.dart';
import 'trash_service.dart';

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
/// The delete verb (00 D15) runs through this queue too:
/// [prepareDelete] builds the confirmation's disclosure model and
/// [enqueueDelete] enqueues the confirmed task — the walker's post-order
/// delete enumeration feeds a serialized executor that routes every item
/// through the trash layer (OS trash locally, `.poltergeist-trash/`
/// remotely when the server opted in, raw `delete` only on the
/// confirmed-permanent path). A `replace` that must remove an occupant
/// still fails the item honestly rather than deleting unguarded.
///
/// Deferred to later M4 slices: the D14 produce-on-demand hook, the
/// occupant-replacement integration of D15, and all UI.
/// The narrow queue surface a checkout manager needs — the managed verb
/// plus the event stream its completions arrive on. [TransferQueue]
/// implements it; the seam exists so tests and composition can
/// substitute.
abstract interface class ManagedCheckoutQueue {
  TransferTask enqueueManagedCheckout(ManagedCheckoutSpec spec);
  Stream<TransferQueueEvent> get events;
  List<TransferTask> get tasks;
}

class TransferQueue implements ManagedCheckoutQueue, TransferProducer {
  TransferQueue({
    required this.connections,
    RemoteFileSystem? localFileSystem,
    this.poolPolicy = const PoolPolicy(),
    bool Function(FsLocation destination)? isCaseInsensitiveDestination,
    bool Function(RemoteFileEntry entry)? isFlaggedEntry,
    int maxInFlightFiles = maxGlobalInFlightTransfers,
    int maxPendingConflicts = maxSurfacedPendingConflicts,
    this.pipeBufferBytes = 4 * 1024 * 1024,
    BandwidthLimiter? downloadLimiter,
    BandwidthLimiter? uploadLimiter,
    Future<void> Function(String destinationPath)? flushLocalDestination,
    LocalTrashService? localTrash,
    RemoteTrash? remoteTrash,
    bool Function(String serverId)? remoteTrashEnabled,
    this.deleteQuantifyTimeout = const Duration(seconds: 10),
    this.persistence,
  }) : _localFileSystem = localFileSystem ?? LocalFileSystem(),
       _isCaseInsensitiveDestination =
           isCaseInsensitiveDestination ?? _defaultCaseSensitivity,
       _isFlaggedEntry = isFlaggedEntry ?? _noFlags,
       localTrash = localTrash ?? LocalTrashService(),
       remoteTrash = remoteTrash ?? RemoteTrash(),
       _remoteTrashEnabled = remoteTrashEnabled ?? _trashOptedOut,
       flushLocalDestination =
           flushLocalDestination ?? _flushLocalDestinationDefault,
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

  /// The §13 flag detector handed to the scan's [RecursiveWalker] —
  /// it defaults to [_noFlags] until the upstream `RemoteFileEntry`
  /// exposes raw-name metadata (docs/STATUS.md open item 13), so
  /// nothing is flagged today. Never wire it to a decoded-name
  /// heuristic: a literal U+FFFD in an otherwise valid name is real
  /// data, not a flag.
  final bool Function(RemoteFileEntry entry) _isFlaggedEntry;

  static bool _noFlags(RemoteFileEntry _) => false;
  final int _maxInFlightFiles;

  /// The D15 trash layer (03 §7.1/§7.3): [localTrash] dispatches to the
  /// platform's OS-trash mechanism, [remoteTrash] owns the
  /// `.poltergeist-trash/<runId>` layout, and [_remoteTrashEnabled] is
  /// the per-server opt-in (00 D15: remote deletion is
  /// confirm-then-permanent unless enabled).
  final LocalTrashService localTrash;
  final RemoteTrash remoteTrash;
  final bool Function(String serverId) _remoteTrashEnabled;

  static bool _trashOptedOut(String _) => false;

  /// The confirmation quantification budget (02 §10's "may fall back to
  /// unquantified copy on timeout/error" — the dialog's count/size
  /// disclosure degrades, never the delete itself).
  final Duration deleteQuantifyTimeout;

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

  /// The produce path's own bucket (03 §4.7): preview downloads bypass
  /// the user-set [downloadLimiter] throttle — a foreground Quick Look
  /// read must not crawl at the background bandwidth limit.
  final BandwidthLimiter _produceLimiter = BandwidthLimiter();

  /// 03 §4.7's dedicated produce-slot cap: at most
  /// [previewProduceSlotLimit] produce hops hold a channel at once;
  /// further requests wait in [_produceWaiters] holding no lease.
  int _produceInFlight = 0;
  final ListQueue<Completer<void>> _produceWaiters = ListQueue();

  /// The durability barrier a move landing on a local destination runs
  /// before its source is unlinked (00 D26): fsync the landed file's
  /// data, then the destination's containing directory, so a failure or
  /// crash leaves either the original or a durable copy — never
  /// neither. Injectable for tests; the production default is
  /// [_flushLocalDestinationDefault].
  final Future<void> Function(String destinationPath) flushLocalDestination;

  /// The default [flushLocalDestination]: the journal's own fsync
  /// primitives (03 §4.6's durability rule, borrowed for D26's move) —
  /// file data first, then the parent directory so the rename that
  /// committed the file survives power loss. The directory fsync is a
  /// no-op on Windows, where dart:io cannot open a directory handle.
  static Future<void> _flushLocalDestinationDefault(String destinationPath) {
    const io = TransferJournalIo();
    final file = File(destinationPath);
    return io.fsyncFile(file).then((_) => io.fsyncDirectory(file.parent));
  }

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
  @override
  List<TransferTask> get tasks =>
      List.unmodifiable(_tasks.values.map((rt) => rt.task));

  bool get isPaused => _paused;

  /// Lifecycle, item-state, and byte-progress events for mirrors/UI.
  @override
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
    // A delete spec must carry its disposition — the destructive verb
    // never defaults in (the journal decoder enforces the same rule on
    // replay). [enqueueDelete] is the guarded front door: it is where
    // the confirmation/opt-in checks live; a hand-built spec through
    // here is journaled verbatim.
    if (spec.operation == TransferOperation.delete &&
        spec.disposition == null) {
      throw ArgumentError.value(
        spec.disposition,
        'disposition',
        'a delete task requires its trash-or-permanent disposition',
      );
    }
    // Symmetric strictness — a copy/move spec carrying a disposition
    // would journal a field the decoder refuses, quarantining its own
    // records on replay.
    if (spec.operation != TransferOperation.delete &&
        spec.disposition != null) {
      throw ArgumentError.value(
        spec.disposition,
        'disposition',
        'only a delete task carries a disposition',
      );
    }
    // The managed-checkout payload is the guarded verb's to build — a
    // hand-built spec could disagree with its own endpoints, so the
    // generic door refuses it like an un-dispositioned delete.
    if (spec.managedCheckout != null) {
      throw ArgumentError.value(
        spec.managedCheckout,
        'managedCheckout',
        'use enqueueManagedCheckout — a managed spec must be built by the verb',
      );
    }
    // Same guard for the produce payload: `enqueueProduce` builds the
    // spec so the unjournaled, head-inserted shape is the only shape.
    if (spec.produce != null) {
      throw ArgumentError.value(
        spec.produce,
        'produce',
        'use enqueueProduce — a produce spec must be built by the verb',
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
        disposition: spec.disposition,
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

  // ---------------------------------------------------------------------
  // Managed checkouts (06 §3.2/§3.4) — the 03 §4.7 produce-task consumer:
  // one journaled, queue-visible, cancellable file hop per save/checkout.
  // ---------------------------------------------------------------------

  /// Enqueues one managed-checkout hop and returns its live task handle —
  /// `unawaited(_runTask)` starts it immediately (the §4.7 priority
  /// exemption: these tasks ride inside the journaled queue and the
  /// activity surface, but outside the in-flight file cap and the
  /// queue-level pause; a per-task pause and cancel still hold).
  ///
  /// The spec's endpoints are derived here, never from the caller:
  /// a download crosses server→local into the store-created checkout
  /// file, an upload crosses local→server onto the record's own
  /// `remotePath` under the spec's CAS target.
  @override
  TransferTask enqueueManagedCheckout(ManagedCheckoutSpec managed) {
    if (_disposed) {
      throw StateError('the transfer queue is disposed');
    }
    final isDownload = managed.direction == ManagedCheckoutDirection.download;
    final task = TransferTask(
      TransferTaskSpec(
        source: isDownload
            ? ServerFsLocation(managed.serverId)
            : const LocalFsLocation(),
        destination: isDownload
            ? const LocalFsLocation()
            : ServerFsLocation(managed.serverId),
        rootPaths: [managed.remotePath],
        destinationDir: isDownload
            ? p.dirname(managed.localPath)
            : remoteParent(managed.remotePath),
        // The managed path never reaches `_decideFile` — the spec's own
        // expectedTarget is the conflict authority. The policy fields
        // exist only to satisfy the journaled shape.
        policy: ResolvedConflictPolicy(
          files: ConflictResolution.replace,
          folders: ConflictResolution.replace,
        ),
        managedCheckout: managed,
      ),
    );
    final runtime = _TaskRuntime(task);
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

  // ---------------------------------------------------------------------
  // Produce-on-demand (03 §4.7, 06 §5.3) — the Quick Look / preview hook:
  // one unjournaled, head-inserted download hop per request, exempt from
  // queue pause, in-flight caps, and the throttle, under a dedicated
  // two-slot ceiling.
  // ---------------------------------------------------------------------

  /// Enqueues one produce hop and returns its live task handle. The task
  /// lands at the HEAD of [tasks] — the one programmatic exception to
  /// §4.3's strict-FIFO admission (Quick Look waits on it) — and is
  /// journaled NOWHERE: the caller's completion rides the returned
  /// task's awaited Future, which dies with the process, so a restored
  /// queue must never resurrect it (03 §4.6's rule for futures a caller
  /// cannot re-await). Every journal/history write site guards on
  /// `spec.produce != null`.
  ///
  /// The row stays queue-visible like a managed checkout — the activity
  /// panel lists it with byte progress and a working Cancel — but
  /// progress rides item events, never `TransferQueueProgressEvent`
  /// (03 §4.7: the awaited Future is the completion signal; the §6
  /// mirror's per-flush event bound is sized for §4.3-capped tasks).
  TransferTask enqueueProduce(PreviewProduceSpec produce) {
    if (_disposed) {
      throw StateError('the transfer queue is disposed');
    }
    final task = TransferTask(
      TransferTaskSpec(
        source: ServerFsLocation(produce.serverId),
        destination: const LocalFsLocation(),
        rootPaths: [produce.remotePath],
        destinationDir: p.dirname(produce.destinationPath),
        // The produce path never reaches `_decideFile` — the caller's
        // exclusive temp target is the authority. The policy fields
        // exist only to satisfy the task shape.
        policy: ResolvedConflictPolicy(
          files: ConflictResolution.replace,
          folders: ConflictResolution.replace,
        ),
        produce: produce,
      ),
    );
    final runtime = _TaskRuntime(task);
    // Head insertion: LinkedHashMap iteration order is queue order, so
    // the row renders ahead of every waiting task.
    final existing = Map.of(_tasks);
    _tasks
      ..clear()
      ..[task.id] = runtime
      ..addAll(existing);
    _emit(TransferQueueTaskEvent(task.id, task.state));
    unawaited(_runTask(runtime));
    return task;
  }

  /// 03 §4.7's `TransferProducer` surface: enqueues a produce hop for
  /// [path] on [source] into [destinationPath] and awaits the task,
  /// completing with the produced entry (its size and SHA-256 digest
  /// are the caller's cache metadata). [cancellation] cancels the
  /// queue task — the same machinery the row's Cancel verb uses.
  @override
  Future<RemoteFileEntry> produceLocalCopy(
    FsLocation source,
    String path, {
    required String destinationPath,
    RemoteTransferCancellation? cancellation,
  }) async {
    if (source is! ServerFsLocation) {
      throw ArgumentError.value(
        source,
        'source',
        'produceLocalCopy produces remote files into local paths',
      );
    }
    final task = enqueueProduce(
      PreviewProduceSpec(
        serverId: source.serverId,
        remotePath: path,
        destinationPath: destinationPath,
      ),
    );
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then(
          (_) => cancelTask(task.id),
          // A faulted token must not wedge the produce.
          onError: (Object _) {},
        ),
      );
    }
    await _tasks[task.id]?.done.future;
    final item = task.items.where((i) => !i.isDirectory).firstOrNull;
    if (task.state == TransferTaskState.completed &&
        item?.resultEntry != null) {
      return item!.resultEntry!;
    }
    if (task.state == TransferTaskState.cancelled ||
        task.cancellation.isCancelled ||
        cancellation?.isCancelled == true) {
      throw _cancelledException();
    }
    throw RemoteFileException(
      kind: task.failureKind ?? RemoteFileErrorKind.other,
      operation: 'produce',
      path: path,
      message: task.error ?? 'the produce task failed',
    );
  }

  /// Waits for a free produce slot (03 §4.7's cap of two), holding no
  /// lease while queued. Cancellation — the task token or the attempt
  /// token a per-task pause trips — abandons the wait; a grant that
  /// arrives as the wait dies is handed to the next waiter rather than
  /// leaked.
  Future<void> _acquireProduceSlot(
    TransferTask task,
    RemoteTransferCancellation attempt,
  ) async {
    _throwIfTaskCancelled(task);
    if (attempt.isCancelled) throw _cancelledException();
    if (_produceInFlight < previewProduceSlotLimit) {
      _produceInFlight++;
      return;
    }
    final waiter = Completer<void>();
    _produceWaiters.addLast(waiter);
    await Future.any([
      waiter.future,
      task.cancellation.whenCancelled,
      attempt.whenCancelled,
    ]);
    if (_produceWaiters.remove(waiter)) {
      // Still queued when we woke: the wait died to a cancel — no slot
      // was granted.
      throw _cancelledException();
    }
    if (task.cancellation.isCancelled || attempt.isCancelled) {
      // Granted concurrently with the cancel: pass the slot on.
      final next = _produceWaiters.isEmpty
          ? null
          : _produceWaiters.removeFirst();
      next?.complete();
      throw _cancelledException();
    }
    _produceInFlight++;
  }

  void _releaseProduceSlot() {
    _produceInFlight--;
    final next = _produceWaiters.isEmpty
        ? null
        : _produceWaiters.removeFirst();
    next?.complete();
  }

  /// Executes the produce task's single hop (03 §4.7, 06 §5.3): server
  /// → the caller's exclusive local temp path. The exemptions are the
  /// contract — no queue-pause gate, no `_inFlightFiles` accounting, no
  /// user throttle ([_produceLimiter] stands in) — while per-task pause
  /// and cancel, the disconnect retry budget, and the queue row all
  /// behave exactly like a managed checkout's.
  ///
  /// Progress emits `TransferQueueItemEvent`s (byte counts live on the
  /// item) rather than `TransferQueueProgressEvent` — §4.7's rule that
  /// the produce Future is the completion signal keeps the §6 mirror's
  /// per-flush bound honest.
  Future<void> _runProduce(_TaskRuntime runtime) async {
    final task = runtime.task;
    final produce = task.spec.produce!;
    task.startedAt ??= DateTime.now();
    task.plan ??= TransferPlan();
    task.scanComplete = true;
    task.totalBytes = produce.expectedSize;
    task.totalFiles = 1;

    final item = TransferItem(
      id: 'produce-${task.id}',
      sourcePath: produce.remotePath,
      isDirectory: false,
      destinationPath: produce.destinationPath,
      size: produce.expectedSize,
    );
    task.items.add(item);
    _emit(TransferQueueItemEvent(task.id, item.id, item.state));

    while (!item.isTerminal && !task.isTerminal) {
      // Per-task pause only: §4.7 exempts produce tasks from the
      // queue-level pause — a foreground preview read must never wait
      // behind a paused queue.
      while (task.state == TransferTaskState.paused &&
          !task.cancellation.isCancelled &&
          !_disposed) {
        await runtime.notPaused.future;
      }
      _throwIfTaskCancelled(task);
      if (_disposed) throw _cancelledException();
      if (item.isTerminal || task.isTerminal) break;

      var attempt = RemoteTransferCancellation();
      runtime.attempts[item.id] = attempt;
      item.state = TransferItemState.active;
      _emit(TransferQueueItemEvent(task.id, item.id, item.state));
      _setTaskState(runtime, TransferTaskState.running);
      try {
        await _acquireProduceSlot(task, attempt);
        try {
          final leases = await _leaseServerIds([produce.serverId], attempt);
          try {
            final serverFs = leases[produce.serverId]!.fs;
            final result = await _pipe(
              source: serverFs,
              destination: _localFileSystem,
              readLimiter: _produceLimiter,
              writeLimiter: _localLimiter,
              sourcePath: produce.remotePath,
              destinationPath: produce.destinationPath,
              length: produce.expectedSize,
              maximumBytes: produce.maximumBytes,
              // The temp is the cache's exclusive sibling — overwrite is
              // the expected shape; the commit rename serializes it.
              overwrite: true,
              // The produced entry's digest is the cache's honesty
              // check — record it beside the file (06 §5.3).
              computeHash: true,
              downloadGate: produce.gate,
              cancellation: attempt,
              onProgress: (transferred, total) {
                _onProduceProgress(runtime, item, transferred, total);
                // The session's progress card reads bytes off this
                // hook — produce rows never emit queue-mirror progress
                // events (03 §4.7).
                produce.onProgress?.call(transferred, total);
              },
            );
            task.retryCount = 0;
            item.resultEntry = result.source;
            _finishItem(runtime, item, TransferItemState.completed);
            break;
          } on RemoteFileException catch (error) {
            if (error.kind != RemoteFileErrorKind.disconnected) rethrow;
            task.retryCount++;
            if (task.retryCount > poolPolicy.taskRetryLimit) rethrow;
            _debitItemProgress(runtime, item);
            item.state = TransferItemState.pending;
            _emit(TransferQueueItemEvent(task.id, item.id, item.state));
            _setTaskState(runtime, TransferTaskState.queued);
            attempt = RemoteTransferCancellation();
            runtime.attempts[item.id] = attempt;
          } finally {
            await _releaseLeases(leases);
          }
        } finally {
          _releaseProduceSlot();
        }
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.cancelled ||
            task.cancellation.isCancelled) {
          if (task.cancellation.isCancelled) {
            _finishItem(runtime, item, TransferItemState.cancelled);
          } else {
            // The attempt token died to pauseTask (or a denied gate —
            // same unwind shape): return to pending so a resume re-runs
            // the hop, except a denied gate leaves the task cancelled.
            if (produce.gate?.isDenied == true) {
              cancelTask(task.id);
              break;
            }
            _debitItemProgress(runtime, item);
            item.state = TransferItemState.pending;
            _emit(TransferQueueItemEvent(task.id, item.id, item.state));
          }
        } else {
          _finishItem(
            runtime,
            item,
            TransferItemState.failed,
            error: error.message,
            failureKind: error.kind,
          );
        }
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
      }
    }
    _maybeFinishTask(runtime);
  }

  /// Produce progress updates the counters and emits an item event —
  /// the row's byte progress — but never `TransferQueueProgressEvent`
  /// (03 §4.7). The pane's own progress card keys off the same events.
  void _onProduceProgress(
    _TaskRuntime runtime,
    TransferItem item,
    int transferred,
    int? total,
  ) {
    final task = runtime.task;
    task.transferredBytes += transferred - item.transferredBytes;
    item.transferredBytes = transferred;
    _emit(TransferQueueItemEvent(task.id, item.id, item.state));
  }

  // ---------------------------------------------------------------------
  // Delete (00 D15) — 03 §7.1/§7.3's trash layer driving 02 §2.6's verbs
  // ---------------------------------------------------------------------

  /// Builds the disclosure model a destructive delete's confirmation
  /// renders (02 §10, §13): up to three leading names, the quantified
  /// count and size, the flagged-descendant disclosure, and the
  /// disposition the confirmed action would actually run — `trash` only
  /// where trash can serve (OS backend present locally, or the server's
  /// `.poltergeist-trash/` opt-in on), `permanent` otherwise, so the
  /// dialog's wording can never promise trash it cannot deliver.
  ///
  /// Quantification walks the source through the D15 delete
  /// enumeration and falls back to unquantified values on timeout or
  /// error — §10's stated fallback; the delete itself is unaffected.
  /// [preferTrash] is the gesture's verb: the standard delete passes
  /// true, the permanent shortcut (⌥⌘⌫ / Shift+Delete) false — either
  /// way the model feeds one confirmation surface with its own wording.
  /// Throws `cancelled` when [cancellation] trips mid-quantify.
  Future<DeleteConfirmation> prepareDelete({
    required FsLocation source,
    required List<String> rootPaths,
    bool preferTrash = true,
    RemoteTransferCancellation? cancellation,
  }) async {
    if (_disposed) {
      throw StateError('the transfer queue is disposed');
    }
    final roots = _normalizeRoots(rootPaths, source);
    if (roots.isEmpty) {
      throw ArgumentError.value(
        rootPaths,
        'rootPaths',
        'must contain at least one source path',
      );
    }

    // The effective disposition is resolved BEFORE the dialog shows —
    // "Move to Trash" and "Delete permanently" are different promises.
    // A remote delete is permanent by default (00 D15); the per-server
    // opt-in is the only thing that changes that, never a failed move.
    final remoteOptIn =
        source is ServerFsLocation && _remoteTrashEnabled(source.serverId);
    final DeleteDisposition effective;
    var trashUnavailable = false;
    if (!preferTrash) {
      effective = DeleteDisposition.permanent;
    } else if (source is LocalFsLocation) {
      if (await localTrash.isAvailable()) {
        effective = DeleteDisposition.trash;
      } else {
        effective = DeleteDisposition.permanent;
        trashUnavailable = true;
      }
    } else {
      effective = remoteOptIn
          ? DeleteDisposition.trash
          : DeleteDisposition.permanent;
      trashUnavailable = !remoteOptIn;
    }

    // Quantify through the same post-order enumeration the task runs —
    // a listing that lies to the dialog is worse than no count at all.
    var quantified = true;
    int? totalItems;
    int? totalBytes;
    var flaggedCount = 0;
    final token = cancellation ?? RemoteTransferCancellation();
    final leases = await _leaseServerIds(_serverIds({source}), token);
    try {
      final fs = _fsFor(source, leases);
      final walker = RecursiveWalker(
        location: source,
        purpose: WalkPurpose.delete,
        source: fs,
        isFlaggedEntry: _isFlaggedEntry,
        cancellation: token,
      );
      final clock = Stopwatch()..start();
      final events = StreamIterator(walker.walk(roots));
      try {
        while (clock.elapsed <= deleteQuantifyTimeout &&
            await events.moveNext()) {}
      } on RemoteFileException {
        // A quantification walk error degrades to unquantified copy —
        // §10's fallback. `cancelled` still propagates (the dialog is
        // being dismissed); everything else the task's own scan reports
        // again per item.
        if (token.isCancelled) rethrow;
        quantified = false;
      } finally {
        try {
          await events.cancel();
        } catch (_) {}
      }
      if (quantified && (walker.isComplete && walker.failedEntries == 0)) {
        totalItems =
            walker.discoveredFiles +
            walker.discoveredDirectories +
            walker.discoveredSymlinks +
            walker.unsupportedEntries +
            walker.flaggedEntries;
        totalBytes = walker.discoveredBytes;
      } else {
        // Timed out or partially enumerated — counts are a floor; the
        // flagged count already seen is still an honest disclosure.
        quantified = false;
      }
      flaggedCount = walker.flaggedEntries;
    } finally {
      await _releaseLeases(leases);
    }

    return DeleteConfirmation(
      source: source,
      rootPaths: roots,
      names: [for (final root in roots.take(3)) _leafName(source, root)],
      effectiveDisposition: effective,
      quantified: quantified,
      remoteTrashOptIn: remoteOptIn,
      trashUnavailable: trashUnavailable,
      totalItems: totalItems,
      totalBytes: totalBytes,
      flaggedCount: flaggedCount,
    );
  }

  /// Enqueues one confirmed delete task (02 §2.6, 03 §7.3). The scan
  /// enumerates the roots post-order through the D15 delete walk; the
  /// executor then routes every item through the trash layer:
  /// [DeleteDisposition.trash] delivers to the OS trash locally or
  /// renames into `.poltergeist-trash/<runId>/` on an opted-in server;
  /// [permanent] calls the VFS's raw `delete` — and may only arrive
  /// here with [DeleteRequest.confirmed] set (the engine-owned guard
  /// every entry point shares: no silent unlink, ever).
  ///
  /// Throws [ArgumentError] for an unconfirmed permanent delete, for a
  /// remote `trash` request against a server whose opt-in is off, or for
  /// a filesystem-root path (it has no parent to trash under); throws
  /// [TrashException] when a local `trash` request finds the OS trash
  /// unavailable — the caller re-confirms permanent, per D15's
  /// confirm-then-permanent fallback.
  Future<TransferTask> enqueueDelete(DeleteRequest request) async {
    if (_disposed) {
      throw StateError('the transfer queue is disposed');
    }
    final source = request.source;
    final roots = _normalizeRoots(request.rootPaths, source);
    if (roots.isEmpty) {
      throw ArgumentError.value(
        request.rootPaths,
        'rootPaths',
        'must contain at least one source path',
      );
    }
    for (final root in roots) {
      // A filesystem root has no parent to trash beneath — and a
      // permanent walk of `/` is never something a gesture meant.
      if (_parentOf(source, root) == root) {
        throw ArgumentError.value(
          root,
          'rootPaths',
          'a filesystem root cannot be deleted',
        );
      }
    }
    final commonParent = _commonParentPath(source, roots);

    final String destinationDir;
    switch (request.disposition) {
      case DeleteDisposition.permanent:
        if (!request.confirmed) {
          throw ArgumentError.value(
            request.confirmed,
            'confirmed',
            'a permanent delete requires an explicit confirmation — '
                'D15 forbids an unconfirmed unlink (03 §7.3)',
          );
        }
        // The roots' common parent, for display and history — there is
        // no transfer destination.
        destinationDir = commonParent;
      case DeleteDisposition.trash:
        if (source is ServerFsLocation) {
          if (!_remoteTrashEnabled(source.serverId)) {
            throw ArgumentError.value(
              request.disposition,
              'disposition',
              'remote trash (.poltergeist-trash/) is not enabled for '
                  'this server — remote deletes are confirm-then-'
                  'permanent by default (00 D15)',
            );
          }
          // The run directory lands under the roots' common parent —
          // same-directory placement keeps the trash rename on one
          // filesystem (03 §7.3).
          destinationDir = remoteJoin(
            remoteJoin(commonParent, RemoteTrash.rootDirectoryName),
            remoteTrash.newRunId(),
          );
        } else {
          if (!await localTrash.isAvailable()) {
            throw const TrashException(
              kind: TrashErrorKind.unavailable,
              message:
                  'the OS trash is unavailable on this platform; '
                  'confirm permanent deletion instead',
            );
          }
          destinationDir = commonParent;
        }
    }
    return enqueue(
      TransferTaskSpec(
        source: source,
        // A delete has no transfer destination — the spec's destination
        // mirrors the source endpoint (leases key on it; journals and
        // history record where the delete acted).
        destination: source,
        rootPaths: roots,
        destinationDir: destinationDir,
        // Conflict policy is never consulted by the delete executor —
        // `skip` is the fail-safe should a bug ever route a delete item
        // through the transfer conflict machinery.
        policy: ResolvedConflictPolicy(
          files: ConflictResolution.skip,
          folders: ConflictResolution.skip,
        ),
        operation: TransferOperation.delete,
        disposition: request.disposition,
      ),
    );
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
    assert(runtime.notPaused.isCompleted, 'notPaused was incomplete pre-pause');
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
    // A managed checkout carries its own execution contract — one hop,
    // no scan, no conflict machinery (06 §3.4).
    if (task.spec.managedCheckout != null) {
      await _runManagedCheckout(runtime);
      return;
    }
    // A produce task's single download hop is likewise self-contained
    // (03 §4.7) — and unjournaled, so no scan state exists to replay.
    if (task.spec.produce != null) {
      await _runProduce(runtime);
      return;
    }
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

  /// Executes the managed-checkout task's single hop (06 §3.2/§3.4).
  ///
  /// Unlike `_runFile` work this item never enters `eligible`, never
  /// consults `_decideFile`, and never claims a destination-registry key —
  /// the spec's `expectedTarget` IS the conflict decision (the caller's
  /// recorded snapshot, carrying `contentSha256`, so the destination
  /// adapter's mandatory remote hash re-read decides; 00 D7). Per-task
  /// pause cancels the in-flight attempt and the hop restarts from byte
  /// zero on resume, exactly like §4.4's ordinary files; a `disconnected`
  /// failure re-leases in place under the task retry budget.
  ///
  /// Crash semantics: nothing here journals a scan or plan record, so a
  /// restored task replays the whole hop — for an upload the CAS
  /// re-verifies the remote (and a load-swept `.upload` snapshot fails
  /// the replay honestly), for a download the store's abandoned-marker
  /// sweep has already dropped the half-written target.
  Future<void> _runManagedCheckout(_TaskRuntime runtime) async {
    final task = runtime.task;
    final managed = task.spec.managedCheckout!;
    final isDownload = managed.direction == ManagedCheckoutDirection.download;
    task.startedAt ??= DateTime.now();
    task.plan ??= TransferPlan();
    // In-memory only — deliberately never journaled, so a restored task
    // replays the hop instead of adopting a torn plan.
    task.scanComplete = true;
    task.totalBytes = managed.expectedSize;
    task.totalFiles = 1;

    var item = _itemOf(task, managed.checkoutId);
    if (item == null) {
      // The checkout id keys the row — the manager correlates terminal
      // events back to its record without a second map.
      item = TransferItem(
        id: managed.checkoutId,
        sourcePath: isDownload
            ? managed.remotePath
            : managed.displayLocalPath ?? managed.localPath,
        isDirectory: false,
        destinationPath: isDownload ? managed.localPath : managed.remotePath,
        size: managed.expectedSize,
      );
      task.items.add(item);
      _emit(TransferQueueItemEvent(task.id, item.id, item.state));
    }

    while (!item.isTerminal && !task.isTerminal) {
      // Per-task pause only: §4.7 exempts managed transfers from the
      // queue-level pause (a paused queue must not silently stall a
      // save), while an explicit per-task pause or cancel still wins.
      while (task.state == TransferTaskState.paused &&
          !task.cancellation.isCancelled &&
          !_disposed) {
        // Invariant: pauseTask swaps in a fresh incomplete completer on
        // each pause, and resumeTask/cancelTask/dispose complete it —
        // this await can neither spin on a completed future nor hang.
        await runtime.notPaused.future;
      }
      _throwIfTaskCancelled(task);
      if (_disposed) throw _cancelledException();
      if (item.isTerminal || task.isTerminal) break;

      var attempt = RemoteTransferCancellation();
      runtime.attempts[item.id] = attempt;
      item.state = TransferItemState.active;
      _emit(TransferQueueItemEvent(task.id, item.id, item.state));
      _setTaskState(runtime, TransferTaskState.running);
      try {
        final leases = await _leaseServerIds([managed.serverId], attempt);
        try {
          final serverFs = leases[managed.serverId]!.fs;
          final result = await _pipe(
            source: isDownload ? serverFs : _localFileSystem,
            destination: isDownload ? _localFileSystem : serverFs,
            readLimiter: isDownload ? downloadLimiter : _localLimiter,
            writeLimiter: isDownload ? _localLimiter : uploadLimiter,
            sourcePath: isDownload ? managed.remotePath : managed.localPath,
            destinationPath: isDownload
                ? managed.localPath
                : managed.remotePath,
            length: managed.expectedSize,
            maximumBytes: isDownload ? managed.maximumBytes : null,
            // Download: the target is the store's exclusive-created
            // empty checkout — overwrite is the expected shape. Upload:
            // always overwrite, CAS-guarded by expectedTarget.
            overwrite: true,
            expectedTarget: managed.expectedTarget,
            preserveMode: managed.preserveMode,
            // D7: the returned remote entry must carry the content
            // digest — the record's snapshot/baseline authority.
            computeHash: true,
            cancellation: attempt,
            onProgress: (transferred, total) =>
                _onFileProgress(runtime, item!, transferred, total),
          );
          task.retryCount = 0;
          item.resultEntry = isDownload ? result.source : result.destination;
          _finishItem(runtime, item, TransferItemState.completed);
          break;
        } on RemoteFileException catch (error) {
          if (error.kind != RemoteFileErrorKind.disconnected) rethrow;
          task.retryCount++;
          if (task.retryCount > poolPolicy.taskRetryLimit) rethrow;
          _debitItemProgress(runtime, item);
          item.state = TransferItemState.pending;
          _emit(TransferQueueItemEvent(task.id, item.id, item.state));
          _setTaskState(runtime, TransferTaskState.queued);
          attempt = RemoteTransferCancellation();
          runtime.attempts[item.id] = attempt;
        } finally {
          await _releaseLeases(leases);
        }
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.cancelled ||
            task.cancellation.isCancelled) {
          if (task.cancellation.isCancelled) {
            _finishItem(runtime, item, TransferItemState.cancelled);
          } else {
            // The attempt token died to pauseTask — return to pending
            // and re-enter the wait; resumeTask completes notPaused.
            _debitItemProgress(runtime, item);
            item.state = TransferItemState.pending;
            _emit(TransferQueueItemEvent(task.id, item.id, item.state));
          }
        } else {
          _finishItem(
            runtime,
            item,
            TransferItemState.failed,
            error: error.message,
            failureKind: error.kind,
          );
        }
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
      }
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
      if (task.operation == TransferOperation.delete) {
        // D15: no destination to ensure — the remote-trash disposition
        // materializes its `.poltergeist-trash/<runId>/` target here
        // instead (created 0700, repaired or refused per 03 §7.3), then
        // the post-order delete walk enumerates the roots.
        if (task.spec.disposition == DeleteDisposition.trash &&
            task.source is ServerFsLocation) {
          await _scanOp(
            runtime,
            (fs) =>
                remoteTrash.ensureExistingRunDirectory(fs, task.destinationDir),
          );
        }
        await _walkDeleteRoots(runtime);
      } else {
        await _ensureDestinationRoot(runtime);
        await _walkRoots(runtime);
      }
      // Entries the walk never re-discovered — a source deleted between
      // the journaled plan and this (re-)scan — still hold a pending
      // record. Without a terminal record a later restore would
      // resurrect them, so each gets an explicit removal (03 §4.6's
      // no-resurrection rule needs the record, not silence).
      for (final bucket
          in runtime.restoredIndex?.values ?? <List<RestoredPlanItem>>[]) {
        for (final item in bucket) {
          if (item.outcome == null) {
            persistence?.appendJournal(
              ItemRemovedRecord(
                taskId: task.id,
                itemId: item.itemId,
                error: 'the source no longer exists',
              ),
            );
          }
        }
      }
      runtime.restoredIndex = null;
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

  /// The §3.5 app-level walker drives the scan (03 §4.2): enumeration
  /// is pull-driven — the pause/cancel gate runs before every pull, so
  /// a paused task holds the whole walk (no listings run behind it) and
  /// a cancelled task unwinds at the walker's next check point. The
  /// pending-entry bound is the stream itself: a directory's children
  /// only exist while its listing is being consumed, and the
  /// not-yet-listed directory backlog is the only retained state.
  Future<void> _walkRoots(_TaskRuntime runtime) async {
    final task = runtime.task;
    final walker = RecursiveWalker(
      location: task.source,
      purpose: WalkPurpose.transfer,
      destination: task.destination,
      isFlaggedEntry: _isFlaggedEntry,
      cancellation: task.cancellation,
      // Each VFS op rides the scan leases and the `disconnected`
      // re-lease seam, exactly as the pre-walker inline walk did.
      stat: (path) =>
          _scanOp(runtime, (fs) => fs.stat(path, followLinks: false)),
      listDirectory: (path) => _scanOp(runtime, (fs) => fs.listDirectory(path)),
    );
    final events = StreamIterator(walker.walk(task.rootPaths));
    try {
      while (true) {
        _throwIfTaskCancelled(task);
        await _scanPauseGate(runtime);
        if (!await events.moveNext()) break;
        final event = events.current;
        switch (event) {
          case WalkEntryEvent():
            await _scanWalkEntry(runtime, event);
          // The listing closed: this directory's mkdir and its file
          // children become usable now (03 §4.2).
          case WalkListingClosedEvent():
            _scheduleDirectory(
              runtime,
              runtime.walkDirectories[event.directory]!,
            );
          // The listing failed atomically: the directory item fails and
          // no children were ever discovered. `disconnected`/`cancelled`
          // are walk-ending, never per-item — the walker's contract is to
          // propagate them as stream errors; rethrow defensively so a
          // wrapped one cannot degrade into a failed row while siblings
          // keep listing against a dead connection.
          case WalkListingFailedEvent():
            if (_isWalkEndingError(event.error)) {
              throw event.error;
            }
            final directory = runtime.walkDirectories[event.directory]!;
            // A listing failure is not per-item retryable: the subtree
            // was never discovered, so re-arming the mkdir would claim
            // success over children that were never planned. The flag
            // routes the retry through `retryTask`'s re-scan instead.
            directory.listingFailed = true;
            _finishDirectory(
              runtime,
              directory,
              outcome: _DirOutcome.failed,
              error: event.error.message,
              failureKind: event.error.kind,
            );
          case WalkRootFailedEvent():
            if (_isWalkEndingError(event.error)) {
              throw event.error;
            }
            _addTerminalItem(
              runtime,
              sourcePath: event.rootPath,
              destinationPath: _joinDest(
                task.destination,
                task.destinationDir,
                _leafName(task.source, event.rootPath),
              ),
              state: TransferItemState.failed,
              error: event.error.message,
              failureKind: event.error.kind,
            );
        }
      }
    } finally {
      // Dropping the subscription suspends the generator — a cancelled
      // or failed walk performs no further listings. The await is kept
      // so the generator finishes unwinding before teardown continues,
      // but a cleanup error must not mask the exception that unwound
      // the walk (the caller classifies task state off it).
      try {
        await events.cancel();
      } catch (_) {
        // Swallow deliberately: a teardown failure must not mask the
        // exception that unwound the walk, and must not fail a walk
        // that already completed successfully.
      }
    }
  }

  /// `disconnected` and `cancelled` are walk-ending conditions, never
  /// per-item outcomes — the walker's contract is to propagate them as
  /// stream errors; this guard keeps that contract enforced even if a
  /// walker event ever carries one.
  static bool _isWalkEndingError(RemoteFileException error) =>
      error.kind == RemoteFileErrorKind.disconnected ||
      error.kind == RemoteFileErrorKind.cancelled;

  /// The D15 delete enumeration (07 §3.5): the walker's post-order
  /// delete walk — children before their container, symlinks as leaf
  /// targets — journals and arms one delete op per entry. Nothing here
  /// deletes; the destructive action is the serialized delete executor's
  /// ([_armDelete]). A §13 flagged entry is a terminal skipped row —
  /// disclosed, never acted on: its lossy name can never round-trip, so
  /// even a permanent delete cannot safely address it. (A flagged entry
  /// inside a trashed directory still moves with its container — the
  /// server-side rename is byte-preserving.)
  Future<void> _walkDeleteRoots(_TaskRuntime runtime) async {
    final task = runtime.task;
    final walker = RecursiveWalker(
      location: task.source,
      purpose: WalkPurpose.delete,
      isFlaggedEntry: _isFlaggedEntry,
      cancellation: task.cancellation,
      // Each VFS op rides the scan leases and the `disconnected`
      // re-lease seam, exactly as the transfer walk does.
      stat: (path) =>
          _scanOp(runtime, (fs) => fs.stat(path, followLinks: false)),
      listDirectory: (path) => _scanOp(runtime, (fs) => fs.listDirectory(path)),
    );
    // A directory whose listing failed still emits its post-order delete
    // entry — keying the failure by node lets the item carry it (a
    // permanent delete then fails non-empty; a trash move succeeds and
    // discloses the listing failure on its completed row).
    final listingErrors = <WalkNode, RemoteFileException>{};
    final events = StreamIterator(walker.walk(task.rootPaths));
    try {
      while (true) {
        _throwIfTaskCancelled(task);
        await _scanPauseGate(runtime);
        if (!await events.moveNext()) break;
        final event = events.current;
        switch (event) {
          case WalkEntryEvent():
            _scanDeleteEntry(runtime, event, listingErrors);
          case WalkListingFailedEvent():
            if (_isWalkEndingError(event.error)) {
              throw event.error;
            }
            listingErrors[event.directory] = event.error;
          case WalkRootFailedEvent():
            if (_isWalkEndingError(event.error)) {
              throw event.error;
            }
            _addTerminalItem(
              runtime,
              sourcePath: event.rootPath,
              destinationPath: event.rootPath,
              state: TransferItemState.failed,
              error: event.error.message,
              failureKind: event.error.kind,
            );
          case WalkListingClosedEvent():
            // Transfer-only marker — a delete walk never emits it.
            break;
        }
      }
    } finally {
      try {
        await events.cancel();
      } catch (_) {
        // Same teardown rule as the transfer walk: a cleanup error must
        // not mask the exception unwinding the walk.
      }
    }
  }

  /// Journals and arms one delete-walk entry. The destination path
  /// records the source path — a delete has no transfer destination;
  /// the item's `resolvedPath` at completion carries where it actually
  /// went (the `.poltergeist-trash/` or OS-reported path).
  void _scanDeleteEntry(
    _TaskRuntime runtime,
    WalkEntryEvent event,
    Map<WalkNode, RemoteFileException> listingErrors,
  ) {
    final task = runtime.task;
    final entry = event.entry;
    switch (event.kind) {
      case WalkItemKind.flagged:
        _addTerminalItem(
          runtime,
          sourcePath: entry.path,
          destinationPath: entry.path,
          isDirectory: entry.isDirectory,
          size: entry.size,
          state: TransferItemState.skipped,
          error: event.detail ?? 'the entry name is not valid UTF-8',
        );
        return;
      case WalkItemKind.rejectedName:
        // Unreachable — the walker validates destination names for
        // transfer walks only. A failed row beats a silent skip if that
        // ever changes.
        _addTerminalItem(
          runtime,
          sourcePath: entry.path,
          destinationPath: entry.path,
          isDirectory: entry.isDirectory,
          size: entry.size,
          state: TransferItemState.failed,
          error: event.detail ?? 'the entry name was rejected',
          failureKind: RemoteFileErrorKind.other,
        );
        return;
      case WalkItemKind.file ||
          WalkItemKind.directory ||
          WalkItemKind.symbolicLink ||
          WalkItemKind.unsupported:
        break;
    }
    // A restored mid-scan task merges by source path — a delete item's
    // destination path IS its source path (03 §4.6's no-resurrection
    // rule applies unchanged: a journaled terminal outcome suppresses
    // re-dispatch, so a crash cannot re-delete or re-trash an entry).
    final restored = runtime.takeRestored(entry.path, entry.path);
    final itemId = restored?.itemId ?? uuidV4();
    if (restored?.outcome == null) {
      _journalPlanEntry(
        task,
        itemId: itemId,
        isDirectory: entry.isDirectory,
        source: entry,
        name: entry.name,
        containerKey: null,
        destinationPath: entry.path,
      );
    }
    if (!entry.isDirectory) {
      task.totalBytes = (task.totalBytes ?? 0) + (entry.size ?? 0);
    }
    if (restored?.outcome != null) {
      _addRestoredTerminalItem(
        runtime,
        restored!,
        entry,
        entry.path,
        isDirectory: entry.isDirectory,
      );
      return;
    }
    final item = _addPendingItem(
      runtime,
      id: itemId,
      entry: entry,
      destinationPath: entry.path,
      isDirectory: entry.isDirectory,
    );
    _armDelete(
      runtime,
      _DeleteWork(
        item: item,
        entry: entry,
        listingError: listingErrors[event.node],
      ),
    );
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

  /// Consumes one walker-classified entry (07 §3.5): the report kinds
  /// land as terminal rows — symlink skips, §13 flagged names, and
  /// destination-name rejections are scan-time outcomes the walker
  /// already classified — while files and directories plan, journal,
  /// and arm exactly as the pre-walker scan did. The per-item conflict
  /// check still happens at dispatch time on fresh destination stats.
  Future<void> _scanWalkEntry(
    _TaskRuntime runtime,
    WalkEntryEvent event,
  ) async {
    final task = runtime.task;
    final entry = event.entry;
    final containerDir = event.container == null
        ? null
        : runtime.walkDirectories[event.container]!;
    final containerKey = containerDir?.planned.itemId;
    final containerPlanned =
        containerDir?.planned.destinationPath ?? task.destinationDir;
    final plannedDest = _joinDest(
      task.destination,
      containerPlanned,
      entry.name,
    );
    switch (event.kind) {
      case WalkItemKind.symbolicLink:
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
      case WalkItemKind.flagged:
        // §13: a flagged name can never round-trip to the wire — the
        // row reports the skip with its reason; nothing dispatches.
        _addTerminalItem(
          runtime,
          sourcePath: entry.path,
          destinationPath: plannedDest,
          size: entry.size,
          isDirectory: entry.isDirectory,
          state: TransferItemState.skipped,
          error: event.detail ?? 'the entry name is not valid UTF-8',
        );
        return;
      case WalkItemKind.rejectedName:
        _addTerminalItem(
          runtime,
          sourcePath: entry.path,
          destinationPath: plannedDest,
          size: entry.size,
          isDirectory: entry.isDirectory,
          state: TransferItemState.failed,
          error:
              event.detail ?? 'the entry name is not valid for the destination',
          failureKind: RemoteFileErrorKind.other,
        );
        return;
      case WalkItemKind.unsupported:
        _addTerminalItem(
          runtime,
          sourcePath: entry.path,
          destinationPath: plannedDest,
          size: entry.size,
          state: TransferItemState.failed,
          error:
              event.detail ??
              'unsupported source entry type ${entry.type.name}',
          failureKind: RemoteFileErrorKind.unsupported,
        );
        return;
      case WalkItemKind.file || WalkItemKind.directory:
        break;
    }
    // The walker already applied the destination's name rules.
    final name = entry.name;
    final existing = await _scanStatDestination(runtime, plannedDest);
    switch (event.kind) {
      case WalkItemKind.file:
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
      case WalkItemKind.directory:
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
        // Node-keyed so the walker's container link resolves back to the
        // planned directory; the node itself holds the listing order.
        runtime.walkDirectories[event.node] = dirState;
      // The report kinds returned above — file/directory are the only
      // kinds that reach the plan.
      case WalkItemKind.symbolicLink ||
          WalkItemKind.flagged ||
          WalkItemKind.rejectedName ||
          WalkItemKind.unsupported:
        throw StateError('unreachable: ${event.kind} returned above');
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
    final existing = await _scanOp(runtime, (fs) async {
      try {
        return await fs.stat(task.destinationDir, followLinks: false);
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.notFound) return null;
        rethrow;
      }
    }, destination: true);
    if (existing == null) {
      await _scanOp(runtime, (fs) async {
        try {
          await fs.createDirectory(task.destinationDir);
        } on RemoteFileException catch (error) {
          // A concurrent creator won the stat→mkdir race: merging is
          // correct when the occupant is a directory — the same
          // classification _materializeDirectory applies per entry.
          if (error.kind != RemoteFileErrorKind.conflict) rethrow;
          final raced = await fs.stat(task.destinationDir, followLinks: false);
          if (!raced.isDirectory) rethrow;
        }
      }, destination: true);
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

  Future<void> _runDirectory(_TaskRuntime runtime, _DirState directory) async {
    final task = runtime.task;
    try {
      // A cancel/fail sweep settled the item while its op waited on the
      // chain — the chain drains quickly rather than re-acting on it.
      if (directory.item.isTerminal) return;
      await _waitForAdmission(runtime);
      if (directory.item.isTerminal) return;
      final containerPath = _resolvedContainer(
        runtime,
        directory.planned.containerKey,
      );
      if (containerPath == null) {
        // The containing directory was skipped or failed: the subtree is
        // skipped with the reason recorded. Collateral — a retried
        // ancestor re-arms this row with it.
        runtime.containerSkips.add(directory.item.id);
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
    // D26's directory self-move, ahead of the conflict verbs: a move
    // within one endpoint (local→local, or one server) whose resolved
    // destination IS the source directory — the same path, or a
    // spelling the endpoint folds/resolves to it — leaves the tree in
    // place. The file children resolve onto their own source paths and
    // self-complete in `_decideFile`; marking the state here keeps
    // `_removeMovedDirectories` from unlinking the source afterward.
    if (existing != null &&
        existing.isDirectory &&
        task.operation == TransferOperation.move &&
        _endpointKey(task.source) == _endpointKey(task.destination) &&
        await _isSelfTarget(
          dstFs,
          directory.planned.source.path,
          destination,
        )) {
      directory.selfTarget = true;
      _finishDirectory(
        runtime,
        directory,
        outcome: _DirOutcome.ready,
        resolvedPath: destination,
      );
      return;
    }
    // 02 §5.2's folder semantics at the decision level: `merge` recurses
    // (the directory resolves to its existing destination and children
    // land under the file policy), `keepBoth` creates the source under
    // the first free numbered name, and a non-directory occupant routes
    // through the same folder verb — `merge` there falls back to `ask`
    // (03 §4.1) rather than pretending recursion is possible.
    switch (resolveTransferConflict(
      verb: _effectiveFolderVerb(runtime, directory.item.id),
      sourceIsDirectory: true,
      existing: existing == null ? null : DestinationStat.fromEntry(existing),
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
        // Dir→dir wholesale replace and dir→non-dir occupant removal
        // route through the D15 trash layer — that integration is a
        // later M4 slice; the item fails honestly rather than deleting
        // unguarded.
        _finishDirectory(
          runtime,
          directory,
          outcome: _DirOutcome.failed,
          error:
              'replacing $destination removes the existing occupant, '
              'which requires the D15 occupant-replacement integration '
              '(a later M4 slice)',
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
        _DirOutcome.pending => throw StateError(
          'a directory cannot finish pending',
        ),
      },
      error: error,
      failureKind: failureKind,
      resolvedPath: resolvedPath,
    );
    switch (outcome) {
      case _DirOutcome.ready:
        item.state = TransferItemState.completed;
        task.completedDirectories++;
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
  // Delete executor (00 D15) — serialized per task so post-order holds:
  // a permanent delete must unlink children before their container, and
  // a remote-trash move must never let a retried child land after its
  // parent already moved. Each item routes through the trash layer —
  // never straight at `fs.delete` unless the disposition is the
  // confirmed-permanent one.
  // ---------------------------------------------------------------------

  void _armDelete(_TaskRuntime runtime, _DeleteWork work) {
    runtime.deleteOpsPending++;
    // The work order outlives the arm: a failed delete item retries from
    // this record (there is no plan object to recover it from).
    runtime.deleteWork[work.item.id] = work;
    runtime.deleteChain = runtime.deleteChain.then(
      (_) => _runDeleteItem(runtime, work),
    );
    unawaited(runtime.deleteChain.catchError((_) {}));
  }

  Future<void> _runDeleteItem(_TaskRuntime runtime, _DeleteWork work) async {
    final task = runtime.task;
    final item = work.item;
    try {
      // A cancel/fail sweep settled the item while it waited on the
      // chain — the chain drains quickly rather than re-acting on it.
      if (item.isTerminal) return;
      await _waitForAdmission(runtime);
      if (item.isTerminal) return;
      item.state = TransferItemState.active;
      _emit(TransferQueueItemEvent(task.id, item.id, item.state));
      if (task.state == TransferTaskState.queued ||
          task.state == TransferTaskState.scanning) {
        _setTaskState(runtime, TransferTaskState.running);
      }
      while (true) {
        final leases = await _leaseServerIds(
          _serverIds({task.source}),
          task.cancellation,
        );
        try {
          final fs = _fsFor(task.source, leases);
          final outcome = await _executeDelete(runtime, fs, work);
          // A completed op proves connectivity — the retry budget
          // bounds consecutive losses, not lifetime ones (03 §3.3).
          task.retryCount = 0;
          _finishDeleteItem(runtime, work, outcome);
          return;
        } on RemoteFileException catch (error) {
          if (error.kind != RemoteFileErrorKind.disconnected) rethrow;
          task.retryCount++;
          if (task.retryCount > poolPolicy.taskRetryLimit) rethrow;
          // Retry in place — re-chaining at the tail would let the
          // item's parent run first and break the post-order the
          // permanent path relies on.
        } finally {
          await _releaseLeases(leases);
        }
      }
    } on TrashException catch (error) {
      _finishItem(
        runtime,
        item,
        TransferItemState.failed,
        error: error.message,
        failureKind: switch (error.kind) {
          TrashErrorKind.unsupportedPlatform => RemoteFileErrorKind.unsupported,
          TrashErrorKind.unavailable ||
          TrashErrorKind.failed => RemoteFileErrorKind.other,
        },
      );
    } on RemoteFileException catch (error) {
      if (error.kind == RemoteFileErrorKind.cancelled ||
          task.cancellation.isCancelled) {
        _finishItem(runtime, item, TransferItemState.cancelled);
      } else {
        _finishItem(
          runtime,
          item,
          TransferItemState.failed,
          error: error.message,
          failureKind: error.kind,
        );
      }
    } catch (error) {
      _finishItem(
        runtime,
        item,
        TransferItemState.failed,
        error: '$error',
        failureKind: RemoteFileErrorKind.other,
      );
    } finally {
      runtime.deleteOpsPending--;
      _maybeFinishTask(runtime);
    }
  }

  /// One item through the trash layer — the outcome's `resolvedPath` is
  /// the trash path (remote) or the OS-reported trashed location (Put
  /// Back anchor — best-effort, often null); for the permanent path it
  /// is the source path itself.
  Future<({String resolvedPath, ItemDisposition disposition})> _executeDelete(
    _TaskRuntime runtime,
    RemoteFileSystem fs,
    _DeleteWork work,
  ) async {
    final task = runtime.task;
    final entry = work.entry;
    final disposition = task.spec.disposition;
    if (disposition == null) {
      throw StateError(
        'delete task ${task.id} has no disposition; refusing to guess',
      );
    }
    switch (disposition) {
      case DeleteDisposition.permanent:
        await fs.delete(entry);
        return (
          resolvedPath: entry.path,
          disposition: ItemDisposition.permanent,
        );
      case DeleteDisposition.trash:
        if (task.source is LocalFsLocation) {
          // The OS trash — `trash` throws TrashException on failure;
          // nothing here ever falls back to unlinking.
          final trashed = await localTrash.trash(entry.path);
          return (
            resolvedPath: trashed ?? entry.path,
            disposition: ItemDisposition.osTrash,
          );
        }
        final target = await remoteTrash.moveToTrash(
          fs,
          entry,
          task.destinationDir,
          () => runtime.nextTrashSequence++,
        );
        return (resolvedPath: target, disposition: ItemDisposition.remoteTrash);
    }
  }

  /// A delete item's completion: journal the trashed-vs-permanent
  /// outcome before the row flips (D15's per-item disposition record —
  /// [resolvedPath] is where the entry actually went).
  void _finishDeleteItem(
    _TaskRuntime runtime,
    _DeleteWork work,
    ({String resolvedPath, ItemDisposition disposition}) outcome,
  ) {
    final task = runtime.task;
    final item = work.item;
    // A cancel/fail sweep that settled the item while its VFS op was in
    // flight owns the row — never overwrite a terminal state (the same
    // rule `_finishItem` applies).
    if (item.isTerminal) return;
    _journalItemOutcome(
      task,
      item,
      TransferItemState.completed,
      resolvedPath: outcome.resolvedPath,
      disposition: outcome.disposition,
    );
    item.state = TransferItemState.completed;
    item.disposition = outcome.disposition;
    item.destinationPath = outcome.resolvedPath;
    // A trashed directory whose listing failed moved wholesale anyway —
    // the completed row still discloses the enumeration gap.
    if (work.listingError != null) {
      item.error =
          'moved to trash; its listing failed earlier: '
          '${work.listingError!.message}';
    }
    if (item.isDirectory) {
      task.completedDirectories++;
    } else {
      task.completedFiles++;
      _onFileProgress(runtime, item, item.size ?? 0, item.size);
    }
    _emit(
      TransferQueueItemEvent(task.id, item.id, item.state, error: item.error),
    );
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
      // Collateral skip: a retried container re-arms this row with it.
      runtime.containerSkips.add(work.item.id);
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

    // A cancel/skip/requeue that settled the item while it sat in
    // `eligible` owns the row — dispatch must not resurrect it.
    if (item.isTerminal) {
      _maybeFinishTask(runtime);
      return;
    }

    // Resolve the actual destination through the container key so a
    // keep-both-renamed ancestor rebases this item (03 §4.1).
    final containerPath = _resolvedContainer(runtime, file.containerKey);
    if (containerPath == null) {
      // Collateral skip: a retried container re-arms this row with it.
      runtime.containerSkips.add(item.id);
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
    final key = (_endpointKey(task.destination), _fold(task, destinationPath));
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
            case _FileSelfTarget(:final destinationPath):
              // The resolved destination IS the source (a move into the
              // file's own directory, or a folded spelling of it on a
              // case-insensitive volume): the move's end state already
              // holds — complete in place instead of piping the file
              // onto itself and then unlinking the only copy (00 D26's
              // never-self-overwrite rule). The file counts as fully
              // transferred for progress parity with the piped path.
              item.destinationPath = destinationPath;
              _onFileProgress(
                runtime,
                item,
                file.source.size ?? 0,
                file.source.size,
              );
              // A completed item is a success — reset the consecutive-
              // failure budget like the piped and rename paths do.
              task.retryCount = 0;
              _finishItem(runtime, item, TransferItemState.completed);
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
                if (await _commitLocalMove(
                  task,
                  dstFs,
                  file,
                  commitPath,
                  overwrite: overwrite,
                  expectedTarget: expectedTarget,
                )) {
                  // rename(2) moved the entry atomically — mtime and
                  // mode ride along, nothing was piped, and there is
                  // no post-copy source unlink. The file counts as
                  // fully transferred for progress parity with the
                  // piped path.
                  _onFileProgress(
                    runtime,
                    item,
                    file.source.size ?? 0,
                    file.source.size,
                  );
                  task.retryCount = 0;
                  _finishItem(runtime, item, TransferItemState.completed);
                  return;
                }
                if (srcFs is LocalFileSystem && dstFs is LocalFileSystem) {
                  // D26's local→local fast path (00 D26, 07 §3.10):
                  // bytes move through the platform copy pump
                  // (copy_file_range on Linux, streamed fallback
                  // elsewhere) inside LocalFileSystem's own temp+rename
                  // commit — the bounded pipe's job is bounding a REMOTE
                  // leg, and a local hop through it pays a full
                  // user-space round trip for nothing. Conflict and
                  // cancellation semantics ride the same exception
                  // taxonomy, so the retry/requeue logic below applies
                  // unchanged.
                  await srcFs.copyLocalFile(
                    file.source.path,
                    commitPath,
                    overwrite: overwrite,
                    preserveMode: file.source.mode,
                    expectedTarget: expectedTarget,
                    cancellation: attempt,
                    onProgress: (transferred, total) =>
                        _onFileProgress(runtime, item, transferred, total),
                  );
                } else {
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
                }
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
              await _postCommit(runtime, srcFs, dstFs, file, commitPath);
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
  ///
  /// For a move landing on local storage the delete is gated on 00 D26's
  /// durability barrier: the piped copy is byte-verified but only
  /// page-cache durable until [flushLocalDestination] fsyncs the file's
  /// data and then its containing directory — a crash must leave either
  /// the original or a durable copy, never neither. A same-device local
  /// move never reaches here: `_commitLocalMove` renamed the entry
  /// atomically instead.
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
      if (runtime.task.destination is LocalFsLocation) {
        await flushLocalDestination(destinationPath);
      }
      await srcFs.delete(file.source);
    }
  }

  /// D26's same-device local move: rename(2) through the VFS seam — one
  /// atomic directory-entry swap carrying mtime and mode, with no bytes
  /// through the pipe and no post-copy unlink. Returns true when the
  /// rename committed; false only on [LocalCrossDeviceRenameException]
  /// (EXDEV), where the caller falls back to the durable piped
  /// copy+delete — [flushLocalDestination] then runs before the source
  /// unlink. Any other throw is a real rename error and propagates for
  /// the caller's conflict-retry or item failure.
  Future<bool> _commitLocalMove(
    TransferTask task,
    RemoteFileSystem dstFs,
    PlannedFile file,
    String destinationPath, {
    required bool overwrite,
    RemoteFileEntry? expectedTarget,
  }) async {
    if (task.operation != TransferOperation.move ||
        task.source is! LocalFsLocation ||
        task.destination is! LocalFsLocation) {
      return false;
    }
    if (overwrite && expectedTarget != null) {
      // The piped path re-verifies the occupant at commit; the rename
      // must do the same — POSIX rename clobbers whatever is there, so
      // an occupant that changed between decide and commit conflicts
      // here instead of being silently overwritten. The caller's
      // conflict-retry then re-decides on fresh reality (03 §4.2).
      final latest = await _statOrNull(dstFs, destinationPath);
      if (latest == null ||
          latest.size != expectedTarget.size ||
          latest.modifiedAt != expectedTarget.modifiedAt) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'rename',
          path: destinationPath,
          message:
              '"$destinationPath" changed on disk before the move '
              'committed.',
        );
      }
    } else if (!overwrite &&
        await _statOrNull(dstFs, destinationPath) != null) {
      // Symmetric guard: overwrite:false means the destination was free
      // at decide time — an occupant that appeared since must conflict,
      // not be silently clobbered by the rename (dart:io has no
      // no-replace mode; the piped path's exclusive create would have
      // conflicted, and this check restores that protection).
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'rename',
        path: destinationPath,
        message:
            '"$destinationPath" appeared on disk before the move '
            'committed.',
      );
    }
    try {
      await dstFs.rename(
        file.source.path,
        destinationPath,
        overwrite: overwrite,
      );
      return true;
    } on LocalCrossDeviceRenameException {
      return false;
    }
  }

  void _handleFileError(
    _TaskRuntime runtime,
    _FileWork work,
    RemoteFileException error,
  ) {
    final task = runtime.task;
    final item = work.item;
    // The item's row already settled (per-item cancel/skip, or a sweep)
    // while the attempt unwound — its outcome is owned, and the
    // cancelled-requeue branch below must never re-pend it.
    if (item.isTerminal) return;
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
        taskTotalFiles: task.totalFiles,
        taskTotalDirectories: task.totalDirectories,
        taskCompletedFiles: task.completedFiles,
        taskCompletedDirectories: task.completedDirectories,
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
    // D26's self-target rule, ahead of the conflict verbs: a move within
    // one endpoint (local→local, or one server — two casings on a
    // case-insensitive server, a symlinked directory) whose resolved
    // destination names the source itself — the same path, or a
    // spelling that folds/resolves to it there — must never pipe onto
    // itself and then unlink the only copy, whatever the conflict
    // answer. The move's end state already holds, so the item completes
    // in place.
    if (existing != null &&
        !existing.isDirectory &&
        task.operation == TransferOperation.move &&
        _endpointKey(task.source) == _endpointKey(task.destination) &&
        await _isSelfTarget(dstFs, file.source.path, candidate)) {
      return _FileSelfTarget(candidate);
    }
    switch (resolveTransferConflict(
      verb: _effectiveFileVerb(runtime, work.item.id),
      sourceIsDirectory: false,
      existing: existing == null ? null : DestinationStat.fromEntry(existing),
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
            'D15 occupant-replacement integration (a later M4 slice)',
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
  /// Streams [sourcePath] into [destinationPath] and returns both
  /// endpoints' committed entries (`source` is the download's result,
  /// `destination` the upload's). Managed checkouts read the remote
  /// side's entry off the result — the post-commit stat plus, with
  /// [computeHash], the content digest the record's snapshot needs (D7).
  Future<({RemoteFileEntry source, RemoteFileEntry destination})> _pipe({
    required RemoteFileSystem source,
    required RemoteFileSystem destination,
    required BandwidthLimiter readLimiter,
    required BandwidthLimiter writeLimiter,
    required String sourcePath,
    required String destinationPath,
    int? length,
    int? maximumBytes,
    required bool overwrite,
    RemoteFileEntry? expectedTarget,
    int? preserveMode,
    bool computeHash = false,
    PreviewByteGate? downloadGate,
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
      computeHash: computeHash,
    );
    unawaited(
      uploadFuture.then(
        (_) {},
        onError: (Object error) {
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
        },
      ),
    );
    unawaited(
      cancellation.whenCancelled.then(
        (_) => sink.abort(),
        // abort() is pure cleanup — fail closed: even an errored
        // cancellation signal must still release the sink.
        onError: (Object _) => sink.abort(),
      ),
    );
    late final RemoteFileEntry sourceResult;
    try {
      // The download-side decorations: the §5.2 byte gate sits
      // outermost so its parked confirmation stalls the remote read
      // itself (backpressure, not buffering), and §3.2's stream cap sits
      // inside it so gated bytes don't count toward the cap until the
      // user's answer releases them. The cap lives on the download side
      // only — a capped sink on an upload would mislabel the remote
      // write as the oversized party.
      StreamSink<List<int>> downloadSink = sink;
      if (maximumBytes != null) {
        downloadSink = MaximumByteSink(
          downloadSink,
          maximumBytes: maximumBytes,
        );
      }
      if (downloadGate != null) {
        downloadSink = downloadGate.wrap(downloadSink);
      }
      sourceResult = await source.download(
        sourcePath,
        downloadSink,
        onProgress: pipeProgress,
        cancellation: cancellation,
        computeHash: computeHash,
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
      // Never await close() itself: a destination that died before
      // subscribing leaves buffered chunks nobody drains, and
      // StreamController.close() waits on delivery forever — the
      // upload's own completion is the drain proof. An aborted sink
      // can still fail close() incidentally — ignore() keeps that
      // unwind artifact off the zone's unhandled-error path.
      sink.close().ignore();
      final destinationResult = await uploadFuture;
      return (source: sourceResult, destination: destinationResult);
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
    runtime.pendingConflicts[item.id] = _ParkedConflict(
      conflict,
      item,
      directory,
    );
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
        runtime.directoryOpsPending > 0 ||
        runtime.deleteOpsPending > 0) {
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
        // A D26 self-move resolved the directory to its own path — the
        // tree it would delete is the destination.
        if (dirState.selfTarget) continue;
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
        runtime.directoryOpsPending > 0 ||
        runtime.deleteOpsPending > 0) {
      return;
    }
    _releaseRegistryClaims(runtime.task.id);
    final task = runtime.task;
    if (task.isTerminal) {
      // The task's journal records precede this append on the writer
      // chain, and the store fsyncs the journal before the history line
      // lands (03 §4.6's ordering rule). Produce tasks keep their
      // unjournaled posture all the way through history — a produce
      // row is session state, never a durable record.
      task.finishedAt ??= DateTime.now();
      if (task.spec.produce == null) {
        persistence?.appendHistory(TransferHistoryEntry.fromTask(task));
      }
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
    if (isDirectory) {
      runtime.task.totalDirectories++;
    } else {
      runtime.task.totalFiles++;
    }
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
    if (runtime.task.spec.produce == null) {
      persistence?.appendJournal(TaskRemovedRecord(taskId: taskId));
    }
    _tasks.remove(taskId);
    return true;
  }

  // ---------------------------------------------------------------------
  // Activity-panel verbs (02 §6) — the panel's query/mutation surface:
  // history reads, pending-task reorder, per-item cancel, and retry.
  // ---------------------------------------------------------------------

  /// The capped persisted history — the History tab's source (02 §6),
  /// oldest first. Null persistence means no durable log exists; the
  /// seam reports empty rather than synthesizing rows the journal never
  /// kept.
  List<TransferHistoryEntry> get history => persistence?.history ?? const [];

  /// The History tab's Clear History (02 §6): drops every persisted
  /// record through the store's writer chain; the journal is untouched.
  Future<void> clearHistory() => persistence?.clearHistory() ?? Future.value();

  /// Reorders one not-yet-running task in admission order — 02 §6's
  /// drag. `queued` and `scanning` both move (a scanning task has
  /// dispatched no file yet — the first dispatch flips it to
  /// `running`, which pins it); running, paused, and terminal rows are
  /// pinned: reordering them would lie about dispatch reality. The drop
  /// target is another movable task — or null, which lands the task
  /// behind the last movable one. Returns false when the move is not
  /// legal; emits [TransferQueueOrderEvent] on success.
  bool moveTask(String taskId, {String? beforeTaskId}) {
    final runtime = _tasks[taskId];
    if (runtime == null || !_isReorderable(runtime.task)) return false;
    if (beforeTaskId == taskId) return true;
    final entries = _tasks.entries.toList();
    entries.removeWhere((entry) => entry.key == taskId);
    final int index;
    if (beforeTaskId != null) {
      final target = _tasks[beforeTaskId];
      if (target == null || !_isReorderable(target.task)) return false;
      index = entries.indexWhere((entry) => entry.key == beforeTaskId);
    } else {
      // End of the movable run — behind the last reorderable task.
      final lastMovable = entries.lastIndexWhere(
        (entry) => _isReorderable(entry.value.task),
      );
      index = lastMovable < 0 ? entries.length : lastMovable + 1;
    }
    entries.insert(index, MapEntry(taskId, runtime));
    _tasks
      ..clear()
      ..addEntries(entries);
    _emit(TransferQueueOrderEvent(taskId));
    return true;
  }

  /// The reorderable states — 02 §6's "queued" as the panel renders it:
  /// admission has not reached the task's file work yet.
  static bool _isReorderable(TransferTask task) =>
      task.state == TransferTaskState.queued ||
      task.state == TransferTaskState.scanning;

  /// Cancels one item — 02 §6's per-row Cancel, and the queued row's
  /// Skip (same verb: the row leaves the queue either way). Pending
  /// work is pulled from the dispatch backlog, a parked conflict
  /// dismisses its surface, an in-flight attempt's token trips so the
  /// unwinding pipe cannot re-pend the row, and a directory's cancel
  /// cascades to its subtree through the `ready` gate — children skip
  /// as collateral, and a later retry of the directory re-arms them.
  /// Journaled as `itemRemoved` before the state flips.
  bool cancelItem(String taskId, String itemId) {
    final runtime = _tasks[taskId];
    if (runtime == null || runtime.task.isTerminal) return false;
    final item = _itemOf(runtime.task, itemId);
    if (item == null || item.isTerminal) return false;

    // Dismiss the parked-conflict surface first so a mirror's stream
    // never shows a row that vanished and progressed at once (the same
    // ordering resolveConflict keeps).
    final parked = runtime.pendingConflicts.remove(itemId);
    if (parked != null) {
      _pendingConflictCount--;
      _emit(
        TransferQueueConflictEvent(
          taskId,
          itemId,
          conflict: parked.conflict,
          pending: false,
        ),
      );
    }
    runtime.conflictWaiters.removeWhere((work) => _workItemId(work) == itemId);
    runtime.eligible.removeWhere((work) => work.item.id == itemId);
    runtime.deleteWork.remove(itemId);

    final directory = item.isDirectory ? runtime.directories[itemId] : null;
    if (directory != null) {
      // `_finishDirectory` completes `ready`, which cascades the cancel
      // to every armed child through `_fileContainerReady`.
      _finishDirectory(runtime, directory, outcome: _DirOutcome.cancelled);
    } else {
      _finishItem(runtime, item, TransferItemState.cancelled);
    }
    runtime.attempts.remove(itemId)?.cancel();
    _promoteConflictWaiters();
    _maybeFinishTask(runtime);
    return true;
  }

  /// Whether [retryItem] can re-arm this row: it failed, it still has a
  /// work order (a scan-time terminal row — a failed root stat, a
  /// rejected name — has none to re-dispatch), and a terminal task's
  /// scan completed. A mid-scan failure instead retries through
  /// [retryTask]'s re-scan, which rebuilds every row at once.
  bool canRetryItem(String taskId, String itemId) {
    final runtime = _tasks[taskId];
    if (runtime == null) return false;
    final task = runtime.task;
    if (task.isTerminal && !task.scanComplete) return false;
    final item = _itemOf(task, itemId);
    if (item == null || item.state != TransferItemState.failed) {
      return false;
    }
    return _retryWork(runtime, item) != null;
  }

  /// Re-enqueues one failed item in place — 02 §6's per-row Retry. The
  /// row keeps its itemId (the journaled outcome already records the
  /// failed attempt; a re-run appends the fresh outcome behind it), and
  /// a directory's retry re-arms the children that skipped as
  /// collateral — the user's own per-item skips stay removed. On a
  /// terminal failed task the retry re-queues the task itself.
  bool retryItem(String taskId, String itemId) {
    final runtime = _tasks[taskId];
    if (runtime == null || !canRetryItem(taskId, itemId)) return false;
    _retryItemInPlace(runtime, _itemOf(runtime.task, itemId)!);
    if (runtime.task.isTerminal) _requeueTask(runtime);
    _pump();
    _maybeFinishTask(runtime);
    return true;
  }

  /// Whether [retryTask] can re-run the task: it failed, and either the
  /// scan never completed (the retry re-scans) or at least one failed
  /// row still has a work order to re-arm.
  bool canRetryTask(String taskId) {
    final runtime = _tasks[taskId];
    if (runtime == null || runtime.task.state != TransferTaskState.failed) {
      return false;
    }
    if (!runtime.task.scanComplete) return true;
    return runtime.task.items.any((item) => canRetryItem(taskId, item.id));
  }

  /// 02 §6's per-task Retry — failed items only. With a completed scan
  /// every retryable row re-arms in place (a directory's retry carries
  /// its collateral-skipped subtree with it); a task that died mid-scan
  /// re-runs the whole scan, merging onto the journaled rows so no
  /// duplicate items appear and terminal outcomes still suppress
  /// re-dispatch.
  bool retryTask(String taskId) {
    final runtime = _tasks[taskId];
    if (runtime == null || !canRetryTask(taskId)) return false;
    if (!runtime.task.scanComplete) {
      _rescanRetry(runtime);
      return true;
    }
    // `_retryItemInPlace` flips each row to pending, so a descendant
    // re-armed by its directory's retry reads as non-failed when the
    // outer loop reaches it — no double arm.
    for (final item in runtime.task.items.toList()) {
      if (canRetryItem(taskId, item.id)) _retryItemInPlace(runtime, item);
    }
    _requeueTask(runtime);
    _pump();
    _maybeFinishTask(runtime);
    return true;
  }

  /// The shared body of [retryItem]/[retryTask] for one item: reset the
  /// row, re-arm its work order, and — for a directory — cascade the
  /// retry through the subtree it took down (collateral skips and
  /// failed children with work orders).
  void _retryItemInPlace(_TaskRuntime runtime, TransferItem item) {
    _resetItemForRetry(runtime, item);
    final work = _retryWork(runtime, item)!;
    if (work is _DirState) {
      for (final descendant in _descendantsOf(runtime, item.id)) {
        final retriable =
            descendant.state == TransferItemState.failed &&
            _retryWork(runtime, descendant) != null;
        final collateral = runtime.containerSkips.contains(descendant.id);
        if (!retriable && !collateral) continue;
        _resetItemForRetry(runtime, descendant);
        final descendantWork = _retryWork(runtime, descendant);
        if (descendantWork != null) {
          _rearmWork(runtime, descendantWork);
        }
      }
    }
    _rearmWork(runtime, work);
  }

  /// Flips one terminal row back to `pending`: the aggregate debits its
  /// partial bytes (02 §5.3's floor rule — the re-transfer reports them
  /// again), the counters release it, and a directory's `ready` gate
  /// re-arms so its re-dispatching children wait on the fresh mkdir.
  void _resetItemForRetry(_TaskRuntime runtime, TransferItem item) {
    final task = runtime.task;
    _debitItemProgress(runtime, item);
    if (item.state == TransferItemState.failed) {
      task.failedItems--;
    } else if (runtime.containerSkips.remove(item.id)) {
      task.skippedItems--;
    }
    item.state = TransferItemState.pending;
    item.error = null;
    item.failureKind = null;
    final directory = runtime.directories[item.id];
    if (directory != null) {
      directory.outcome = _DirOutcome.pending;
      directory.resolvedPath = null;
      directory.selfTarget = false;
      directory.ready = Completer();
    }
    _emit(TransferQueueItemEvent(task.id, item.id, item.state));
  }

  /// Re-arms one work order — the dispatch path each shape already owns.
  void _rearmWork(_TaskRuntime runtime, Object work) => switch (work) {
    _FileWork() => _armFile(runtime, work),
    _DirState() => _scheduleDirectory(runtime, work),
    _DeleteWork() => _armDelete(runtime, work),
    _ => throw StateError('unknown work order: $work'),
  };

  /// The work order a failed item re-arms with, or null when there is
  /// nothing to re-dispatch — a scan-time terminal row (failed root
  /// stat, rejected name, unsupported type) planned no work.
  Object? _retryWork(_TaskRuntime runtime, TransferItem item) {
    if (runtime.task.operation == TransferOperation.delete) {
      return runtime.deleteWork[item.id];
    }
    if (item.isDirectory) {
      final directory = runtime.directories[item.id];
      // A listing failure discovered no children — re-arming the mkdir
      // alone would "complete" the subtree with nothing in it.
      if (directory == null || directory.listingFailed) return null;
      return directory;
    }
    for (final file in runtime.task.plan?.files ?? const <PlannedFile>[]) {
      if (file.itemId == item.id) return _FileWork(item: item, file: file);
    }
    return null;
  }

  /// The items whose container chain runs through [dirItemId] — the
  /// subtree a retried directory re-arms (03 §4.1's containerKey links).
  List<TransferItem> _descendantsOf(_TaskRuntime runtime, String dirItemId) {
    final plan = runtime.task.plan;
    final parentByItemId = <String, String?>{
      for (final file in plan?.files ?? const <PlannedFile>[])
        file.itemId: file.containerKey,
      for (final dir in plan?.directoriesInOrder ?? const <PlannedDirectory>[])
        dir.itemId: dir.containerKey,
    };
    return [
      for (final item in runtime.task.items)
        if (_isDescendant(parentByItemId, item.id, dirItemId)) item,
    ];
  }

  static bool _isDescendant(
    Map<String, String?> parentByItemId,
    String itemId,
    String dirItemId,
  ) {
    var key = parentByItemId[itemId];
    while (key != null) {
      if (key == dirItemId) return true;
      key = parentByItemId[key];
    }
    return false;
  }

  /// Flips a terminal task back to `queued` for a retry: the journal
  /// records the re-queue before the state flips, and the runtime's
  /// one-shot latches (`done`, `finishing`, a stranded `notPaused` from
  /// a pause that landed before the failure) re-arm so the second run's
  /// finish path still fires.
  void _requeueTask(_TaskRuntime runtime) {
    final task = runtime.task;
    _journalState(task, TransferTaskState.queued);
    task.state = TransferTaskState.queued;
    task.error = null;
    task.failureKind = null;
    task.finishedAt = null;
    task.retryCount = 0;
    runtime.finishing = false;
    runtime.done = Completer();
    if (!runtime.notPaused.isCompleted) runtime.notPaused.complete();
    _emit(TransferQueueTaskEvent(task.id, task.state));
  }

  /// The mid-scan retry: clears the plan and dispatch state and re-runs
  /// `_runTask`, seeding `restoredIndex` with the live rows so the
  /// re-walk merges onto the journaled itemIds instead of minting
  /// duplicate rows — the same merge 03 §4.6's crash restore runs.
  /// Terminal outcomes carry through: completed rows suppress
  /// re-dispatch, user-removed rows stay removed, failed rows with a
  /// work order get a fresh dispatch.
  void _rescanRetry(_TaskRuntime runtime) {
    final task = runtime.task;
    final plan = task.plan;
    final filesById = {
      for (final file in plan?.files ?? const <PlannedFile>[])
        file.itemId: file,
    };
    final dirsById = {
      for (final dir in plan?.directoriesInOrder ?? const <PlannedDirectory>[])
        dir.itemId: dir,
    };
    final index = <String, List<RestoredPlanItem>>{};
    for (final item in task.items) {
      final file = filesById[item.id];
      final dir = dirsById[item.id];
      final delete = runtime.deleteWork[item.id];
      final RestoredItemOutcome? outcome = switch (item.state) {
        TransferItemState.completed => RestoredItemOutcome.completed,
        // Collateral of a failed container — the retried container's
        // re-scan re-discovers and re-dispatches it.
        _ when runtime.containerSkips.contains(item.id) => null,
        TransferItemState.skipped ||
        TransferItemState.cancelled => RestoredItemOutcome.removed,
        _ =>
          (file != null || dir != null || delete != null)
              ? null
              : RestoredItemOutcome.failed,
      };
      final destinationPath =
          file?.destinationPath ??
          dir?.destinationPath ??
          delete?.entry.path ??
          item.destinationPath;
      (index[destinationPath] ??= []).add(
        RestoredPlanItem(
          itemId: item.id,
          isDirectory: item.isDirectory,
          sourcePath: item.sourcePath,
          destinationPath: destinationPath,
          containerKey: file?.containerKey ?? dir?.containerKey,
          name: file?.name ?? dir?.name,
          source: file?.source ?? dir?.source ?? delete?.entry,
          existing: file?.existing ?? dir?.existing,
          outcome: outcome,
          error: item.error,
          failureKind: item.failureKind,
          resolvedPath: outcome == RestoredItemOutcome.completed
              ? item.destinationPath
              : null,
          disposition: item.disposition,
        ),
      );
    }
    task.items.clear();
    task.plan = null;
    task.scanComplete = false;
    task.totalBytes = null;
    task.totalFiles = 0;
    task.totalDirectories = 0;
    task.completedFiles = 0;
    task.completedDirectories = 0;
    task.failedItems = 0;
    task.skippedItems = 0;
    task.transferredBytes = 0;
    runtime.directories.clear();
    runtime.walkDirectories.clear();
    runtime.deleteWork.clear();
    runtime.containerSkips.clear();
    runtime.eligible.clear();
    runtime.restoredIndex = index;
    _requeueTask(runtime);
    unawaited(_runTask(runtime));
  }

  /// The item id a conflict-waiter entry parks — `_FileWork` and
  /// `_DirState` are the only shapes `conflictWaiters` holds.
  static String? _workItemId(Object work) => switch (work) {
    _FileWork(:final item) => item.id,
    _DirState(:final item) => item.id,
    _ => null,
  };

  static TransferItem? _itemOf(TransferTask task, String itemId) {
    for (final item in task.items) {
      if (item.id == itemId) return item;
    }
    return null;
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
      if (restored.spec.operation == TransferOperation.delete) {
        _rebuildScannedDeletePlan(runtime, restored);
      } else {
        _rebuildScannedPlan(runtime, restored);
      }
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
            dirState.resolvedPath = entry.resolvedPath ?? entry.destinationPath;
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
                name:
                    entry.name ??
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

  /// Rebuilds a fully-scanned delete task from its journaled records —
  /// the D15 analog of [_rebuildScannedPlan]. Journaled append order is
  /// the walk's post-order, so arming the pending items in iteration
  /// order preserves children-before-container on the serialized chain.
  /// A journaled `fileCompleted` (with its trashed-vs-permanent
  /// disposition) or a terminal skip/fail replays as the finished row —
  /// a crash can never re-delete or re-trash an entry.
  void _rebuildScannedDeletePlan(
    _TaskRuntime runtime,
    RestoredTransferTask restored,
  ) {
    final task = runtime.task;
    task.plan = TransferPlan();
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
        task.totalDirectories++;
      } else {
        task.totalFiles++;
      }
      switch (entry.outcome) {
        case RestoredItemOutcome.completed:
          item.state = TransferItemState.completed;
          item.disposition = entry.disposition;
          if (entry.isDirectory) {
            task.completedDirectories++;
          } else {
            task.completedFiles++;
            task.transferredBytes += entry.source?.size ?? 0;
          }
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
            // The planEntry's source detail was lost (a quarantined
            // journal tail) — the delete cannot re-run blind, so the
            // item fails honestly rather than dispatching on a guess.
            item.state = TransferItemState.failed;
            item.error = 'the journal lost this item\'s source detail';
            item.failureKind = RemoteFileErrorKind.other;
            task.failedItems++;
          } else {
            _armDelete(runtime, _DeleteWork(item: item, entry: source));
          }
      }
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
    // A delete task writes no upload temps — there is nothing to sweep.
    if (task.operation == TransferOperation.delete) return;
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
      (name.startsWith('.poltergeist-') ||
          name.startsWith('.seance-upload-')) &&
      name.endsWith('.tmp');

  /// Journals a lifecycle transition before its caller mutates
  /// `task.state` (write-before-effect, 03 §4.6).
  void _journalState(
    TransferTask task,
    TransferTaskState state, {
    String? error,
    RemoteFileErrorKind? failureKind,
  }) {
    // Produce tasks are unjournaled (03 §4.6/§4.7): the caller's Future
    // dies with the process, so no record may resurrect them.
    if (task.spec.produce != null) return;
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
    ItemDisposition? disposition,
  }) {
    final store = persistence;
    if (store == null || task.spec.produce != null) return;
    switch (state) {
      case TransferItemState.completed:
        store.appendJournal(
          FileCompletedRecord(
            taskId: task.id,
            itemId: item.id,
            resolvedPath: resolvedPath ?? item.destinationPath,
            disposition: disposition,
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
          ItemRemovedRecord(taskId: task.id, itemId: item.id, error: error),
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
    if (isDirectory) {
      task.totalDirectories++;
    } else {
      task.totalFiles++;
    }
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
    bool isDirectory = false,
    int? size,
    String? error,
    RemoteFileErrorKind? failureKind,
  }) {
    final task = runtime.task;
    // A re-scanned report-kind row merges onto its journaled record by
    // path, exactly like planned items do — reusing the itemId instead
    // of minting a duplicate row (and a duplicate journal prefix) for
    // the same entry.
    final restored = runtime.takeRestored(destinationPath, sourcePath);
    final item = TransferItem(
      id: restored?.itemId ?? uuidV4(),
      sourcePath: sourcePath,
      isDirectory: isDirectory,
      destinationPath: destinationPath,
      size: size,
    );
    // Journal the entry and its terminal outcome before the row exists —
    // a scan-time terminal item (skipped symlink, failed root stat) is
    // part of the task's record like any other (03 §4.6). A merged row's
    // planEntry already stands from the first scan.
    if (restored == null) {
      persistence?.appendJournal(
        PlanEntryRecord(
          taskId: task.id,
          itemId: item.id,
          isDirectory: isDirectory,
          sourcePath: sourcePath,
          destinationPath: destinationPath,
          sourceSize: size,
        ),
      );
    }
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
    if (isDirectory) {
      task.totalDirectories++;
    } else {
      task.totalFiles++;
    }
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
    return _leaseServerIds(_serverIds({spec.source, spec.destination}), token);
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

  Future<void> _releaseLeases(Map<String, TransferChannelLease>? leases) async {
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

  /// Server ids are deduped: a same-server transfer names one server on
  /// both ends, and leasing it twice would let the map overwrite strand
  /// the first lease forever.
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

  String _leafName(FsLocation location, String path) =>
      location is ServerFsLocation
      ? path.replaceAll(RegExp(r'/+$'), '').split('/').last
      : p.basename(path.replaceAll(RegExp(r'[/\\]+$'), ''));

  /// The containing path of [path] — `remoteParent` on a server, the
  /// platform's dirname locally. A filesystem root answers itself, which
  /// is how [enqueueDelete] refuses to delete one.
  String _parentOf(FsLocation location, String path) =>
      location is ServerFsLocation ? remoteParent(path) : p.dirname(path);

  /// The deepest directory containing every root — where a remote trash
  /// run directory lands (the rename then stays on one filesystem) and
  /// what history records for a permanent delete. On Windows both
  /// separators split, matching [_normalizeRoots]'s source-aware rule.
  String _commonParentPath(FsLocation location, List<String> roots) {
    final remote = location is ServerFsLocation;
    // Match p.dirname's own rule: Windows accepts both separators, POSIX
    // only '/' — a backslash is a legal filename character there, and
    // splitting on it would invent a parent that does not exist.
    List<String> segmentsOf(String path) => path
        .split(remote || !Platform.isWindows ? '/' : RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty)
        .toList();
    String join(List<String> segments) => remote
        ? '/${segments.join('/')}'
        : (Platform.isWindows ? segments.join('\\') : '/${segments.join('/')}');
    final common = segmentsOf(_parentOf(location, roots.first));
    for (final root in roots.skip(1)) {
      final parent = segmentsOf(_parentOf(location, root));
      var shared = 0;
      while (shared < common.length &&
          shared < parent.length &&
          common[shared] == parent[shared]) {
        shared++;
      }
      common.removeRange(shared, common.length);
    }
    return join(common);
  }

  String _sourceChildPrefix(FsLocation location, String directory) =>
      location is ServerFsLocation ? '$directory/' : '$directory${p.separator}';

  Future<RemoteFileEntry?> _statOrNull(RemoteFileSystem fs, String path) async {
    try {
      return await fs.stat(path, followLinks: false);
    } on RemoteFileException catch (error) {
      if (error.kind == RemoteFileErrorKind.notFound) return null;
      rethrow;
    }
  }

  /// Whether the planned destination names the source entry itself —
  /// the same path, or a spelling that canonicalizes to it on this
  /// volume or server (a case-insensitive filesystem folds `SRC/` onto
  /// `src/`, and a symlink at the destination resolves through to the
  /// source; on a server, canonicalize is its realpath). Only a move
  /// within one endpoint asks: across endpoints the conflict model's
  /// view of the occupant is authoritative. A canonicalize failure is
  /// inconclusive, not proof — the normal rules then apply.
  Future<bool> _isSelfTarget(
    RemoteFileSystem fs,
    String sourcePath,
    String destinationPath,
  ) async {
    if (sourcePath == destinationPath) return true;
    try {
      return await fs.canonicalize(sourcePath) ==
          await fs.canonicalize(destinationPath);
    } on RemoteFileException {
      return false;
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
      while (path.length > 1 && separators.contains(path[path.length - 1])) {
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

  /// Plan-directory state keyed by the §3.5 walker's node — the scan
  /// resolves a child entry's container (and a closed/failed listing's
  /// directory) through this identity link.
  final Map<WalkNode, _DirState> walkDirectories = {};

  /// itemId → per-attempt token (03 §4.4: pause cancels attempts, never
  /// the sticky task token).
  final Map<String, RemoteTransferCancellation> attempts = {};

  /// Queue-ordered dispatch backlog for this task's discovered files.
  final ListQueue<_FileWork> eligible = ListQueue();

  /// Serializes this task's directory operations parents-first.
  Future<void> directoryChain = Future.value();
  int directoryOpsPending = 0;

  /// Serializes a delete task's destructive ops in the walk's
  /// post-order — children before containers (00 D15). A task is either
  /// a transfer or a delete, never both.
  Future<void> deleteChain = Future.value();
  int deleteOpsPending = 0;

  /// The remote-trash run's name uniquifier (03 §7.3's
  /// `<seq>-<basename>` collision policy): monotonic within the task so
  /// same-basename entries from different directories can never collide,
  /// and a collision retry consumes a fresh value rather than
  /// overwriting a foreign occupant.
  int nextTrashSequence = 1;

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

  /// Live arm records for delete-task items — the retry seam needs the
  /// original [RemoteFileEntry] to re-arm a failed item; transfer items
  /// recover theirs from the plan/`_DirState` instead.
  final Map<String, _DeleteWork> deleteWork = {};

  /// Items skipped as collateral of an unreachable container (02 §6's
  /// per-item Skip abandoning a directory abandons its whole subtree).
  /// A retried directory re-arms these children with it; the user's own
  /// per-item skip is NOT in this set and stays removed.
  final Set<String> containerSkips = {};

  /// Completes when the task is terminal and every in-flight attempt and
  /// scan operation has drained. The retry re-queue recreates it — a
  /// completed completer cannot un-complete.
  Completer<void> done = Completer();
}

class _DirState {
  _DirState({required this.planned, required this.item});

  final PlannedDirectory planned;
  final TransferItem item;

  /// Completes when this directory's mkdir resolved (any outcome), which
  /// releases its file children to dispatch — or skips them. The retry
  /// seam recreates it: a retried directory's children must wait on the
  /// fresh attempt, not a completer that already fired.
  Completer<void> ready = Completer();
  String? resolvedPath;
  _DirOutcome outcome = _DirOutcome.pending;

  /// The scan's listing for this directory failed atomically — its
  /// children were never discovered, so re-arming just the mkdir would
  /// "complete" the subtree with nothing in it. Such a row is not
  /// per-item retryable; only a re-scan (`retryTask` mid-scan path, or
  /// a fresh enqueue) can rediscover it.
  bool listingFailed = false;

  /// 00 D26's directory self-move: the resolved destination canonicalizes
  /// to the source directory itself, so the tree stays in place — the
  /// file children self-complete, and `_removeMovedDirectories` must
  /// not unlink the source.
  bool selfTarget = false;
}

enum _DirOutcome { pending, ready, skipped, failed, cancelled }

class _FileWork {
  const _FileWork({required this.item, required this.file});

  final TransferItem item;
  final PlannedFile file;
}

/// One armed delete op — the walked entry plus its item row. Unlike the
/// file path there is no plan object: the entry IS the whole work order
/// (a delete has no destination to decide against). [listingError]
/// carries a directory's earlier listing failure so the completed
/// trash-move row can still disclose it.
final class _DeleteWork {
  const _DeleteWork({
    required this.item,
    required this.entry,
    this.listingError,
  });

  final TransferItem item;
  final RemoteFileEntry entry;
  final RemoteFileException? listingError;
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

/// The resolved destination IS the source entry (00 D26): a local→local
/// move into the file's own directory — possibly through a spelling a
/// case-insensitive volume folds onto it — is already satisfied. The
/// item completes in place rather than piping onto itself and then
/// unlinking the only copy.
final class _FileSelfTarget extends _FileDecision {
  const _FileSelfTarget(this.destinationPath);

  final String destinationPath;
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

/// Queue-admission order changed — 02 §6's drag-to-reorder moved
/// [taskId]. Carries no position; `tasks` order is the truth and
/// mirrors re-render it verbatim.
final class TransferQueueOrderEvent extends TransferQueueEvent {
  const TransferQueueOrderEvent(super.taskId);
}

/// Byte progress on one item plus the task rollups (02 §5.3's growing
/// totals — `taskTotalBytes` and the `taskTotal*` counts are floors
/// while `scanComplete` is false; `scanComplete` is the marker that
/// makes them final).
final class TransferQueueProgressEvent extends TransferQueueEvent {
  const TransferQueueProgressEvent(
    super.taskId, {
    required this.itemId,
    required this.transferred,
    required this.total,
    required this.taskTransferredBytes,
    required this.taskTotalBytes,
    required this.taskTotalFiles,
    required this.taskTotalDirectories,
    required this.taskCompletedFiles,
    required this.taskCompletedDirectories,
    required this.scanComplete,
  });

  final String itemId;
  final int transferred;
  final int? total;
  final int taskTransferredBytes;
  final int taskTotalBytes;

  /// Planned file work items — the §3.5 walker's discovery count.
  final int taskTotalFiles;

  /// Planned directory entries.
  final int taskTotalDirectories;
  final int taskCompletedFiles;
  final int taskCompletedDirectories;
  final bool scanComplete;
}
