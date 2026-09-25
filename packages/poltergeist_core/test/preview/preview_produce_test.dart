// Contract tests for the 03 §4.7 produce path on TransferQueue:
// head-inserted, queue-visible, unjournaled single-file hops that bypass
// the queue pause / in-flight cap / throttle but ride the dedicated
// two-slot produce ceiling, plus the §5.2 byte gate's pause/confirm/deny
// and the unknown-size cap.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import '../transfer/transfer_fakes.dart';

void main() {
  late Directory tempDir;
  late Directory outDir;
  late FakeTreeFileSystem s1;
  late FakeQueueConnectionManager connections;
  late RecordingPersistence persistence;
  late TransferQueue queue;
  late List<TransferQueueEvent> events;
  late StreamSubscription<TransferQueueEvent> sub;

  TransferTask produce(
    String remotePath,
    String localName, {
    int? expectedSize,
    int? maximumBytes,
    PreviewByteGate? gate,
    ProduceWriteMode writeMode = ProduceWriteMode.replace,
    ProduceSlotPool slotPool = ProduceSlotPool.preview,
  }) => queue.enqueueProduce(
    PreviewProduceSpec(
      serverId: 's1',
      remotePath: remotePath,
      destinationPath: '${outDir.path}/$localName',
      expectedSize: expectedSize,
      maximumBytes: maximumBytes,
      gate: gate,
      writeMode: writeMode,
      slotPool: slotPool,
    ),
  );

  /// The hidden `.poltergeist-*.tmp` siblings an interrupted write
  /// could leave in [outDir].
  List<String> strayTemps() => [
    for (final entity in outDir.listSync())
      if (entity.uri.pathSegments.last.startsWith('.poltergeist-')) entity.path,
  ];

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('poltergeist-pp-');
    tempDir = Directory(temp.resolveSymbolicLinksSync());
    outDir = Directory('${tempDir.path}/out')..createSync();
    s1 = FakeTreeFileSystem();
    connections = FakeQueueConnectionManager({'s1': s1});
    persistence = RecordingPersistence();
    queue = TransferQueue(
      connections: connections,
      persistence: persistence,
    );
    events = [];
    sub = queue.events.listen(events.add);
  });

  tearDown(() async {
    await sub.cancel();
    await queue.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('produces a remote file into the local path with a digest', () async {
    s1.addFile('/r/hello.txt', [104, 105]); // "hi"
    final ticket = QueuePreviewProducer(queue).start(
      PreviewProduceSpec(
        serverId: 's1',
        remotePath: '/r/hello.txt',
        destinationPath: '${outDir.path}/hello.txt',
        expectedSize: 2,
      ),
    );
    final entry = await ticket.result;
    expect(entry.contentSha256, isNotNull);
    expect(
      await File('${outDir.path}/hello.txt').readAsBytes(),
      [104, 105],
    );
    expect(s1.calls.where((c) => c == 'download:/r/hello.txt'), hasLength(1));
  });

  test('the produce row sits at the head of the queue listing', () async {
    // Park an ordinary task behind a lease gate, then a produce must
    // still list ahead of it — the §4.7 head-insertion exception.
    connections.leaseGate = Completer<void>();
    final ordinary = queue.enqueue(
      TransferTaskSpec(
        source: ServerFsLocation('s1'),
        destination: LocalFsLocation(),
        rootPaths: ['/r/a.txt'],
        destinationDir: outDir.path,
        policy: ResolvedConflictPolicy(
          files: ConflictResolution.replace,
          folders: ConflictResolution.replace,
        ),
      ),
    );
    s1.addFile('/r/a.txt', [1]);
    final p = produce('/r/a.txt', 'p-a.txt', expectedSize: 1);
    expect(queue.tasks.first.id, p.id);
    expect(queue.tasks.last.id, ordinary.id);
    connections.leaseGate!.complete();
    await pumpUntil(() => p.isTerminal && ordinary.isTerminal);
    expect(p.state, TransferTaskState.completed);
  });

  test('produce runs while the queue is paused', () async {
    queue.pauseQueue();
    s1.addFile('/r/p.txt', [1, 2, 3]);
    final task = produce('/r/p.txt', 'p.txt', expectedSize: 3);
    await pumpUntil(() => task.isTerminal);
    expect(task.state, TransferTaskState.completed);
    expect(
      await File('${outDir.path}/p.txt').readAsBytes(),
      [1, 2, 3],
    );
  });

  test('produce is never journaled and never enters history', () async {
    s1.addFile('/r/j.txt', [1]);
    final task = produce('/r/j.txt', 'j.txt', expectedSize: 1);
    await pumpUntil(() => task.isTerminal);
    expect(task.state, TransferTaskState.completed);
    expect(persistence.journal, isEmpty);
    expect(persistence.historyEntries, isEmpty);
    // removeTask must not journal either.
    queue.removeTask(task.id);
    expect(persistence.journal, isEmpty);
  });

  test('cancelTask unwinds a produce row to cancelled', () async {
    s1.addFile('/r/c.txt', List<int>.filled(1 << 20, 7));
    s1.downloadGate = (_) => Completer<void>(); // never releases
    final task = produce('/r/c.txt', 'c.txt', expectedSize: 1 << 20);
    await pumpUntil(() => s1.activeDownloads == 1);
    queue.cancelTask(task.id);
    await pumpUntil(() => task.isTerminal);
    expect(task.state, TransferTaskState.cancelled);
    // The cancel path writes nothing to the journal.
    expect(persistence.journal, isEmpty);
  });

  test('the produce-slot cap admits at most two concurrent hops', () async {
    s1.addFile('/r/1.bin', List<int>.filled(4, 1));
    s1.addFile('/r/2.bin', List<int>.filled(4, 2));
    s1.addFile('/r/3.bin', List<int>.filled(4, 3));
    final gates = <String, Completer<void>>{};
    s1.downloadGate = (path) =>
        gates.putIfAbsent(path, Completer<void>.new);
    final t1 = produce('/r/1.bin', '1.bin');
    final t2 = produce('/r/2.bin', '2.bin');
    final t3 = produce('/r/3.bin', '3.bin');
    await pumpUntil(() => s1.maxActiveDownloads == previewProduceSlotLimit);
    expect(s1.activeDownloads, previewProduceSlotLimit);
    expect(s1.downloadCalls, previewProduceSlotLimit);
    // Release the two in flight; the third then gets its slot.
    gates['/r/1.bin']!.complete();
    gates['/r/2.bin']!.complete();
    await pumpUntil(() => t1.isTerminal && t2.isTerminal);
    gates['/r/3.bin']!.complete();
    await pumpUntil(() => t3.isTerminal);
    expect(t3.state, TransferTaskState.completed);
    expect(s1.maxActiveDownloads, previewProduceSlotLimit);
  });

  test('a byte gate pauses at the threshold and confirm resumes', () async {
    // 64 bytes in 8-byte chunks, threshold 16 → the third chunk parks.
    s1.downloadChunkSize = 8;
    s1.addFile('/r/g.bin', List<int>.filled(64, 5));
    final reached = Completer<int>();
    final gate = PreviewByteGate(
      thresholdBytes: 16,
      onThresholdReached: reached.complete,
    );
    final task = produce('/r/g.bin', 'g.bin', gate: gate);
    await reached.future;
    await pump();
    // Parked: nothing beyond the threshold lands until confirm.
    expect(gate.transferred, greaterThan(16));
    expect(task.isTerminal, isFalse);
    gate.confirm();
    await pumpUntil(() => task.isTerminal);
    expect(task.state, TransferTaskState.completed);
    expect(
      (await File('${outDir.path}/g.bin').readAsBytes()).length,
      64,
    );
  });

  test('a denied byte gate cancels the hop', () async {
    s1.downloadChunkSize = 8;
    s1.addFile('/r/d.bin', List<int>.filled(64, 5));
    final gate = PreviewByteGate(thresholdBytes: 8);
    final task = produce('/r/d.bin', 'd.bin', gate: gate);
    await pumpUntil(() => gate.isAwaitingConfirmation);
    gate.deny();
    await pumpUntil(() => task.isTerminal);
    expect(task.state, TransferTaskState.cancelled);
  });

  test('an unknown-size stream aborts past maximumBytes', () async {
    s1.addFile('/r/big.bin', List<int>.filled(100, 9));
    final task = produce('/r/big.bin', 'big.bin', maximumBytes: 10);
    await pumpUntil(() => task.isTerminal);
    expect(task.state, TransferTaskState.failed);
  });

  test('the over-cap ticket error is the typed limit exception', () async {
    // The stream cap's throw reaches the queue as a wrapped
    // 'transfer source: …-byte editor limit.' failure — the produce
    // seam re-pins it to CheckoutLimitException (the suffix-pin trick
    // CheckoutManager uses) so the session can render the over-cap
    // refusal instead of a retryable failure.
    s1.addFile('/r/big.bin', List<int>.filled(100, 9));
    final producer = QueuePreviewProducer(queue);
    addTearDown(producer.dispose);
    final ticket = producer.start(
      PreviewProduceSpec(
        serverId: 's1',
        remotePath: '/r/big.bin',
        destinationPath: '${outDir.path}/big.bin',
        maximumBytes: 10,
      ),
    );
    await expectLater(
      ticket.result,
      throwsA(
        isA<CheckoutLimitException>().having(
          (e) => e.message,
          'message',
          contains('10-byte preview limit'),
        ),
      ),
    );
  });

  test('produceLocalCopy completes with the committed entry', () async {
    s1.addFile('/r/m.txt', [65]);
    final entry = await queue.produceLocalCopy(
      ServerFsLocation('s1'),
      '/r/m.txt',
      destinationPath: '${outDir.path}/m.txt',
    );
    expect(entry.size, 1);
    expect(entry.contentSha256, isNotNull);
  });

  test('produceLocalCopy honors the caller cancellation token', () async {
    s1.addFile('/r/x.txt', List<int>.filled(1 << 20, 1));
    s1.downloadGate = (_) => Completer<void>();
    final token = RemoteTransferCancellation();
    final future = queue.produceLocalCopy(
      ServerFsLocation('s1'),
      '/r/x.txt',
      destinationPath: '${outDir.path}/x.txt',
      cancellation: token,
    );
    await pumpUntil(() => s1.activeDownloads == 1);
    token.cancel();
    await expectLater(
      future,
      throwsA(
        isA<RemoteFileException>().having(
          (e) => e.kind,
          'kind',
          RemoteFileErrorKind.cancelled,
        ),
      ),
    );
  });

  test('a per-task pause returns the hop to pending, resume retries', () async {
    s1.addFile('/r/pz.txt', List<int>.filled(32, 4));
    s1.downloadGate = (_) => Completer<void>();
    final task = produce('/r/pz.txt', 'pz.txt', expectedSize: 32);
    await pumpUntil(() => s1.activeDownloads == 1);
    queue.pauseTask(task.id);
    await pumpUntil(() => task.state == TransferTaskState.paused);
    // Release the gate — the attempt is already dead; resume reruns.
    s1.downloadGate = null;
    queue.resumeTask(task.id);
    await pumpUntil(() => task.isTerminal);
    expect(task.state, TransferTaskState.completed);
    expect(
      (await File('${outDir.path}/pz.txt').readAsBytes()).length,
      32,
    );
  });

  group('drag-out produce (the D14 amendment)', () {
    test(
      'an exclusive produce refuses an existing file and keeps it',
      () async {
        File('${outDir.path}/keep.txt').writeAsBytesSync([9, 9]);
        s1.addFile('/r/keep.txt', [1, 2, 3]);
        final task = produce(
          '/r/keep.txt',
          'keep.txt',
          expectedSize: 3,
          writeMode: ProduceWriteMode.exclusive,
        );
        await pumpUntil(() => task.isTerminal);
        expect(task.state, TransferTaskState.failed);
        expect(task.failureKind, RemoteFileErrorKind.conflict);
        expect(File('${outDir.path}/keep.txt').readAsBytesSync(), [9, 9]);
        expect(strayTemps(), isEmpty);
      },
    );

    test('an exclusive produce lands a new file', () async {
      s1.addFile('/r/new.txt', [4, 5]);
      final task = produce(
        '/r/new.txt',
        'new.txt',
        expectedSize: 2,
        writeMode: ProduceWriteMode.exclusive,
      );
      await pumpUntil(() => task.isTerminal);
      expect(task.state, TransferTaskState.completed);
      expect(File('${outDir.path}/new.txt').readAsBytesSync(), [4, 5]);
    });

    test('the preview default still replaces its own target', () async {
      File('${outDir.path}/cache.bin').writeAsBytesSync([0]);
      s1.addFile('/r/cache.bin', [7, 7]);
      final task = produce('/r/cache.bin', 'cache.bin', expectedSize: 2);
      await pumpUntil(() => task.isTerminal);
      expect(task.state, TransferTaskState.completed);
      expect(File('${outDir.path}/cache.bin').readAsBytesSync(), [7, 7]);
    });

    test(
      'drag-out hops ride their own slots, so Quick Look keeps its two',
      () async {
        for (var i = 1; i <= 5; i++) {
          s1.addFile('/r/$i.bin', List<int>.filled(4, i));
        }
        final gates = <String, Completer<void>>{};
        s1.downloadGate = (path) =>
            gates.putIfAbsent(path, Completer<void>.new);
        final dragOut = [
          for (final i in [1, 2, 3])
            produce(
              '/r/$i.bin',
              '$i.bin',
              writeMode: ProduceWriteMode.exclusive,
              slotPool: ProduceSlotPool.dragOut,
            ),
        ];
        await pumpUntil(() => s1.activeDownloads == dragOutProduceSlotLimit);
        // The third drag-out hop waits on its own budget; a preview hop
        // still starts at once.
        final previews = [
          produce('/r/4.bin', '4.bin'),
          produce('/r/5.bin', '5.bin'),
        ];
        await pumpUntil(
          () =>
              s1.activeDownloads ==
              dragOutProduceSlotLimit + previewProduceSlotLimit,
        );
        await pump();
        expect(gates.containsKey('/r/3.bin'), isFalse);
        gates['/r/1.bin']!.complete();
        await pumpUntil(() => gates.containsKey('/r/3.bin'));
        for (final gate in gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
        await pumpUntil(
          () => [...dragOut, ...previews].every((task) => task.isTerminal),
        );
        for (final task in [...dragOut, ...previews]) {
          expect(task.state, TransferTaskState.completed);
        }
        expect(
          s1.maxActiveDownloads,
          dragOutProduceSlotLimit + previewProduceSlotLimit,
        );
      },
    );

    test(
      'a cancelled exclusive produce leaves neither file nor temp',
      () async {
        s1.downloadChunkSize = 8;
        s1.addFile('/r/half.bin', List<int>.filled(64, 3));
        // Three chunks flow, then the stream parks mid-file with bytes
        // already written to the hidden temp sibling.
        var chunks = 0;
        final parked = Completer<void>();
        s1.downloadGate = (_) => ++chunks > 3 ? parked : null;
        final task = produce(
          '/r/half.bin',
          'half.bin',
          expectedSize: 64,
          writeMode: ProduceWriteMode.exclusive,
          slotPool: ProduceSlotPool.dragOut,
        );
        await pumpUntil(() => strayTemps().isNotEmpty && chunks > 3);
        expect(File('${outDir.path}/half.bin').existsSync(), isFalse);
        queue.cancelTask(task.id);
        await pumpUntil(() => task.isTerminal);
        expect(task.state, TransferTaskState.cancelled);
        expect(File('${outDir.path}/half.bin').existsSync(), isFalse);
        await pumpUntil(() => strayTemps().isEmpty, reason: 'temp removed');
      },
    );
  });
}
