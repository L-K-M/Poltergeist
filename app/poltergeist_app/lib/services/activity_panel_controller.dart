import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'app_transfer_queue.dart';
import 'transfer_rate_tracker.dart';

/// Which body the activity panel renders (02 §6's header tabs).
enum ActivityPanelTab { activity, history }

/// The activity panel's state owner (02 §6, D16): mirrors the queue
/// seam into a listenable the widgets rebuild on, runs the completed-row
/// linger, tracks the §5.3 smoothed rates, and carries the verbs the
/// rows and header invoke. The queue itself stays behind
/// [AppTransferQueue]; this controller adds presentation state only —
/// every honesty rule (which rows exist, what state they are in) is
/// answered by the queue, never cached here.
final class ActivityPanelController extends ChangeNotifier {
  ActivityPanelController({
    AppTransferQueue? queue,

    /// 02 §6's "auto-remove on success — setting, default on": a
    /// completed task lingers [completedLinger] before leaving the
    /// listing.
    this.autoClearCompleted = true,
    this.completedLinger = const Duration(seconds: 10),

    /// The persisted throttle choices (02 §6's "applied immediately,
    /// persisted"), applied to whichever queue binds — the limiters
    /// live on the queue, so the desired values must outlive it.
    int? downloadLimit,
    int? uploadLimit,

    /// Persist callbacks for the throttle popover's writes (02 §6):
    /// invoked after the limiter change lands, best-effort — a failed
    /// write reports through [onError], never silently.
    this.persistDownloadLimit,
    this.persistUploadLimit,
    this.onError,

    /// Fires on the no-tasks → some-tasks edge so the shell can un-hide
    /// the panel for new work. Optional: a panel without it still shows
    /// every row once visible.
    this.onTasksArrived,
    DateTime Function()? clock,
  }) : _rateTracker = TransferRateTracker(clock: clock),
       _desiredDownloadLimit = downloadLimit,
       _desiredUploadLimit = uploadLimit {
    this.queue = queue;
  }

  final bool autoClearCompleted;
  final Duration completedLinger;
  final void Function()? onTasksArrived;
  final FutureOr<void> Function(int? bytesPerSecond)? persistDownloadLimit;
  final FutureOr<void> Function(int? bytesPerSecond)? persistUploadLimit;

  /// Write-failure sink for the persist callbacks (the same posture as
  /// the other controllers' onError seams).
  final void Function(Object, StackTrace)? onError;
  final TransferRateTracker _rateTracker;
  int? _desiredDownloadLimit;
  int? _desiredUploadLimit;

  AppTransferQueue? _queue;
  StreamSubscription<TransferQueueEvent>? _subscription;
  final _lingerTimers = <String, Timer>{};
  ActivityPanelTab _tab = ActivityPanelTab.activity;
  bool _hadLiveTasks = false;
  bool _disposed = false;

  /// The live queue seam, or null while nothing hosts a queue (the
  /// engine-host slice owns production wiring). Swapping seams re-binds
  /// the event subscription; the linger timers and rate window are
  /// presentation state and carry over harmlessly.
  AppTransferQueue? get queue => _queue;

  set queue(AppTransferQueue? next) {
    if (identical(next, _queue)) return;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _queue = next;
    _hadLiveTasks = _anyLive(next);
    if (next != null) {
      // Persisted limits re-apply on every bind — the limiter objects
      // live on the queue, so a fresh seam starts unlimited until the
      // desired values land.
      next.downloadLimiter.bytesPerSecond = _desiredDownloadLimit;
      next.uploadLimiter.bytesPerSecond = _desiredUploadLimit;
      _subscription = next.events.listen(_onQueueEvent);
    }
    notifyListeners();
  }

  /// The header's selected tab.
  ActivityPanelTab get tab => _tab;

  void selectTab(ActivityPanelTab tab) {
    if (tab == _tab) return;
    _tab = tab;
    notifyListeners();
  }

  // -------------------------------------------------------------------
  // Queue mirror — the widgets read these, never the queue directly.
  // -------------------------------------------------------------------

  List<TransferTask> get tasks => _queue?.tasks ?? const [];

  bool get queuePaused => _queue?.isPaused ?? false;

  List<PendingConflict> get pendingConflicts =>
      _queue?.pendingConflicts ?? const [];

  List<TransferHistoryEntry> get history => _queue?.history ?? const [];

  BandwidthLimiter? get downloadLimiter => _queue?.downloadLimiter;

  BandwidthLimiter? get uploadLimiter => _queue?.uploadLimiter;

