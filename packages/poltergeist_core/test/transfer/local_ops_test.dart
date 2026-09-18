// D26 local↔local ops through the engine-side transfer queue
// (00 D26, 03 §4.2/§4.5, 07 §3.5): the streamed copy rides the same
// bounded pipe as the remote directions, a same-device move is a
// rename(2) through the VFS seam, and a cross-device move degrades to a
// durable copy+delete inside one task — the source is unlinked only
// after the copy is verified and fsynced, so a failure or cancel leaves
// either the original or a durable copy, never neither.
//
// The local endpoint is the production LocalFileSystem over a real temp
// dir, behind an instrumented subclass that counts VFS calls and scripts
// the faults the tests need (EXDEV rename, mid-stream failures, a byte
// probe for the pipe's bound). The case-insensitive-volume halves run a
// FakeTreeFileSystem as the local side — it models a posix tree, so
// those cases are gated off Windows (path joining is platform-native).

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

void main() {
  late Directory tempDir;
  late Directory localSrc;
  late Directory localDst;
  late InstrumentedLocalFs localFs;
  late FakeQueueConnectionManager connections;
  late TransferQueue queue;
  late List<TransferQueueEvent> events;

  final createdQueues = <TransferQueue>[];

  TransferQueue newQueue({
    RemoteFileSystem? localFileSystem,
    int? pipeBufferBytes,
    bool Function(FsLocation)? isCaseInsensitiveDestination,
    Future<void> Function(String destinationPath)? flushLocalDestination,
    TransferPersistence? persistence,
    BandwidthLimiter? downloadLimiter,
    BandwidthLimiter? uploadLimiter,
  }) {
    final created = TransferQueue(
      connections: connections,
      localFileSystem: localFileSystem ?? localFs,
      pipeBufferBytes: pipeBufferBytes ?? 4 * 1024 * 1024,
      isCaseInsensitiveDestination: isCaseInsensitiveDestination,
      flushLocalDestination: flushLocalDestination,
      persistence: persistence,
      downloadLimiter: downloadLimiter,
      uploadLimiter: uploadLimiter,
    );
    createdQueues.add(created);
    // The queue↔events subscription lives here so call sites can't
    // forget it and assert against a silently empty list.
    events = [];
    created.events.listen(events.add);
    return created;
  }

  File writeLocal(String name, List<int> bytes) {
    final file = File(p.join(localSrc.path, name));
    file.writeAsBytesSync(bytes);
    return file;
  }

  File dstFile(String name) => File(p.join(localDst.path, name));

  /// The aborted upload's temp cleanup is async dart:io work — the task
  /// terminalizes when the sticky token trips, ahead of the temp's
  /// unlink landing. Poll rather than asserting on a torn view.
  Future<void> expectNoOrphanTemps() async {
    await pumpUntil(
      () => !localDst
          .listSync()
          .any((e) => p.basename(e.path).startsWith('.poltergeist-')),
      reason: 'aborted upload left a temp behind',
    );
  }

  TransferTaskSpec localSpec({
    required List<String> rootPaths,
    required String destinationDir,
    ConflictResolution files = ConflictResolution.skip,
    ConflictResolution folders = ConflictResolution.merge,
    TransferOperation operation = TransferOperation.copy,
  }) => TransferTaskSpec(
    source: const LocalFsLocation(),
    destination: const LocalFsLocation(),
    rootPaths: rootPaths,
    destinationDir: destinationDir,
    policy: ResolvedConflictPolicy(files: files, folders: folders),
    operation: operation,
  );

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('poltergeist-lops-');
    // Resolve symlinks once: macOS /var → /private/var makes raw paths
    // compare unequal to resolved ones downstream.
    tempDir = Directory(temp.resolveSymbolicLinksSync());
    localSrc = Directory(p.join(tempDir.path, 'src'))..createSync();
    localDst = Directory(p.join(tempDir.path, 'dst'))..createSync();
    localFs = InstrumentedLocalFs();
    connections = FakeQueueConnectionManager({});
    queue = newQueue();
  });

  tearDown(() async {
    for (final created in createdQueues) {
      await created.dispose();
    }
    createdQueues.clear();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('D26 streamed copy', () {
    test(
      'streams a local→local copy through the bounded pipe with progress',
      () async {
        final bytes = List<int>.generate(256 * 1024, (i) => i & 0xFF);
        writeLocal('big.bin', bytes);
        final probe = PipeProbe();
        localFs.pipeProbe = probe;
        queue = newQueue(pipeBufferBytes: 8 * 1024);

        final task = queue.enqueue(
          localSpec(
            rootPaths: [p.join(localSrc.path, 'big.bin')],
            destinationDir: localDst.path,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        expect(dstFile('big.bin').readAsBytesSync(), bytes);
        // The pipe's bound held: in-flight bytes never exceeded the
        // configured bound plus one dart:io read chunk — addStream
        // counts a whole chunk before pausing the source, and openRead
        // delivers 64 KiB blocks (measured: peak == 64 KiB here).
        expect(probe.peak, lessThanOrEqualTo(8 * 1024 + 64 * 1024));
        expect(probe.peak, greaterThan(0));
        final progress = events
            .whereType<TransferQueueProgressEvent>()
            .map((event) => event.transferred)
            .toList();
        expect(progress, isNotEmpty);
        expect(progress.last, bytes.length);
        // Local endpoints never touch the channel pool (03 §4.3).
        expect(connections.leaseCalls, 0);
      },
    );

    test('preserves mtime (and mode) on the destination', () async {
      final file = writeLocal('meta.txt', 'meta'.codeUnits);
      final mtime = DateTime.utc(2020, 1, 2, 3, 4, 5);
      await file.setLastModified(mtime);
      if (!Platform.isWindows) {
        final chmod = await Process.run('chmod', ['640', file.path]);
        expect(chmod.exitCode, 0, reason: 'chmod failed: ${chmod.stderr}');
      }

      final task = queue.enqueue(
        localSpec(
          rootPaths: [file.path],
          destinationDir: localDst.path,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      final stat = FileStat.statSync(dstFile('meta.txt').path);
      expect(
        stat.modified.difference(mtime).abs(),
        lessThan(const Duration(seconds: 2)),
      );
      if (!Platform.isWindows) {
        // 03 §4's mode bit — the upload's preserveMode channel.
        expect(stat.mode & 0x1FF, 0x1A0 /* 0640 */);
      }
      // xattrs/ACLs/other metadata are explicitly out of v1 scope (D26).
    });

    test(
      'cancel mid-copy leaves no destination file and keeps the source',
      () async {
        final bytes = List<int>.filled(16 * 1024, 7);
        final file = writeLocal('cancel.bin', bytes);
        localFs.downloadGate = Completer<void>();
        queue = newQueue();

        final task = queue.enqueue(
          localSpec(
            rootPaths: [file.path],
            destinationDir: localDst.path,
          ),
        );
        await pumpUntil(() => localFs.downloadStarted.isCompleted);
        queue.cancelTask(task.id);
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.cancelled);
        expect(file.readAsBytesSync(), bytes);
        expect(dstFile('cancel.bin').existsSync(), isFalse);
        // No orphan temp siblings from the aborted upload.
        await expectNoOrphanTemps();
      },
    );

    test('charges neither directional throttle bucket', () async {
      writeLocal('fast.bin', List<int>.filled(64 * 1024, 3));
      // A wrongly-charged 64 KiB copy at 1 B/s would need ~18 hours;
      // completing proves the local no-op limiter was used.
      queue = newQueue(
        downloadLimiter: BandwidthLimiter(bytesPerSecond: 1),
        uploadLimiter: BandwidthLimiter(bytesPerSecond: 1),
      );

      final task = queue.enqueue(
        localSpec(
          rootPaths: [p.join(localSrc.path, 'fast.bin')],
          destinationDir: localDst.path,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(dstFile('fast.bin').existsSync(), isTrue);
    });

    test('records the same journal milestones as remote copies', () async {
      final persistence = RecordingPersistence();
      queue = newQueue(persistence: persistence);
      writeLocal('j.txt', 'j'.codeUnits);

      final task = queue.enqueue(
        localSpec(
          rootPaths: [p.join(localSrc.path, 'j.txt')],
          destinationDir: localDst.path,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      final kinds = persistence.journal.map((r) => r.runtimeType).toList();
      for (final required in [
        TaskEnqueuedRecord,
        ScanCompleteRecord,
        FileCompletedRecord,
        TaskStateRecord,
      ]) {
        expect(kinds, contains(required));
      }
      expect(
        persistence.journal.whereType<TaskStateRecord>().last.state,
        TransferTaskState.completed,
      );
    });
  });

  group('D26 move', () {
    test('same-device move is a rename — no bytes through the pipe', () async {
      final file = writeLocal('mv.txt', 'moved'.codeUnits);
      final mtime = DateTime.utc(2019, 5, 5, 6, 7, 8);
      await file.setLastModified(mtime);

      final task = queue.enqueue(
        localSpec(
          rootPaths: [file.path],
          destinationDir: localDst.path,
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(localFs.renameCalls, 1);
      expect(localFs.downloadCalls, 0);
      expect(localFs.uploadCalls, 0);
      // rename(2) already moved the file — no post-copy unlink.
      expect(localFs.deleteCalls, 0);
      expect(file.existsSync(), isFalse);
      final dst = dstFile('mv.txt');
      expect(dst.readAsStringSync(), 'moved');
      // The rename carries mtime natively — no setTimes round-trip.
      expect(localFs.setTimesCalls, 0);
      expect(
        FileStat.statSync(dst.path).modified.difference(mtime).abs(),
        lessThan(const Duration(seconds: 2)),
      );
    });

    test(
      'cross-device move degrades to a durable copy+delete in one task',
      () async {
        localFs.renameCrossDevice = true;
        final bytes = List<int>.generate(4096, (i) => i & 0xFF);
        final file = writeLocal('xdev.bin', bytes);
        final mtime = DateTime.utc(2021, 2, 3, 4, 5, 6);
        await file.setLastModified(mtime);
        queue = newQueue(
          flushLocalDestination: (path) async {
            localFs.operationLog.add('flush:$path');
          },
        );

        final task = queue.enqueue(
          localSpec(
            rootPaths: [file.path],
            destinationDir: localDst.path,
            operation: TransferOperation.move,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        // Rename was tried first; the EXDEV degraded to the pipe.
        expect(localFs.renameCalls, 1);
        expect(localFs.downloadCalls, 1);
        expect(localFs.uploadCalls, 1);
        expect(localFs.deleteCalls, 1);
        expect(dstFile('xdev.bin').readAsBytesSync(), bytes);
        expect(file.existsSync(), isFalse);
        expect(
          FileStat.statSync(dstFile('xdev.bin').path).modified
              .difference(mtime)
              .abs(),
          lessThan(const Duration(seconds: 2)),
        );
        // The durability barrier ran before the source unlink (00 D26).
        final flushIndex = localFs.operationLog.indexWhere(
          (entry) => entry.startsWith('flush:'),
        );
        final deleteIndex = localFs.operationLog.indexWhere(
          (entry) => entry.startsWith('delete:'),
        );
        expect(flushIndex, isNonNegative);
        expect(deleteIndex, greaterThan(flushIndex));
      },
    );

    test('a failed cross-device copy preserves the source fully', () async {
      localFs.renameCrossDevice = true;
      localFs.downloadFailAfterBytes = 100;
      final bytes = List<int>.filled(4096, 5);
      final file = writeLocal('keep.bin', bytes);

      final task = queue.enqueue(
        localSpec(
          rootPaths: [file.path],
          destinationDir: localDst.path,
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.failed);
      // The no-data-loss rule: partial copy → source fully intact,
      // nothing committed at the destination.
      expect(file.readAsBytesSync(), bytes);
      expect(localFs.deleteCalls, 0);
      expect(dstFile('keep.bin').existsSync(), isFalse);
      await expectNoOrphanTemps();
    });

    test(
      'cancel mid-cross-device-copy leaves the source fully intact',
      () async {
        localFs.renameCrossDevice = true;
        localFs.downloadGate = Completer<void>();
        final bytes = List<int>.filled(16 * 1024, 9);
        final file = writeLocal('xcancel.bin', bytes);

        final task = queue.enqueue(
          localSpec(
            rootPaths: [file.path],
            destinationDir: localDst.path,
            operation: TransferOperation.move,
          ),
        );
        await pumpUntil(() => localFs.downloadStarted.isCompleted);
        queue.cancelTask(task.id);
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.cancelled);
        expect(file.readAsBytesSync(), bytes);
        expect(localFs.deleteCalls, 0);
        expect(dstFile('xcancel.bin').existsSync(), isFalse);
        await expectNoOrphanTemps();
      },
    );

    test(
      'a failed durability flush fails the move with the source intact',
      () async {
        localFs.renameCrossDevice = true;
        var flushReached = false;
        queue = newQueue(
          flushLocalDestination: (path) async {
            localFs.operationLog.add('flush:$path');
            flushReached = true;
            throw StateError('fsync failed');
          },
        );
        final bytes = List<int>.filled(2048, 11);
        final file = writeLocal('nofsync.bin', bytes);

        final task = queue.enqueue(
          localSpec(
            rootPaths: [file.path],
            destinationDir: localDst.path,
            operation: TransferOperation.move,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.failed);
        expect(
          flushReached,
          isTrue,
          reason: 'task must fail at the durability flush',
        );
        expect(file.readAsBytesSync(), bytes);
        expect(localFs.deleteCalls, 0);
        await expectNoOrphanTemps();
      },
    );

    test('a move onto itself completes in place — never self-overwrites', () async {
      final file = writeLocal('self.txt', 'self'.codeUnits);

      final task = queue.enqueue(
        localSpec(
          rootPaths: [file.path],
          destinationDir: localSrc.path,
          files: ConflictResolution.replace,
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(task.items.single.state, TransferItemState.completed);
      // The self-target short-circuit: no rename, no pipe, no unlink.
      expect(localFs.renameCalls, 0);
      expect(localFs.downloadCalls, 0);
      expect(localFs.deleteCalls, 0);
      expect(file.readAsStringSync(), 'self');
    });

    test(
      'a copy onto itself with keepBoth produces a numbered duplicate',
      () async {
        final file = writeLocal('dup.txt', 'dup'.codeUnits);

        final task = queue.enqueue(
          localSpec(
            rootPaths: [file.path],
            destinationDir: localSrc.path,
            files: ConflictResolution.keepBoth,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        expect(file.existsSync(), isTrue);
        expect(
          File(p.join(localSrc.path, 'dup (2).txt')).readAsStringSync(),
          'dup',
        );
      },
    );

    test(
      'a same-device directory move renames only files, never the tree',
      () async {
        // FakeTreeFileSystem models a posix tree — path joining is
        // platform-native, so this can't run where '\' is the
        // separator.
        final local = FakeTreeFileSystem();
        local.addDirectory(localDst.path);
        local.addDirectory(p.join(localSrc.path, 'sub'));
        local.addFile(
          p.join(localSrc.path, 'sub', 'a.txt'),
          'a'.codeUnits,
        );
        local.addFile(
          p.join(localSrc.path, 'sub', 'b.txt'),
          'bb'.codeUnits,
        );
        queue = newQueue(localFileSystem: local);

        final task = queue.enqueue(
          localSpec(
            rootPaths: [p.join(localSrc.path, 'sub')],
            destinationDir: localDst.path,
            operation: TransferOperation.move,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        // Directory moves are mkdir + per-child ops + rmdir: rename(2)
        // is the per-FILE fast path — the contract the fake's
        // file-only UnimplementedError can't be trusted to prove
        // under the queue's broad failure handling.
        expect(local.renameCalls, 2);
        expect(local.renameSourceTypes, everyElement(RemoteFileType.file));
        expect(
          local.entryAt(p.join(localDst.path, 'sub', 'a.txt'))?.size,
          1,
          reason: 'moved file must retain its bytes',
        );
        expect(
          local.entryAt(p.join(localDst.path, 'sub', 'b.txt'))?.size,
          2,
          reason: 'moved file must retain its bytes',
        );
        expect(local.entryAt(p.join(localSrc.path, 'sub')), isNull);
      },
      skip: Platform.isWindows
          ? 'FakeTreeFileSystem models posix separators only'
          : null,
    );
  });

  group('D26 case-only rules', () {
    // The case-insensitive halves run a posix-tree fake as the local fs,
    // so they can't run where path joining is Windows-native.
    final posixOnly = {'skip': Platform.isWindows};

    test(
      'same-name move onto its own directory is a no-op on a folding volume',
      () async {
        final local = FakeTreeFileSystem()..caseInsensitive = true;
        local.addDirectory(localSrc.path);
        local.addFile(
          p.join(localSrc.path, 'stay.txt'),
          'stay'.codeUnits,
        );
        queue = newQueue(
          localFileSystem: local,
          isCaseInsensitiveDestination: (_) => true,
        );

        final task = queue.enqueue(
          localSpec(
            rootPaths: [p.join(localSrc.path, 'stay.txt')],
            destinationDir: localSrc.path,
            files: ConflictResolution.replace,
            operation: TransferOperation.move,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        expect(local.renameCalls, 0);
        expect(local.deleteCalls, 0);
        expect(
          local.entryAt(p.join(localSrc.path, 'stay.txt'))!.size,
          4,
        );
      },
      skip: posixOnly['skip'],
    );

    test(
      'move onto a folded-spelling parent is still a self-move',
      () async {
        final local = FakeTreeFileSystem()..caseInsensitive = true;
        local.addDirectory(localSrc.path);
        local.addFile(
          p.join(localSrc.path, 'stay.txt'),
          'stay'.codeUnits,
        );
        // A destDir that differs only by case: on a folding volume it
        // resolves to the source's own parent.
        final foldedDest = p.join(tempDir.path, 'SRC');
        queue = newQueue(
          localFileSystem: local,
          isCaseInsensitiveDestination: (_) => true,
        );

        final task = queue.enqueue(
          localSpec(
            rootPaths: [p.join(localSrc.path, 'stay.txt')],
            destinationDir: foldedDest,
            files: ConflictResolution.replace,
            operation: TransferOperation.move,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        expect(local.renameCalls, 0);
        expect(local.deleteCalls, 0);
        expect(
          local.entryAt(p.join(localSrc.path, 'stay.txt')),
          isNotNull,
        );
      },
      skip: posixOnly['skip'],
    );

    test(
      'a case-only occupant on a folding volume follows the conflict model',
      () async {
        final local = FakeTreeFileSystem()..caseInsensitive = true;
        local.addDirectory(localSrc.path);
        local.addDirectory(localDst.path);
        local.addFile(
          p.join(localSrc.path, 'foo.txt'),
          'source'.codeUnits,
        );
        local.addFile(
          p.join(localDst.path, 'FOO.TXT'),
          'occupant'.codeUnits,
        );
        queue = newQueue(
          localFileSystem: local,
          isCaseInsensitiveDestination: (_) => true,
        );

        // skip → the folded occupant wins; nothing moves.
        final skipped = queue.enqueue(
          localSpec(
            rootPaths: [p.join(localSrc.path, 'foo.txt')],
            destinationDir: localDst.path,
          ),
        );
        await awaitTaskDone(skipped);
        expect(skipped.state, TransferTaskState.completed);
        expect(
          skipped.items.single.state,
          TransferItemState.skipped,
        );
        expect(
          local.entryAt(p.join(localDst.path, 'FOO.TXT'))!.size,
          8,
        );
        expect(
          local.entryAt(p.join(localSrc.path, 'foo.txt')),
          isNotNull,
        );

        // keepBoth → the source lands under a numbered name; the
        // occupant is untouched.
        final kept = queue.enqueue(
          localSpec(
            rootPaths: [p.join(localSrc.path, 'foo.txt')],
            destinationDir: localDst.path,
            files: ConflictResolution.keepBoth,
            operation: TransferOperation.move,
          ),
        );
        await awaitTaskDone(kept);
        expect(kept.state, TransferTaskState.completed);
        expect(
          local.entryAt(p.join(localDst.path, 'FOO.TXT'))!.size,
          8,
        );
        expect(
          local.entryAt(p.join(localDst.path, 'foo (2).txt'))!.size,
          6,
        );
        expect(
          local.entryAt(p.join(localSrc.path, 'foo.txt')),
          isNull,
        );
      },
      skip: posixOnly['skip'],
    );

    test(
      'case-only names are distinct files on a case-sensitive volume',
      () async {
        final local = FakeTreeFileSystem();
        local.addDirectory(localSrc.path);
        local.addDirectory(localDst.path);
        local.addFile(
          p.join(localSrc.path, 'foo.txt'),
          'source'.codeUnits,
        );
        local.addFile(
          p.join(localDst.path, 'FOO.TXT'),
          'occupant'.codeUnits,
        );
        queue = newQueue(
          localFileSystem: local,
          isCaseInsensitiveDestination: (_) => false,
        );

        final task = queue.enqueue(
          localSpec(
            rootPaths: [p.join(localSrc.path, 'foo.txt')],
            destinationDir: localDst.path,
            operation: TransferOperation.move,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        // No conflict: foo.txt is a *new* name here — the normal
        // conflict model applies, and both files coexist.
        expect(local.entryAt(p.join(localDst.path, 'FOO.TXT'))!.size, 8);
        expect(local.entryAt(p.join(localDst.path, 'foo.txt'))!.size, 6);
        expect(local.entryAt(p.join(localSrc.path, 'foo.txt')), isNull);
      },
      skip: posixOnly['skip'],
    );

    test(
      'the real local fs resolves case-only collisions per its own rules',
      () async {
        writeLocal('foo.txt', 'source'.codeUnits);
        dstFile('FOO.TXT').writeAsStringSync('occupant');
        final folds = dstFile('foo.txt').existsSync();

        final task = queue.enqueue(
          localSpec(
            rootPaths: [p.join(localSrc.path, 'foo.txt')],
            destinationDir: localDst.path,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        if (folds) {
          // Case-insensitive host: the folded occupant surfaced a
          // conflict and skip won.
          expect(task.items.single.state, TransferItemState.skipped);
          expect(dstFile('FOO.TXT').readAsStringSync(), 'occupant');
        } else {
          // Case-sensitive host: a distinct new file landed.
          expect(task.items.single.state, TransferItemState.completed);
          expect(dstFile('foo.txt').readAsStringSync(), 'source');
          expect(dstFile('FOO.TXT').readAsStringSync(), 'occupant');
        }
      },
    );
  });
}

/// A [LocalFileSystem] that counts VFS calls and scripts the faults the
/// D26 tests need: a cross-device rename (EXDEV), a gated/failing
/// download stream, and an in-flight byte probe for the pipe's bound.
/// Everything not scripted delegates to the real implementation over
/// the temp tree.
class InstrumentedLocalFs extends LocalFileSystem {
  int renameCalls = 0;
  int downloadCalls = 0;
  int uploadCalls = 0;
  int deleteCalls = 0;
  int setTimesCalls = 0;

  /// When true, every `rename` throws [LocalCrossDeviceRenameException]
  /// — the EXDEV posture the queue must degrade to copy+delete.
  bool renameCrossDevice = false;

  /// Scripted-download hooks: pause mid-stream on [downloadGate], die
  /// mid-stream past [downloadFailAfterBytes]. Either engages the
  /// chunked emission below (the real adapter's per-chunk contract —
  /// cancellation is honored between chunks and while parked).
  Completer<void>? downloadGate;
  int? downloadFailAfterBytes;
  final Completer<void> downloadStarted = Completer<void>();

  /// Optional byte-probe wrapped around the pipe: `sent` at the sink,
  /// `received` in the upload — peak is the buffered high-water mark.
  PipeProbe? pipeProbe;

  /// Operation log shared with the queue's flush seam so ordering tests
  /// can assert "flush before unlink" in one sequence.
  final List<String> operationLog = [];

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) {
    renameCalls++;
    if (renameCrossDevice) {
      throw LocalCrossDeviceRenameException(
        path: oldPath,
        newPath: newPath,
      );
    }
    return super.rename(oldPath, newPath, overwrite: overwrite);
  }

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    downloadCalls++;
    if (downloadGate == null && downloadFailAfterBytes == null) {
      return super.download(
        path,
        pipeProbe == null ? destination : _CreditingSink(destination, pipeProbe!),
        onProgress: onProgress,
        cancellation: cancellation,
        computeHash: computeHash,
      );
    }
    // Scripted path: emit the file in small chunks, honoring the gate
    // and the cancellation token the way the real adapter does.
    final bytes = await File(path).readAsBytes();
    if (!downloadStarted.isCompleted) downloadStarted.complete();
    const step = 256;
    var sent = 0;
    for (var offset = 0; offset < bytes.length; offset += step) {
      if (cancellation?.isCancelled ?? false) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.cancelled,
          operation: 'download',
          path: path,
          message: 'Transfer cancelled.',
        );
      }
      if (downloadFailAfterBytes != null && sent >= downloadFailAfterBytes!) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.other,
          operation: 'download',
          path: path,
          message: 'injected mid-copy failure',
        );
      }
      final gate = downloadGate;
      if (gate != null) {
        // Wake on cancel so a parked read unwinds like the real
        // adapter's cancellation race.
        await Future.any([
          gate.future,
          if (cancellation != null) cancellation.whenCancelled,
        ]);
        if (cancellation?.isCancelled ?? false) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.cancelled,
            operation: 'download',
            path: path,
            message: 'Transfer cancelled.',
          );
        }
      }
      final end = offset + step > bytes.length ? bytes.length : offset + step;
      final chunk = bytes.sublist(offset, end);
      sent += chunk.length;
      pipeProbe?.sent(chunk.length);
      destination.add(chunk);
      onProgress?.call(sent, bytes.length);
    }
    // Return the same stat-backed entry shape the real adapter does —
    // verify-after-transfer must not be silently untested on the
    // scripted mid-stream paths.
    final stat = await FileStat.stat(path);
    return RemoteFileEntry(
      path: path,
      name: p.basename(path),
      type: RemoteFileType.file,
      size: bytes.length,
      accessedAt: stat.accessed.toUtc(),
      modifiedAt: stat.modified.toUtc(),
      mode: stat.mode,
      contentSha256: computeHash ? sha256.convert(bytes).toString() : null,
    );
  }

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) {
    uploadCalls++;
    final probe = pipeProbe;
    return super.upload(
      path,
      probe == null
          ? content
          : content.map((chunk) {
              probe.received(chunk.length);
              return chunk;
            }),
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    );
  }

  @override
  Future<void> delete(RemoteFileEntry entry) {
    deleteCalls++;
    operationLog.add('delete:${entry.path}');
    return super.delete(entry);
  }

  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) {
    setTimesCalls++;
    return super.setTimes(
      path,
      accessedAt: accessedAt,
      modifiedAt: modifiedAt,
    );
  }
}

/// A `StreamSink` wrapper that credits each produced chunk to a
/// [PipeProbe] before forwarding — the "sent" half of the bounded-pipe
/// measurement for the real LocalFileSystem adapter.
class _CreditingSink implements StreamSink<List<int>> {
  _CreditingSink(this._inner, this._probe);

  final StreamSink<List<int>> _inner;
  final PipeProbe _probe;

  @override
  void add(List<int> event) {
    _probe.sent(event.length);
    _inner.add(event);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(
    stream.map((chunk) {
      _probe.sent(chunk.length);
      return chunk;
    }),
  );

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}
