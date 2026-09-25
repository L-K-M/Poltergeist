import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';

/// The activity panel's queue seam (02 §6, D16): the UI-facing half of
/// the transfer queue. The app composition names this interface, never
/// the concrete [TransferQueue] — the same posture as [AppEngine], so a
/// scripted fake drives every widget test without an isolate or a
/// socket.
///
/// Production wiring lands with the engine-host slice: the queue runs
/// engine-side (03 §4) and the host maps these verbs and events onto
/// the §5 protocol. Producers (pane drops, a future paste) enqueue one
/// task per gesture via [enqueue]; while no queue is wired the panel
/// still mounts empty over a null seam rather than simulating activity.
abstract interface class AppTransferQueue {
  /// 02 §5.1's enqueue: one user gesture (a pane drop, a future paste)
  /// = one task. The UI composes the [TransferTaskSpec] — endpoints,
  /// roots, destination, resolved policy, verb — and the queue owns
  /// everything after admission; conflicts ride the existing ask-park
  /// flow, never a drop-time pre-check.
  TransferTask enqueue(TransferTaskSpec spec);

  /// Queue-order task snapshot — insertion order is admission order.
  /// Implementations return a detached copy, so callers may iterate
  /// while the verbs below mutate the queue (clearCompleted does).
  List<TransferTask> get tasks;

  /// The queue-level pause gate (02 §6's header toggle): paused stops
  /// new dispatch; in-flight items finish.
  bool get isPaused;

  /// Lifecycle, item-state, conflict, order, and progress events.
  Stream<TransferQueueEvent> get events;

  /// The parked conflicts awaiting an answer (02 §5.2's ask-park).
  List<PendingConflict> get pendingConflicts;

  /// The conflict parked for one item, or null when none is.
  PendingConflict? pendingConflictFor(String taskId, String itemId);

  /// The capped persisted history — the History tab's source, oldest
  /// first.
  List<TransferHistoryEntry> get history;

  /// The dynamic rate limits the throttle popover writes through —
  /// [BandwidthLimiter.bytesPerSecond] is the live setter.
  BandwidthLimiter get downloadLimiter;
  BandwidthLimiter get uploadLimiter;

  /// 00 D37's per-server caps on simultaneous transfers, in force from
  /// the next dispatch. `TransferLimitsController` is their one writer.
  ServerTransferLimits get serverTransferLimits;
  set serverTransferLimits(ServerTransferLimits limits);

  void pauseQueue();
  void resumeQueue();

  void pauseTask(String taskId);
  void resumeTask(String taskId);

  /// Sticky whole-task cancel (03 §4.4): pending items flip to
  /// cancelled; in-flight work unwinds asynchronously.
  void cancelTask(String taskId);

  /// Removes a terminal task from the listing (the panel's Remove and
  /// the completed-row linger).
  bool removeTask(String taskId);

  /// 02 §6's drag-to-reorder; only not-yet-running tasks move. Returns
  /// false when the move is not legal.
  bool moveTask(String taskId, {String? beforeTaskId});

  /// 02 §6's per-row cancel/skip: pulls pending work, trips an in-flight
  /// attempt, and cascades a directory's cancel to its subtree.
  bool cancelItem(String taskId, String itemId);

  /// Whether a failed row still has a work order to re-dispatch.
  bool canRetryItem(String taskId, String itemId);

  /// Re-enqueues one failed item in place, keeping its itemId.
  bool retryItem(String taskId, String itemId);

  /// Whether the task is failed with something retryable left.
  bool canRetryTask(String taskId);

  /// 02 §6's per-task Retry — failed items only.
  bool retryTask(String taskId);

  /// Answers one parked conflict (02 §5.2's verbs + apply-to-all scope).
  bool resolveConflict(
    String taskId,
    String itemId,
    ConflictResolution verb, {
    ConflictResolutionScope scope = ConflictResolutionScope.item,
  });

  /// The History tab's Clear History: drops persisted records; the live
  /// journal is untouched.
  Future<void> clearHistory();

  /// D16's quit safe point (02 §6, 07 §3.5): drains the persistence
  /// writer chain and fsyncs the journal so queued, paused, and
  /// in-flight task states are durable before the window destroys. The
  /// store stays open — unlike shutdown this leaves a vetoed quit's
  /// queue fully writable. A queue with no persistence resolves
  /// immediately: nothing exists to flush.
  Future<void> flushJournal();

  /// 02 §2.6/§10's delete confirmation model (D15): the disposition the
  /// confirmed action will really run (OS trash, remote
  /// `.poltergeist-trash/`, or permanent), the quantified count and size
  /// the dialog discloses, and the trash-unavailable notice. [preferTrash]
  /// is the gesture — `file.delete` passes true, `file.deletePermanently`
  /// false. Throws `cancelled` when [cancellation] trips mid-quantify.
  Future<DeleteConfirmation> prepareDelete({
    required FsLocation source,
    required List<String> rootPaths,
    bool preferTrash = true,
    RemoteTransferCancellation? cancellation,
  });

