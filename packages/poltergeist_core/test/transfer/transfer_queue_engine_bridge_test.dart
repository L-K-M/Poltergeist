// The transfer queue over the bridged lease (protocol v13, STATUS item
// 23): the production TransferQueue leases through EngineConnectionManager,
// every VFS call and byte crosses the in-process engine port, and the
// engine host's real PooledConnectionManager serves FakeTreeFileSystem
// channels. The queue's own contract suite runs against the in-process
// fake manager; this suite proves the same flows survive the port —
// bytes, pause/cancel unwinding, conflict parking, disconnect requeue,
// deletes, and moves — and that every lease returns to the pool.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import '../engine/engine_bridge_harness.dart';
import 'transfer_fakes.dart';

TransferTaskSpec _copy({
  required FsLocation source,
  required FsLocation destination,
  required List<String> rootPaths,
  required String destinationDir,
  ConflictResolution files = ConflictResolution.skip,
  TransferOperation operation = TransferOperation.copy,
}) => TransferTaskSpec(
  source: source,
  destination: destination,
  rootPaths: rootPaths,
  destinationDir: destinationDir,
  policy: ResolvedConflictPolicy(
    files: files,
    folders: ConflictResolution.merge,
  ),
  operation: operation,
);

void main() {
  late Directory tempDir;
  late FakeTreeFileSystem s1;
  late FakeTreeFileSystem s2;
  late BridgeHarness harness;
  late TransferQueue queue;

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('poltergeist-bridge-');
    tempDir = Directory(temp.resolveSymbolicLinksSync());
    s1 = FakeTreeFileSystem()..addDirectory('/dst');
    s2 = FakeTreeFileSystem()..addDirectory('/dst');
    harness = BridgeHarness({'s1': s1, 's2': s2});
    queue = TransferQueue(
      connections: harness.connections,
      poolPolicy: const PoolPolicy(taskRetryLimit: 2),
    );
  });

  tearDown(() async {
    await queue.dispose();
    await harness.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<void> expectLeasesReturned() => pumpUntil(
    () => harness.host.bridgeCounts == (leases: 0, streams: 0),
    reason: 'a bridged lease or stream stayed open',
  );

  test('local→remote lands bytes and returns every lease', () async {
    final file = File('${tempDir.path}/hello.txt')
      ..writeAsBytesSync(List.generate(200 * 1024, (i) => i % 256));
    final task = queue.enqueue(
      _copy(
        source: const LocalFsLocation(),
        destination: const ServerFsLocation('s1'),
        rootPaths: [file.path],
        destinationDir: '/dst',
      ),
    );
    await awaitTaskDone(task);
    expect(task.state, TransferTaskState.completed);
    expect(s1.fileBytes['/dst/hello.txt'], file.readAsBytesSync());
    expect(task.transferredBytes, 200 * 1024);
    await expectLeasesReturned();
  });

  test('remote→local materializes a tree under the local directory', () async {
    s1
      ..addFile('/src/tree/a.txt', 'alpha'.codeUnits)
      ..addFile('/src/tree/sub/b.txt', 'beta'.codeUnits);
    final task = queue.enqueue(
      _copy(
        source: const ServerFsLocation('s1'),
        destination: const LocalFsLocation(),
        rootPaths: ['/src/tree'],
        destinationDir: tempDir.path,
      ),
    );
    await awaitTaskDone(task);
    expect(task.state, TransferTaskState.completed);
    expect(File('${tempDir.path}/tree/a.txt').readAsStringSync(), 'alpha');
    expect(File('${tempDir.path}/tree/sub/b.txt').readAsStringSync(), 'beta');
    await expectLeasesReturned();
  });

  test('remote→remote pipes between two engine-held pools', () async {
    s1.addFile('/src/big.bin', List.generate(700 * 1024, (i) => i % 7));
    final task = queue.enqueue(
      _copy(
        source: const ServerFsLocation('s1'),
        destination: const ServerFsLocation('s2'),
        rootPaths: ['/src/big.bin'],
        destinationDir: '/dst',
      ),
    );
    await awaitTaskDone(task);
    expect(task.state, TransferTaskState.completed);
    expect(s2.fileBytes['/dst/big.bin'], s1.fileBytes['/src/big.bin']);
    await expectLeasesReturned();
  });

  test('task pause unwinds the bridged attempt; resume restarts it', () async {
    s1.addFile('/src/big.bin', List.filled(64 * 1024, 7));
    s1.downloadChunkSize = 4096;
    final gate = Completer<void>();
    s1.downloadGate = (_) => gate;
    final task = queue.enqueue(
      _copy(
        source: const ServerFsLocation('s1'),
        destination: const ServerFsLocation('s2'),
        rootPaths: ['/src/big.bin'],
        destinationDir: '/dst',
      ),
    );
    await pumpUntil(() => s1.activeDownloads == 1);
    queue.pauseTask(task.id);
    await pumpUntil(() => task.state == TransferTaskState.paused);
    s1.downloadGate = null;
    gate.complete();
    final item = task.items.single;
    await pumpUntil(() => item.state == TransferItemState.pending);
    await expectLeasesReturned();
    queue.resumeTask(task.id);
    await awaitTaskDone(task);
    expect(task.state, TransferTaskState.completed);
    expect(s1.downloadCalls, greaterThan(1));
    expect(s2.fileBytes['/dst/big.bin'], List.filled(64 * 1024, 7));
  });

  test('task cancel drains in-flight work and strands no lease', () async {
    for (var i = 0; i < 4; i++) {
      s1.addFile('/src/f$i.bin', List.filled(8, i));
    }
    final gate = Completer<void>();
    s1.downloadGate = (_) => gate;
    final task = queue.enqueue(
      _copy(
        source: const ServerFsLocation('s1'),
        destination: const ServerFsLocation('s2'),
        rootPaths: ['/src'],
        destinationDir: '/dst',
      ),
    );
    await pumpUntil(() => s1.activeDownloads > 0);
    queue.cancelTask(task.id);
    await pumpUntil(() => task.state == TransferTaskState.cancelled);
    gate.complete();
    await expectLeasesReturned();
    expect(s2.fileBytes, isEmpty);
  });

  test('an ask conflict parks across the bridge and resumes', () async {
    s1.addFile('/src/f.txt', 'new'.codeUnits);
    s2.addFile('/dst/f.txt', 'old'.codeUnits);
    final task = queue.enqueue(
      _copy(
        source: const ServerFsLocation('s1'),
        destination: const ServerFsLocation('s2'),
        rootPaths: ['/src/f.txt'],
        destinationDir: '/dst',
        files: ConflictResolution.ask,
      ),
    );
    await pumpUntil(() => queue.pendingConflicts.isNotEmpty);
    final item = task.items.single;
    expect(
      queue.resolveConflict(task.id, item.id, ConflictResolution.replace),
      isTrue,
    );
    await awaitTaskDone(task);
    expect(task.state, TransferTaskState.completed);
    expect(s2.fileBytes['/dst/f.txt'], 'new'.codeUnits);
    await expectLeasesReturned();
  });

  test('an engine-side disconnect requeues and the retry lands', () async {
    s1.addFile('/src/f.bin', List.filled(8, 9));
    var failOnce = true;
    s1.downloadFailure = (_) {
      if (!failOnce) return null;
      failOnce = false;
      return const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'download',
        message: 'transport dropped',
      );
    };
    final task = queue.enqueue(
      _copy(
        source: const ServerFsLocation('s1'),
        destination: const ServerFsLocation('s2'),
        rootPaths: ['/src/f.bin'],
        destinationDir: '/dst',
      ),
    );
    await pumpUntil(() => task.isTerminal, maxPumps: 1200);
    expect(task.state, TransferTaskState.completed);
    expect(s1.downloadCalls, 2);
    expect(s2.fileBytes['/dst/f.bin'], List.filled(8, 9));
    await expectLeasesReturned();
  });

  test(
    'a confirmed permanent remote delete walks the tree over the bridge',
    () async {
      s1
        ..addFile('/doomed/a.txt', [1])
        ..addFile('/doomed/sub/b.txt', [2]);
      final confirmation = await queue.prepareDelete(
        source: const ServerFsLocation('s1'),
        rootPaths: ['/doomed'],
      );
      expect(confirmation.effectiveDisposition, DeleteDisposition.permanent);
      expect(confirmation.totalItems, 4);
      final task = await queue.enqueueDelete(
        const DeleteRequest(
          source: ServerFsLocation('s1'),
          rootPaths: ['/doomed'],
          disposition: DeleteDisposition.permanent,
          confirmed: true,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s1.entryAt('/doomed'), isNull);
      await expectLeasesReturned();
    },
  );

  test('a same-server move renames engine-side', () async {
    s1.addFile('/src/m.txt', 'move me'.codeUnits);
    final task = queue.enqueue(
      _copy(
        source: const ServerFsLocation('s1'),
        destination: const ServerFsLocation('s1'),
        rootPaths: ['/src/m.txt'],
        destinationDir: '/dst',
        operation: TransferOperation.move,
      ),
    );
    await awaitTaskDone(task);
    expect(task.state, TransferTaskState.completed);
    expect(s1.entryAt('/src/m.txt'), isNull);
    expect(s1.fileBytes['/dst/m.txt'], 'move me'.codeUnits);
    await expectLeasesReturned();
  });
}
