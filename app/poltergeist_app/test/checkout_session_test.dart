// M7's app seam proven at the composition boundary: startCheckoutSession
// boots the CheckoutManager over the app-support store, drives its bytes
// through the transfer-queue session's one composed queue (the same
// AppTransferQueue seam the activity panel mirrors), exposes the durable
// checkout state the future editor UI reads, and reconciles on resume.
// Remote verbs fail honestly through the local-only connection seam —
// typed `unsupported`, never a simulated success (STATUS item 23).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/checkout_session.dart';
import 'package:poltergeist_app/services/transfer_queue_session.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  late Directory tempDir;
  late Directory supportDir;
  late TransferQueueSession queueSession;
  final sessions = <CheckoutSession>[];

  RemoteFileEntry remoteEntry(String path, {int? size}) => RemoteFileEntry(
    path: path,
    name: path.split('/').last,
    type: RemoteFileType.file,
    size: size,
    mode: 0x180, // 0600
  );

  Future<CheckoutSession> boot() async {
    final session = await startCheckoutSession(
      supportDirectoryPath: supportDir.path,
      queue: queueSession.concreteQueue,
      connections: queueSession.connections,
    );
    expect(session, isNotNull);
    sessions.add(session!);
    return session;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('checkout_session');
    supportDir = Directory('${tempDir.path}/support');
    await supportDir.create(recursive: true);
    queueSession = (await startTransferQueue(
      supportDirectoryPath: supportDir.path,
    ))!;
  });

  tearDown(() async {
    for (final session in sessions) {
      await session.shutdown();
    }
    sessions.clear();
    await queueSession.dispose();
    await tempDir.delete(recursive: true);
  });

  /// Seeds one durable record + checkout file as a "previous process"
  /// would have left them, then releases the store lock so the session
  /// under test reopens it — the relaunch path, minus the process death.
  Future<ManagedRemoteFile> seedRecord({
    required String serverId,
    required String remotePath,
    required String content,
  }) async {
    final store = ManagedRemoteFileStore(
      indexFile: File('${supportDir.path}/managed_remote_files.json'),
      checkoutRoot: Directory('${supportDir.path}/checkouts'),
    );
    final localPath = store.checkoutPathFor(
      id: 'seed-1',
      fileName: remotePath.split('/').last,
    );
    await store.prepareCheckout(localPath);
    final file = await store.createCheckout(localPath);
    await file.writeAsString(content);
    await store.clearCheckoutInFlight(localPath);
    final record = ManagedRemoteFile(
      id: 'seed-1',
      serverId: serverId,
      editSessionId: serverId,
      remotePath: remotePath,
      localPath: localPath,
      remoteSnapshot: remoteEntry(
        remotePath,
        size: content.length,
      ).copyWithSha256(sha256.convert(utf8.encode(content)).toString()),
      baselineSha256: sha256.convert(utf8.encode(content)).toString(),
    );
    await store.put(record);
    await store.close();
    return record;
  }

  test('boots over the app-support store and exposes empty state', () async {
    final session = await boot();
    expect(session.copiesFor('server-a'), isEmpty);
    expect(session.checkoutFor('server-a', '/x'), isNull);
    expect(session.displacedFor('server-a'), isEmpty);
    expect(await session.recoveredCheckouts(), isEmpty);
  });

  test(
    'a checkout attempt enqueues on the composed queue — panel-visible '
    '— and fails honestly while remote endpoints are unavailable',
    () async {
      final session = await boot();
      final entry = remoteEntry('/home/test/notes.txt', size: 5);
      await expectLater(
        session.checkout(serverId: 'server-a', entry: entry),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.unsupported,
          ),
        ),
      );
      // The download hop rode the shared queue: the AppTransferQueue
      // seam the activity panel mirrors shows the managed task and its
      // honest terminal failure — never an invisible or wedged row.
      final tasks = queueSession.queue.tasks;
      expect(tasks, hasLength(1));
      final managed = tasks.single.spec.managedCheckout;
      expect(managed, isNotNull);
      expect(managed!.direction, ManagedCheckoutDirection.download);
      expect(managed.serverId, 'server-a');
      expect(managed.remotePath, '/home/test/notes.txt');
      expect(tasks.single.state, TransferTaskState.failed);
      // The failed checkout leaves no record and no plaintext behind.
      expect(session.copiesFor('server-a'), isEmpty);
      expect(
        await session.recoveredCheckouts(),
        isEmpty,
      );
    },
  );

  test(
    'a persisted record survives relaunch: exposed, watchable, '
    'reconciled dirty on edit',
    () async {
      final seeded = await seedRecord(
        serverId: 'server-a',
        remotePath: '/home/test/notes.txt',
        content: 'original',
      );
      final session = await boot();

      // Durable state is exposed to the future editor UI — and the
      // reconcile pass left it clean (baseline matches the file).
      final restored = session.checkoutFor('server-a', seeded.remotePath);
      expect(restored, isNotNull);
      expect(restored!.dirty, isFalse);
      // Round-trip of the seeded id; D17's derivation is covered in core.
      expect(restored.editSessionId, 'server-a');
      expect(session.localFile(restored).existsSync(), isTrue);

      // An edit the watcher may have missed still surfaces through the
      // explicit resume reconcile — and the session notifies listeners.
      var notified = 0;
      session.addListener(() => notified++);
      await File(session.localFile(restored).path).writeAsString('edited');
      await session.reconcileOnResume();
      // `changes` is a broadcast stream — its delivery lags the awaited
      // verb by a microtask, so pump before reading the flag.
      await pumpEventQueue();
      expect(notified, greaterThan(0));
      expect(
        session.checkoutFor('server-a', seeded.remotePath)!.dirty,
        isTrue,
      );
    },
  );

  test('discard removes the record and its plaintext', () async {
    final seeded = await seedRecord(
      serverId: 'server-a',
      remotePath: '/home/test/notes.txt',
      content: 'original',
    );
    final session = await boot();
    final record = session.checkoutFor('server-a', seeded.remotePath)!;
    final local = session.localFile(record);

    var notified = 0;
    session.addListener(() => notified++);
    await session.discard(record);
    await pumpEventQueue();

    expect(session.copiesFor('server-a'), isEmpty);
    expect(local.existsSync(), isFalse);
    expect(notified, greaterThan(0));
  });

  test(
    'uploadLocalCopy reaches the same unsupported refusal honestly '
    '(no silent upload, no fake lease)',
    () async {
      await seedRecord(
        serverId: 'server-a',
        remotePath: '/home/test/notes.txt',
        content: 'original',
      );
      final session = await boot();
      final record = session.checkoutFor('server-a', '/home/test/notes.txt')!;
      await expectLater(
        session.uploadLocalCopy(record),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.unsupported,
          ),
        ),
      );
      // The refused save must not disturb the local copy or its record.
      expect(session.checkoutFor('server-a', '/home/test/notes.txt'), isNotNull);
    },
  );

  test('shutdown is idempotent — repeat calls share one teardown', () async {
    final session = await boot();
    final first = session.shutdown();
    final second = session.shutdown();
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    // dispose joins the same teardown rather than double-closing.
    session.dispose();
    expect(identical(session.shutdown(), first), isTrue);
  });

  test('dispose drives teardown — the store lock is released', () async {
    final session = await boot();
    session.dispose();
    await session.shutdown(); // joins dispose's in-flight teardown
    final probe = ManagedRemoteFileStore(
      indexFile: File('${supportDir.path}/managed_remote_files.json'),
      checkoutRoot: Directory('${supportDir.path}/checkouts'),
    );
    expect(await probe.list(), isEmpty);
    await probe.close();
  });

  test('reconcileOnResume joins an in-flight pass', () async {
    await seedRecord(
      serverId: 'server-a',
      remotePath: '/home/test/notes.txt',
      content: 'original',
    );
    final session = await boot();
    final first = session.reconcileOnResume();
    final second = session.reconcileOnResume();
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    // Completed passes are cleared — the next resume reconciles anew.
    final third = session.reconcileOnResume();
    expect(identical(first, third), isFalse);
    await third;
  });

  test('a failed startup reports, returns null, and leaks no lock', () async {
    // A live peer holding the store lock forces the startup failure.
    final contender = ManagedRemoteFileStore(
      indexFile: File('${supportDir.path}/managed_remote_files.json'),
      checkoutRoot: Directory('${supportDir.path}/checkouts'),
    );
    await contender.list();
    final errors = <Object>[];
    final session = await startCheckoutSession(
      supportDirectoryPath: supportDir.path,
      queue: queueSession.concreteQueue,
      connections: queueSession.connections,
      onError: (error, _) => errors.add(error),
    );
    expect(session, isNull);
    expect(errors, isNotEmpty);
    // The failed store never held the lock — its close must not have
    // erased the contender's same-process registration.
    final third = ManagedRemoteFileStore(
      indexFile: File('${supportDir.path}/managed_remote_files.json'),
      checkoutRoot: Directory('${supportDir.path}/checkouts'),
    );
    await expectLater(
      third.list().timeout(const Duration(seconds: 10)),
      throwsA(isA<FileSystemException>()),
    );
    await third.close();
    await contender.close();
    // Once the peer releases, the same path boots clean.
    final recovered = await startCheckoutSession(
      supportDirectoryPath: supportDir.path,
      queue: queueSession.concreteQueue,
      connections: queueSession.connections,
    );
    expect(recovered, isNotNull);
    sessions.add(recovered!);
  });
}

extension on RemoteFileEntry {
  RemoteFileEntry copyWithSha256(String digest) => RemoteFileEntry(
    path: path,
    name: name,
    type: type,
    size: size,
    uid: uid,
    gid: gid,
    accessedAt: accessedAt,
    modifiedAt: modifiedAt,
    mode: mode,
    contentSha256: digest,
  );
}
