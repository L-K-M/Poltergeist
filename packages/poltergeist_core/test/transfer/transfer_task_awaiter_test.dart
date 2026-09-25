// Contract tests for awaitTransferTaskTerminal: the awaitable shape a
// caller outside the queue (the drag-out folder promise, D14's
// amendment) uses to wait for an ordinary, journaled download task.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

void main() {
  late Directory tempDir;
  late Directory outDir;
  late FakeTreeFileSystem s1;
  late TransferQueue queue;

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('poltergeist-await-');
    tempDir = Directory(temp.resolveSymbolicLinksSync());
    outDir = Directory('${tempDir.path}/out')..createSync();
    s1 = FakeTreeFileSystem();
    queue = TransferQueue(connections: FakeQueueConnectionManager({'s1': s1}));
  });

  tearDown(() async {
    await queue.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  TransferTask downloadFolder(String remoteFolder) => queue.enqueue(
    TransferTaskSpec(
      source: ServerFsLocation('s1'),
      destination: const LocalFsLocation(),
      rootPaths: [remoteFolder],
      destinationDir: outDir.path,
      policy: ConflictPolicy().policyFor(
        ServerFsLocation('s1'),
        const LocalFsLocation(),
      ),
    ),
  );

  Future<TransferTask?> settle(TransferTask task) => awaitTransferTaskTerminal(
    events: queue.events,
    tasks: () => queue.tasks,
    taskId: task.id,
  );

  test(
    'resolves a recursive folder download with its completed task',
    () async {
      s1.addFile('/r/site/index.html', [1, 2]);
      s1.addFile('/r/site/css/main.css', [3]);
      final task = downloadFolder('/r/site');
      final settled = await settle(task);
      expect(settled?.id, task.id);
      expect(settled?.state, TransferTaskState.completed);
      expect(File('${outDir.path}/site/index.html').readAsBytesSync(), [1, 2]);
      expect(File('${outDir.path}/site/css/main.css').readAsBytesSync(), [3]);
    },
  );

  test('resolves a task that settled before the wait began', () async {
    s1.addFile('/r/done/a.txt', [1]);
    final task = downloadFolder('/r/done');
    await awaitTaskDone(task);
    final settled = await settle(task);
    expect(settled?.state, TransferTaskState.completed);
  });

  test('resolves a cancelled task as cancelled, not as a hang', () async {
    s1.addFile('/r/slow/a.bin', List<int>.filled(64, 1));
    s1.downloadGate = (_) => Completer<void>(); // never releases
    final task = downloadFolder('/r/slow');
    final settled = settle(task);
    await pumpUntil(() => s1.activeDownloads == 1);
    queue.cancelTask(task.id);
    expect((await settled)?.state, TransferTaskState.cancelled);
  });

  test('resolves null when the task is not (or no longer) listed', () async {
    s1.addFile('/r/gone/a.txt', [1]);
    final task = downloadFolder('/r/gone');
    await awaitTaskDone(task);
    expect(queue.removeTask(task.id), isTrue);
    expect(await settle(task), isNull);
    expect(
      await awaitTransferTaskTerminal(
        events: queue.events,
        tasks: () => queue.tasks,
        taskId: 'never-enqueued',
      ),
      isNull,
    );
  });
}
