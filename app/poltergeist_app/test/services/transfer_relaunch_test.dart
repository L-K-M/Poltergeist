// 07 §3.5's kill-mid-queue exit criterion proven at the app seam: the
// real TransferQueue + FileTransferPersistence journal round-trips
// through a simulated relaunch — a crashed session's queued and paused
// tasks come back as restored rows behind the activity panel's banner
// (ActivityPanelController.restoredTasks), the forced queue pause holds
// admission until Resume, and the completed task shows in the History
// tab's source. Resume then finishes the surviving work for real (local
// files land on disk).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:poltergeist_app/services/activity_panel_controller.dart';
import 'package:poltergeist_app/services/app_transfer_queue.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// Local↔local tasks never touch the pool — every ConnectionManager
/// member fails the test if one is reached.
class _NoPool implements ConnectionManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'local transfers must never reach the pool: ${invocation.memberName}',
  );
}

void main() {
  late Directory tempDir;
  late Directory storeDir;
  late Directory srcDir;
  late Directory destDir;

  // "Crashed" session objects stay tracked so tearDown can still clean
  // them up — a kill abandons the store without shutdown.
  final stores = <FileTransferPersistence>[];
  final queues = <TransferQueue>[];
  final controllers = <ActivityPanelController>[];

  Future<TransferQueueAdapter> openSession() async {
    final store = await FileTransferPersistence.open(storeDir);
    stores.add(store);
    final queue = TransferQueue(
      connections: _NoPool(),
      persistence: store,
    );
    queues.add(queue);
    return TransferQueueAdapter(queue);
  }

  ActivityPanelController openPanel(AppTransferQueue queue) {
    final controller = ActivityPanelController(queue: queue);
    controllers.add(controller);
    return controller;
  }

  TransferTaskSpec copySpec(String name) => TransferTaskSpec(
    source: const LocalFsLocation(),
    destination: const LocalFsLocation(),
    rootPaths: ['${srcDir.path}/$name'],
    destinationDir: destDir.path,
    policy: ResolvedConflictPolicy(
      files: ConflictResolution.replace,
      folders: ConflictResolution.merge,
    ),
  );

  Future<void> pumpUntil(
    bool Function() condition, {
    String reason = '',
  }) async {
    for (var i = 0; i < 400; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('pumpUntil timed out${reason.isEmpty ? '' : ': $reason'}');
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('poltergeist-relaunch-');
    tempDir = Directory(tempDir.resolveSymbolicLinksSync());
    storeDir = Directory('${tempDir.path}/store');
    srcDir = Directory('${tempDir.path}/src')..createSync();
    destDir = Directory('${tempDir.path}/dest')..createSync();
  });

  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    controllers.clear();
    for (final queue in queues) {
      await queue.dispose();
    }
    queues.clear();
    for (final store in stores) {
      await store.shutdown();
    }
    stores.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('a kill mid-queue relaunches into a restored queue with history',
      () async {
    // Session 1: a live app session with the real journal.
    final queue1 = await openSession();
    openPanel(queue1);

    File('${srcDir.path}/done.txt').writeAsStringSync('done!');
    File('${srcDir.path}/paused.txt').writeAsStringSync('paused?');
    File('${srcDir.path}/queued.txt').writeAsStringSync('queued?');

    // One task completes before the kill — it belongs in history.
    final done = queue1.enqueue(copySpec('done.txt'));
    await pumpUntil(() => done.isTerminal, reason: 'first task stuck');
    expect(done.state, TransferTaskState.completed);

    // A paused task and a queued task are mid-flight when the process
    // dies: the queue-level pause holds admission so both stay
    // non-terminal, and the paused one's per-task latch is journaled.
    queue1.pauseQueue();
    final paused = queue1.enqueue(copySpec('paused.txt'));
    queue1.pauseTask(paused.id);
    final queued = queue1.enqueue(copySpec('queued.txt'));
    await pumpUntil(
      () => paused.state == TransferTaskState.paused,
      reason: 'pause never journaled',
    );
    // The queue gate holds admission, not scanning: the third task is
    // still discovering work when the process dies. §4.6 replays both
    // non-terminal shapes as queued.
    expect(queued.isTerminal, isFalse);

    // The quit guard's durability point, then the kill: no shutdown, no
    // compaction — the journal on disk is all the next session gets.
    await queue1.flushJournal();

    // Session 2: relaunch — new store + queue over the same directory.
    final queue2 = await openSession();
    await queues.last.restore();
    final panel = openPanel(queue2);

    // §4.6's two latches: the journaled-paused task survives paused, the
    // queued one waits under the forced queue-level pause.
    expect(queue2.isPaused, isTrue);
    final restoredPaused = queue2.tasks.singleWhere((t) => t.id == paused.id);
    final restoredQueued = queue2.tasks.singleWhere((t) => t.id == queued.id);
    expect(restoredPaused.state, TransferTaskState.paused);
    expect(restoredQueued.state, TransferTaskState.queued);
    expect(restoredPaused.wasRestored, isTrue);
    expect(restoredQueued.wasRestored, isTrue);

    // The panel surface: the restored banner's two rows plus the
    // completed task in the History tab's source.
    expect(
      panel.restoredTasks.map((t) => t.id),
      unorderedEquals([paused.id, queued.id]),
    );
    expect(queue2.history.single.taskId, done.id);
    expect(queue2.history.single.outcome, TransferTaskState.completed);
    expect(File('${destDir.path}/paused.txt').existsSync(), isFalse);

    // The banner's Resume un-parks both latches and the work finishes.
    panel.resumeRestoredQueue();
    await pumpUntil(
      () => restoredPaused.isTerminal && restoredQueued.isTerminal,
      reason: 'restored tasks never finished after Resume',
    );
    expect(restoredPaused.state, TransferTaskState.completed);
    expect(restoredQueued.state, TransferTaskState.completed);
    expect(File('${destDir.path}/paused.txt').readAsStringSync(), 'paused?');
    expect(File('${destDir.path}/queued.txt').readAsStringSync(), 'queued?');
    expect(panel.restoredTasks, isEmpty);
    await pumpUntil(
      () => queue2.history.length == 3,
      reason: 'history never recorded the resumed tasks',
    );
  });
}
