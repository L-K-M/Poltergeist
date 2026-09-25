// Contract tests for the M7 CheckoutManager
// (packages/poltergeist_core/lib/src/checkout/checkout_manager.dart) —
// the 06 §3 pipeline: durable checkout download, parent-directory
// watching, resume/relaunch reconciliation, CAS-guarded upload-on-save,
// rename migration, and queue/activity visibility.
//
// No sockets: remote endpoints are FakeTreeFileSystems behind a
// FakeQueueConnectionManager; the queue is the production
// TransferQueue so managed tasks exercise the real journaled dispatch
// path (03 §4.7). Watchers are injected broadcast streams — no reliance
// on platform FSEvents/inotify timing; the debounce timer is real but
// shrunk to 10 ms.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import '../transfer/transfer_fakes.dart';

void main() {
  late Directory tempDir;
  late File indexFile;
  late Directory checkoutRoot;
  late ManagedRemoteFileStore store;
  late FakeTreeFileSystem s1;
  late FakeQueueConnectionManager connections;
  late TransferQueue queue;
  late CheckoutManager manager;
  late List<TransferQueueEvent> queueEvents;
  late List<Object> errors;
  late Map<String, StreamController<FileSystemEvent>> watchStreams;

  final createdStores = <ManagedRemoteFileStore>[];
  final createdQueues = <TransferQueue>[];
  final createdManagers = <CheckoutManager>[];

  ManagedRemoteFileStore newStore() {
    final created = ManagedRemoteFileStore(
      indexFile: indexFile,
      checkoutRoot: checkoutRoot,
    );
    createdStores.add(created);
    return created;
  }

  TransferQueue newQueue() {
    final created = TransferQueue(connections: connections);
    createdQueues.add(created);
    return created;
  }

  Stream<FileSystemEvent> fakeWatch(String directoryPath) => watchStreams
      .putIfAbsent(
        directoryPath,
        () => StreamController<FileSystemEvent>.broadcast(),
      )
      .stream;

  CheckoutManager newManager({
    Duration watchDebounce = const Duration(milliseconds: 10),
    Duration watchReconcileMaxDelay = const Duration(seconds: 10),
    Future<int?> Function(String path)? freeSpaceBytes,
  }) {
    final created = CheckoutManager(
      store: store,
      connections: connections,
      queue: queue,
      watchDirectory: fakeWatch,
      watchDebounce: watchDebounce,
      watchReconcileMaxDelay: watchReconcileMaxDelay,
      freeSpaceBytes: freeSpaceBytes,
      onError: (error, stack) => errors.add(error),
    );
    createdManagers.add(created);
    return created;
  }

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('poltergeist-cm-');
    tempDir = Directory(temp.resolveSymbolicLinksSync());
    indexFile = File('${tempDir.path}/state/managed-files.json');
    checkoutRoot = Directory('${tempDir.path}/support/checkouts');
    store = newStore();
    s1 = FakeTreeFileSystem()
      ..addFile(
        '/home/test/file.txt',
        utf8.encode('remote contents'),
        modifiedAt: DateTime.utc(2026, 7, 10, 12),
        mode: 0x1a4,
      );
    connections = FakeQueueConnectionManager({'s1': s1});
    queue = newQueue();
    queueEvents = [];
    queue.events.listen(queueEvents.add);
    errors = [];
    watchStreams = {};
    manager = newManager();
    await manager.start();
  });

  tearDown(() async {
    for (final created in createdManagers) {
      try {
        await created.dispose();
      } catch (_) {
        // Best-effort teardown.
      }
    }
    createdManagers.clear();
    for (final created in createdQueues) {
      try {
        await created.dispose();
      } catch (_) {
        // Best-effort teardown.
      }
    }
    createdQueues.clear();
    for (final created in createdStores) {
      try {
        await created.close();
      } catch (_) {
        // Best-effort teardown.
      }
    }
    createdStores.clear();
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Best-effort teardown.
    }
  });

  Future<RemoteFileEntry> remoteStat(String path) =>
      s1.stat(path, followLinks: false);

  /// Waits out the debounce and lets the reconcile chain settle.
  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await pump();
  }

  /// Fires a watch event in the record's parent directory.
  void emitWatchEvent(ManagedRemoteFile record, String name) {
    final dir = manager.localFile(record).parent.path;
    watchStreams[dir]!.add(FileSystemModifyEvent('$dir/$name', false, true));
  }

  String basenameOf(ManagedRemoteFile record) =>
      record.localPath.split(RegExp(r'[\\/]')).last;

  group('checkout', () {
    test('downloads through the queue into a durable, hashed record', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);

      final local = manager.localFile(record);
      expect(await local.readAsString(), 'remote contents');
      expect(record.serverId, 's1');
      // editSessionId is the per-server identity — never a pane/tab id.
      expect(record.editSessionId, 's1');
      expect(record.remotePath, '/home/test/file.txt');
      final digest = sha256.convert(utf8.encode('remote contents')).toString();
      expect(record.baselineSha256, digest);
      expect(record.remoteSnapshot.contentSha256, digest);
      expect(record.remoteSnapshot.size, entry.size);
      expect(record.dirty, isFalse);
      expect(record.missing, isFalse);
      expect(record.needsReconcile, isFalse);
      if (!Platform.isWindows) {
        expect((await local.stat()).modeString(), 'rw-------');
      }

      // The hop rode the shared queue — visible to the activity panel.
      final task = queue.tasks.single;
      expect(task.spec.managedCheckout, isNotNull);
      expect(
        task.spec.managedCheckout!.direction,
        ManagedCheckoutDirection.download,
      );
      expect(task.state, TransferTaskState.completed);
      expect(queueEvents.whereType<TransferQueueItemEvent>(), isNotEmpty);
    });

    test(
      'a second checkout of the same path dedupes onto the record',
      () async {
        final entry = await remoteStat('/home/test/file.txt');
        final first = await manager.checkout(serverId: 's1', entry: entry);
        final second = await manager.checkout(serverId: 's1', entry: entry);
        expect(identical(first, second) || first.id == second.id, isTrue);
        expect(queue.tasks, hasLength(1));
      },
    );

    test('a non-file entry is refused', () async {
      await s1.createDirectory('/home/test/dir');
      final dir = await s1.stat('/home/test/dir');
      await expectLater(
        manager.checkout(serverId: 's1', entry: dir),
        throwsStateError,
      );
    });

    test('the byte limit is enforced before and after download', () async {
      final entry = await remoteStat('/home/test/file.txt');
      await expectLater(
        manager.checkout(serverId: 's1', entry: entry, maximumBytes: 4),
        throwsA(
          isA<CheckoutLimitException>().having(
            (error) => error.toString(),
            'message',
            'The file is larger than the 4-byte editor limit.',
          ),
        ),
      );
      // Remote entries that report no size are caught mid-download by
      // the stream cap, or on the post-download length check.
      s1.addFile('/home/test/big.txt', List.filled(64, 0x61));
      final big = await remoteStat('/home/test/big.txt');
      final understated = RemoteFileEntry(
        path: big.path,
        name: big.name,
        type: big.type,
        modifiedAt: big.modifiedAt,
      );
      await expectLater(
        manager.checkout(serverId: 's1', entry: understated, maximumBytes: 16),
        throwsA(
          isA<CheckoutLimitException>().having(
            (error) => error.toString(),
            'message',
            'The file is larger than the 16-byte editor limit.',
          ),
        ),
      );
      // The refused download left no record or partial file behind.
      expect(manager.copiesFor('s1'), isEmpty);
    });

    test(
      'the free-space preflight refuses a checkout that cannot fit',
      () async {
        final tight = newManager(freeSpaceBytes: (_) async => 4);
        await tight.start();
        final entry = await remoteStat('/home/test/file.txt');
        await expectLater(
          tight.checkout(serverId: 's1', entry: entry),
          throwsA(
            isA<RemoteFileException>().having(
              (e) => e.operation,
              'operation',
              'checkout',
            ),
          ),
        );
      },
    );
  });

  group('watching and reconciliation', () {
    test('a local edit marks the record dirty after the debounce', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);

      await manager.localFile(record).writeAsString('edited');
      // Wait for the reconcile's own change rather than a fixed delay: the
      // reconcile hashes the file for real, and a slow runner (Windows CI)
      // can outlast settle()'s 40 ms.
      final reconciled = manager.changes.firstWhere(
        (_) => manager.copiesFor('s1')[record.remotePath]?.dirty ?? false,
      );
      emitWatchEvent(record, basenameOf(record));
      await reconciled.timeout(const Duration(seconds: 10));

      final updated = manager.copiesFor('s1')[record.remotePath]!;
      expect(updated.dirty, isTrue);
      expect(updated.missing, isFalse);
    });

    test('a burst of sibling events coalesces into one reconcile', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      var changes = 0;
      final sub = manager.changes.listen((_) => changes++);
      // The reconcile's own change, not a fixed delay: it hashes the file
      // for real, and a loaded runner (macOS CI) can outlast settle().
      final reconciled = manager.changes.first;

      for (var i = 0; i < 5; i++) {
        emitWatchEvent(record, basenameOf(record));
      }
      await reconciled.timeout(const Duration(seconds: 10));
      // One more debounce, so a second reconcile would still be counted.
      await settle();
      expect(changes, 1);
      await sub.cancel();
    });

    test(
      'generated temp and marker events are filtered; payload events pass',
      () async {
        final entry = await remoteStat('/home/test/file.txt');
        final record = await manager.checkout(serverId: 's1', entry: entry);
        var changes = 0;
        final sub = manager.changes.listen((_) => changes++);
        final dir = manager.localFile(record).parent.path;
        void fire(String name) => watchStreams[dir]!.add(
          FileSystemModifyEvent('$dir/$name', false, true),
        );

        fire('x.poltergeist-abcdef12.upload');
        fire('.poltergeist-abcdef12.tmp');
        fire('x.poltergeist-12345678-1234-1234-1234-123456789abc.edit');
        fire(ManagedRemoteFileStore.epochMarkerName);
        fire(ManagedRemoteFileStore.abandonedMarkerName);
        await settle();
        expect(changes, 0);

        // As above: wait for the reconcile itself, then one debounce more.
        final reconciled = manager.changes.first;
        fire('unrelated-sibling.txt');
        await reconciled.timeout(const Duration(seconds: 10));
        await settle();
        expect(changes, 1);
        await sub.cancel();
      },
    );

    test('the per-copy reconcile rehashes on demand — the editor '
        'onSaved hook', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      await manager.localFile(record).writeAsString('saved edit');

      // No watch event, no debounce wait — 06 §2.3's onSaved seam
      // drives the rehash directly and never throws.
      await manager.reconcile(record);
      await pump();

      final updated = manager.copiesFor('s1')[record.remotePath]!;
      expect(updated.dirty, isTrue);
      expect(errors, isEmpty);
    });

    test('the per-copy reconcile never throws on a vanished record', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      await store.remove(record.id);

      await manager.reconcile(record);
      await pump();

      expect(errors, isEmpty);
    });

    test('reconcileOnResume catches edits the watcher missed', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      await manager.localFile(record).writeAsString('silent edit');

      await manager.reconcileOnResume();
      expect(manager.copiesFor('s1')[record.remotePath]!.dirty, isTrue);

      await manager.localFile(record).delete();
      await manager.reconcileOnResume();
      final updated = manager.copiesFor('s1')[record.remotePath]!;
      expect(updated.missing, isTrue);
      expect(updated.dirty, isFalse);
    });

    test('records survive a manager relaunch with reconciled state', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      final localPath = manager.localFile(record).path;

      // Simulate process death: drop the manager and the store, edit the
      // payload, then boot a fresh pair over the same index.
      await manager.dispose();
      await store.close();
      store = newStore();
      await File(localPath).writeAsString('edited while dead');

      final revived = newManager();
      await revived.start();
      await pump();

      final restored = revived.copiesFor('s1')[record.remotePath];
      expect(restored, isNotNull);
      expect(restored!.dirty, isTrue);
      expect(restored.localPath, record.localPath);
      expect(restored.editSessionId, 's1');
    });

    test('a checkout file deleted while dead restores as missing', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      final localPath = manager.localFile(record).path;

      await manager.dispose();
      await store.close();
      store = newStore();
      await File(localPath).delete();

      final revived = newManager();
      await revived.start();
      await pump();
      expect(revived.copiesFor('s1')[record.remotePath]!.missing, isTrue);
    });
  });

  group('upload-on-save', () {
    Future<ManagedRemoteFile> checkedOut() async {
      final entry = await remoteStat('/home/test/file.txt');
      return manager.checkout(serverId: 's1', entry: entry);
    }

    test('saves through the queue under CAS and re-baselines', () async {
      final record = await checkedOut();
      await manager.localFile(record).writeAsString('saved edit');

      expect(await manager.uploadLocalCopy(record), isTrue);

      expect(utf8.decode(s1.fileBytes['/home/test/file.txt']!), 'saved edit');
      final updated = manager.copiesFor('s1')[record.remotePath]!;
      expect(updated.dirty, isFalse);
      final digest = sha256.convert(utf8.encode('saved edit')).toString();
      expect(updated.baselineSha256, digest);
      expect(updated.remoteSnapshot.contentSha256, digest);
      // preserveMode re-applies the recorded remote mode.
      expect(s1.modes['/home/test/file.txt'], 0x1a4);

      final task = queue.tasks.last;
      expect(
        task.spec.managedCheckout!.direction,
        ManagedCheckoutDirection.upload,
      );
      expect(task.spec.managedCheckout!.expectedTarget, isNotNull);
      expect(task.state, TransferTaskState.completed);
    });

    test(
      'a remote change blocks the save and preserves local content',
      () async {
        final record = await checkedOut();
        await manager.localFile(record).writeAsString('saved edit');
        s1.addFile(
          '/home/test/file.txt',
          utf8.encode('someone else wrote this'),
        );

        await expectLater(
          manager.uploadLocalCopy(record),
          throwsA(
            isA<RemoteFileException>().having(
              (e) => e.kind,
              'kind',
              RemoteFileErrorKind.conflict,
            ),
          ),
        );
        // Remote untouched; local dirty copy preserved for resolution.
        expect(
          utf8.decode(s1.fileBytes['/home/test/file.txt']!),
          'someone else wrote this',
        );
        expect(await manager.localFile(record).readAsString(), 'saved edit');
        // The preflight stat already proved divergence — no upload ever
        // reached the fake, no upload task was enqueued.
        expect(s1.uploadCalls, 0);
        expect(
          queue.tasks.where(
            (t) =>
                t.spec.managedCheckout?.direction ==
                ManagedCheckoutDirection.upload,
          ),
          isEmpty,
        );
      },
    );

    test(
      'D7: a same-size same-mtime tamper still conflicts on the digest',
      () async {
        final record = await checkedOut();
        await manager.localFile(record).writeAsString('saved edit!');
        // Same byte length ('remote contents' is 15 bytes) and the same
        // mtime — metadata identical, content different.
        s1.addFile(
          '/home/test/file.txt',
          utf8.encode('tampered same!!'),
          modifiedAt: DateTime.utc(2026, 7, 10, 12),
          mode: 0x1a4,
        );
        final latest = await remoteStat('/home/test/file.txt');
        expect(latest.size, record.remoteSnapshot.size);
        expect(latest.modifiedAt, record.remoteSnapshot.modifiedAt);

        await expectLater(
          manager.uploadLocalCopy(record),
          throwsA(
            isA<RemoteFileException>().having(
              (e) => e.kind,
              'kind',
              RemoteFileErrorKind.conflict,
            ),
          ),
        );
        expect(
          utf8.decode(s1.fileBytes['/home/test/file.txt']!),
          'tampered same!!',
        );
      },
    );

    test('a remote deletion blocks the save', () async {
      final record = await checkedOut();
      await manager.localFile(record).writeAsString('saved edit');
      await s1.delete(await remoteStat('/home/test/file.txt'));

      await expectLater(
        manager.uploadLocalCopy(record),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
    });

    test('overwriteRemoteChanges drops the CAS and lands the save', () async {
      final record = await checkedOut();
      await manager.localFile(record).writeAsString('forced save');
      s1.addFile('/home/test/file.txt', utf8.encode('remote churn'));

      expect(
        await manager.uploadLocalCopy(record, overwriteRemoteChanges: true),
        isTrue,
      );
      expect(utf8.decode(s1.fileBytes['/home/test/file.txt']!), 'forced save');
      // The overwrite hop carried no expectedTarget.
      expect(queue.tasks.last.spec.managedCheckout!.expectedTarget, isNull);
    });

    test(
      'concurrent saves of one record share a single upload flight',
      () async {
        final record = await checkedOut();
        await manager.localFile(record).writeAsString('saved edit');
        final first = manager.uploadLocalCopy(record);
        final second = manager.uploadLocalCopy(record);
        // Same conflict semantics coalesce onto the one in-flight save —
        // the futures are distinct wrappers over the shared flight.
        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(
          queue.tasks
              .where(
                (t) =>
                    t.spec.managedCheckout?.direction ==
                    ManagedCheckoutDirection.upload,
              )
              .length,
          1,
        );
      },
    );

    test(
      'a degraded snapshot repairs remotely and clears needsReconcile',
      () async {
        final record = await checkedOut();
        // Force only the post-upload stat to fail → synthesized snapshot
        // + needsReconcile mark (the preflight still sees reality).
        var failStats = true;
        s1.statFailure = (path) => failStats && s1.uploadCalls > 0
            ? RemoteFileException(
                kind: RemoteFileErrorKind.other,
                operation: 'stat',
                path: path,
                message: 'stat exploded',
              )
            : null;
        await manager.localFile(record).writeAsString('saved edit');
        expect(await manager.uploadLocalCopy(record), isTrue);
        final degraded = manager.copiesFor('s1')[record.remotePath]!;
        expect(degraded.needsReconcile, isTrue);
        // The synthesized digest is the uploaded content's.
        expect(
          degraded.remoteSnapshot.contentSha256,
          sha256.convert(utf8.encode('saved edit')).toString(),
        );

        failStats = false;
        await manager.reconcileOnResume();
        final repaired = manager.copiesFor('s1')[record.remotePath]!;
        expect(repaired.needsReconcile, isFalse);
      },
    );

    test('a needsReconcile record whose remote moved stays marked', () async {
      final record = await checkedOut();
      var failStats = true;
      s1.statFailure = (path) => failStats && s1.uploadCalls > 0
          ? RemoteFileException(
              kind: RemoteFileErrorKind.other,
              operation: 'stat',
              path: path,
              message: 'stat exploded',
            )
          : null;
      await manager.localFile(record).writeAsString('saved edit');
      await manager.uploadLocalCopy(record);
      failStats = false;
      // Remote diverged from the synthesized snapshot's digest.
      s1.addFile('/home/test/file.txt', utf8.encode('remote churn again'));

      await manager.reconcileOnResume();
      expect(
        manager.copiesFor('s1')[record.remotePath]!.needsReconcile,
        isTrue,
      );
    });
  });

  group('rename migration', () {
    test('a remote rename re-keys the record and the save target', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      await s1.rename('/home/test/file.txt', '/home/test/renamed.txt');
      await manager.migrateRename(
        serverId: 's1',
        oldPath: '/home/test/file.txt',
        newPath: '/home/test/renamed.txt',
      );

      expect(manager.checkoutFor('s1', '/home/test/file.txt'), isNull);
      final moved = manager.checkoutFor('s1', '/home/test/renamed.txt')!;
      expect(moved.id, record.id);
      expect(moved.remoteSnapshot.path, '/home/test/renamed.txt');
      // The local checkout file did not move.
      expect(manager.localFile(moved).path, manager.localFile(record).path);

      await manager.localFile(moved).writeAsString('post-rename save');
      expect(await manager.uploadLocalCopy(moved), isTrue);
      expect(
        utf8.decode(s1.fileBytes['/home/test/renamed.txt']!),
        'post-rename save',
      );
    });

    test('a directory rename re-keys descendants prefix-wise', () async {
      s1.addFile('/dir/sub/leaf.txt', utf8.encode('leaf bytes'));
      final entry = await remoteStat('/dir/sub/leaf.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      await s1.rename('/dir', '/dir2');
      await manager.migrateRename(
        serverId: 's1',
        oldPath: '/dir',
        newPath: '/dir2',
      );
      expect(manager.checkoutFor('s1', '/dir2/sub/leaf.txt')!.id, record.id);
    });

    test('an arrival onto an occupied path displaces the occupant', () async {
      final entryA = await remoteStat('/home/test/file.txt');
      s1.addFile('/home/test/other.txt', utf8.encode('other bytes'));
      final entryB = await remoteStat('/home/test/other.txt');
      final recordA = await manager.checkout(serverId: 's1', entry: entryA);
      final recordB = await manager.checkout(serverId: 's1', entry: entryB);

      await s1.rename(
        '/home/test/other.txt',
        '/home/test/file.txt',
        overwrite: true,
      );
      await manager.migrateRename(
        serverId: 's1',
        oldPath: '/home/test/other.txt',
        newPath: '/home/test/file.txt',
      );

      // The arrival takes the live slot; the prior occupant is
      // displaced, not overwritten.
      final live = manager.checkoutFor('s1', '/home/test/file.txt')!;
      expect(live.id, recordB.id);
      final displaced = manager.displacedFor('s1');
      expect(displaced.single.id, recordA.id);
      expect(displaced.single.remotePath, '/home/test/file.txt');
      // Both payloads survive on disk.
      expect(await manager.localFile(recordA).exists(), isTrue);
      expect(await manager.localFile(recordB).exists(), isTrue);
    });
  });

  group('discard and recovery', () {
    test('discard deletes the checkout and the record', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      final local = manager.localFile(record);

      await manager.discard(record);
      expect(manager.copiesFor('s1'), isEmpty);
      expect(await local.exists(), isFalse);
      expect(await store.get(record.id), isNull);
    });

    test('acceptLocalCopy re-baselines a dirty checkout', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      await manager.localFile(record).writeAsString('accepted');
      await manager.reconcileOnResume();
      expect(manager.copiesFor('s1')[record.remotePath]!.dirty, isTrue);

      await manager.acceptLocalCopy(record);
      final updated = manager.copiesFor('s1')[record.remotePath]!;
      expect(updated.dirty, isFalse);
      expect(
        updated.baselineSha256,
        sha256.convert(utf8.encode('accepted')).toString(),
      );
    });

    test('recovered recordless payloads list and forget explicitly', () async {
      // A payload-bearing dir the index never recorded — preserved by
      // the sweep, surfaced for explicit review.
      final orphan = Directory('${checkoutRoot.path}/orphan-dir');
      await orphan.create(recursive: true);
      await File('${orphan.path}/stray.txt').writeAsString('stray');

      final recovered = await manager.recoveredCheckouts();
      expect(recovered.single.directory, 'orphan-dir');
      expect(recovered.single.files, contains('stray.txt'));

      await manager.forgetRecovered(recovered.single);
      expect(await orphan.exists(), isFalse);
      expect(await manager.recoveredCheckouts(), isEmpty);
    });
  });

  group('lifecycle', () {
    test('dispose fails a pending managed transfer', () async {
      // Gate the fake's download so the checkout task parks mid-hop.
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;
      final entry = await remoteStat('/home/test/file.txt');
      final pending = manager.checkout(serverId: 's1', entry: entry);
      await pump();

      await manager.dispose();
      await expectLater(
        pending,
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.cancelled,
          ),
        ),
      );
      gate.complete();
      await pump();
    });

    test('post-dispose calls are inert', () async {
      await manager.dispose();
      await manager.reconcileOnResume(); // no-op, no throw
      expect(errors, isEmpty);
    });

    test('dispose fails every waiter coalesced onto a flight', () async {
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;
      final entry = await remoteStat('/home/test/file.txt');
      final first = manager.checkout(serverId: 's1', entry: entry);
      await pump();
      // The dedupe path returns the flight's completer future — it must
      // fail on dispose exactly like the driving call does.
      final second = manager.checkout(serverId: 's1', entry: entry);
      await pump();

      await manager.dispose();
      for (final future in [first, second]) {
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
      }
      gate.complete();
      await pump();
    });
  });

  group('review hardening', () {
    test('a mid-flight rename cannot leak or evict flight entries', () async {
      s1.addFile('/a/f.txt', utf8.encode('aaa'));
      final entry = await remoteStat('/a/f.txt');
      final gateA = Completer<void>();
      s1.downloadGate = (path) => path == '/a/f.txt' ? gateA : null;
      final futureA = manager.checkout(serverId: 's1', entry: entry);
      await pumpUntil(
        () => s1.downloadCalls > 0,
        reason: 'first download never reached the gate',
      );

      // Re-key the in-flight flight, then let a second checkout
      // reoccupy the original key.
      await manager.migrateRename(
        serverId: 's1',
        oldPath: '/a/f.txt',
        newPath: '/b/f.txt',
      );
      final gateB = Completer<void>();
      s1.downloadGate = (path) => path == '/a/f.txt' ? gateB : null;
      final futureB = manager.checkout(serverId: 's1', entry: entry);
      await pumpUntil(
        () => s1.downloadCalls > 1,
        reason: 'second download never reached the gate',
      );

      // A's completion must not evict B's reoccupied flight entry —
      // a third checkout of the path dedupes onto B, never forks.
      gateA.complete();
      await futureA;
      final futureC = manager.checkout(serverId: 's1', entry: entry);
      gateB.complete();
      final recordB = await futureB;
      expect(identical(await futureC, recordB), isTrue);
      expect(s1.downloadCalls, 2);
    });

    test('a rename onto an in-flight checkout bridges its waiters', () async {
      s1.addFile('/x.txt', utf8.encode('x-content'));
      s1.addFile('/y.txt', utf8.encode('y-content'));
      final gateX = Completer<void>();
      final gateY = Completer<void>();
      s1.downloadGate = (path) => path == '/x.txt'
          ? gateX
          : path == '/y.txt'
          ? gateY
          : null;
      final futureX = manager.checkout(
        serverId: 's1',
        entry: await remoteStat('/x.txt'),
      );
      final futureY = manager.checkout(
        serverId: 's1',
        entry: await remoteStat('/y.txt'),
      );
      await pumpUntil(
        () => s1.downloadCalls > 1,
        reason: 'both downloads never reached their gates',
      );

      // Y's flight re-keys onto X's occupied destination — it must not
      // evict X's entry, and its later dedupe waiters ride X's flight.
      await manager.migrateRename(
        serverId: 's1',
        oldPath: '/y.txt',
        newPath: '/x.txt',
      );
      final futureZ = manager.checkout(
        serverId: 's1',
        entry: await remoteStat('/x.txt'),
      );
      gateX.complete();
      gateY.complete();
      final recordX = await futureX;
      expect(identical(await futureZ, recordX), isTrue);
      expect(await futureY, isNotNull);
      expect(s1.downloadCalls, 2);
    });

    test('a post-commit refresh lease failure degrades instead of failing '
        'a committed save', () async {
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      await manager.localFile(record).writeAsString('saved edit');
      // The preflight and pipe leases still succeed — only the
      // post-commit refresh's acquisition fails.
      connections.leaseFailure = (serverId) => s1.uploadCalls > 0
          ? RemoteFileException(
              kind: RemoteFileErrorKind.disconnected,
              operation: 'lease transfer channel',
              message: 'server dropped',
            )
          : null;

      expect(await manager.uploadLocalCopy(record), isTrue);
      final updated = manager.copiesFor('s1')[record.remotePath]!;
      expect(updated.needsReconcile, isTrue);
      expect(
        updated.remoteSnapshot.contentSha256,
        sha256.convert(utf8.encode('saved edit')).toString(),
      );
    });

    test('snapshot cleanup failure never masks the save result', () async {
      if (Platform.isWindows) return; // POSIX permission bits only
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      await manager.localFile(record).writeAsString('saved edit');
      final dir = manager.localFile(record).parent;
      final gate = Completer<void>();
      s1.uploadGate = (_) => gate;
      final save = manager.uploadLocalCopy(record);
      await pumpUntil(
        () => s1.uploadCalls > 0,
        reason: 'upload never reached the gate',
      );
      // The .upload snapshot already exists; a delete failure in the
      // finally must report, never replace, the save's true result.
      await Process.run('chmod', ['500', dir.path]);
      gate.complete();
      expect(await save, isTrue);
      expect(errors, isNotEmpty);
      await Process.run('chmod', ['700', dir.path]);
    });

    test('a conflict still reaches the caller when cleanup fails', () async {
      if (Platform.isWindows) return;
      final entry = await remoteStat('/home/test/file.txt');
      final record = await manager.checkout(serverId: 's1', entry: entry);
      await manager.localFile(record).writeAsString('saved edit');
      s1.addFile('/home/test/file.txt', utf8.encode('remote churn'));
      final dir = manager.localFile(record).parent;
      // Park the preflight stat, then make the snapshot dir unwritable —
      // the finally cleanup fails while the conflict is in flight. The
      // baseline count skips stats the checkout itself already made.
      final baselineStats = s1.statCalls;
      final gate = Completer<void>();
      s1.statGate = (path) => path == record.remotePath ? gate : null;
      final save = manager.uploadLocalCopy(record);
      await pumpUntil(
        () => s1.statCalls > baselineStats,
        reason: 'preflight stat never reached the gate',
      );
      await Process.run('chmod', ['500', dir.path]);
      gate.complete();
      await expectLater(
        save,
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
      expect(errors, isNotEmpty);
      await Process.run('chmod', ['700', dir.path]);
    });

    test('a task evicted before its terminal event fails the waiter', () async {
      // A probe subscribed before the manager's: the panel's
      // clear-finished gesture can drop a terminal task before the
      // manager's listener sees the event — the waiter must fail,
      // never hang.
      queue = newQueue();
      queue.events.listen((event) {
        if (event is TransferQueueTaskEvent && _isTerminalTask(event)) {
          queue.removeTask(event.taskId);
        }
      });
      manager = newManager();
      await manager.start();
      final entry = await remoteStat('/home/test/file.txt');
      await expectLater(
        manager.checkout(serverId: 's1', entry: entry),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.message,
            'message',
            contains('no longer tracked'),
          ),
        ),
      );
    });

    test(
      'a mismatched overwrite flag serializes instead of coalescing',
      () async {
        final entry = await remoteStat('/home/test/file.txt');
        final record = await manager.checkout(serverId: 's1', entry: entry);
        await manager.localFile(record).writeAsString('v1');
        final gate = Completer<void>();
        s1.uploadGate = (_) => gate;
        final casSave = manager.uploadLocalCopy(record);
        await pumpUntil(
          () => s1.uploadCalls > 0,
          reason: 'first upload never reached the gate',
        );

        // A different conflict policy must not ride the in-flight CAS
        // upload — it serializes behind it and runs its own save.
        final overwriteSave = manager.uploadLocalCopy(
          record,
          overwriteRemoteChanges: true,
        );
        gate.complete();
        expect(await casSave, isTrue);
        s1.addFile('/home/test/file.txt', utf8.encode('remote churn'));
        expect(await overwriteSave, isTrue);
        expect(s1.uploadCalls, 2);
        expect(utf8.decode(s1.fileBytes['/home/test/file.txt']!), 'v1');
      },
    );

    test(
      'two mismatched waiters coalesce onto one serialized flight',
      () async {
        final entry = await remoteStat('/home/test/file.txt');
        final record = await manager.checkout(serverId: 's1', entry: entry);
        await manager.localFile(record).writeAsString('v1');
        final gate1 = Completer<void>();
        final gate2 = Completer<void>();
        var useSecondGate = false;
        s1.uploadGate = (_) => useSecondGate ? gate2 : gate1;
        final casSave = manager.uploadLocalCopy(record);
        await pumpUntil(
          () => s1.uploadCalls > 0,
          reason: 'first upload never reached the gate',
        );

        // Both overwrite saves sleep on the CAS flight; when it lands,
        // the second waiter must find the first waiter's flight in the
        // map — never fork a duplicate upload of the same record.
        final waitA = manager.uploadLocalCopy(
          record,
          overwriteRemoteChanges: true,
        );
        final waitB = manager.uploadLocalCopy(
          record,
          overwriteRemoteChanges: true,
        );
        useSecondGate = true;
        gate1.complete();
        expect(await casSave, isTrue);
        await pumpUntil(
          () => s1.uploadCalls > 1,
          reason: 'serialized upload never reached the second gate',
        );
        gate2.complete();
        expect(await waitA, isTrue);
        expect(await waitB, isTrue);
        expect(s1.uploadCalls, 2);
      },
    );

    test('continuous sibling noise cannot starve reconciliation', () async {
      final throttled = newManager(
        watchDebounce: const Duration(milliseconds: 80),
        watchReconcileMaxDelay: const Duration(milliseconds: 150),
      );
      await throttled.start();
      final entry = await remoteStat('/home/test/file.txt');
      final record = await throttled.checkout(serverId: 's1', entry: entry);
      await throttled.localFile(record).writeAsString('edited');
      final dir = throttled.localFile(record).parent.path;

      // Events faster than the debounce would postpone a pure debounce
      // forever — the deadline must still force a reconcile through.
      var dirty = false;
      for (var i = 0; i < 40 && !dirty; i++) {
        watchStreams[dir]!.add(
          FileSystemModifyEvent('$dir/noise.txt', false, true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        dirty = throttled.copiesFor('s1')[record.remotePath]!.dirty;
      }
      expect(dirty, isTrue);
    });
  });
}

bool _isTerminalTask(TransferQueueTaskEvent event) =>
    event.state == TransferTaskState.completed ||
    event.state == TransferTaskState.failed ||
    event.state == TransferTaskState.cancelled;
