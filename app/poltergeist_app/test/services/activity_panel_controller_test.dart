import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/activity_panel_controller.dart';
import 'package:poltergeist_app/services/transfer_rate_tracker.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';

void main() {
  group('TransferRateTracker', () {
    var now = DateTime.utc(2026, 1, 1);
    late TransferRateTracker tracker;

    setUp(() {
      now = DateTime.utc(2026, 1, 1);
      tracker = TransferRateTracker(clock: () => now);
    });

    void tick(Duration delta) => now = now.add(delta);

    test('withholds a rate until two samples span real time', () {
      tracker.record('t', 0);
      expect(tracker.bytesPerSecond('t'), isNull);
      tick(const Duration(milliseconds: 500));
      tracker.record('t', 500);
      expect(tracker.bytesPerSecond('t'), closeTo(1000, 0.001));
    });

    test('smooths across the 5s window and drops expired samples', () {
      tracker.record('t', 0);
      tick(const Duration(seconds: 2));
      tracker.record('t', 2000);
      tick(const Duration(seconds: 2));
      tracker.record('t', 4000);
      expect(tracker.bytesPerSecond('t'), closeTo(1000, 0.001));

      // Push the first sample past the window: the rate now spans
      // only the last two samples.
      tick(const Duration(seconds: 4));
      tracker.record('t', 5000);
      expect(tracker.dataSpan('t'), const Duration(seconds: 4));
      expect(tracker.bytesPerSecond('t'), closeTo(250, 0.001));
    });

    test('expires the rate once the newest sample leaves the window',
        () {
      tracker.record('t', 0);
      tick(const Duration(seconds: 4));
      tracker.record('t', 1000);
      expect(tracker.bytesPerSecond('t'), closeTo(250, 0.001));
      expect(tracker.eta('t', 500), const Duration(seconds: 2));

      // A stalled transfer records nothing: without a read-side
      // expiry the panel would keep quoting a rate that is no longer
      // true — the window lapses and the rate withdraws instead.
      tick(TransferRateTracker.window + const Duration(seconds: 1));
      expect(tracker.bytesPerSecond('t'), isNull);
      expect(tracker.eta('t', 500), isNull);
    });

    test('gates the ETA on three seconds of data', () {
      tracker.record('t', 0);
      tick(const Duration(seconds: 2));
      tracker.record('t', 2000);
      expect(tracker.eta('t', 10 * 1000), isNull);
      tick(const Duration(seconds: 1));
      tracker.record('t', 3000);
      expect(tracker.eta('t', 10 * 1000), const Duration(seconds: 10));
    });

    test('refreshes the ETA at most once per second', () {
      tracker.record('t', 0);
      tick(const Duration(seconds: 4));
      tracker.record('t', 4000);
      final first = tracker.eta('t', 8000);
      expect(first, const Duration(seconds: 8));

      tick(const Duration(milliseconds: 500));
      tracker.record('t', 4500);
      // Inside the refresh window: the cached value answers even
      // though the underlying rate moved.
      expect(tracker.eta('t', 6000), first);

      tick(const Duration(seconds: 1));
      tracker.record('t', 5000);
      final refreshed = tracker.eta('t', 6000);
      expect(refreshed, isNot(first));
    });

    test('a non-monotonic byte count resets the window', () {
      tracker.record('t', 1000);
      tick(const Duration(seconds: 2));
      tracker.record('t', 3000);
      expect(tracker.bytesPerSecond('t'), closeTo(1000, 0.001));

      // Retry debit: cumulative bytes drop, the stale rate must go.
      tick(const Duration(seconds: 1));
      tracker.record('t', 500);
      expect(tracker.bytesPerSecond('t'), isNull);
      expect(tracker.dataSpan('t'), Duration.zero);
    });

    test('a debit below the previous sample resets even above the '
        'window floor', () {
      tracker.record('t', 1000);
      tick(const Duration(seconds: 1));
      tracker.record('t', 2000);
      // The debit drops below the PREVIOUS sample but stays above the
      // window's oldest — comparing against the window floor would let
      // a stale rate misreport.
      tick(const Duration(seconds: 1));
      tracker.record('t', 1500);
      expect(tracker.bytesPerSecond('t'), isNull);
      expect(tracker.dataSpan('t'), Duration.zero);
    });

    test('prune drops unknown tasks; remove drops one', () {
      tracker.record('a', 0);
      tracker.record('b', 0);
      tracker.prune({'b'});
      tick(const Duration(seconds: 1));
      tracker.record('a', 100);
      tracker.record('b', 100);
      expect(tracker.bytesPerSecond('a'), isNull);
      expect(tracker.bytesPerSecond('b'), closeTo(100, 0.001));

      tracker.remove('b');
      tick(const Duration(seconds: 1));
      tracker.record('b', 200);
      expect(tracker.bytesPerSecond('b'), isNull);
    });
  });

  group('ActivityPanelController', () {
    late FakeAppTransferQueue queue;

    setUp(() {
      queue = FakeAppTransferQueue();
      addTearDown(queue.close);
    });

    ActivityPanelController bind({
      bool autoClearCompleted = true,
      Duration completedLinger = const Duration(milliseconds: 40),
      int? downloadLimit,
      int? uploadLimit,
      void Function()? onTasksArrived,
      Future<void> Function(int?)? persistDownloadLimit,
      Future<void> Function(int?)? persistUploadLimit,
      DateTime Function()? clock,
    }) {
      final controller = ActivityPanelController(
        queue: queue,
        autoClearCompleted: autoClearCompleted,
        completedLinger: completedLinger,
        downloadLimit: downloadLimit,
        uploadLimit: uploadLimit,
        onTasksArrived: onTasksArrived,
        persistDownloadLimit: persistDownloadLimit,
        persistUploadLimit: persistUploadLimit,
        clock: clock,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    TransferQueueProgressEvent progress(
      String taskId,
      String itemId,
      int taskBytes,
    ) =>
        TransferQueueProgressEvent(
          taskId,
          itemId: itemId,
          transferred: taskBytes,
          total: null,
          taskTransferredBytes: taskBytes,
          taskTotalBytes: 10000,
          taskTotalFiles: 1,
          taskTotalDirectories: 0,
          taskCompletedFiles: 0,
          taskCompletedDirectories: 0,
          scanComplete: true,
        );

    test('a null queue mounts empty — no fabricated rows, safe verbs',
        () async {
      final controller = ActivityPanelController();
      addTearDown(controller.dispose);

      expect(controller.tasks, isEmpty);
      expect(controller.pendingConflicts, isEmpty);
      expect(controller.history, isEmpty);
      expect(controller.queuePaused, isFalse);
      // Verbs on a null seam are no-ops, not crashes.
      controller.toggleQueuePause();
      controller.cancelTask('x');
      controller.removeTask('x');
      controller.retryTask('x');
      controller.clearCompleted();
      await controller.clearHistory();
      expect(queue.tasks, isEmpty);
    });

    test('mirrors tasks and events into notifyListeners', () async {
      final controller = bind();
      var notifies = 0;
      controller.addListener(() => notifies++);
      final task = queue.addTask(state: TransferTaskState.running);
      await Future<void>.delayed(Duration.zero);
      expect(controller.tasks.single.id, task.id);
      expect(notifies, greaterThan(0));
    });

    test('completed rows linger, then auto-remove via the queue',
        () async {
      final controller = bind();
      final task = queue.addTask(state: TransferTaskState.running);
      await Future<void>.delayed(Duration.zero);
      task.state = TransferTaskState.completed;
      queue.emit(TransferQueueTaskEvent(task.id, task.state));
      await Future<void>.delayed(Duration.zero);

      // Still listed — the user sees it land.
      expect(controller.tasks.single.id, task.id);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(controller.tasks, isEmpty);
      expect(queue.removeTaskCalls, [task.id]);
    });

    test('failed and cancelled rows stay until removed explicitly',
        () async {
      final controller = bind();
      final failed = queue.addTask(state: TransferTaskState.failed);
      final cancelled = queue.addTask(state: TransferTaskState.cancelled);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        controller.tasks.map((t) => t.id),
        containsAll([failed.id, cancelled.id]),
      );

      controller.removeTask(failed.id);
      expect(queue.removeTaskCalls, [failed.id]);
      expect(controller.tasks.map((t) => t.id), [cancelled.id]);
    });

    test('autoClearCompleted off: completed rows never auto-remove',
        () async {
      bind(autoClearCompleted: false);
      final task = queue.addTask(state: TransferTaskState.running);
      await Future<void>.delayed(Duration.zero);
      task.state = TransferTaskState.completed;
      queue.emit(TransferQueueTaskEvent(task.id, task.state));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(controllerTasks(queue).single.id, task.id);
    });

    test('a retry clears the linger timer for that task', () async {
      final controller = bind();
      final task = queue.addTask(state: TransferTaskState.running);
      await Future<void>.delayed(Duration.zero);
      task.state = TransferTaskState.completed;
      queue.emit(TransferQueueTaskEvent(task.id, task.state));
      await Future<void>.delayed(Duration.zero);
      controller.retryTask(task.id);
      // The linger timer for this id is gone — surviving past the
      // window proves it. The queue owns the retry verdict itself.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(queue.removeTaskCalls, isEmpty);
      expect(queue.retryTaskCalls, [task.id]);
    });

    test('restoredTasks filters to journaled, still-live tasks', () {
      final controller = bind();
      final restored = queue.addTask(
        state: TransferTaskState.paused,
        wasRestored: true,
      );
      queue.addTask(state: TransferTaskState.queued);
      queue.addTask(state: TransferTaskState.completed, wasRestored: true);
      expect(controller.restoredTasks.single.id, restored.id);
    });

    test('resumeRestoredQueue lifts paused tasks and the queue gate',
        () {
      final controller = bind();
      final task = queue.addTask(
        state: TransferTaskState.paused,
        wasRestored: true,
      );
      queue.pauseQueue();
      controller.resumeRestoredQueue();
      expect(queue.resumeTaskCalls, [task.id]);
      expect(queue.resumeQueueCalls, 1);
      expect(queue.isPaused, isFalse);
    });

    test('discardRestoredQueue cancels every live restored task', () {
      final controller = bind();
      final a = queue.addTask(
        state: TransferTaskState.paused,
        wasRestored: true,
      );
      final b = queue.addTask(
        state: TransferTaskState.queued,
        wasRestored: true,
      );
      final live = queue.addTask(state: TransferTaskState.queued);
      controller.discardRestoredQueue();
      expect(queue.cancelTaskCalls, containsAll([a.id, b.id]));
      expect(queue.cancelTaskCalls, isNot(contains(live.id)));
    });

    test('onTasksArrived fires once on the empty→live edge, then '
        're-arms only after the queue drains', () async {
      var arrived = 0;
      bind(onTasksArrived: () => arrived++);
      queue.addTask(state: TransferTaskState.queued);
      await Future<void>.delayed(Duration.zero);
      queue.emitRefresh();
      await Future<void>.delayed(Duration.zero);
      expect(arrived, 1);

      // Drain fully, then arrive again.
      queue.cancelTask(queue.tasks.single.id);
      await Future<void>.delayed(Duration.zero);
      queue.removeTask(queue.tasks.single.id);
      await Future<void>.delayed(Duration.zero);
      queue.addTask(state: TransferTaskState.running);
      await Future<void>.delayed(Duration.zero);
      expect(arrived, 2);
    });

    test('throttle writes land on the limiter and the persist '
        'callback; desired values re-apply on rebind', () {
      final persisted = <(String, int?)>[];
      final controller = bind(
        persistDownloadLimit: (v) async => persisted.add(('down', v)),
        persistUploadLimit: (v) async => persisted.add(('up', v)),
      );

      controller.setDownloadLimit(256000);
      controller.setUploadLimit(1000000);
      expect(queue.downloadLimiter.bytesPerSecond, 256000);
      expect(queue.uploadLimiter.bytesPerSecond, 1000000);
      expect(persisted, [('down', 256000), ('up', 1000000)]);
      expect(controller.downloadLimit, 256000);
      expect(controller.uploadLimit, 1000000);

      // Rebinding a fresh seam applies the remembered values.
      final other = FakeAppTransferQueue();
      addTearDown(other.close);
      controller.queue = other;
      expect(other.downloadLimiter.bytesPerSecond, 256000);
      expect(other.uploadLimiter.bytesPerSecond, 1000000);

      controller.setDownloadLimit(null);
      expect(other.downloadLimiter.bytesPerSecond, isNull);
      expect(persisted.last, ('down', null));
    });

    test('verbs delegate to the queue seam and notify', () {
      final controller = bind();
      var notifies = 0;
      controller.addListener(() => notifies++);
      final task = queue.addTask(state: TransferTaskState.queued);
      final item = queue.addItem(task);

      controller.moveTask(task.id);
      expect(queue.moveTaskCalls, [(task.id, null)]);
      controller.cancelItem(task.id, item.id);
      expect(queue.cancelItemCalls, [(task.id, item.id)]);
      controller.pauseTask(task.id);
      expect(queue.pauseTaskCalls, [task.id]);
      controller.toggleQueuePause();
      expect(queue.pauseQueueCalls, 1);
      expect(controller.queuePaused, isTrue);
      controller.toggleQueuePause();
      expect(queue.resumeQueueCalls, 1);
      expect(notifies, greaterThan(0));
    });

    test('resolveConflict returns the queue answer', () {
      final controller = bind();
      final task = queue.addTask(state: TransferTaskState.running);
      final item = queue.addItem(task);
      final conflict = queue.addConflict(task, item);
      expect(
        controller.resolveConflict(conflict, ConflictResolution.replace),
        isTrue,
      );
      expect(
        queue.resolveConflictCalls.single,
        (
          task.id,
          item.id,
          ConflictResolution.replace,
          ConflictResolutionScope.item,
        ),
      );
      // A second answer on a resolved conflict is refused.
      expect(
        controller.resolveConflict(conflict, ConflictResolution.skip),
        isFalse,
      );
    });

    test('rate and ETA read through progress events', () async {
      var now = DateTime.utc(2026, 1, 1);
      final controller = bind(clock: () => now);
      final task = queue.addTask(
        state: TransferTaskState.running,
        totalBytes: 10000,
      );
      final item = queue.addItem(task);
      await Future<void>.delayed(Duration.zero);

      task.transferredBytes = 1000;
      queue.emit(progress(task.id, item.id, 1000));
      await Future<void>.delayed(Duration.zero);
      expect(controller.rateFor(task.id), isNull);

      now = now.add(const Duration(seconds: 4));
      task.transferredBytes = 5000;
      queue.emit(progress(task.id, item.id, 5000));
      await Future<void>.delayed(Duration.zero);
      expect(controller.rateFor(task.id), closeTo(1000, 0.001));
      expect(controller.etaFor(task), const Duration(seconds: 5));
    });

    test('clearHistory delegates and refreshes', () async {
      final controller = bind();
      queue.addHistory();
      await Future<void>.delayed(Duration.zero);
      expect(controller.history, hasLength(1));
      await controller.clearHistory();
      expect(queue.clearHistoryCalls, 1);
      expect(controller.history, isEmpty);
    });

    test('aggregateRate sums only tasks with a derivable rate', () async {
      var now = DateTime.utc(2026, 1, 1);
      final controller = bind(clock: () => now);
      final a = queue.addTask(
        state: TransferTaskState.running,
        totalBytes: 10000,
      );
      final b = queue.addTask(
        state: TransferTaskState.running,
        totalBytes: 10000,
      );
      final itemA = queue.addItem(a);
      await Future<void>.delayed(Duration.zero);
      queue.emit(progress(a.id, itemA.id, 0));
      queue.emit(progress(b.id, 'none', 0));
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(seconds: 2));
      queue.emit(progress(a.id, itemA.id, 2000));
      await Future<void>.delayed(Duration.zero);
      // b has one sample only — no rate, contributes zero.
      expect(controller.aggregateRate, closeTo(1000, 0.001));
    });
  });
}

/// The controller's own task mirror without holding a reference —
/// re-reads the fake (the mirror is pass-through by contract).
List<TransferTask> controllerTasks(FakeAppTransferQueue queue) =>
    queue.tasks;
