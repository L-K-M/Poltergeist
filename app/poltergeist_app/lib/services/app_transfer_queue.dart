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
/// the §5 protocol. Until then no producer enqueues work, so the panel
/// mounts empty over a null seam rather than simulating activity.
abstract interface class AppTransferQueue {
  /// Queue-order task snapshot — insertion order is admission order.
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
}

/// [TransferQueue] behind the app seam — the in-process adapter used by
/// tests and by the engine-host slice if the queue ever runs in the app
/// isolate. Pure delegation: the queue's API is already the panel's
/// vocabulary, so no translation lives here.
final class TransferQueueAdapter implements AppTransferQueue {
  TransferQueueAdapter(this._queue);

  final TransferQueue _queue;

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
}