  /// Restored tasks still on the queue (02 §6's banner scope): the
  /// journal proved they came from a previous session. Terminal ones
  /// dropped out on their own — they need no banner decision.
  List<TransferTask> get restoredTasks => [
    for (final task in tasks)
      if (task.wasRestored && !task.isTerminal) task,
  ];

  /// Aggregate smoothed rate across live tasks — the status bar's
  /// transfer chip.
  double get aggregateRate {
    var sum = 0.0;
    var any = false;
    for (final task in tasks) {
      final rate = _rateTracker.bytesPerSecond(task.id);
      if (rate != null) {
        sum += rate;
        any = true;
      }
    }
    return any ? sum : 0.0;
  }

  /// One task's smoothed bytes/second (02 §5.3's 5 s window); null
  /// before enough samples exist.
  double? rateFor(String taskId) => _rateTracker.bytesPerSecond(taskId);

  /// The task's ETA — null while the rate window holds under three
  /// seconds of data or the scan has not bounded the total (02 §5.3).
  Duration? etaFor(TransferTask task) {
    final total = task.totalBytes;
    if (total == null) return null;
    return _rateTracker.eta(task.id, total - task.transferredBytes);
  }

  // -------------------------------------------------------------------
  // Verbs — thin, honest delegation; every call notifies so the mirror
  // reflects state mutations the queue reports synchronously.
  // -------------------------------------------------------------------

  /// The throttle popover's write path (02 §6): the desired value is
  /// recorded (it outlives the seam and re-applies on bind), the live
  /// limiter takes it immediately, and the persist callback lands it
  /// best-effort. Null is Off — the popover's invalid-input path never
  /// reaches here.
  void setDownloadLimit(int? bytesPerSecond) {
    _desiredDownloadLimit = bytesPerSecond;
    _queue?.downloadLimiter.bytesPerSecond = bytesPerSecond;
    _persist(persistDownloadLimit, bytesPerSecond);
    notifyListeners();
  }

  void setUploadLimit(int? bytesPerSecond) {
    _desiredUploadLimit = bytesPerSecond;
    _queue?.uploadLimiter.bytesPerSecond = bytesPerSecond;
    _persist(persistUploadLimit, bytesPerSecond);
    notifyListeners();
  }

  /// The effective limit the popover and status chip read — the desired
  /// value, not the limiter's, so a null queue still reports what the
  /// user last chose.
  int? get downloadLimit => _desiredDownloadLimit;
  int? get uploadLimit => _desiredUploadLimit;

  void _persist(
    FutureOr<void> Function(int?)? persist,
    int? bytesPerSecond,
  ) {
    final callback = persist;
    if (callback == null) return;
    try {
      final result = callback(bytesPerSecond);
      if (result is Future<void>) {
        unawaited(
          result.catchError((Object error, StackTrace stack) {
            onError?.call(error, stack);
          }),
        );
      }
    } on Object catch (error, stack) {
      onError?.call(error, stack);
    }
  }

  /// `queue.togglePause`'s body: pause stops new dispatch (in-flight
  /// finishes); resume re-opens admission.
  void toggleQueuePause() {
    final queue = _queue;
    if (queue == null) return;
    queue.isPaused ? queue.resumeQueue() : queue.pauseQueue();
    notifyListeners();
  }

  void pauseTask(String taskId) {
    _queue?.pauseTask(taskId);
    notifyListeners();
  }

  void resumeTask(String taskId) {
    _queue?.resumeTask(taskId);
    notifyListeners();
  }

  void cancelTask(String taskId) {
    _queue?.cancelTask(taskId);
    _lingerTimers.remove(taskId)?.cancel();
    notifyListeners();
  }

  /// The row's Remove and the linger's expiry share this path —
  /// [AppTransferQueue.removeTask] itself refuses non-terminal tasks.
  void removeTask(String taskId) {
    _lingerTimers.remove(taskId)?.cancel();
    if (_queue?.removeTask(taskId) ?? false) {
      _rateTracker.remove(taskId);
      notifyListeners();
    }
  }

  /// The header's Clear-completed: drops every terminal row that
  /// finished successfully. Failed and cancelled rows stay — they
  /// carry answers the user has not dismissed.
  void clearCompleted() {
    final queue = _queue;
    if (queue == null) return;
    var removed = false;
    for (final task in queue.tasks) {
      if (task.state == TransferTaskState.completed &&
          queue.removeTask(task.id)) {
        _lingerTimers.remove(task.id)?.cancel();
        _rateTracker.remove(task.id);
        removed = true;
      }
    }
    if (removed) notifyListeners();
  }

