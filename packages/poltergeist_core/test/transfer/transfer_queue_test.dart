// Deterministic contract tests for the engine-side transfer queue
// (packages/poltergeist_core/lib/src/transfer/), M4's first slice.
//
// No sockets: remote endpoints are FakeTreeFileSystems behind a
// FakeQueueConnectionManager whose leases mirror the real pool's
// leaseTransferChannel contract (block at capacity, deterministic
// release); the local endpoint is the production LocalFileSystem over a
// real temp dir, which exercises the §2.3 safety walk for free. Every
// gate is a Completer, so nothing depends on wall-clock timing.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

TransferTaskSpec copySpec({
  required FsLocation source,
  required FsLocation destination,
  required List<String> rootPaths,
  required String destinationDir,
  ConflictResolution files = ConflictResolution.skip,
  ConflictResolution folders = ConflictResolution.merge,
  TransferOperation operation = TransferOperation.copy,
}) => TransferTaskSpec(
  source: source,
  destination: destination,
  rootPaths: rootPaths,
  destinationDir: destinationDir,
  policy: ResolvedConflictPolicy(files: files, folders: folders),
  operation: operation,
);

void main() {
  late Directory tempDir;
  late Directory localSrc;
  late FakeTreeFileSystem s1;
  late FakeTreeFileSystem s2;
  late FakeQueueConnectionManager connections;
  late TransferQueue queue;
  late List<TransferQueueEvent> events;

  // Every queue the harness creates — several tests replace the setUp
  // queue mid-test; tearDown disposes them all so none leaks its event
  // sink or pause completers.
  final createdQueues = <TransferQueue>[];

  TransferQueue newQueue({
    int? leaseCap,
    int? maxInFlightFiles,
    int? pipeBufferBytes,
    int taskRetryLimit = 5,
    bool Function(FsLocation)? isCaseInsensitiveDestination,
  }) {
    connections.leaseCap = leaseCap;
    final created = TransferQueue(
      connections: connections,
      poolPolicy: PoolPolicy(taskRetryLimit: taskRetryLimit),
      maxInFlightFiles: maxInFlightFiles ?? maxGlobalInFlightTransfers,
      pipeBufferBytes: pipeBufferBytes ?? 4 * 1024 * 1024,
      isCaseInsensitiveDestination: isCaseInsensitiveDestination,
    );
    createdQueues.add(created);
    return created;
  }

  TransferTask enqueue(TransferTaskSpec spec) => queue.enqueue(spec);

  setUp(() async {
    // Resolve the fixture root: on macOS, systemTemp lives under /var,
    // a symlink to /private/var — the destination-side safety walk must
    // see the real path or it fails on the rule, not a bug.
    final temp = await Directory.systemTemp.createTemp('poltergeist-tq-');
    tempDir = Directory(temp.resolveSymbolicLinksSync());
    localSrc = Directory('${tempDir.path}/src')..createSync();
    s1 = FakeTreeFileSystem()..addDirectory('/dst');
    s2 = FakeTreeFileSystem()..addDirectory('/dst');
    connections = FakeQueueConnectionManager({'s1': s1, 's2': s2});
    queue = newQueue();
    events = [];
    queue.events.listen(events.add);
  });

  tearDown(() async {
    for (final created in createdQueues) {
      try {
        await created.dispose();
      } catch (_) {
        // A dispose that throws already fails this test; don't let it
        // leak the remaining queues or skip the temp-dir cleanup.
      }
    }
    createdQueues.clear();
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Best effort: a spawned process may still hold a handle.
    }
  });

  File writeLocal(String relative, List<int> bytes) {
    final file = File('${localSrc.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file;
  }

  group('task model', () {
    test('file-field merge normalizes to ask', () {
      final policy = ResolvedConflictPolicy(files: ConflictResolution.merge);
      expect(policy.files, ConflictResolution.ask);
    });

    test('enqueue dedupes roots and drops nested roots', () async {
      final file = writeLocal('a.txt', [1]);
      final task = enqueue(
        copySpec(
          source: const LocalFsLocation(),
          destination: const ServerFsLocation('s1'),
          rootPaths: [
            localSrc.path,
            file.path,
            '${localSrc.path}/',
            localSrc.path,
          ],
          destinationDir: '/dst',
        ),
      );
      // The directory root swallows the nested file root; duplicates and
      // the trailing-slash spelling collapse to one.
      expect(task.rootPaths, [localSrc.path]);
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
    });

    test('enqueue rejects an empty root list', () {
      expect(
        () => enqueue(
          copySpec(
            source: const LocalFsLocation(),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [],
            destinationDir: '/dst',
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('scan-then-execute', () {
    test('single file local→remote lands bytes and releases leases',
        () async {
      final file = writeLocal('hello.txt', 'payload'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const LocalFsLocation(),
          destination: const ServerFsLocation('s1'),
          rootPaths: [file.path],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(task.scanComplete, isTrue);
      expect(task.completedFiles, 1);
      expect(task.totalBytes, 'payload'.codeUnits.length);
      expect(task.transferredBytes, 'payload'.codeUnits.length);
      expect(s1.fileBytes['/dst/hello.txt'], 'payload'.codeUnits);
      // Scan lease + dispatch lease, both released.
      expect(connections.leaseCalls, 2);
      expect(connections.activeLeases('s1'), 0);
      expect(connections.totalReleased, 2);
      final states = events
          .whereType<TransferQueueTaskEvent>()
          .map((e) => e.state)
          .toList();
      expect(states.first, TransferTaskState.queued);
      expect(states, contains(TransferTaskState.scanning));
      expect(states.last, TransferTaskState.completed);
    });

    test('directory tree remote→remote: parents-first mkdir, symlink skip',
        () async {
      s1.addDirectory('/src/dir/sub');
      s1.addFile('/src/dir/a.txt', 'aaa'.codeUnits);
      s1.addFile('/src/dir/sub/b.txt', 'bb'.codeUnits);
      s1.addSymlink('/src/dir/link');

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dir'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/dir/a.txt'], 'aaa'.codeUnits);
      expect(s2.fileBytes['/dst/dir/sub/b.txt'], 'bb'.codeUnits);
      expect(task.plan!.skippedSymlinks, 1);
      // Parents first: dir before sub, and both before any upload into
      // them (scan order is the append order).
      final mkdirs = s2.calls.where((c) => c.startsWith('mkdir:')).toList();
      expect(mkdirs, containsAllInOrder(['mkdir:/dst/dir', 'mkdir:/dst/dir/sub']));
      final uploads = s2.calls.where((c) => c.startsWith('upload:')).toList();
      expect(
        uploads,
        containsAllInOrder(['upload:/dst/dir/a.txt', 'upload:/dst/dir/sub/b.txt']),
      );
    });

    test('first bytes flow before the scan completes', () async {
      s1.addDirectory('/src');
      s1.addFile('/src/first.txt', 'early'.codeUnits);
      s1.addDirectory('/src/slow');
      s1.addFile('/src/slow/late.txt', 'late'.codeUnits);
      // Hold the slow subtree's listing: the scan is unfinished while the
      // root listing's file already dispatches.
      final gate = Completer<void>();
      s1.listGate = (path) => path == '/src/slow' ? gate : null;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );

      // The root listing itself carries the pending dir; first.txt can
      // complete while the scan is still parked on /src/slow.
      await pumpUntil(
        () => s2.fileBytes.containsKey('/dst/src/first.txt'),
        reason: 'first file never landed while scan held',
      );
      expect(task.scanComplete, isFalse);
      expect(task.state, isNot(TransferTaskState.completed));

      gate.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/src/slow/late.txt'], 'late'.codeUnits);
    });

    test('growing totals: totalBytes is a floor until the scan closes',
        () async {
      s1.addDirectory('/src');
      s1.addFile('/src/a.bin', List.filled(10, 1));
      s1.addDirectory('/src/more');
      s1.addFile('/src/more/b.bin', List.filled(20, 2));
      final gate = Completer<void>();
      s1.listGate = (path) => path == '/src/more' ? gate : null;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => (task.totalBytes ?? 0) > 0);
      // Only a.bin is discovered so far: the floor is 10 of a final 30.
      expect(task.totalBytes, 10);
      expect(task.scanComplete, isFalse);

      gate.complete();
      await awaitTaskDone(task);
      expect(task.totalBytes, 30);
      expect(task.transferredBytes, 30);
    });

    test('remote→local tree materializes under the local destination dir',
        () async {
      final localDest = Directory('${tempDir.path}/local-dest')
        ..createSync();
      s1.addDirectory('/src/dir');
      s1.addFile('/src/dir/a.txt', 'aaa'.codeUnits);
      s1.addFile('/src/dir/deep/b.bin', [1, 2, 3]);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const LocalFsLocation(),
          rootPaths: ['/src/dir'],
          destinationDir: localDest.path,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 2);
      expect(
        File('${localDest.path}/dir/a.txt').readAsBytesSync(),
        'aaa'.codeUnits,
      );
      expect(
        File('${localDest.path}/dir/deep/b.bin').readAsBytesSync(),
        [1, 2, 3],
      );
      // Local endpoints hold no channel lease — only the source did.
      expect(connections.activeLeases('s1'), 0);
      expect(connections.maxActiveLeases('s1'), greaterThan(0));
      expect(connections.filesystems.containsKey('local'), isFalse);
    });

    test('scan-time existing hint is populated but never trusted',
        () async {
      s1.addFile('/src/dup.txt', 'new-bytes'.codeUnits);
      s2.addFile('/dst/dup.txt', 'old'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dup.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.plan!.files.single.existing, isNotNull);
      expect(s2.fileBytes['/dst/dup.txt'], 'new-bytes'.codeUnits);
    });
  });

  group('concurrency', () {
    test('global cap: never more than maxInFlightFiles active', () async {
      queue = newQueue(maxInFlightFiles: 3);
      events = [];
      queue.events.listen(events.add);
      for (var i = 0; i < 8; i++) {
        s1.addFile('/src/f$i.bin', List.filled(4, i));
      }
      // Every download stalls at its first chunk until released.
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(
        () => s1.activeDownloads == 3,
        reason: 'expected 3 in-flight downloads',
      );
      // One pump past the cap: nothing else may start.
      await pump();
      expect(s1.activeDownloads, 3);
      expect(
        task.items.where((i) => i.state == TransferItemState.active).length,
        3,
      );

      gate.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 8);
      expect(s1.maxActiveDownloads, 3);
    });

    test('per-server lease capacity blocks admission and frees on release',
        () async {
      queue = newQueue(leaseCap: 2);
      for (var i = 0; i < 4; i++) {
        s1.addFile('/src/f$i.bin', List.filled(4, i));
      }
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      // While the scan holds one s1 lease only one dispatch fits; once it
      // finishes, two downloads may hold leases — never three.
      await pumpUntil(
        () => task.scanComplete && s1.activeDownloads == 2,
        reason: 'two dispatches should hold the two free leases',
      );
      await pump();
      expect(s1.activeDownloads, lessThanOrEqualTo(2));
      expect(connections.maxActiveLeases('s1'), lessThanOrEqualTo(2));

      gate.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 4);
      expect(connections.activeLeases('s1'), 0);
      expect(connections.activeLeases('s2'), 0);
    });

    test('cancel while a lease call is blocked unwinds without a wedge',
        () async {
      connections.leaseGate = Completer<void>(); // never completed
      final file = writeLocal('x.txt', [1, 2, 3]);
      final task = enqueue(
        copySpec(
          source: const LocalFsLocation(),
          destination: const ServerFsLocation('s1'),
          rootPaths: [file.path],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => connections.leaseCalls > 0);
      queue.cancelTask(task.id);
      await pumpUntil(() => task.state == TransferTaskState.cancelled);
      // The pending lease future is released when it eventually lands —
      // here it never does, and nothing waits on it.
      connections.leaseGate!.complete();
      await pump();
    });
  });

  group('pause and cancel', () {
    test('queue pause stops new dispatch; in-flight completes; resume drains',
        () async {
      s1.addDirectory('/src');
      s1.addFile('/src/f0.bin', List.filled(4, 0));
      s1.addDirectory('/src/rest');
      s1.addFile('/src/rest/f1.bin', List.filled(4, 1));
      s1.addFile('/src/rest/f2.bin', List.filled(4, 2));
      // Hold the subtree listing: f1/f2 get discovered during the pause.
      final listGate = Completer<void>();
      s1.listGate = (path) => path == '/src/rest' ? listGate : null;
      final downloadGates = {
        for (final p in ['/src/f0.bin', '/src/rest/f1.bin', '/src/rest/f2.bin'])
          p: Completer<void>(),
      };
      s1.downloadGate = (path) => downloadGates[path];

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => s1.activeDownloads == 1);
      queue.pauseQueue();

      // The scan keeps discovering while paused; the new files become
      // eligible but cannot dispatch.
      listGate.complete();
      await pumpUntil(() => task.scanComplete);
      expect(task.items.length, greaterThan(3));

      // The in-flight f0 still completes — pause stops admission, not
      // running VFS work (03 §4.4).
      downloadGates['/src/f0.bin']!.complete();
      await pumpUntil(
        () => s2.fileBytes.containsKey('/dst/src/f0.bin'),
        reason: 'in-flight download should complete during queue pause',
      );
      await pump();
      expect(s2.fileBytes.containsKey('/dst/src/rest/f1.bin'), isFalse);
      expect(s1.activeDownloads, 0);

      queue.resumeQueue();
      await pumpUntil(() => s1.activeDownloads == 2);
      downloadGates['/src/rest/f1.bin']!.complete();
      downloadGates['/src/rest/f2.bin']!.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 3);
      expect(s2.fileBytes['/dst/src/rest/f1.bin'], List.filled(4, 1));
      expect(s2.fileBytes['/dst/src/rest/f2.bin'], List.filled(4, 2));
    });

    test('task pause cancels the attempt; resume restarts the item', () async {
      s1.addFile('/src/big.bin', List.filled(64, 7));
      s1.downloadChunkSize = 8;
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/big.bin'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => s1.activeDownloads == 1);
      queue.pauseTask(task.id);
      await pumpUntil(() => task.state == TransferTaskState.paused);
      // Let the parked fake read return so its generator can unwind.
      gate.complete();
      final item = task.items.single;
      await pumpUntil(() => item.state == TransferItemState.pending);
      expect(item.transferredBytes, 0);
      expect(task.transferredBytes, 0);
      expect(s1.downloadCalls, 1);

      queue.resumeTask(task.id);
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      // The item restarted from byte zero — a second download call.
      expect(s1.downloadCalls, greaterThan(1));
      expect(s2.fileBytes['/dst/big.bin'], List.filled(64, 7));
    });

    test('task cancel stops new work, drains in-flight, releases leases',
        () async {
      for (var i = 0; i < 4; i++) {
        s1.addFile('/src/f$i.bin', List.filled(8, i));
      }
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => s1.activeDownloads > 0);
      queue.cancelTask(task.id);
      await pumpUntil(() => task.state == TransferTaskState.cancelled);
      expect(
        task.items.every(
          (i) =>
              i.state == TransferItemState.cancelled ||
              i.state == TransferItemState.completed,
        ),
        isTrue,
      );
      // Release the parked fake read so the in-flight attempt unwinds
      // through the cancelled attempt token.
      gate.complete();
      await pumpUntil(
        () =>
            connections.activeLeases('s1') == 0 &&
            connections.activeLeases('s2') == 0,
        reason: 'cancelled task never released its leases',
      );
      // No partial commit landed on the destination.
      expect(s2.fileBytes, isEmpty);
    });

    test('cancel during scan stops the walk without wedging', () async {
      s1.addDirectory('/src');
      s1.addDirectory('/src/held');
      s1.addFile('/src/held/x.txt', [1]);
      final gate = Completer<void>();
      s1.listGate = (path) => path == '/src/held' ? gate : null;
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => task.state == TransferTaskState.scanning);
      queue.cancelTask(task.id);
      await pumpUntil(() => task.state == TransferTaskState.cancelled);
      // The scan is blocked inside listDirectory — the pinned reality is
      // that it unwinds when the call returns; nothing wedges on cancel.
      gate.complete();
      await pumpUntil(
        () => connections.activeLeases('s1') == 0,
        reason: 'cancelled scan never released its leases',
      );
    });
  });

  group('conflict policy', () {
    test('skip leaves the destination untouched', () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.skip,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.items.single.state, TransferItemState.skipped);
      expect(s2.fileBytes['/dst/f.txt'], 'old'.codeUnits);
    });

    test('replace overwrites through expectedTarget', () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/f.txt'], 'new'.codeUnits);
    });

    test('replaceIfNewer replaces only when the source is newer', () async {
      final older = DateTime.fromMillisecondsSinceEpoch(1000000);
      final newer = DateTime.fromMillisecondsSinceEpoch(2000000);
      s1.addFile('/src/new.txt', 'new'.codeUnits, modifiedAt: newer);
      s1.addFile('/src/old.txt', 'oldsrc'.codeUnits, modifiedAt: older);
      s2.addFile('/dst/new.txt', 'x'.codeUnits, modifiedAt: older);
      s2.addFile('/dst/old.txt', 'y'.codeUnits, modifiedAt: newer);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/new.txt', '/src/old.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replaceIfNewer,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/new.txt'], 'new'.codeUnits);
      expect(s2.fileBytes['/dst/old.txt'], 'y'.codeUnits);
      final bySource = {
        for (final i in task.items) i.sourcePath: i,
      };
      expect(bySource['/src/new.txt']!.state, TransferItemState.completed);
      expect(bySource['/src/old.txt']!.state, TransferItemState.skipped);
    });

    test('keepBoth lands the numbered name and preserves the original',
        () async {
      s1.addFile('/src/report.pdf', 'new'.codeUnits);
      s2.addFile('/dst/report.pdf', 'old'.codeUnits);
      s2.addFile('/dst/report (2).pdf', 'older'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/report.pdf'],
          destinationDir: '/dst',
          files: ConflictResolution.keepBoth,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/report.pdf'], 'old'.codeUnits);
      expect(s2.fileBytes['/dst/report (2).pdf'], 'older'.codeUnits);
      expect(s2.fileBytes['/dst/report (3).pdf'], 'new'.codeUnits);
      expect(task.items.single.destinationPath, '/dst/report (3).pdf');
    });

    test('ask parks the item on the conflict surface — never a silent '
        'overwrite', () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.ask,
        ),
      );
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the collision never surfaced',
      );
      final item = task.items.single;
      expect(item.state, TransferItemState.conflictPending);
      expect(task.isTerminal, isFalse);
      expect(s2.fileBytes['/dst/f.txt'], 'old'.codeUnits);
      // The full seam lives in transfer_conflict_test.dart — here the
      // answer just proves the parked item resumes and settles.
      expect(
        queue.resolveConflict(task.id, item.id, ConflictResolution.skip),
        isTrue,
      );
      await awaitTaskDone(task);
      expect(item.state, TransferItemState.skipped);
      expect(task.state, TransferTaskState.completed);
    });

    test('case-insensitive destination serializes folded duplicates',
        () async {
      queue = newQueue(isCaseInsensitiveDestination: (_) => true);
      events = [];
      queue.events.listen(events.add);
      s2.caseInsensitive = true;
      s1.addFile('/src/A.txt', 'upper'.codeUnits);
      s1.addFile('/src/a.txt', 'lower'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
          files: ConflictResolution.keepBoth,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 2);
      // One landed on the scanned name; the folded twin waited, re-stat'd
      // reality, and took the numbered name.
      final landed = s2.fileBytes.keys.toList()..sort();
      expect(landed, ['/dst/src/A.txt', '/dst/src/a (2).txt']);
    });

    test('folder keepBoth rebases the subtree into the numbered directory',
        () async {
      s1.addDirectory('/src/dir');
      s1.addFile('/src/dir/inside.txt', 'in'.codeUnits);
      s2.addDirectory('/dst/dir');
      s2.addFile('/dst/dir/stale.txt', 'stale'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dir'],
          destinationDir: '/dst',
          folders: ConflictResolution.keepBoth,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/dir (2)/inside.txt'], 'in'.codeUnits);
      expect(s2.fileBytes['/dst/dir/stale.txt'], 'stale'.codeUnits);
    });

    test('non-directory occupant + folder skip skips the subtree', () async {
      s1.addDirectory('/src/dir');
      s1.addFile('/src/dir/inside.txt', 'in'.codeUnits);
      s2.addFile('/dst/dir', 'a-file'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dir'],
          destinationDir: '/dst',
          folders: ConflictResolution.skip,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      final byPath = {for (final i in task.items) i.sourcePath: i};
      expect(byPath['/src/dir']!.state, TransferItemState.skipped);
      expect(byPath['/src/dir/inside.txt']!.state, TransferItemState.skipped);
      expect(s2.fileBytes['/dst/dir'], 'a-file'.codeUnits);
    });
  });

  group('move', () {
    test('move deletes the source file after commit', () async {
      s1.addFile('/src/m.txt', 'mm'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/m.txt'],
          destinationDir: '/dst',
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/m.txt'], 'mm'.codeUnits);
      expect(s1.entryAt('/src/m.txt'), isNull);
    });

    test('move removes source directories deepest-first; skipped children '
        'keep their directory', () async {
      s1.addDirectory('/src/dir/sub');
      s1.addFile('/src/dir/sub/keep.txt', 'k'.codeUnits);
      s1.addFile('/src/dir/gone.txt', 'g'.codeUnits);
      s2.addDirectory('/dst/dir');
      s2.addDirectory('/dst/dir/sub');
      s2.addFile('/dst/dir/sub/keep.txt', 'existing'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dir'],
          destinationDir: '/dst',
          files: ConflictResolution.skip,
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      // gone.txt moved; keep.txt skipped → sub stays, and so does dir.
      expect(s2.fileBytes['/dst/dir/gone.txt'], 'g'.codeUnits);
      expect(s1.entryAt('/src/dir/gone.txt'), isNull);
      expect(s1.entryAt('/src/dir/sub/keep.txt'), isNotNull);
      expect(s1.entryAt('/src/dir/sub'), isNotNull);
      expect(s1.entryAt('/src/dir'), isNotNull);
    });
  });

  group('failures', () {
    test('disconnected mid-transfer requeues within the retry budget then '
        'fails the task honestly', () async {
      queue = newQueue(taskRetryLimit: 1);
      events = [];
      queue.events.listen(events.add);
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
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      // The retry re-downloaded the file; a landed commit resets the
      // counter — the budget bounds consecutive losses, not lifetime
      // cumulative ones (03 §3.3).
      expect(s1.downloadCalls, 2);
      expect(task.retryCount, 0);
      expect(s2.fileBytes['/dst/f.bin'], List.filled(8, 9));
    });

    test('persistent disconnect beyond the retry budget fails the task',
        () async {
      queue = newQueue(taskRetryLimit: 1);
      events = [];
      queue.events.listen(events.add);
      s1.addFile('/src/f.bin', List.filled(8, 9));
      s1.downloadFailure = (_) => const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'download',
        message: 'transport dropped',
      );
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      expect(task.failureKind, RemoteFileErrorKind.disconnected);
    });

    test('an upload that dies early aborts the download instead of '
        'buffering the whole file', () async {
      // 512 KB source, tiny pipe buffer, upload fails at once.
      queue = newQueue(pipeBufferBytes: 64);
      events = [];
      queue.events.listen(events.add);
      s1.addFile('/src/big.bin', List.filled(512 * 1024, 3));
      s1.downloadChunkSize = 1024;
      s2.uploadFailure = (_) => const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'upload',
        message: 'denied',
      );
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/big.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      // The real upload error must dominate the internal abort-cancel.
      expect(task.failureKind, RemoteFileErrorKind.permissionDenied);
      // The download must not have delivered all 512 KB into a dead pipe.
      expect(task.transferredBytes, lessThan(512 * 1024));
    });

    test('unsafe destination names fail the item, not the task scan',
        () async {
      s1.addDirectory('/src');
      s1.addFile('/src/good.txt', 'g'.codeUnits);
      // Backslash is rejected by validatePathComponent for every
      // destination (it is a traversal hazard on Windows).
      s1.directories['/src']!.add(
        const RemoteFileEntry(
          path: '/src/evil\\name.txt',
          name: 'evil\\name.txt',
          type: RemoteFileType.file,
          size: 1,
        ),
      );
      s1.fileBytes['/src/evil\\name.txt'] = [0];
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      final bySource = {for (final i in task.items) i.sourcePath: i};
      expect(bySource['/src/good.txt']!.state, TransferItemState.completed);
      expect(
        bySource['/src/evil\\name.txt']!.state,
        TransferItemState.failed,
      );
      expect(s2.fileBytes['/dst/src/good.txt'], 'g'.codeUnits);
    });

    test('a missing root fails its item; siblings still transfer', () async {
      s1.addFile('/src/here.txt', 'h'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/here.txt', '/src/gone.txt'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      final bySource = {for (final i in task.items) i.sourcePath: i};
      expect(bySource['/src/here.txt']!.state, TransferItemState.completed);
      expect(bySource['/src/gone.txt']!.state, TransferItemState.failed);
      expect(s2.fileBytes['/dst/here.txt'], 'h'.codeUnits);
    });

    test('a mid-scan listing failure fails that directory; siblings finish',
        () async {
      s1.addDirectory('/src');
      s1.addDirectory('/src/bad');
      s1.addFile('/src/bad/x.txt', [1]);
      s1.addFile('/src/ok.txt', 'ok'.codeUnits);
      s1.listFailure = (path) => path == '/src/bad'
          ? const RemoteFileException(
              kind: RemoteFileErrorKind.permissionDenied,
              operation: 'list',
              message: 'denied',
            )
          : null;
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      expect(s2.fileBytes['/dst/src/ok.txt'], 'ok'.codeUnits);
      final dir = task.items.firstWhere((i) => i.sourcePath == '/src/bad');
      expect(dir.state, TransferItemState.failed);
    });
  });

  group('lifecycle', () {
    test('dispose cancels running work, drains, and closes events', () async {
      s1.addFile('/src/f.bin', List.filled(8, 1));
      s1.downloadGate = (_) => Completer<void>(); // never completes
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => s1.activeDownloads == 1);
      final closed = Completer<void>();
      queue.events.listen((_) {}, onDone: closed.complete);
      await queue.dispose();
      expect(task.state, TransferTaskState.cancelled);
      expect(connections.activeLeases('s1'), 0);
      await pumpUntil(() => closed.isCompleted,
          reason: 'the event stream never closed');
    });

    test('cross-task destination claims serialize commits', () async {
      s1.addFile('/src/shared.txt', 'first'.codeUnits);
      s2.addFile('/src/shared.txt', 'second'.codeUnits);
      final gate = Completer<void>();
      var armed = true;
      s2.uploadGate = (_) => armed ? gate : null;

      final taskA = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/shared.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
        ),
      );
      await pumpUntil(() => s2.activeUploads == 1);
      // While task A holds the claim, task B's identical destination
      // waits — slotless, no upload started.
      final taskB = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/shared.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
        ),
      );
      await pump();
      expect(s2.activeUploads, 1);
      armed = false;
      gate.complete();
      await awaitTaskDone(taskA);
      await awaitTaskDone(taskB);
      expect(taskA.state, TransferTaskState.completed);
      expect(taskB.state, TransferTaskState.completed);
      expect(s2.uploadCalls, 2);
    });
  });

  group('review regressions', () {
    test('a same-server transfer holds one lease and strands none',
        () async {
      // FsLocation has no value equality — source and destination naming
      // one server must still dedupe to a single server id, or the
      // double-lease's overwritten map entry never releases.
      s1.addFile('/src/f.txt', 'x'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s1'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s1.fileBytes['/dst/f.txt'], 'x'.codeUnits);
      // Scan lease + file lease at most — never scan + two file leases.
      expect(connections.maxActiveLeases('s1'), lessThanOrEqualTo(2));
      expect(connections.activeLeases('s1'), 0);
    });

    test('a commit-time conflict retries on a fresh cancellation token',
        () async {
      // The first upload loses the decide→commit race; the retry must not
      // reuse the attempt token _pipe cancelled when its upload died —
      // a dead token would abort the retry instantly and bounce the item
      // through a pointless requeue.
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      var failOnce = true;
      s2.uploadFailure = (path) {
        if (path != '/dst/f.txt' || !failOnce) return null;
        failOnce = false;
        return const RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'upload',
          path: '/dst/f.txt',
          message: 'appeared mid-transfer',
        );
      };
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/f.txt'], 'new'.codeUnits);
      // Exactly two commits: the raced one plus its in-place retry.
      expect(s2.uploadCalls, 2);
    });

    test('a pause landing in the scan disconnect retry parks lease-free',
        () async {
      s1.addDirectory('/src');
      s1.addFile('/src/f.txt', 'x'.codeUnits);
      late TransferTask task;
      var failOnce = true;
      s1.listFailure = (path) {
        if (path != '/src' || !failOnce) return null;
        failOnce = false;
        // Pause inside the failing op: the retry must release the scan
        // leases and park on notPaused rather than re-leasing under a
        // paused task.
        queue.pauseTask(task.id);
        return const RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'list',
          message: 'transport dropped',
        );
      };
      task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => task.state == TransferTaskState.paused);
      await pump(16);
      // Parked: no retry listing ran and no lease is held while paused.
      expect(s1.listCalls, 1);
      expect(connections.activeLeases('s1'), 0);

      queue.resumeTask(task.id);
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/src/f.txt'], 'x'.codeUnits);
    });

    test('a mkdir-conflict on the destination root merges the raced '
        'directory', () async {
      // A concurrent creator wins the stat→mkdir race on /dst: mkdir
      // throws conflict but a re-stat sees a directory — the correct
      // answer is merge, not a scan failure.
      final racing = _RacingMkdirFileSystem('/dst');
      connections = FakeQueueConnectionManager({'s1': s1, 's2': racing});
      queue = newQueue();
      events = [];
      queue.events.listen(events.add);

      s1.addFile('/src/f.txt', 'x'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(racing.fileBytes['/dst/f.txt'], 'x'.codeUnits);
    });

    test('skipped items roll up on the task', () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
          // files: skip is the copySpec default.
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.skippedItems, 1);
      expect(s2.fileBytes['/dst/f.txt'], 'old'.codeUnits);
    });

    test('a failed source-directory removal reports an item event',
        () async {
      s1.addDirectory('/src/dir');
      s1.addFile('/src/dir/f.txt', 'x'.codeUnits);
      s1.deleteFailure = (entry) => entry.isDirectory
          ? const RemoteFileException(
              kind: RemoteFileErrorKind.permissionDenied,
              operation: 'delete',
              message: 'denied',
            )
          : null;
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dir'],
          destinationDir: '/dst',
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);
      // A move that leaves its source behind is not complete — the copy
      // landed but the surviving source directory fails the task.
      expect(task.state, TransferTaskState.failed);
      expect(s2.fileBytes['/dst/dir/f.txt'], 'x'.codeUnits);
      expect(s1.entryAt('/src/dir/f.txt'), isNull);
      expect(s1.entryAt('/src/dir'), isNotNull);
      final dir = task.items.firstWhere((i) => i.sourcePath == '/src/dir');
      expect(dir.error, contains('could not be removed'));
      expect(task.error, isNotNull);
      expect(
        events
            .whereType<TransferQueueItemEvent>()
            .any((e) => e.itemId == dir.id && e.error != null),
        isTrue,
        reason: 'the dir-removal failure must surface as an item event',
      );
    });
  });
}

/// A destination whose `createDirectory` loses the stat→mkdir race on
/// [racePath]: the entry materializes between the queue's absent-stat and
/// its mkdir, so mkdir throws conflict even though a later stat sees the
/// directory a "concurrent creator" made.
final class _RacingMkdirFileSystem extends FakeTreeFileSystem {
  _RacingMkdirFileSystem(this.racePath);

  final String racePath;

  @override
  Future<void> createDirectory(String path) async {
    if (path == racePath) {
      addDirectory(path);
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'mkdir',
        path: path,
        message: 'already exists: $path',
      );
    }
    return super.createDirectory(path);
  }
}
