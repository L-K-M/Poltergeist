// Deterministic contract tests for M4's throttle + remote→remote pipe
// slice (03 §4.3's token buckets, §4.5's piping contract).
//
// The queue-level tests use the same harness as transfer_queue_test —
// FakeTreeFileSystem endpoints behind gated Completers — plus a
// RecordingLimiter that reports exactly which bucket each direction
// charged and can park an acquire on demand. Nothing depends on
// wall-clock rate math here; the fake_async token-bucket contract lives
// in bandwidth_limiter_test.dart.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

/// A limiter that logs every acquire and can park the Nth+ acquire on a
/// completer — the observation seam for "which bucket did this leg
/// charge" and "a parked acquire unwinds on pause".
class RecordingLimiter extends BandwidthLimiter {
  RecordingLimiter({super.bytesPerSecond, super.maxChunkBytes});

  /// chunkBytes of every acquire call, in order.
  final List<int> requests = [];

  /// The first [freeAcquisitions] calls pass instantly; every later call
  /// parks on [release] (if set).
  int freeAcquisitions = 1 << 60;
  Completer<void>? release;
  int _served = 0;

  @override
  Future<void> acquire(
    int chunkBytes, {
    RemoteTransferCancellation? cancellation,
  }) {
    requests.add(chunkBytes);
    if (_served++ < freeAcquisitions) return Future<void>.value();
    final gate = release;
    if (gate == null) return Future<void>.value();
    return Future.any<void>([
      gate.future,
      if (cancellation != null)
        cancellation.whenCancelled.then<void>(
          (_) => throw const RemoteFileException(
            kind: RemoteFileErrorKind.cancelled,
            operation: 'throttle',
            message: 'throttle wait cancelled',
          ),
        ),
    ]);
  }
}

TransferTaskSpec pipeSpec({
  required FsLocation source,
  required FsLocation destination,
  required List<String> rootPaths,
  required String destinationDir,
  ConflictResolution files = ConflictResolution.skip,
}) => TransferTaskSpec(
  source: source,
  destination: destination,
  rootPaths: rootPaths,
  destinationDir: destinationDir,
  policy: ResolvedConflictPolicy(files: files),
);

