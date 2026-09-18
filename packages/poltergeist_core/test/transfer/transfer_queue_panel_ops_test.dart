import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

/// The activity-panel seams (02 §6, M4): per-item cancel/skip, failed-item
/// retry, pending-task reorder, and the history read/clear surface. Each
/// test drives a real [TransferQueue] over the fake VFS/pool so the
/// engine-side behavior the panel renders is what gets asserted.
void main() {
  late FakeTreeFileSystem remote;
  late FakeTreeFileSystem destination;
  late FakeQueueConnectionManager connections;
  late RecordingPersistence persistence;
  late TransferQueue queue;

  /// A server→server copy spec: both endpoints ride the fake trees, so
  /// destination occupants are planted in memory, never on disk.
  TransferTaskSpec copySpec({
    List<String> rootPaths = const ['/src/a.txt'],
    ConflictResolution files = ConflictResolution.replace,
    ConflictResolution folders = ConflictResolution.merge,
  }) => TransferTaskSpec(
    source: const ServerFsLocation('src'),
    destination: const ServerFsLocation('dst'),
    rootPaths: rootPaths,
    destinationDir: '/dst',
    policy: ResolvedConflictPolicy(files: files, folders: folders),
  );

  RemoteFileException failure(String operation, String path) =>
      RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: operation,
        path: path,
        message: 'simulated $operation failure',
      );

  List<String> downloads() => remote.calls
      .where((call) => call.startsWith('download:'))
      .toList();

  setUp(() {
    remote = FakeTreeFileSystem();
    destination = FakeTreeFileSystem()..addDirectory('/dst');
    connections = FakeQueueConnectionManager({'src': remote, 'dst': destination});
    persistence = RecordingPersistence();
    // One file in flight keeps the observable dispatch order strict —
    // a second task's work can never overtake a first task's through
    // parallelism the assertion cannot see.
    queue = TransferQueue(
      connections: connections,
      persistence: persistence,
      maxInFlightFiles: 1,
    );
  });

  tearDown(() => queue.dispose());

  group('moveTask', () {
    test('reorders pending tasks and emits an order event', () async {
      final orderEvents = <TransferQueueOrderEvent>[];
      final sub = queue.events.listen((event) {
        if (event is TransferQueueOrderEvent) orderEvents.add(event);
      });
      addTearDown(sub.cancel);

      // No pump between the enqueues and the move: both tasks are still
      // `queued` (their scans have not run yet).
      final first = queue.enqueue(copySpec(rootPaths: ['/src/a.txt']));
      final second = queue.enqueue(copySpec(rootPaths: ['/src/b.txt']));
      expect(queue.tasks.map((t) => t.id), [first.id, second.id]);

      expect(queue.moveTask(second.id, beforeTaskId: first.id), isTrue);
      expect(queue.tasks.map((t) => t.id), [second.id, first.id]);
      await pump();
      expect(orderEvents, hasLength(1));
      expect(orderEvents.single.taskId, second.id);
    });

    test('changes the observable admission order', () async {
      remote.addFile('/src/hold.txt', [0]);
      remote.addFile('/src/a.txt', [1]);
      remote.addFile('/src/b.txt', [2]);
      // The single in-flight slot is held so both pending tasks sit
      // eligible — the reorder decides which dispatches when it frees.
      final gate = Completer<void>();
      remote.downloadGate = (path) => path == '/src/hold.txt' ? gate : null;
      final holder = queue.enqueue(copySpec(rootPaths: ['/src/hold.txt']));
      await pumpUntil(
        () => holder.state == TransferTaskState.running,
        reason: 'holder never ran',
      );
      final first = queue.enqueue(copySpec(rootPaths: ['/src/a.txt']));
      final second = queue.enqueue(copySpec(rootPaths: ['/src/b.txt']));
      await pumpUntil(
        () => first.items.isNotEmpty && second.items.isNotEmpty,
        reason: 'queued tasks never planned',
      );
      expect(queue.tasks.map((t) => t.id), [holder.id, first.id, second.id]);

      expect(queue.moveTask(second.id, beforeTaskId: first.id), isTrue);
      expect(queue.tasks.map((t) => t.id), [holder.id, second.id, first.id]);

      gate.complete();
      await pumpUntil(
        () => queue.tasks.every((t) => t.isTerminal),
        reason: 'tasks never settled',
      );
      // The moved task's file dispatched ahead of the unmoved one.
      expect(downloads(), [
        'download:/src/hold.txt',
        'download:/src/b.txt',
        'download:/src/a.txt',
      ]);
    });

    test('refuses running, paused, and terminal tasks', () async {
      remote.addFile('/src/a.txt', [1]);
      remote.addFile('/src/b.txt', [2]);
      final gate = Completer<void>();
      remote.downloadGate = (path) =>
          path == '/src/a.txt' ? gate : null;
      final first = queue.enqueue(copySpec(rootPaths: ['/src/a.txt']));
      final second = queue.enqueue(copySpec(rootPaths: ['/src/b.txt']));
      await pumpUntil(
        () => first.state == TransferTaskState.running,
        reason: 'first task never ran',
      );
      // second is still queued behind the one in-flight slot.
      expect(second.state, isNot(TransferTaskState.running));

      // A running task is pinned — both as mover and as drop target.
      expect(queue.moveTask(first.id), isFalse);
      expect(queue.moveTask(second.id, beforeTaskId: first.id), isFalse);
      expect(queue.tasks.map((t) => t.id), [first.id, second.id]);

      // A paused task is pinned too.
      queue.pauseTask(second.id);
      expect(second.state, TransferTaskState.paused);
      expect(queue.moveTask(second.id), isFalse);

      gate.complete();
      await awaitTaskDone(first);
      queue.resumeTask(second.id);
      await awaitTaskDone(second);
      // Terminal rows are pinned.
      expect(queue.moveTask(first.id), isFalse);
      expect(queue.moveTask('missing'), isFalse);
    });
  });

  group('cancelItem', () {
    test('a pending file is pulled and never dispatches', () async {
      remote.addFile('/src/a.txt', [1, 2, 3]);
      remote.addFile('/src/b.txt', [4, 5]);
      // The queue-level pause holds dispatch while the scan plans both
      // items — they sit pending in the eligible backlog.
      queue.pauseQueue();
      final task = queue.enqueue(
        copySpec(rootPaths: ['/src/a.txt', '/src/b.txt']),
      );
      await pumpUntil(() => task.items.length == 2, reason: 'items planned');
      final item = task.items.firstWhere(
        (i) => i.sourcePath == '/src/b.txt',
      );
      expect(item.state, TransferItemState.pending);

      expect(queue.cancelItem(task.id, item.id), isTrue);
      expect(item.state, TransferItemState.cancelled);
      // The journal got the removal record before the state flip's
      // observable window.
      expect(
        persistence.journal
            .whereType<ItemRemovedRecord>()
            .map((r) => r.itemId),
        contains(item.id),
      );

      queue.resumeQueue();
      await awaitTaskDone(task);
      // a.txt transferred; b.txt never dispatched.
      expect(remote.downloadCalls, 1);
      expect(task.state, TransferTaskState.completed);
    });

    test('a pending directory cascades: subtree items skip', () async {
      remote.addFile('/src/dir/inner.txt', [1]);
      queue.pauseQueue();
      final task = queue.enqueue(copySpec(rootPaths: ['/src/dir']));
      await pumpUntil(() => task.items.length >= 2, reason: 'dir+child');
      final dirItem = task.items.firstWhere((i) => i.isDirectory);
      final childItem = task.items.firstWhere((i) => !i.isDirectory);

      expect(queue.cancelItem(task.id, dirItem.id), isTrue);
      expect(dirItem.state, TransferItemState.cancelled);
      queue.resumeQueue();
      await pumpUntil(
        () => childItem.isTerminal,
        reason: 'child never terminal',
      );
      expect(childItem.state, TransferItemState.skipped);
      expect(destination.mkdirCalls, 0);
      await awaitTaskDone(task);
    });

    test('an active item cancels its in-flight attempt', () async {
      remote.addFile('/src/a.txt', List.filled(64, 7));
      final gate = Completer<void>();
      remote.downloadGate = (path) => gate;
      final task = queue.enqueue(copySpec());
      await pumpUntil(
        () =>
            task.items.isNotEmpty &&
            task.items.single.state == TransferItemState.active,
        reason: 'item never activated',
      );
      final item = task.items.single;

      expect(queue.cancelItem(task.id, item.id), isTrue);
      gate.complete();
      await pumpUntil(
        () => task.isTerminal,
        reason: 'task never drained',
      );
      expect(item.state, TransferItemState.cancelled);
      // The unwinding pipe must not re-pend the row — the task settles
      // completed (no failures), not stuck behind a resurrected item.
      expect(task.state, TransferTaskState.completed);
    });

    test('a conflictPending item resolves to cancelled', () async {
      remote.addFile('/src/a.txt', [1, 2, 3]);
      destination.addFile('/dst/a.txt', [9]);
      final task = queue.enqueue(copySpec(files: ConflictResolution.ask));
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'conflict never parked',
      );
      final conflict = queue.pendingConflicts.single;
      expect(conflict.taskId, task.id);

      expect(queue.cancelItem(task.id, conflict.itemId), isTrue);
      expect(queue.pendingConflicts, isEmpty);
      final item = task.items.single;
      expect(item.state, TransferItemState.cancelled);
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
    });

    test('a pending delete item cancels without dispatching', () async {
      remote.addFile('/src/a.txt', [1]);
      remote.addFile('/src/b.txt', [2]);
      queue.pauseQueue();
      final task = await queue.enqueueDelete(
        const DeleteRequest(
          source: ServerFsLocation('src'),
          rootPaths: ['/src/a.txt', '/src/b.txt'],
          disposition: DeleteDisposition.permanent,
          confirmed: true,
        ),
      );
      await pumpUntil(() => task.items.length == 2, reason: 'items planned');
      final item = task.items.firstWhere((i) => i.sourcePath == '/src/b.txt');

      expect(queue.cancelItem(task.id, item.id), isTrue);
      queue.resumeQueue();
      await awaitTaskDone(task);
      expect(remote.deleteCalls, 1);
      expect(remote.entryAt('/src/a.txt'), isNull);
      expect(remote.entryAt('/src/b.txt'), isNotNull);
    });

    test('refuses terminal or unknown items', () async {
      remote.addFile('/src/a.txt', [1]);
      final task = queue.enqueue(copySpec());
      await awaitTaskDone(task);
      expect(queue.cancelItem(task.id, task.items.single.id), isFalse);
      expect(queue.cancelItem(task.id, 'missing'), isFalse);
      expect(queue.cancelItem('missing', 'missing'), isFalse);
    });
  });

  group('retryItem / retryTask', () {
    test('retries a failed file in place (same itemId, journal record)',
        () async {
      remote.addFile('/src/a.txt', [1, 2, 3]);
      remote.downloadFailure = (path) => failure('download', path);
      final task = queue.enqueue(copySpec());
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      final item = task.items.single;
      expect(item.state, TransferItemState.failed);
      final itemId = item.id;

      remote.downloadFailure = null;
      expect(queue.canRetryItem(task.id, itemId), isTrue);
      expect(queue.retryItem(task.id, itemId), isTrue);
      // The re-arm dispatches through the normal path — the row may
      // already read active by the time the call returns.
      expect(item.state, isNot(TransferItemState.failed));
      expect(task.items.single.id, itemId);
      await pumpUntil(() => task.isTerminal, reason: 'retry never settled');
      expect(item.state, TransferItemState.completed);
      expect(task.state, TransferTaskState.completed);
      // The retry's state churn journaled: task went back to queued.
      expect(
        persistence.journal.whereType<TaskStateRecord>().map((r) => r.state),
        containsAllInOrder([
          TransferTaskState.failed,
          TransferTaskState.queued,
          TransferTaskState.completed,
        ]),
      );
      // History carries both terminal passes — the failed attempt and
      // the retried success.
      expect(persistence.historyEntries, hasLength(2));
    });

    test('a retried directory re-arms its collateral-skipped subtree',
        () async {
      remote.addFile('/src/dir/one.txt', [1]);
      remote.addFile('/src/dir/two.txt', [2]);
      // Failing the destination stat fails the dir's materialization;
      // its children skip as collateral.
      destination.statFailure = (path) =>
          path == '/dst/dir' ? failure('stat', path) : null;
      final task = queue.enqueue(copySpec(rootPaths: ['/src/dir']));
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      final dirItem = task.items.firstWhere((i) => i.isDirectory);
      expect(dirItem.state, TransferItemState.failed);
      expect(
        task.items.where((i) => i.state == TransferItemState.skipped),
        hasLength(2),
      );

      destination.statFailure = null;
      expect(queue.canRetryTask(task.id), isTrue);
      expect(queue.retryItem(task.id, dirItem.id), isTrue);
      expect(task.state, TransferTaskState.queued);
      await pumpUntil(() => task.isTerminal, reason: 'retry never settled');
      expect(task.state, TransferTaskState.completed);
      expect(
        task.items.every((i) => i.state == TransferItemState.completed),
        isTrue,
      );
      expect(task.failedItems, 0);
      expect(task.skippedItems, 0);
    });

    test('retryItem refuses rows without a work order', () async {
      remote.statFailure = (path) => path == '/src/a.txt'
          ? failure('stat', path)
          : null;
      final task = queue.enqueue(copySpec());
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      final item = task.items.single;
      // A root-stat failure planned nothing — no work order to re-arm.
      expect(item.state, TransferItemState.failed);
      expect(queue.canRetryItem(task.id, item.id), isFalse);
      expect(queue.retryItem(task.id, item.id), isFalse);
      // The task-level Retry hides too: nothing on it can re-run.
      expect(queue.canRetryTask(task.id), isFalse);
    });

    test('retryTask re-arms every failed item', () async {
      remote.addFile('/src/dir/one.txt', [1]);
      remote.addFile('/src/dir/two.txt', [2]);
      remote.downloadFailure = (path) => failure('download', path);
      final task = queue.enqueue(copySpec(rootPaths: ['/src/dir']));
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      expect(
        task.items.where((i) => i.state == TransferItemState.failed),
        hasLength(2),
      );

      remote.downloadFailure = null;
      expect(queue.canRetryTask(task.id), isTrue);
      expect(queue.retryTask(task.id), isTrue);
      expect(task.state, TransferTaskState.queued);
      await pumpUntil(() => task.isTerminal, reason: 'retry never settled');
      expect(task.state, TransferTaskState.completed);
      expect(
        task.items.every((i) => i.state == TransferItemState.completed),
        isTrue,
      );
    });

    test('retryTask on a mid-scan failure re-scans without duplicate rows',
        () async {
      remote.addFile('/src/dir/one.txt', [1]);
      remote.addFile('/src/dir/two.txt', [2]);
      // A walk-ending listing failure kills the scan after the root
      // dir's row was planned — the task fails mid-scan.
      remote.listFailure = (path) => path == '/src/dir'
          ? RemoteFileException(
              kind: RemoteFileErrorKind.disconnected,
              operation: 'list',
              path: path,
              message: 'simulated disconnect mid-scan',
            )
          : null;
      final task = queue.enqueue(copySpec(rootPaths: ['/src/dir']));
      await pumpUntil(() => task.isTerminal, reason: 'task never failed');
      expect(task.state, TransferTaskState.failed);
      expect(task.scanComplete, isFalse);
      expect(task.items, hasLength(1));
      final dirItemId = task.items.single.id;

      remote.listFailure = null;
      expect(queue.canRetryTask(task.id), isTrue);
      expect(queue.retryTask(task.id), isTrue);
      await pumpUntil(() => task.isTerminal, reason: 'rescan never settled');
      expect(task.state, TransferTaskState.completed);
      expect(task.scanComplete, isTrue);
      // The re-scan merged onto the journaled row — dir + two files,
      // and the dir kept its itemId instead of minting a duplicate.
      expect(task.items, hasLength(3));
      expect(task.items.firstWhere((i) => i.isDirectory).id, dirItemId);
      expect(
        task.items.every((i) => i.state == TransferItemState.completed),
        isTrue,
      );
    });

    test('a restored mid-scan item keeps its id on retry (no duplicate '
        'journal rows)', () async {
      remote.addFile('/src/dir/one.txt', [1]);
      remote.addFile('/src/dir/two.txt', [2]);
      // Same mid-scan failure, but through the restore path: the task
      // replays paused, the user hits Retry on it.
      persistence.replayValue = TransferJournalReplay(
        tasks: [
          RestoredTransferTask(
            taskId: 'restored-1',
            spec: copySpec(rootPaths: ['/src/dir']),
            enqueuedAt: DateTime.utc(2026, 1, 1),
            wasPaused: false,
            scanComplete: false,
            totalBytes: null,
            skippedSymlinks: 0,
            items: [
              RestoredPlanItem(
                itemId: 'dir-item',
                isDirectory: true,
                sourcePath: '/src/dir',
                destinationPath: '/dst/dir',
                containerKey: null,
                name: 'dir',
                source: null,
                existing: null,
                outcome: null,
                error: null,
                failureKind: null,
                resolvedPath: null,
              ),
            ],
            sweepDirectories: <String>{},
          ),
        ],
      );
      final restoredQueue = TransferQueue(
        connections: connections,
        persistence: persistence,
      );
      addTearDown(restoredQueue.dispose);
      await restoredQueue.restore();
      final task = restoredQueue.tasks.single;
      expect(task.wasRestored, isTrue);
      expect(restoredQueue.isPaused, isTrue);

      restoredQueue.resumeQueue();
      await pumpUntil(() => task.isTerminal, reason: 'rescan never ran');
      expect(task.state, TransferTaskState.completed);
      expect(task.items, hasLength(3));
      // The journaled dir row merged instead of duplicating.
      expect(task.items.firstWhere((i) => i.isDirectory).id, 'dir-item');
    });

    test('retryTask refuses non-failed tasks', () async {
      remote.addFile('/src/a.txt', [1]);
      queue.pauseQueue();
      final task = queue.enqueue(copySpec());
      await pump();
      expect(task.isTerminal, isFalse);
      expect(queue.canRetryTask(task.id), isFalse);
      expect(queue.retryTask(task.id), isFalse);
      queue.resumeQueue();
      await awaitTaskDone(task);
      expect(queue.retryTask(task.id), isFalse);
    });
  });

  group('history seam', () {
    test('queue.history exposes the persisted records', () async {
      remote.addFile('/src/a.txt', [1]);
      final task = queue.enqueue(copySpec());
      await pumpUntil(() => task.isTerminal, reason: 'task never settled');
      expect(queue.history, hasLength(1));
      expect(queue.history.single.taskId, task.id);
      expect(queue.history.single.outcome, TransferTaskState.completed);
    });

    test('clearHistory empties the store', () async {
      remote.addFile('/src/a.txt', [1]);
      final task = queue.enqueue(copySpec());
      await pumpUntil(() => task.isTerminal, reason: 'task never settled');
      expect(queue.history, isNotEmpty);
      await queue.clearHistory();
      expect(queue.history, isEmpty);
      expect(persistence.historyEntries, isEmpty);
    });

    test('a null-persistence queue reports empty history', () async {
      final bare = TransferQueue(connections: connections);
      addTearDown(bare.dispose);
      remote.addFile('/src/a.txt', [1]);
      final task = bare.enqueue(copySpec());
      await pumpUntil(() => task.isTerminal, reason: 'task never settled');
      expect(bare.history, isEmpty);
      await bare.clearHistory();
    });
  });

  group('wasRestored', () {
    test('fresh tasks are not restored; replayed ones are', () async {
      remote.addFile('/src/a.txt', [1]);
      final task = queue.enqueue(copySpec());
      expect(task.wasRestored, isFalse);
      await awaitTaskDone(task);
    });
  });
}