  /// Enqueues one confirmed delete task: a post-order walk whose every
  /// item routes through the trash layer; progress, cancel, and failures
  /// ride the activity panel like any transfer. A permanent disposition
  /// requires [DeleteRequest.confirmed] (D15: never an unconfirmed
  /// unlink); a local trash request whose OS trash went unavailable
  /// throws [TrashException] so the caller re-confirms permanent.
  Future<TransferTask> enqueueDelete(DeleteRequest request);
}

/// [TransferQueue] behind the app seam — the in-process adapter used by
/// tests and by the engine-host slice if the queue ever runs in the app
/// isolate. Pure delegation: the queue's API is already the panel's
/// vocabulary, so no translation lives here.
final class TransferQueueAdapter implements AppTransferQueue {
  TransferQueueAdapter(this._queue);

  final TransferQueue _queue;

  @override
  TransferTask enqueue(TransferTaskSpec spec) => _queue.enqueue(spec);

  @override
  List<TransferTask> get tasks => _queue.tasks;

  @override
  bool get isPaused => _queue.isPaused;

  @override
  Stream<TransferQueueEvent> get events => _queue.events;

  @override
  List<PendingConflict> get pendingConflicts => _queue.pendingConflicts;

  @override
  PendingConflict? pendingConflictFor(String taskId, String itemId) =>
      _queue.pendingConflictFor(taskId, itemId);

  @override
  List<TransferHistoryEntry> get history => _queue.history;

  @override
  BandwidthLimiter get downloadLimiter => _queue.downloadLimiter;

  @override
  BandwidthLimiter get uploadLimiter => _queue.uploadLimiter;

  @override
  ServerTransferLimits get serverTransferLimits => _queue.serverTransferLimits;

  @override
  set serverTransferLimits(ServerTransferLimits limits) =>
      _queue.serverTransferLimits = limits;

  @override
  void pauseQueue() => _queue.pauseQueue();

  @override
  void resumeQueue() => _queue.resumeQueue();

  @override
  void pauseTask(String taskId) => _queue.pauseTask(taskId);

  @override
  void resumeTask(String taskId) => _queue.resumeTask(taskId);

  @override
  void cancelTask(String taskId) => _queue.cancelTask(taskId);

  @override
  bool removeTask(String taskId) => _queue.removeTask(taskId);

  @override
  bool moveTask(String taskId, {String? beforeTaskId}) =>
      _queue.moveTask(taskId, beforeTaskId: beforeTaskId);

  @override
  bool cancelItem(String taskId, String itemId) =>
      _queue.cancelItem(taskId, itemId);

  @override
  bool canRetryItem(String taskId, String itemId) =>
      _queue.canRetryItem(taskId, itemId);

  @override
  bool retryItem(String taskId, String itemId) =>
      _queue.retryItem(taskId, itemId);

  @override
  bool canRetryTask(String taskId) => _queue.canRetryTask(taskId);

  @override
  bool retryTask(String taskId) => _queue.retryTask(taskId);

  @override
  bool resolveConflict(
    String taskId,
    String itemId,
    ConflictResolution verb, {
    ConflictResolutionScope scope = ConflictResolutionScope.item,
  }) =>
      _queue.resolveConflict(taskId, itemId, verb, scope: scope);

  @override
  Future<void> clearHistory() => _queue.clearHistory();

  @override
  Future<DeleteConfirmation> prepareDelete({
    required FsLocation source,
    required List<String> rootPaths,
    bool preferTrash = true,
    RemoteTransferCancellation? cancellation,
  }) => _queue.prepareDelete(
    source: source,
    rootPaths: rootPaths,
    preferTrash: preferTrash,
    cancellation: cancellation,
  );

  @override
  Future<TransferTask> enqueueDelete(DeleteRequest request) =>
      _queue.enqueueDelete(request);

  @override
  Future<void> flushJournal() {
    final persistence = _queue.persistence;
    if (persistence is FileTransferPersistence) {
      // The file store's drain-and-fsync leaves it writable — the
      // close gate may veto and leave the queue running.
      return persistence.flush();
    }
    // A foreign implementation has no flush-without-close seam, and the
    // quit guard may veto *after* this call — a failed shutdown() on the
    // veto path would leave the store closed under a live queue. Fail
    // loudly at wiring instead of wedging the quit path.
    if (persistence == null) return Future<void>.value();
    throw UnsupportedError(
      'AppTransferQueue persistence must support a non-closing flush',
    );
  }
}