void main() {
  late Directory tempDir;
  late Directory localSrc;
  late Directory localDst;
  late FakeTreeFileSystem s1;
  late FakeTreeFileSystem s2;
  late FakeQueueConnectionManager connections;
  late TransferQueue queue;
  late List<TransferQueueEvent> events;

  final createdQueues = <TransferQueue>[];

  TransferQueue newQueue({
    int? leaseCap,
    int? maxInFlightFiles,
    int? pipeBufferBytes,
    int taskRetryLimit = 5,
    BandwidthLimiter? downloadLimiter,
    BandwidthLimiter? uploadLimiter,
    TransferPersistence? persistence,
  }) {
    connections.leaseCap = leaseCap;
    final created = TransferQueue(
      connections: connections,
      poolPolicy: PoolPolicy(taskRetryLimit: taskRetryLimit),
      maxInFlightFiles: maxInFlightFiles ?? maxGlobalInFlightTransfers,
      pipeBufferBytes: pipeBufferBytes ?? 4 * 1024 * 1024,
      downloadLimiter: downloadLimiter,
      uploadLimiter: uploadLimiter,
      persistence: persistence,
    );
    createdQueues.add(created);
    return created;
  }

  void useQueue(TransferQueue next) {
    queue = next;
    queue.events.listen(events.add);
  }

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('poltergeist-tt-');
    tempDir = Directory(temp.resolveSymbolicLinksSync());
    localSrc = Directory('${tempDir.path}/src')..createSync();
    localDst = Directory('${tempDir.path}/dst')..createSync();
    s1 = FakeTreeFileSystem()..addDirectory('/dst');
    s2 = FakeTreeFileSystem()..addDirectory('/dst');
    connections = FakeQueueConnectionManager({'s1': s1, 's2': s2});
    events = [];
    useQueue(newQueue());
  });

  tearDown(() async {
    for (final created in createdQueues) {
      try {
        await created.dispose();
      } catch (_) {
        // A dispose that threw already failed the test; don't leak the
        // remaining queues or the temp-dir cleanup.
      }
    }
    createdQueues.clear();
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Best effort — a spawned process may still hold a handle.
    }
  });

  group('bandwidth throttle wiring', () {
    test('remote→remote charges both directional buckets, one acquire '
        'per chunk', () async {
      s1.addFile('/src/f.bin', List.filled(48 * 1024, 1));
      s1.downloadChunkSize = 16 * 1024;
      final downloads = RecordingLimiter();
      final uploads = RecordingLimiter();
      useQueue(newQueue(downloadLimiter: downloads, uploadLimiter: uploads));

      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/f.bin'], hasLength(48 * 1024));
      expect(downloads.requests, [16 * 1024, 16 * 1024, 16 * 1024]);
      expect(uploads.requests, [16 * 1024, 16 * 1024, 16 * 1024]);
    });

    test('local→remote charges only the upload bucket', () async {
      final file = File('${localSrc.path}/up.bin')
        ..writeAsBytesSync(List.filled(200 * 1024, 7));
      final downloads = RecordingLimiter();
      final uploads = RecordingLimiter();
      useQueue(newQueue(downloadLimiter: downloads, uploadLimiter: uploads));

      final task = queue.enqueue(
        pipeSpec(
          source: const LocalFsLocation(),
          destination: const ServerFsLocation('s1'),
          rootPaths: [file.path],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s1.fileBytes['/dst/up.bin'], hasLength(200 * 1024));
      expect(downloads.requests, isEmpty);
      // Whatever chunking dart:io produced, the bucket was charged
      // exactly the file's bytes — once.
      expect(
        uploads.requests.fold<int>(0, (sum, bytes) => sum + bytes),
        200 * 1024,
      );
      expect(uploads.requests, isNotEmpty);
    });

    test('remote→local charges only the download bucket', () async {
      s1.addFile('/src/down.bin', List.filled(40 * 1024, 9));
      s1.downloadChunkSize = 16 * 1024;
      final downloads = RecordingLimiter();
      final uploads = RecordingLimiter();
      useQueue(newQueue(downloadLimiter: downloads, uploadLimiter: uploads));

      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s1'),
          destination: const LocalFsLocation(),
          rootPaths: const ['/src/down.bin'],
          destinationDir: localDst.path,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(
        File('${localDst.path}/down.bin').lengthSync(),
        40 * 1024,
      );
      expect(downloads.requests, [16 * 1024, 16 * 1024, 8 * 1024]);
      expect(uploads.requests, isEmpty);
    });

    test('local→local rides the no-op limiter — neither bucket charged',
        () async {
      final file = File('${localSrc.path}/same.bin')
        ..writeAsBytesSync(List.filled(8 * 1024, 5));
      final downloads = RecordingLimiter();
      final uploads = RecordingLimiter();
      useQueue(newQueue(downloadLimiter: downloads, uploadLimiter: uploads));

      final task = queue.enqueue(
        pipeSpec(
          source: const LocalFsLocation(),
          destination: const LocalFsLocation(),
          rootPaths: [file.path],
          destinationDir: localDst.path,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(File('${localDst.path}/same.bin').lengthSync(), 8 * 1024);
      expect(downloads.requests, isEmpty);
      expect(uploads.requests, isEmpty);
    });

    test('a parked acquire stalls the pipe; releasing it resumes flow',
        () async {
      s1.addFile('/src/f.bin', List.filled(64 * 1024, 2));
      s1.downloadChunkSize = 16 * 1024;
      final release = Completer<void>();
      final downloads = RecordingLimiter()
        ..freeAcquisitions = 1
        ..release = release;
      useQueue(newQueue(downloadLimiter: downloads));

      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      // First chunk grants, the second acquire parks — the download is
      // live but the pipe cannot advance.
      await pumpUntil(
        () => downloads.requests.length >= 2 && s1.activeDownloads == 1,
        reason: 'throttle never parked',
      );
      await pump(8);
      expect(downloads.requests, hasLength(2));
      expect(s2.fileBytes.containsKey('/dst/f.bin'), isFalse);

      release.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/f.bin'], hasLength(64 * 1024));
      expect(downloads.requests, hasLength(4));
    });

    test('task pause evicts a parked acquire; resume re-acquires', () async {
      s1.addFile('/src/f.bin', List.filled(64 * 1024, 4));
      s1.downloadChunkSize = 16 * 1024;
      final release = Completer<void>();
      final downloads = RecordingLimiter()
        ..freeAcquisitions = 1
        ..release = release;
      useQueue(newQueue(downloadLimiter: downloads));

      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(
        () => downloads.requests.length >= 2,
        reason: 'throttle never parked',
      );
      queue.pauseTask(task.id);
      await pumpUntil(
        () => task.items.single.state == TransferItemState.pending,
        reason: 'paused item never returned to pending',
      );
      // The cancelled attempt released its leases — nothing is held
      // while paused.
      await pumpUntil(
        () =>
            connections.activeLeases('s1') == 0 &&
            connections.activeLeases('s2') == 0,
        reason: 'paused item held its leases',
      );

      queue.resumeTask(task.id);
      await pumpUntil(
        () => downloads.requests.length >= 3,
        reason: 'resumed item never re-acquired',
      );
      release.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/f.bin'], hasLength(64 * 1024));
    });
  });

  group('remote→remote piping', () {
    test('streams with bounded in-flight bytes, never the whole file',
        () async {
      s1.addFile('/src/big.bin', List.filled(256 * 1024, 3));
      s1.downloadChunkSize = 16 * 1024;
      final probe = PipeProbe();
      s1.pipeProbe = probe;
      s2.pipeProbe = probe;
      final gate = Completer<void>();
      s2.uploadGate = (_) => gate;
      useQueue(newQueue(pipeBufferBytes: 32 * 1024));

      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/big.bin'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(
        () => probe.inFlight > 0,
        reason: 'source never produced',
      );
      // Let the producer settle against the buffer bound while the
      // upload waits on its gate.
      await pump(24);
      expect(
        probe.peak,
        lessThanOrEqualTo(32 * 1024 + 2 * s1.downloadChunkSize),
        reason: 'the pipe buffered ${probe.peak} bytes of a 256 KiB file',
      );

      gate.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(probe.inFlight, 0);
      expect(s2.fileBytes['/dst/big.bin'], hasLength(256 * 1024));
      expect(
        probe.peak,
        lessThanOrEqualTo(32 * 1024 + 2 * s1.downloadChunkSize),
      );
    });

    test('both sides report progress; bytes are counted once', () async {
      s1.addFile('/src/f.bin', List.filled(48 * 1024, 6));
      s1.downloadChunkSize = 16 * 1024;
      useQueue(newQueue());

      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      // Download and upload both report cumulative bytes — the item must
      // charge each byte once, not twice.
      expect(task.transferredBytes, 48 * 1024);
      final progress = events
          .whereType<TransferQueueProgressEvent>()
          .map((e) => e.transferred)
          .toList();
      expect(progress, isNotEmpty);
      expect(progress, everyElement(lessThanOrEqualTo(48 * 1024)));
      // Monotonic — the max-of-sides combiner never regresses.
      final sorted = [...progress]..sort();
      expect(progress, sorted);
      expect(progress.last, 48 * 1024);
    });

    test('a silent source still progresses through the upload reports',
        () async {
      s1.addFile('/src/f.bin', List.filled(32 * 1024, 8));
      s1.downloadChunkSize = 16 * 1024;
      s1.downloadReportsProgress = false;
      useQueue(newQueue());

      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.transferredBytes, 32 * 1024);
      expect(
        events.whereType<TransferQueueProgressEvent>(),
        isNotEmpty,
      );
    });

    test('a source failure names the source side and unwinds the upload',
        () async {
      s1.addFile('/src/f.bin', List.filled(64 * 1024, 1));
      s1.downloadChunkSize = 16 * 1024;
      var chunks = 0;
      // Fail mid-stream, after the first chunk landed in the pipe.
      s1.beforeDownloadChunk = (_) {
        if (chunks++ == 1) {
          throw const RemoteFileException(
            kind: RemoteFileErrorKind.other,
            operation: 'download',
            message: 'net died mid-read',
          );
        }
      };
      useQueue(newQueue(taskRetryLimit: 0));

      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      final item = task.items.single;
      expect(item.state, TransferItemState.failed);
      expect(item.error, contains('source'));
      expect(item.error, contains('net died mid-read'));
      // No partial commit, both ends idle, both leases released.
      expect(s2.fileBytes.containsKey('/dst/f.bin'), isFalse);
      await pumpUntil(
        () =>
            connections.activeLeases('s1') == 0 &&
            connections.activeLeases('s2') == 0,
        reason: 'failed pipe held its leases',
      );
      expect(s1.activeDownloads, 0);
      expect(s2.activeUploads, 0);
    });

    test('a destination failure names the destination and aborts the '
        'source read', () async {
      s1.addFile('/src/f.bin', List.filled(64 * 1024, 1));
      s1.downloadChunkSize = 16 * 1024;
      s2.uploadFailure = (_) => const RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: 'upload',
        message: 'disk full',
      );
      useQueue(newQueue(taskRetryLimit: 0));

      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      final item = task.items.single;
      expect(item.state, TransferItemState.failed);
      expect(item.error, contains('destination'));
      expect(item.error, contains('disk full'));
      // The upload died before consuming — the read was aborted, not
      // orphaned: the download never ran to completion.
      await pumpUntil(
        () =>
            connections.activeLeases('s1') == 0 &&
            connections.activeLeases('s2') == 0,
      );
      expect(s1.activeDownloads, 0);
      expect(s2.activeUploads, 0);
    });

    test('leases on both connections release on success', () async {
      s1.addFile('/src/f.bin', List.filled(4 * 1024, 1));
      useQueue(newQueue());
      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      // Scan leased s1 once; dispatch leased both — every lease released.
      expect(connections.activeLeases('s1'), 0);
      expect(connections.activeLeases('s2'), 0);
      expect(connections.totalReleased, connections.leaseCalls);
    });

    test('endpoint leases are acquired in sorted server-id order', () async {
      s2.addFile('/src/f.bin', List.filled(4 * 1024, 1));
      useQueue(newQueue());
      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s2'),
          destination: const ServerFsLocation('s1'),
          rootPaths: const ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      // Scan leases the source only; dispatch must lease s1 before s2
      // even though s2 is the source.
      final order = connections.leaseOrder;
      expect(order, hasLength(greaterThanOrEqualTo(3)));
      // Find the dispatch pair: the trailing two acquisitions.
      final dispatchPair = order.sublist(order.length - 2);
      expect(dispatchPair, ['s1', 's2']);
    });

    test('a piped task journals milestones in write-ahead order', () async {
      final recording = RecordingPersistence();
      s1.addFile('/src/f.bin', List.filled(4 * 1024, 1));
      useQueue(newQueue(persistence: recording));

      final task = queue.enqueue(
        pipeSpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);

      final journal = recording.journal;
      expect(journal.first, isA<TaskEnqueuedRecord>());
      expect(
        journal.indexWhere((r) => r is PlanEntryRecord),
        greaterThan(0),
      );
      final scanIndex = journal.indexWhere((r) => r is ScanCompleteRecord);
      final fileIndex = journal.indexWhere((r) => r is FileCompletedRecord);
      expect(scanIndex, greaterThan(-1));
      expect(fileIndex, greaterThan(scanIndex));
      // The terminal task-state record is last.
      final states = journal.whereType<TaskStateRecord>().toList();
      expect(states.last.state, TransferTaskState.completed);
      expect(journal.last, isA<TaskStateRecord>());
      // One history entry for the completed piped task.
      expect(recording.historyEntries.single.taskId, task.id);
      expect(recording.historyEntries.single.transferredBytes, 4 * 1024);
    });
  });
}
