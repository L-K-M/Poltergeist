// Queue-level contract tests for the §3.5 recursive walker integration:
// the TransferQueue scan consumes the app-level walker, so walker-level
// safety (reserved names, traversal containment, §13 flagged reporting,
// mid-walk cancel) surfaces as honest task/item outcomes, and walker
// output still drives the per-item conflict checks.
//
// Same fake harness as transfer_queue_test.dart — no sockets.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

void main() {
  late Directory tempDir;
  late Directory localSrc;
  late FakeTreeFileSystem s1;
  late FakeTreeFileSystem s2;
  late FakeQueueConnectionManager connections;
  late TransferQueue queue;
  late List<TransferQueueEvent> events;

  final createdQueues = <TransferQueue>[];

  TransferQueue newQueue({
    bool Function(RemoteFileEntry)? isFlaggedEntry,
  }) {
    final created = TransferQueue(
      connections: connections,
      isFlaggedEntry: isFlaggedEntry,
    );
    createdQueues.add(created);
    return created;
  }

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

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('poltergeist-tw-');
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
      } catch (_) {}
    }
    createdQueues.clear();
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Best effort cleanup.
    }
  });

  File writeLocal(String relative, List<int> bytes) {
    final file = File('${localSrc.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file;
  }

  group('walker-driven scan', () {
    test('upload direction: a local tree walks into remote work items',
        () async {
      writeLocal('tree/sub/deep.bin', [1, 2, 3]);
      writeLocal('tree/top.txt', 'top'.codeUnits);

      final task = queue.enqueue(
        copySpec(
          source: const LocalFsLocation(),
          destination: const ServerFsLocation('s1'),
          rootPaths: ['${localSrc.path}/tree'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(s1.fileBytes['/dst/tree/top.txt'], 'top'.codeUnits);
      expect(s1.fileBytes['/dst/tree/sub/deep.bin'], [1, 2, 3]);
      expect(task.totalFiles, 2);
      expect(task.totalDirectories, 2); // tree + tree/sub
      expect(task.totalBytes, 6);
      expect(task.scanComplete, isTrue);
      // The public event stream carries the same aggregate totals.
      final progress = events
          .whereType<TransferQueueProgressEvent>()
          .lastWhere((e) => e.taskId == task.id,
              orElse: () =>
                  fail('no TransferQueueProgressEvent emitted for task'));
      expect(progress.taskTotalFiles, 2);
      expect(progress.taskTotalDirectories, 2);
      expect(progress.taskTotalBytes, 6);
      expect(progress.scanComplete, isTrue);
    });

    test('download direction: a remote tree walks into local work items',
        () async {
      s1.addDirectory('/src/dir/sub');
      s1.addFile('/src/dir/a.txt', 'a'.codeUnits);
      s1.addFile('/src/dir/sub/b.txt', 'bb'.codeUnits);
      final localDest = Directory('${tempDir.path}/dest')..createSync();

      final task = queue.enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const LocalFsLocation(),
          rootPaths: ['/src/dir'],
          destinationDir: localDest.path,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(File('${localDest.path}/dir/a.txt').readAsBytesSync(),
          'a'.codeUnits);
      expect(File('${localDest.path}/dir/sub/b.txt').readAsBytesSync(),
          'bb'.codeUnits);
      expect(task.totalFiles, 2);
      expect(task.completedFiles, 2);
    });

    test('walker output still drives the per-item conflict check '
        '(ask parks a scan-discovered file)', () async {
      s1.addFile('/src/clash.txt', 'new'.codeUnits);
      s2.addFile('/dst/clash.txt', 'old'.codeUnits);

      final task = queue.enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/clash.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.ask,
        ),
      );
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'conflict never surfaced',
      );

      final conflict = queue.pendingConflicts.single;
      expect(conflict.isDirectory, isFalse);
      expect(conflict.destinationPath, '/dst/clash.txt');
      expect(
        queue.resolveConflict(
          task.id,
          conflict.itemId,
          ConflictResolution.replace,
        ),
        isTrue,
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/clash.txt'], 'new'.codeUnits);
    });
  });

  group('walker safety at queue level', () {
    test('Windows-reserved names reject per item on download; siblings '
        'transfer', () async {
      s1.addDirectory('/src');
      s1.addFile('/src/CON', 'c'.codeUnits);
      s1.addFile('/src/nul.txt', 'n'.codeUnits);
      s1.addFile('/src/aux .txt', 'a'.codeUnits);
      s1.addFile('/src/trailing.', 't'.codeUnits);
      s1.addFile('/src/ok.txt', 'ok'.codeUnits);
      final localDest = Directory('${tempDir.path}/dest')..createSync();

      final task = queue.enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const LocalFsLocation(),
          rootPaths: ['/src'],
          destinationDir: localDest.path,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.failed);
      final failed = task.items
          .where((i) => i.state == TransferItemState.failed)
          .toList();
      expect(failed.length, 4);
      for (final item in failed) {
        expect(item.error, contains('not a safe local file name'));
      }
      // The clean sibling still landed.
      expect(File('${localDest.path}/src/ok.txt').readAsBytesSync(),
          'ok'.codeUnits);
      expect(task.completedFiles, 1);
    });

    test('a listed entry escaping the walk root fails the task loudly',
        () async {
      s1.addDirectory('/src/dir');
      s1.directories['/src/dir']!.add(
        const RemoteFileEntry(
          path: '/outside/evil.txt',
          name: 'evil.txt',
          type: RemoteFileType.file,
          size: 4,
        ),
      );

      final task = queue.enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dir'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.failed);
      expect(task.error, contains('outside the walk root'));
      // Nothing ever dispatched toward the escaping path.
      expect(
        s2.calls.where((c) => c.contains('outside')),
        isEmpty,
      );
    });

    test('a flagged (undecodable) name becomes a terminal skipped row, '
        'never silently dropped', () async {
      // Injected §13 detector — production wiring waits on the upstream
      // raw-name metadata (STATUS item 13); the test flags by name.
      queue = newQueue(
        isFlaggedEntry: (entry) => entry.name == 'bad.txt',
      );
      events = [];
      queue.events.listen(events.add);

      s1.addDirectory('/src');
      s1.addFile('/src/good.txt', 'g'.codeUnits);
      s1.addFile('/src/bad.txt', 'b'.codeUnits);

      final task = queue.enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      final flagged = task.items.singleWhere(
        (i) => i.sourcePath.endsWith('bad.txt'),
      );
      expect(flagged.state, TransferItemState.skipped);
      expect(flagged.error, contains('UTF-8'));
      expect(task.skippedItems, 1);
      // Its sibling transferred; the task did not fail on one bad name.
      expect(s2.fileBytes['/dst/src/good.txt'], 'g'.codeUnits);
      // No upload ever carried the lossy name.
      expect(
        s1.calls.where((c) => c.contains('bad.txt') && c.startsWith('download')),
        isEmpty,
      );
    });

    test('a transient mid-scan disconnect rides the re-lease seam — '
        'the directory lists on retry, never a per-item failure',
        () async {
      s1.addDirectory('/src/broken');
      s1.addFile('/src/broken/deep.txt', 'd'.codeUnits);
      s1.addFile('/src/ok.txt', 'o'.codeUnits);
      // One drop, then the reconnect succeeds — the walk must retry
      // through _scanOp rather than record a failed directory row.
      var brokenListings = 0;
      s1.listFailure = (path) =>
          path == '/src/broken' && brokenListings++ == 0
              ? const RemoteFileException(
                  kind: RemoteFileErrorKind.disconnected,
                  operation: 'list',
                  message: 'connection dropped',
                )
              : null;

      final task = queue.enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      // The re-lease seam retried the listing (retryCount resets on
      // success, so the call count is the observable proof).
      expect(brokenListings, 2);
      expect(task.failedItems, 0);
      expect(task.scanComplete, isTrue);
      // The retried listing's children transferred — nothing was lost.
      expect(s2.fileBytes['/dst/src/broken/deep.txt'], 'd'.codeUnits);
      expect(s2.fileBytes['/dst/src/ok.txt'], 'o'.codeUnits);
    });

    test('a persistent mid-scan disconnect exhausts the re-lease seam '
        'and fails the task — never a per-item failure', () async {
      s1.addDirectory('/src/broken');
      s1.addFile('/src/ok.txt', 'o'.codeUnits);
      s1.listFailure = (path) => path == '/src/broken'
          ? const RemoteFileException(
              kind: RemoteFileErrorKind.disconnected,
              operation: 'list',
              message: 'connection dropped',
            )
          : null;

      final task = queue.enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.failed);
      // failedItems counts scan-produced failure rows; the teardown
      // mass-failure assigns state without bumping it, so zero pins
      // "no per-item failure while the seam gave up".
      expect(task.failedItems, 0);
      expect(task.scanComplete, isFalse);
    });

    test('mid-walk cancel stops enumeration: no new listings, no new '
        'items', () async {
      s1.addDirectory('/src/a');
      s1.addDirectory('/src/b');
      s1.addFile('/src/a/one.txt', '1'.codeUnits);
      s1.addFile('/src/b/two.txt', '2'.codeUnits);
      final gate = Completer<void>();
      s1.listGate = (path) => path == '/src/a' ? gate : null;

      final task = queue.enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      // /src listed; the walker then pulled /src/a's listing, which is
      // now gated in flight.
      await pumpUntil(
        () => s1.calls.contains('list:/src/a'),
        reason: 'the gated listing never started',
      );
      final itemsAtCancel = task.items.length;
      queue.cancelTask(task.id);
      gate.complete();
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.cancelled);
      expect(s1.listCalls, 2); // /src/b was never enumerated
      expect(task.items.length, lessThanOrEqualTo(itemsAtCancel + 1));
      expect(task.scanComplete, isFalse);
    });
  });
}
