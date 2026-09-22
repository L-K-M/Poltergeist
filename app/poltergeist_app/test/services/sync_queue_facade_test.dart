// The activity-panel seam's unit coverage (M8, 05 §10): task-row
// minting, per-item event rollups, the pause/cancel/retry verb
// routing, and the composite queue's ownership split.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/fake_app_transfer_queue.dart';
import '../support/sync_harness.dart';

TransferTaskSpec _spec() => TransferTaskSpec(
  source: const LocalFsLocation(),
  destination: const LocalFsLocation(),
  rootPaths: const ['/left'],
  destinationDir: '/right',
  policy: ResolvedConflictPolicy(),
);

SyncPlan _plan() => testPlan(testSyncPair(), [
  testItem(
    'a.txt',
    left: testFile(size: 10),
    suggested: SyncActionType.copyLeftToRight,
    reason: SyncReason.onlyOnLeft,
  ),
  testItem(
    'dir',
    left: testDir,
    suggested: SyncActionType.makeDirRight,
    reason: SyncReason.onlyOnLeft,
  ),
  // Skip/conflict rows carry no work — they never get a panel row.
  testItem('same.txt', left: testFile(), right: testFile()),
]);

void main() {
  late SyncQueueTasks tasks;

  SyncTaskBinding begin() => tasks.beginTask(
    spec: _spec(),
    plan: _plan(),
    pause: SyncRunPause(),
    cancellation: RemoteTransferCancellation(),
    retry: () async {},
  );

  setUp(() => tasks = SyncQueueTasks());

  test('beginTask mints one running row per actionable item', () {
    final binding = begin();
    final task = binding.task;
    expect(task.state, TransferTaskState.running);
    expect(task.items, hasLength(2));
    expect(task.totalFiles, 1);
    expect(task.totalDirectories, 1);
    expect(task.totalBytes, 10);
    expect(binding.itemFor('same.txt'), isNull);
    expect(tasks.tasks, contains(task));
  });

  test('item events mirror states and roll up counts', () {
    final binding = begin();
    final item = _plan().items.first;
    binding.emitItemStarted(item);
    expect(binding.itemFor('a.txt')!.state, TransferItemState.active);
    binding.emitProgress('a.txt', 5, 10);
    expect(binding.itemFor('a.txt')!.transferredBytes, 5);
    // Mid-flight progress never commits to the task rollup.
    expect(binding.task.transferredBytes, 0);
    item.status = SyncItemStatus.done;
    binding.emitItemFinished(item);
    expect(binding.itemFor('a.txt')!.state, TransferItemState.completed);
    expect(binding.task.completedFiles, 1);
    expect(binding.task.transferredBytes, 10);
  });

  test('pause/resume/cancel route to the run controls', () {
    final pause = SyncRunPause();
    final cancellation = RemoteTransferCancellation();
    final binding = tasks.beginTask(
      spec: _spec(),
      plan: _plan(),
      pause: pause,
      cancellation: cancellation,
      retry: () async {},
    );
    expect(tasks.setPaused(binding.task.id, true), isTrue);
    expect(pause.isPaused, isTrue);
    expect(binding.task.state, TransferTaskState.paused);
    expect(tasks.setPaused(binding.task.id, false), isTrue);
    expect(pause.isPaused, isFalse);
    expect(tasks.cancel(binding.task.id), isTrue);
    expect(cancellation.isCancelled, isTrue);
  });

  test('retry restarts a failed task through the binding', () async {
    var retried = 0;
    final binding = tasks.beginTask(
      spec: _spec(),
      plan: _plan(),
      pause: SyncRunPause(),
      cancellation: RemoteTransferCancellation(),
      retry: () async => retried++,
    );
    binding.emitTaskState(TransferTaskState.failed);
    expect(tasks.canRetry(binding.task.id), isTrue);
    expect(tasks.retry(binding.task.id), isTrue);
    expect(retried, 1);
    expect(binding.task.state, TransferTaskState.running);
    // A completed task refuses retry — nothing left to drive.
    binding.emitTaskState(TransferTaskState.completed);
    expect(tasks.canRetry(binding.task.id), isFalse);
  });

  test('remove drops terminal rows only', () {
    final binding = begin();
    expect(tasks.remove(binding.task.id), isFalse);
    binding.emitTaskState(TransferTaskState.completed);
    expect(tasks.remove(binding.task.id), isTrue);
    expect(tasks.tasks, isEmpty);
  });

  group('CompositeAppTransferQueue', () {
    test('verbs route by task-id ownership', () {
      final inner = FakeAppTransferQueue();
      final innerTask = inner.addTask();
      final composite = CompositeAppTransferQueue(inner, tasks);
      final binding = begin();

      // Reads concatenate both surfaces.
      expect(
        composite.tasks.map((t) => t.id),
        containsAll([innerTask.id, binding.task.id]),
      );

      // Inner-owned verbs never reach the sync registry.
      composite.pauseTask(innerTask.id);
      expect(inner.pauseTaskCalls, [innerTask.id]);
      composite.cancelTask(innerTask.id);
      expect(inner.cancelTaskCalls, [innerTask.id]);

      // Sync-owned verbs never reach the inner queue.
      composite.pauseTask(binding.task.id);
      expect(binding.task.state, TransferTaskState.paused);
      expect(inner.pauseTaskCalls, hasLength(1));
      composite.resumeTask(binding.task.id);
      expect(binding.task.state, TransferTaskState.running);
      composite.cancelTask(binding.task.id);
      expect(inner.cancelTaskCalls, hasLength(1));
    });

    test('both event streams merge into one', () async {
      final inner = FakeAppTransferQueue();
      final composite = CompositeAppTransferQueue(inner, tasks);
      final seen = <TransferQueueEvent>[];
      final sub = composite.events.listen(seen.add);
      addTearDown(sub.cancel);
      inner.addTask();
      begin();
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(2));
      expect(seen, everyElement(isA<TransferQueueTaskEvent>()));
    });

    test('enqueue and queue-level verbs stay inner-owned', () {
      final inner = FakeAppTransferQueue();
      final composite = CompositeAppTransferQueue(inner, tasks);
      composite.enqueue(_spec());
      expect(inner.enqueuedSpecs, hasLength(1));
      composite.pauseQueue();
      expect(inner.pauseQueueCalls, 1);
      composite.resumeQueue();
      expect(inner.resumeQueueCalls, 1);
      expect(composite.isPaused, inner.isPaused);
    });
  });
}