  bool moveTask(String taskId, {String? beforeTaskId}) {
    final moved = _queue?.moveTask(taskId, beforeTaskId: beforeTaskId) ??
        false;
    if (moved) notifyListeners();
    return moved;
  }

  void cancelItem(String taskId, String itemId) {
    _queue?.cancelItem(taskId, itemId);
    notifyListeners();
  }

  bool canRetryItem(String taskId, String itemId) =>
      _queue?.canRetryItem(taskId, itemId) ?? false;

  void retryItem(String taskId, String itemId) {
    _queue?.retryItem(taskId, itemId);
    notifyListeners();
  }

  bool canRetryTask(String taskId) => _queue?.canRetryTask(taskId) ?? false;

  void retryTask(String taskId) {
    _queue?.retryTask(taskId);
    _lingerTimers.remove(taskId)?.cancel();
    notifyListeners();
  }

  /// The conflict dialog's answer (02 §5.2): the verb plus the
  /// apply-to-all scope. Returns the queue's own answer — false when
  /// the parked conflict was already resolved or invalidated.
  bool resolveConflict(
    PendingConflict conflict,
    ConflictResolution verb, {
    ConflictResolutionScope scope = ConflictResolutionScope.item,
  }) {
    final resolved = _queue?.resolveConflict(
          conflict.taskId,
          conflict.itemId,
          verb,
          scope: scope,
        ) ??
        false;
    if (resolved) notifyListeners();
    return resolved;
  }

  /// The conflict dialog's Stop verb — cancels the task the parked
  /// conflict belongs to (02 §5.2).
  void stopConflictTask(PendingConflict conflict) =>
      cancelTask(conflict.taskId);

  /// The restored banner's Resume: lifts the queue gate and ends each
  /// restored task's surviving journaled pause (03 §4.6's two latches —
  /// resuming the queue alone leaves a journaled-paused task parked).
  void resumeRestoredQueue() {
    final queue = _queue;
    if (queue == null) return;
    for (final task in restoredTasks) {
      if (task.state == TransferTaskState.paused) {
        queue.resumeTask(task.id);
      }
    }
    queue.resumeQueue();
    notifyListeners();
  }

  /// The restored banner's Discard: cancels every restored task still
  /// live, so the journaled leftovers never start.
  void discardRestoredQueue() {
    final queue = _queue;
    if (queue == null) return;
    for (final task in restoredTasks) {
      queue.cancelTask(task.id);
    }
    notifyListeners();
  }

  /// The History tab's Clear History — persisted records only; live
  /// tasks and the journal are untouched.
  Future<void> clearHistory() async {
    final queue = _queue;
    if (queue == null) return;
    await queue.clearHistory();
    if (!_disposed) notifyListeners();
  }

  // -------------------------------------------------------------------
  // Event mirror
  // -------------------------------------------------------------------

  void _onQueueEvent(TransferQueueEvent event) {
    switch (event) {
      case TransferQueueProgressEvent():
        _rateTracker.record(event.taskId, event.taskTransferredBytes);
      case TransferQueueTaskEvent():
        _scheduleLinger(event.taskId, event.state);
      case TransferQueueItemEvent():
      case TransferQueueConflictEvent():
      case TransferQueueOrderEvent():
    }
    _checkTasksArrived();
    _rateTracker.prune({for (final task in tasks) task.id});
    notifyListeners();
  }

  /// The completed-row linger (02 §6): on success the row stays put for
  /// [completedLinger] so the user sees it land, then leaves. Only
  /// `completed` lingers — a failed or cancelled task stays until the
  /// user removes it; retry clears the timer by resetting the state.
  void _scheduleLinger(String taskId, TransferTaskState state) {
    _lingerTimers.remove(taskId)?.cancel();
    if (!autoClearCompleted || state != TransferTaskState.completed) {
      return;
    }
    _lingerTimers[taskId] = Timer(completedLinger, () => removeTask(taskId));
  }

  static bool _anyLive(AppTransferQueue? queue) =>
      queue?.tasks.any((task) => !task.isTerminal) ?? false;

  /// The auto-show edge: work appearing on an empty queue asks the
  /// shell to un-hide the panel. The flag re-arms only once the queue
  /// fully drains, so hiding the panel mid-queue is not fought by
  /// every later event.
  void _checkTasksArrived() {
    final live = _anyLive(_queue);
    if (live && !_hadLiveTasks) onTasksArrived?.call();
    _hadLiveTasks = live;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    for (final timer in _lingerTimers.values) {
      timer.cancel();
    }
    _lingerTimers.clear();
    super.dispose();
  }
}
