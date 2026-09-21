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
      (await store.listForSession('session-a', serverId: 'server-a')).single.id,
      'edit-1',
    );

    final updated = managed.copyWith(
      remotePath: '/home/test/renamed.txt',
      remoteSnapshot: _snapshot('/home/test/renamed.txt'),
    );
    await store.update(updated);
    expect((await store.get('edit-1'))!.remotePath, '/home/test/renamed.txt');

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

  test('creation and deletion refuse to traverse a parent symlink', () async {
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
  }, skip: Platform.isWindows);

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
    final quarantined = indexFile.parent
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
        await File('${indexedDir.path}/.poltergeist-notes').exists(),
        isTrue,
      );
      expect(
        await File(
          '${indexedDir.path}/edit-1.txt.poltergeist-${'a' * 8}.upload',
        ).exists(),
        isFalse,
      );

      final recovered = await restarted.listRecovered();
      expect(recovered.map((r) => r.directory), contains('old-epoch-dir'));
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

  group('the save-temp sweep (06 §2.1 step 5)', () {
    /// A `.poltergeist-<token>.edit|backup` sibling of the checkout,
    /// backdated past the in-flight-save window so the sweep treats it
    /// as crash residue rather than a live save.
    Future<File> tempSibling(
      ManagedRemoteFile managed,
      String suffix, {
      required String content,
      bool fresh = false,
    }) async {
      final local = store.checkoutFile(managed.localPath);
      final sibling = File('${local.path}.poltergeist-deadbeef-cafe.$suffix');
      await sibling.writeAsString(content);
      if (!fresh) {
        await sibling.setLastModified(DateTime.utc(2020));
      }
      return sibling;
    }

    test('stale .edit/.backup beside a live target are reaped', () async {
      final managed = await _createManagedCheckout(
        store,
        id: 'edit-1',
        serverId: 'server-a',
        content: 'abc',
      );
      await store.put(managed);
      final edit = await tempSibling(managed, 'edit', content: 'x');
      final backup = await tempSibling(managed, 'backup', content: 'y');
      // An .upload snapshot is not the save dance's shape — the sweep
      // leaves it for the store's own generated-temp handling.
      final upload = await tempSibling(managed, 'upload', content: 'z');

      final reconciled = await store.reconcile('edit-1');

      expect(reconciled!.dirty, isFalse);
      expect(await edit.exists(), isFalse);
      expect(await backup.exists(), isFalse);
      expect(await upload.exists(), isTrue);
    });

    test(
      'temps inside the in-flight window are left for the live save',
      () async {
        final managed = await _createManagedCheckout(
          store,
          id: 'edit-1',
          serverId: 'server-a',
          content: 'abc',
        );
        await store.put(managed);
        final edit = await tempSibling(
          managed,
          'edit',
          content: 'x',
          fresh: true,
        );
        final backup = await tempSibling(
          managed,
          'backup',
          content: 'y',
          fresh: true,
        );

        final reconciled = await store.reconcile('edit-1');

        expect(reconciled!.dirty, isFalse);
        expect(await edit.exists(), isTrue);
        expect(await backup.exists(), isTrue);
      },
    );

    test('a lone .backup beside a missing target is restored', () async {
      final managed = await _createManagedCheckout(
        store,
        id: 'edit-1',
        serverId: 'server-a',
        content: 'abc',
      );
      await store.put(managed);
      final local = store.checkoutFile(managed.localPath);
      // The crash shape: rename(file → backup) landed, the temp → file
      // rename never ran.
      await local.rename('${local.path}.poltergeist-deadbeef-cafe.backup');
      final backup = File('${local.path}.poltergeist-deadbeef-cafe.backup');
      await backup.setLastModified(DateTime.utc(2020));

      final reconciled = await store.reconcile('edit-1');

      // The pre-save copy is back in place — identical to baseline.
      expect(await local.readAsString(), 'abc');
      expect(await backup.exists(), isFalse);
      expect(reconciled!.missing, isFalse);
      expect(reconciled.dirty, isFalse);
    });

    test(
      '.edit + .backup beside a missing target completes the save',
      () async {
        final managed = await _createManagedCheckout(
          store,
          id: 'edit-1',
          serverId: 'server-a',
          content: 'abc',
        );
        await store.put(managed);
        final local = store.checkoutFile(managed.localPath);
        // Crash after the temp was sealed and file → backup landed: the
        // just-saved content is what the user last wrote — it completes
        // the save so the rehash marks the copy dirty for §3.4.
        await local.rename('${local.path}.poltergeist-deadbeef-cafe.backup');
        final backup = File('${local.path}.poltergeist-deadbeef-cafe.backup');
        await backup.setLastModified(DateTime.utc(2020));
        final edit = await tempSibling(managed, 'edit', content: 'edited');

        final reconciled = await store.reconcile('edit-1');

        expect(await local.readAsString(), 'edited');
        // The pre-save copy is preserved — not deleted by the pass.
        expect(await backup.readAsString(), 'abc');
        expect(await edit.exists(), isFalse);
        expect(reconciled!.missing, isFalse);
        expect(reconciled.dirty, isTrue);
      },
    );

    test(
      'a lone .edit beside a missing target is preserved, not applied',
      () async {
        final managed = await _createManagedCheckout(
          store,
          id: 'edit-1',
          serverId: 'server-a',
          content: 'abc',
        );
        await store.put(managed);
        final local = store.checkoutFile(managed.localPath);
        await local.delete();
        final edit = await tempSibling(managed, 'edit', content: 'torn?');

        final reconciled = await store.reconcile('edit-1');

        // A .edit without a .backup may be torn — never applied, never
        // deleted; the copy reports missing.
        expect(await local.exists(), isFalse);
        expect(await edit.readAsString(), 'torn?');
        expect(reconciled!.missing, isTrue);
      },
    );

    test('a foreign-stem temp name is never swept — the token must be '
        'dot-free', () async {
      final managed = await _createManagedCheckout(
        store,
        id: 'edit-1',
        serverId: 'server-a',
        content: 'abc',
      );
      await store.put(managed);
      final local = store.checkoutFile(managed.localPath);
      // `x.poltergeist-y.poltergeist-<tok>.edit` satisfies the record's
      // prefix AND the generated-name regex, but the span between them
      // holds a foreign stem's own segment — never this record's temp.
      final foreign = File(
        '${local.path}.poltergeist-foreign.poltergeist-deadbeef-cafe'
        '.edit',
      );
      await foreign.writeAsString('not ours');
      await foreign.setLastModified(DateTime.utc(2020));
      // The record's own stale temp still sweeps, proving the pass ran.
      final own = await tempSibling(managed, 'edit', content: 'x');

      final reconciled = await store.reconcile('edit-1');

      expect(reconciled!.dirty, isFalse);
      expect(await own.exists(), isFalse);
      expect(await foreign.readAsString(), 'not ours');
    });

    test('a symlink or directory squatting on the target path is never '
        'renamed over', () async {
      final managed = await _createManagedCheckout(
        store,
        id: 'edit-1',
        serverId: 'server-a',
        content: 'abc',
      );
      await store.put(managed);
      final local = store.checkoutFile(managed.localPath);
      await local.delete();
      final squat = File('${local.parent.path}/squat-target')
        ..writeAsStringSync('squat');
      final link = await Link(local.path).create(squat.path);
      final backup = await tempSibling(managed, 'backup', content: 'y');

      var reconciled = await store.reconcile('edit-1');

      // The link is the target — crash-restore does not run, the
      // sibling is left alone, and the copy reports missing.
      expect(await FileSystemEntity.isLink(local.path), isTrue);
      expect(await link.exists(), isTrue);
      expect(await backup.exists(), isTrue);
      expect(reconciled!.missing, isTrue);

      // Same refusal for a directory at the path.
      await link.delete();
      await Directory(local.path).create();
      reconciled = await store.reconcile('edit-1');

      expect(
        await FileSystemEntity.type(local.path, followLinks: false),
        FileSystemEntityType.directory,
      );
      expect(await backup.exists(), isTrue);
      expect(reconciled!.missing, isTrue);
    });

    test('foreign stems are never swept', () async {
      final managed = await _createManagedCheckout(
        store,
        id: 'edit-1',
        serverId: 'server-a',
        content: 'abc',
      );
      await store.put(managed);
      final local = store.checkoutFile(managed.localPath);
      // A temp-shaped file for a DIFFERENT stem must survive — the
      // sweep deletes only the record's own save-dance siblings.
      final foreign = File(
        '${local.parent.path}/other.poltergeist-deadbeef-cafe.edit',
      );
      await foreign.writeAsString('not ours');
      await foreign.setLastModified(DateTime.utc(2020));

      await store.reconcile('edit-1');

      expect(await foreign.readAsString(), 'not ours');
    });
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
    await expectLater(
      failing.put(managed),
      throwsA(isA<FileSystemException>()),
    );
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
    await expectLater(store.deleteRecovered('../outside'), throwsArgumentError);
    await expectLater(store.deleteRecovered('a/b'), throwsArgumentError);
  });

  test(
    'deleteRecoveredFile drops one payload; the last takes the dir',
    () async {
      // A preserved recordless dir: two payloads beside the epoch
      // marker (an external editor's sibling backup is exactly this).
      final dir = Directory('${checkoutRoot.path}/recovered-dir');
      await dir.create(recursive: true);
      await File(
        '${dir.path}/${ManagedRemoteFileStore.epochMarkerName}',
      ).writeAsString('old-generation');
      await File('${dir.path}/edit.txt').writeAsString('keep me');
      await File('${dir.path}/.edit.txt.swp').writeAsString('swap');
      await store.list(); // loads so the recovered index exists

      await store.deleteRecoveredFile('recovered-dir', 'edit.txt');
      expect(await File('${dir.path}/edit.txt').exists(), isFalse);
      // The sibling and the dir itself survive — the §3.7 surface
      // removes a row's file, never the whole dir.
      expect(await File('${dir.path}/.edit.txt.swp').exists(), isTrue);
      expect(await dir.exists(), isTrue);
      var recovered = await store.listRecovered();
      expect(recovered.single.directory, 'recovered-dir');
      expect(recovered.single.files, ['.edit.txt.swp']);

      // The last payload file's discard deletes the dir — markers and
      // all — per 06 §3.7 ("the dir itself is deleted when its last
      // file goes").
      await store.deleteRecoveredFile('recovered-dir', '.edit.txt.swp');
      expect(await dir.exists(), isFalse);
      recovered = await store.listRecovered();
      expect(recovered, isEmpty);
    },
  );

  test(
    'deleteRecoveredFile never touches a record-owned dir or escapes',
    () async {
      // An indexed checkout's dir is record-owned: the recovered-file
      // verb must refuse it (the record's own lifecycle owns the dir).
      final managed = await _createManagedCheckout(
        store,
        id: 'edit-1',
        serverId: 'server-a',
        content: 'abc',
      );
      await store.put(managed);
      final ownedDir = managed.localPath.split('/').first;

      await expectLater(
        store.deleteRecoveredFile(ownedDir, 'edit-1.txt'),
        throwsArgumentError,
      );
      expect(await store.checkoutFile(managed.localPath).exists(), isTrue);
      await expectLater(
        store.deleteRecoveredFile('dir', '../outside.txt'),
        throwsArgumentError,
      );
      await expectLater(
        store.deleteRecoveredFile('a/b', 'file.txt'),
        throwsArgumentError,
      );
      await expectLater(
        store.deleteRecoveredFile('dir', 'a/b.txt'),
        throwsArgumentError,
      );
    },
  );

  test('prepareCheckout tolerates a marker left by a failed attempt', () async {
    final localPath = store.checkoutPathFor(id: 'edit-9', fileName: 'f.txt');
    await store.prepareCheckout(localPath);
    // The marker from the failed first attempt must not throw the retry.
    await store.prepareCheckout(localPath);
    final marker = File(
      '${store.checkoutFile(localPath).parent.path}'
      '/${ManagedRemoteFileStore.abandonedMarkerName}',
    );
    expect(await marker.exists(), isTrue);
  });

  test('a payload-bearing directory is never marked abandoned', () async {
    // A preserved recovered dir — payload, no markers — re-prepared for
    // a checkout attempt must keep its payload un-sweepable.
    final dir = Directory('${checkoutRoot.path}/deadbeef');
    await dir.create(recursive: true);
    await File('${dir.path}/recovered.txt').writeAsString('keep me');

    await store.prepareCheckout('deadbeef/recovered.txt');
    expect(
      await File(
        '${dir.path}/${ManagedRemoteFileStore.abandonedMarkerName}',
      ).exists(),
      isFalse,
    );

    // The load sweep still preserves the payload rather than deleting it.
    await reopened();
    final recovered = await store.listRecovered();
    expect(recovered.single.directory, 'deadbeef');
    expect(recovered.single.files, contains('recovered.txt'));
  });

  test(
    'a failed contender\'s close does not release the holder\'s lock',
    () async {
      await store.list(); // forces load + lock acquisition
      final contender = ManagedRemoteFileStore(
        indexFile: indexFile,
        checkoutRoot: checkoutRoot,
      );
      await expectLater(
        contender.list().timeout(const Duration(seconds: 10)),
        throwsA(isA<FileSystemException>()),
      );
      // The contender never held the lock — closing it must not erase the
      // holder's same-process registration.
      await contender.close();
      final third = ManagedRemoteFileStore(
        indexFile: indexFile,
        checkoutRoot: checkoutRoot,
      );
      await expectLater(
        third.list().timeout(const Duration(seconds: 10)),
        throwsA(isA<FileSystemException>()),
      );
      await third.close();
    },
  );
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
