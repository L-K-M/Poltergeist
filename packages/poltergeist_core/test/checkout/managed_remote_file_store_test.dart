import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

// Ported from Séance
// app/seance_app/test/managed_remote_file_store_test.dart @ 2e6d1f1
// extended for the Poltergeist lifecycle rails (epoch markers, the
// abandoned-marker sweep, recovered listings, the store lock, and the
// persisted needsReconcile/displaced fields); see docs/PORTS.md.

void main() {
  late Directory temporaryDirectory;
  late File indexFile;
  late Directory checkoutRoot;
  late ManagedRemoteFileStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist-managed-files-',
    );
    indexFile = File('${temporaryDirectory.path}/state/managed-files.json');
    checkoutRoot = Directory('${temporaryDirectory.path}/support/checkouts');
    store = ManagedRemoteFileStore(
      indexFile: indexFile,
      checkoutRoot: checkoutRoot,
    );
  });

  tearDown(() async {
    await store.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  Future<ManagedRemoteFileStore> reopened() async {
    await store.close();
    return store = ManagedRemoteFileStore(
      indexFile: indexFile,
      checkoutRoot: checkoutRoot,
    );
  }

  test('model JSON round-trips metadata but not runtime state', () {
    final original = _managedFile(
      id: 'edit-1',
      localPath: 'checkout/file.txt',
      dirty: true,
    );

    final json = original.toJson();
    expect(json, isNot(contains('dirty')));
    expect(json, isNot(contains('missing')));

    final restored = ManagedRemoteFile.fromJson(json);
    expect(restored.id, original.id);
    expect(restored.serverId, original.serverId);
    expect(restored.editSessionId, original.editSessionId);
    expect(restored.remotePath, original.remotePath);
    expect(restored.localPath, original.localPath);
    expect(restored.baselineSha256, original.baselineSha256);
    expect(restored.remoteSnapshot.name, 'file.txt');
    expect(restored.remoteSnapshot.type, RemoteFileType.file);
    expect(restored.remoteSnapshot.size, 3);
    expect(restored.remoteSnapshot.mode, 0x81a4);
    expect(
      restored.remoteSnapshot.modifiedAt,
      DateTime.utc(2026, 7, 10, 12, 30),
    );
    expect(restored.dirty, isFalse);
    expect(restored.missing, isFalse);
    expect(restored.needsReconcile, isFalse);
    expect(restored.displaced, isFalse);
  });

  test('needsReconcile and displaced persist through JSON', () {
    final original = _managedFile(
      id: 'edit-1',
      localPath: 'checkout/file.txt',
    ).copyWith(needsReconcile: true, displaced: true);

    final restored = ManagedRemoteFile.fromJson(original.toJson());
    expect(restored.needsReconcile, isTrue);
    expect(restored.displaced, isTrue);
  });

  test('store put, list, get, update and remove round-trip', () async {
    final managed = await _createManagedCheckout(
      store,
      id: 'edit-1',
      serverId: 'server-a',
      content: 'abc',
    );
    await store.put(managed);

    expect((await store.get('edit-1'))!.remotePath, '/home/test/file.txt');
    expect((await store.listForServer('server-a')).single.id, 'edit-1');
    expect(await store.listForServer('server-b'), isEmpty);
    expect(
      (await store.listForSession('session-a', serverId: 'server-a'))
          .single
          .id,
      'edit-1',
    );

    final updated = managed.copyWith(
      remotePath: '/home/test/renamed.txt',
      remoteSnapshot: _snapshot('/home/test/renamed.txt'),
    );
    await store.update(updated);
    expect(
      (await store.get('edit-1'))!.remotePath,
      '/home/test/renamed.txt',
    );

    await store.remove('edit-1');
    expect(await store.get('edit-1'), isNull);
    expect(await store.list(), isEmpty);
  });

  test('put rejects a duplicate live key but not a displaced record', () async {
    final first = await _createManagedCheckout(
      store,
      id: 'edit-1',
      serverId: 'server-a',
      content: 'abc',
    );
    await store.put(first);
    final second = await _createManagedCheckout(
      store,
      id: 'edit-2',
      serverId: 'server-a',
      content: 'def',
    );
    await expectLater(store.put(second), throwsStateError);

    // The displaced occupant coexists on the same remotePath — §3.5's
    // re-keyed record keeps its display target but leaves the live slot.
    await store.put(second.copyWith(displaced: true));
    final listed = await store.listForServer('server-a');
    expect(listed, hasLength(2));
    expect(listed.where((r) => r.displaced).single.id, 'edit-2');
  });

  test('checkoutPathFor sanitizes unsafe names deterministically', () {
    final a = store.checkoutPathFor(id: 'id-1', fileName: 'file.txt');
    final b = store.checkoutPathFor(id: 'id-1', fileName: 'file.txt');
    expect(a, b);
    expect(a, endsWith('/file.txt'));

    final unsafe = store.checkoutPathFor(id: 'id-2', fileName: 'a/b\\c:d');
    expect(unsafe, isNot(contains('..')));
    expect(unsafe.split('/').last, 'a_b_c_d');

    final blank = store.checkoutPathFor(id: 'id-3', fileName: '...');
    expect(blank.split('/').last, '_');

    // 06 §3.1's pinned divergence: reserved device names keep their
    // extension under a `file-` prefix (Séance collapsed to a fixed
    // replacement), matched on the stem before the first dot.
    final device = store.checkoutPathFor(id: 'id-4', fileName: 'CON.txt');
    expect(device.split('/').last, 'file-CON.txt');
    final stemVariant = store.checkoutPathFor(
      id: 'id-4b',
      fileName: 'nul.tar.gz',
    );
    expect(stemVariant.split('/').last, 'file-nul.tar.gz');

    // Overlong names truncate to the 255-byte NAME_MAX floor on a
    // codepoint boundary rather than failing the checkout with a raw
    // ENAMETOOLONG — and the truncated name still passes validation.
    final overlong = store.checkoutPathFor(
      id: 'id-5',
      fileName: '${'é' * 200}.txt', // 2-byte runes: 400 + 4 bytes
    );
    final leaf = overlong.split('/').last;
    expect(utf8.encode(leaf).length, lessThanOrEqualTo(255));
    expect(() => store.checkoutFile(overlong), returnsNormally);
  });

  test('unsafe relative paths are rejected', () async {
    for (final bad in [
      '',
      '/absolute/path',
      'C:/win/path',
      'dir/../escape.txt',
      'dir//double.txt',
      'dir/.hidden/../x',
      'has\\backslash.txt',
    ]) {
      await expectLater(
        store.createCheckout(bad),
        throwsArgumentError,
        reason: bad,
      );
    }
    expect(await indexFile.exists(), isFalse);
  });

  test(
    'streamed hashing and reconciliation detect edits and missing files',
    () async {
      final managed = await _createManagedCheckout(
        store,
        id: 'edit-1',
        serverId: 'server-a',
        content: 'abc',
      );
      final local = store.checkoutFile(managed.localPath);
      expect(
        await streamedFileSha256(local),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      await store.put(managed);

      var reconciled = await store.reconcile('edit-1');
      expect(reconciled!.dirty, isFalse);
      expect(reconciled.missing, isFalse);

      await local.writeAsString('changed by editor');
      reconciled = await store.reconcile('edit-1');
      expect(reconciled!.dirty, isTrue);
      expect(reconciled.missing, isFalse);

      final accepted = await store.updateBaseline('edit-1');
      expect(accepted!.dirty, isFalse);
      expect(accepted.baselineSha256, await streamedFileSha256(local));

      await local.delete();
      reconciled = await store.reconcile('edit-1');
      expect(reconciled!.dirty, isFalse);
      expect(reconciled.missing, isTrue);

      final restarted = await reopened();
      final loaded = (await restarted.list()).single;
      expect(loaded.baselineSha256, accepted.baselineSha256);
      expect(loaded.dirty, isFalse);
      expect(loaded.missing, isFalse);
    },
  );

  test('remove deletes its checkout and persists removal', () async {
    final managed = await _createManagedCheckout(
      store,
      id: 'edit-1',
      serverId: 'server-a',
      content: 'plaintext',
    );
    await store.put(managed);
    final local = store.checkoutFile(managed.localPath);

    expect(await local.exists(), isTrue);
    expect((await store.remove('edit-1'))!.id, 'edit-1');
    expect(await local.exists(), isFalse);
    expect(await store.remove('edit-1'), isNull);

    final restarted = await reopened();
    expect(await restarted.list(), isEmpty);
  });

  test(
    'deletion unlinks a checkout symlink without touching its target',
    () async {
      final outside = File('${temporaryDirectory.path}/outside.txt');
      await outside.writeAsString('keep');
      final relative = 'links/file.txt';
      final local = store.checkoutFile(relative);
      await local.parent.create(recursive: true);
      await Link(local.path).create(outside.path);

      await store.deleteCheckout(relative);

      expect(
        await FileSystemEntity.type(local.path, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(await outside.readAsString(), 'keep');
    },
    skip: Platform.isWindows,
  );

  test(
    'creation and deletion refuse to traverse a parent symlink',
    () async {
      final outside = Directory('${temporaryDirectory.path}/outside')
        ..createSync();
      final victim = File('${outside.path}/victim.txt');
      await victim.writeAsString('keep');
      await store.list();
      await checkoutRoot.create(recursive: true);
      await Link('${checkoutRoot.path}/redirect').create(outside.path);

      await expectLater(
        store.createCheckout('redirect/new.txt'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        store.deleteCheckout('redirect/victim.txt'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await victim.readAsString(), 'keep');
      expect(await File('${outside.path}/new.txt').exists(), isFalse);
    },
    skip: Platform.isWindows,
  );

  // ---------------------------------------------------------------------
  // Poltergeist lifecycle rails (06 §3.2/§3.7)
  // ---------------------------------------------------------------------

  test('a corrupt index quarantines instead of overwriting', () async {
    final managed = await _createManagedCheckout(
      store,
      id: 'edit-1',
      serverId: 'server-a',
      content: 'abc',
    );
    await store.put(managed);
    final dir = store.checkoutFile(managed.localPath).parent;

    await indexFile.writeAsString('{not json');
    final restarted = await reopened();
    expect(await restarted.list(), isEmpty);

    // The bad index survives under a stamped quarantine name.
    final quarantined =
        indexFile.parent
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('.corrupt-'))
            .toList();
    expect(quarantined, hasLength(1));
    expect(await quarantined.single.readAsString(), '{not json');

    // Corrupt index → no sweep: the orphaned payload is preserved and
    // surfaces through the recovered listing.
    expect(await dir.exists(), isTrue);
    final recovered = await restarted.listRecovered();
    expect(recovered.single.directory, managed.localPath.split('/').first);
    expect(recovered.single.files, contains('edit-1.txt'));
  });

  test(
    'the load sweep deletes abandoned in-flight dirs but preserves payload',
    () async {
      // An indexed, committed checkout.
      final managed = await _createManagedCheckout(
        store,
        id: 'edit-1',
        serverId: 'server-a',
        content: 'abc',
      );
      await store.put(managed);
      await store.clearCheckoutInFlight(managed.localPath);

      // A second dir abandoned mid-checkout (markers only).
      final inFlightKey = 'inflight-checkout-dir';
      final inFlightDir = Directory('${checkoutRoot.path}/$inFlightKey');
      await inFlightDir.create(recursive: true);
      await File(
        '${inFlightDir.path}/${ManagedRemoteFileStore.epochMarkerName}',
      ).writeAsString('older-generation');
      await File(
        '${inFlightDir.path}/${ManagedRemoteFileStore.abandonedMarkerName}',
      ).create();
      await File('${inFlightDir.path}/partial.txt').writeAsString('half');

      // An old-epoch dir with payload (a completed checkout whose index
      // entry was lost) — preserved for recovery.
      final orphanDir = Directory('${checkoutRoot.path}/old-epoch-dir');
      await orphanDir.create();
      await File(
        '${orphanDir.path}/${ManagedRemoteFileStore.epochMarkerName}',
      ).writeAsString('older-generation');
      await File('${orphanDir.path}/notes.txt').writeAsString('keep me');

      // A markerless empty dir — the safe carve-out may remove it.
      final emptyDir = Directory('${checkoutRoot.path}/empty-dir');
      await emptyDir.create();

      // Generated temp debris inside the indexed dir is swept; the
      // checkout payload and a `.poltergeist-`-prefixed user file stay.
      final indexedDir = store.checkoutFile(managed.localPath).parent;
      await File(
        '${indexedDir.path}/edit-1.txt.poltergeist-${'a' * 8}.upload',
      ).writeAsString('snapshot debris');
      await File(
        '${indexedDir.path}/.poltergeist-${'b' * 8}.tmp',
      ).writeAsString('pipe debris');
      await File(
        '${indexedDir.path}/.poltergeist-notes',
      ).writeAsString('a real file, not a temp');

      final restarted = await reopened();
      expect(await restarted.list(), hasLength(1));

      expect(await inFlightDir.exists(), isFalse);
      expect(await orphanDir.exists(), isTrue);
      expect(await emptyDir.exists(), isFalse);
      expect(
        await File(
          '${indexedDir.path}/.poltergeist-notes',
        ).exists(),
        isTrue,
      );
      expect(
        await File(
          '${indexedDir.path}/edit-1.txt.poltergeist-${'a' * 8}.upload',
        ).exists(),
        isFalse,
      );

      final recovered = await restarted.listRecovered();
      expect(
        recovered.map((r) => r.directory),
        contains('old-epoch-dir'),
      );
      // The indexed dir is retained, not "recovered" — only recordless
      // payload-bearing dirs surface for §3.7's review.
      expect(
        recovered.map((r) => r.directory),
        isNot(contains(managed.localPath.split('/').first)),
      );
    },
  );

  test('the record basename is never swept as a generated temp', () async {
    // A remote file legitimately named like a generated temp keeps its
    // payload through the load sweep (06 §3.3's exact-shape rule).
    final localPath = store.checkoutPathFor(
      id: 'edit-1',
      fileName: 'x.poltergeist-abcdef12.tmp',
    );
    expect(localPath, endsWith('/x.poltergeist-abcdef12.tmp'));
    final local = await store.createCheckout(localPath);
    await local.writeAsString('payload');
    final managed = _managedFile(
      id: 'edit-1',
      localPath: localPath,
      baselineSha256: await streamedFileSha256(local),
    );
    await store.put(managed);

    final restarted = await reopened();
    expect(await local.exists(), isTrue);
    expect((await restarted.list()).single.id, 'edit-1');
    expect(await restarted.listRecovered(), isEmpty);
  });

  test('a second store over the same index is locked out', () async {
    await store.list(); // forces load + lock acquisition
    final contender = ManagedRemoteFileStore(
      indexFile: indexFile,
      checkoutRoot: checkoutRoot,
    );
    await expectLater(
      contender.list().timeout(const Duration(seconds: 10)),
      throwsA(isA<FileSystemException>()),
    );
    await contender.close();

    await store.close();
    final afterRelease = ManagedRemoteFileStore(
      indexFile: indexFile,
      checkoutRoot: checkoutRoot,
    );
    expect(await afterRelease.list(), isEmpty);
    store = afterRelease;
  });

  test('index writes roll back when the atomic writer fails', () async {
    var failWrites = false;
    final failing = ManagedRemoteFileStore(
      indexFile: indexFile,
      checkoutRoot: checkoutRoot,
      atomicWriter: (target, contents, {restrictToOwner = false}) async {
        if (failWrites) {
          throw const FileSystemException('disk full');
        }
        await target.parent.create(recursive: true);
        await target.writeAsString(contents);
      },
    );
    final managed = await _createManagedCheckout(
      failing,
      id: 'edit-1',
      serverId: 'server-a',
      content: 'abc',
    );
    failWrites = true;
    await expectLater(failing.put(managed), throwsA(isA<FileSystemException>()));
    // Rolled back: no record, no index mutation.
    expect(await failing.get('edit-1'), isNull);
    failWrites = false;
    await failing.put(managed);
    expect((await failing.get('edit-1'))!.id, 'edit-1');
    await failing.close();
  });

  test('upload snapshots take the exact generated sibling shape', () async {
    final managed = await _createManagedCheckout(
      store,
      id: 'edit-1',
      serverId: 'server-a',
      content: 'abc',
    );
    await store.put(managed);
    final snapshot = await store.createUploadSnapshot(managed.localPath);
    expect(
      ManagedRemoteFileStore.generatedTempName.hasMatch(
        snapshot.path.split(Platform.pathSeparator).last,
      ),
      isTrue,
    );
    expect(await snapshot.readAsString(), 'abc');
  });

  test('deleteRecovered refuses non-single-segment identities', () async {
    await store.list();
    await expectLater(
      store.deleteRecovered('../outside'),
      throwsArgumentError,
    );
    await expectLater(
      store.deleteRecovered('a/b'),
      throwsArgumentError,
    );
  });
}

Future<ManagedRemoteFile> _createManagedCheckout(
  ManagedRemoteFileStore store, {
  required String id,
  required String serverId,
  required String content,
}) async {
  final localPath = store.checkoutPathFor(id: id, fileName: '$id.txt');
  final local = await store.createCheckout(localPath);
  await local.writeAsString(content);
  return _managedFile(
    id: id,
    serverId: serverId,
    localPath: localPath,
    baselineSha256: await streamedFileSha256(local),
  );
}

ManagedRemoteFile _managedFile({
  required String id,
  required String localPath,
  String serverId = 'server-a',
  String sessionId = 'session-a',
  String baselineSha256 =
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  bool dirty = false,
}) => ManagedRemoteFile(
  id: id,
  serverId: serverId,
  editSessionId: sessionId,
  remotePath: '/home/test/file.txt',
  localPath: localPath,
  remoteSnapshot: _snapshot('/home/test/file.txt'),
  baselineSha256: baselineSha256,
  dirty: dirty,
);

RemoteFileEntry _snapshot(String path) => RemoteFileEntry(
  path: path,
  name: path.split('/').last,
  type: RemoteFileType.file,
  size: 3,
  modifiedAt: DateTime.utc(2026, 7, 10, 12, 30),
  mode: 0x81a4,
);
