import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

final _fixedNow = DateTime.utc(2026, 9, 8, 12);

Bookmark _remoteBookmark(String id, {String? label, String? sortKey}) {
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: label ?? id,
    server: const BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 2222,
        username: 'deploy',
        authMethod: AuthMethod.privateKey,
        identityFilePath: '~/.ssh/id_ed25519',
      ),
    ),
    remotePath: '/',
    sortKey: sortKey ?? id,
    createdAt: _fixedNow,
    updatedAt: _fixedNow,
  );
}

Bookmark _localBookmark(
  String id, {
  String? label,
  String? group,
  String? sortKey,
}) {
  return Bookmark(
    id: id,
    kind: BookmarkKind.localFolder,
    label: label ?? id,
    group: group,
    localPath: '~/Downloads',
    sortKey: sortKey ?? id,
    createdAt: _fixedNow,
    updatedAt: _fixedNow,
  );
}

/// One representative per 04 §2.1 kind, every synced field populated.
List<Bookmark> _allKinds() => [
      Bookmark(
        id: 'local-1',
        kind: BookmarkKind.localFolder,
        label: 'Downloads',
        group: 'Places',
        color: ServerColor.amber,
        icon: ServerIcon.home,
        localPath: '~/Downloads',
        preferredPane: PreferredPane.left,
        sortKey: 'am',
        createdAt: _fixedNow,
        updatedAt: _fixedNow,
      ),
      Bookmark(
        id: 'remote-1',
        kind: BookmarkKind.remotePath,
        label: 'www logs',
        group: 'Work',
        color: ServerColor.violet,
        icon: ServerIcon.database,
        server: const BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: 'nas.local',
            username: 'alice',
            authMethod: AuthMethod.privateKey,
            identityFilePath: '~/.ssh/id_ed25519',
          ),
        ),
        remotePath: '/var/log/nginx',
        preferredPane: PreferredPane.right,
        sortKey: 'b',
        createdAt: _fixedNow,
        updatedAt: _fixedNow,
      ),
      Bookmark(
        id: 'ws-1',
        kind: BookmarkKind.workspace,
        label: 'Site pair',
        left: const BookmarkLocation(path: '~/site'),
        right: const BookmarkLocation(
          server: BookmarkServerRef(
            identity: EmbeddedHostIdentity(
              host: 'nas.local',
              username: 'alice',
              authMethod: AuthMethod.password,
              secretRef: 'nas-password',
            ),
          ),
          path: '/srv/site',
        ),
        sortKey: 'd',
        createdAt: _fixedNow,
        updatedAt: _fixedNow,
      ),
      Bookmark(
        id: 'sync-1',
        kind: BookmarkKind.savedSync,
        label: 'Deploy',
        sync: SavedSyncSpec(
          source: const BookmarkLocation(path: '~/site'),
          destination: const BookmarkLocation(
            server: BookmarkServerRef(serverConfigId: 'srv-9'),
            path: '/srv/site',
          ),
          ignoreRules: const ['.git/**'],
          rules: const {'direction': 'leftToRight'},
        ),
        sortKey: 'g',
        createdAt: _fixedNow,
        updatedAt: _fixedNow,
      ),
    ];

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('poltergeist-bookmarks');
  });

  tearDown(() async {
    // Windows can hold a handle on a just-written store for a beat past
    // the test's last await; retry instead of flaking the suite. The
    // attempt bound and the final-attempt rethrow share one constant so
    // they cannot drift apart if the retry count is ever tuned.
    const attempts = 3;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        // A lock that survives the retries is a real problem (a held
        // handle or a wedged write tail), not flake — surface it.
        if (attempt == attempts - 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  String pathIn(String name) => '${dir.path}${Platform.pathSeparator}$name';

  group('persistence', () {
    test('persists and reloads bookmarks across instances', () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([_remoteBookmark('a', sortKey: 'm')]);

      final reloaded = FileBookmarkStore(path: path);
      final bookmarks = await reloaded.load();

      expect(bookmarks, hasLength(1));
      final identity = bookmarks.single.server!.identity!;
      expect(bookmarks.single.id, 'a');
      expect(bookmarks.single.label, 'a');
      expect(identity.host, 'web.example.com');
      expect(identity.port, 2222);
      expect(identity.username, 'deploy');
      // Reference-style key auth: the path travels verbatim, never key bytes.
      expect(identity.authMethod, AuthMethod.privateKey);
      expect(identity.identityFilePath, '~/.ssh/id_ed25519');
    });

    test('updates a bookmark whose id already exists', () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([_remoteBookmark('a', label: 'first')]);
      await store.upsertAll([_remoteBookmark('a', label: 'second')]);

      final reloaded = await FileBookmarkStore(path: path).load();

      expect(reloaded, hasLength(1));
      expect(reloaded.single.label, 'second');
    });

    test('quarantines a corrupt file and starts empty', () async {
      final path = pathIn('bookmarks.json');
      File(path).writeAsStringSync('{not valid json');

      final store = FileBookmarkStore(path: path);

      expect(await store.load(), isEmpty);
      final quarantined = dir
          .listSync()
          .where((entity) => entity.path.contains('.corrupt-'));
      expect(quarantined, hasLength(1));
      expect(
        File(quarantined.single.path).readAsStringSync(),
        '{not valid json',
        reason: 'quarantine must preserve the corrupt bytes verbatim',
      );
    });

    test('a failed quarantine fails the load instead of starting empty',
        () async {
      final path = pathIn('bookmarks.json');
      const contents = '{not valid json';
      File(path).writeAsStringSync(contents);

      // Park a directory where the quarantine rename would land, so the
      // rename fails. The store must then fail closed rather than load
      // empty and let the next save overwrite the unreadable bytes.
      Directory(
        bookmarkQuarantinePath(path, _fixedNow),
      ).createSync();
      final store = FileBookmarkStore(
        path: path,
        now: () => _fixedNow,
      );

      await expectLater(store.load(), throwsA(isA<FileSystemException>()));
      expect(File(path).readAsStringSync(), contents);

      // A later save must fail too, never replacing the bytes.
      await expectLater(
        store.upsertAll([_remoteBookmark('a')]),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(path).readAsStringSync(), contents);
    });

    test('preserves undecodable records verbatim on the next write', () async {
      final path = pathIn('bookmarks.json');
      // A record from a newer Poltergeist (unknown kind) plus a valid one:
      // the unknown kind must survive a local re-save untouched (04 §2.1's
      // skip-and-preserve).
      final future = <String, dynamic>{
        'id': 'future',
        'kind': 'fromTheFuture',
        'label': 'later',
        'sortKey': 'f',
        'createdAt': '2026-09-08T12:00:00.000Z',
        'updatedAt': '2026-09-08T12:00:00.000Z',
      };
      File(path).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'bookmarks': [future, _remoteBookmark('a', sortKey: 'm').toJson()],
        }),
      );

      final store = FileBookmarkStore(path: path);
      expect((await store.load()).map((bookmark) => bookmark.id), ['a']);

      await store.upsertAll([_remoteBookmark('b', sortKey: 'q')]);

      final written = jsonDecode(File(path).readAsStringSync()) as Map;
      final records = (written['bookmarks'] as List).cast<Map>();
      expect(records, contains(equals(future)));
      expect(records.map((record) => record['id']), containsAll(['a', 'b']));
    });

    test('preserves a record whose field has the wrong JSON type', () async {
      final path = pathIn('bookmarks.json');
      // A malformed port is a decode failure, not a fatal load error: the
      // record is preserved verbatim like any other unreadable record.
      final malformed = <String, dynamic>{
        'id': 'bad',
        'kind': 'remotePath',
        'label': 'bad',
        'server': {
          'identity': {
            'host': 'web.example.com',
            'port': 'not-a-number',
            'username': 'deploy',
            'authMethod': 'password',
          },
        },
        'remotePath': '/',
        'sortKey': 'bad',
        'createdAt': '2026-09-08T12:00:00.000Z',
        'updatedAt': '2026-09-08T12:00:00.000Z',
      };
      File(path).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'bookmarks': [malformed, _remoteBookmark('a', sortKey: 'm').toJson()],
        }),
      );

      final store = FileBookmarkStore(path: path);
      expect((await store.load()).map((bookmark) => bookmark.id), ['a']);

      await store.upsertAll([_remoteBookmark('b', sortKey: 'q')]);
      final records =
          ((jsonDecode(File(path).readAsStringSync()) as Map)['bookmarks']
                  as List)
              .cast<Map>();
      expect(records, contains(equals(malformed)));
    });

    test('a newer store version fails without quarantining', () async {
      final path = pathIn('bookmarks.json');
      final contents = jsonEncode({
        'version': 2,
        'bookmarks': [_remoteBookmark('a', sortKey: 'm').toJson()],
      });
      File(path).writeAsStringSync(contents);

      await expectLater(
        FileBookmarkStore(path: path).load(),
        throwsA(isA<FormatException>()),
      );

      // The unreadable newer store must stay in place so this version's
      // next save cannot replace it (no quarantine, no empty start).
      expect(File(path).readAsStringSync(), contents);
      expect(
        dir.listSync().where((entity) => entity.path.contains('.corrupt-')),
        isEmpty,
      );
    });

    test('rethrows read failures instead of silently starting empty',
        () async {
      if (!Platform.isLinux && !Platform.isMacOS) {
        markTestSkipped('mode-000 read denial applies on desktop POSIX only');
        return;
      }
      final uid = await Process.run('id', ['-u']);
      if ((uid.stdout as String).trim() == '0') {
        markTestSkipped('chmod 000 does not deny reads when running as root');
        return;
      }

      final path = pathIn('bookmarks.json');
      File(path).writeAsStringSync('{"version":1,"bookmarks":[]}');
      final denied = await Process.run('chmod', ['--', '000', path]);
      expect(
        denied.exitCode,
        0,
        reason: 'chmod 000 must succeed to deny reads',
      );
      addTearDown(() => Process.run('chmod', ['--', '600', path]));

      // An unreadable-but-present file must fail the load, never read as
      // empty (a later save would then overwrite data nobody could read).
      await expectLater(
        FileBookmarkStore(path: path).load(),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        dir.listSync().where((entity) => entity.path.contains('.corrupt-')),
        isEmpty,
      );
    });

    test('an unrecognized store version encoding fails closed', () async {
      final path = pathIn('bookmarks.json');
      const unreadable = '{"version":"2","bookmarks":[]}';
      // A non-integer version and an older integer are both formats this
      // version cannot read, so they fail like a newer version rather than
      // load as v1.
      for (final contents in [unreadable, '{"version":0,"bookmarks":[]}']) {
        File(path).writeAsStringSync(contents);
        await expectLater(
          FileBookmarkStore(path: path).load(),
          throwsA(isA<FormatException>()),
        );
        expect(File(path).readAsStringSync(), contents);
      }

      // An absent version and the current version both load normally.
      File(path).writeAsStringSync('{"bookmarks":[]}');
      expect(await FileBookmarkStore(path: path).load(), isEmpty);
      File(path).writeAsStringSync('{"version":1,"bookmarks":[]}');
      expect(await FileBookmarkStore(path: path).load(), isEmpty);
    });

    test('a load waits for a queued write', () async {
      final path = pathIn('bookmarks.json');
      final gate = Completer<void>();
      final writerStarted = Completer<void>();
      final store = FileBookmarkStore(
        path: path,
        atomicWriter: (file, contents) async {
          writerStarted.complete();
          await gate.future;
          await const TransferJournalIo().atomicRewrite(file, contents);
        },
      );

      final write = store.upsertAll([_remoteBookmark('a', sortKey: 'm')]);
      await writerStarted.future;

      var readSettled = false;
      final read = store.load().then((bookmarks) {
        readSettled = true;
        return bookmarks;
      });
      // The write is parked, so the read must not resolve with the pre-write
      // (empty) state.
      await Future<void>.delayed(Duration.zero);
      expect(readSettled, isFalse);

      gate.complete();
      await write;

      final bookmarks = await read;
      expect(bookmarks.map((bookmark) => bookmark.id), ['a']);
    });

    test('serializes concurrent writes so neither bookmark is lost', () async {
      final path = pathIn('bookmarks.json');
      final gate = Completer<void>();
      final firstWriteParked = Completer<void>();
      var writes = 0;
      final store = FileBookmarkStore(
        path: path,
        atomicWriter: (file, contents) async {
          writes++;
          if (writes == 1) {
            firstWriteParked.complete();
            await gate.future;
          }
          await const TransferJournalIo().atomicRewrite(file, contents);
        },
      );

      final first = store.upsertAll([_remoteBookmark('a', sortKey: 'm')]);
      // Park the first write in flight, then enqueue the second: a store
      // without a serialized write tail would snapshot the same empty state
      // and let the second write clobber the first.
      await firstWriteParked.future;
      final second = store.upsertAll([_remoteBookmark('b', sortKey: 'q')]);
      gate.complete();
      await Future.wait([first, second]);

      final reloaded = await FileBookmarkStore(path: path).load();
      expect(reloaded.map((bookmark) => bookmark.id).toSet(), {'a', 'b'});
    });

    test('persists rows built by the ssh_config import service', () async {
      const home = '/home/tester';
      const configPath = '$home/.ssh/config';
      const config = '''
Host web
  HostName web.example.com
  Port 2222
  User deploy
  IdentityFile ~/.ssh/id_ed25519
''';
      var next = 0;
      final service = SshConfigImportService(
        homeDirectory: home,
        source: _FakeSshConfigSource({configPath: config}),
        mintId: () => 'row-${next++}',
      );

      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      final preview = await service.loadPreview(
        configPath: configPath,
        existingBookmarks: await store.load(),
      );
      await store.upsertAll([
        for (final row in preview.rows) row.toBookmark(now: _fixedNow),
      ]);

      final reloaded = await FileBookmarkStore(path: path).load();
      expect(reloaded, hasLength(1));
      final identity = reloaded.single.server!.identity!;
      expect(identity.host, 'web.example.com');
      expect(identity.port, 2222);
      expect(identity.username, 'deploy');
      expect(identity.authMethod, AuthMethod.privateKey);
      expect(identity.identityFilePath, '~/.ssh/id_ed25519');
    });
  });

  group('atomic-write durability', () {
    test('a torn temp sibling from a crashed write leaves the old store',
        () async {
      final path = pathIn('bookmarks.json');
      final good = jsonEncode({
        'version': 1,
        'bookmarks': [_remoteBookmark('a', sortKey: 'm').toJson()],
      });
      File(path).writeAsStringSync(good);
      // The crash landed between temp write and rename: the temp holds a
      // truncated payload, the real file still holds the last good store.
      File('$path.tmp-deadbeef').writeAsStringSync('{"version":1,"bookmar');

      final store = FileBookmarkStore(path: path);
      expect((await store.load()).map((bookmark) => bookmark.id), ['a']);
      expect(File(path).readAsStringSync(), good);
    });

    test('a write that throws mid-rename never truncates the old store',
        () async {
      final path = pathIn('bookmarks.json');
      final good = jsonEncode({
        'version': 1,
        'bookmarks': [_remoteBookmark('a', sortKey: 'm').toJson()],
      });
      File(path).writeAsStringSync(good);

      final store = FileBookmarkStore(
        path: path,
        atomicWriter: (file, contents) async {
          // Simulated crash: a torn temp lands, the rename never runs.
          await File('${file.path}.tmp-aaaa').writeAsString('{torn');
          throw StateError('simulated crash');
        },
      );

      await expectLater(
        store.upsertAll([_remoteBookmark('b', sortKey: 'q')]),
        throwsStateError,
      );
      expect(File(path).readAsStringSync(), good);

      // The failed write must not wedge the store either: a working writer
      // still sees the pre-failure state and completes.
      final recovered = FileBookmarkStore(path: path);
      expect((await recovered.load()).map((bookmark) => bookmark.id), ['a']);
    });
  });

  group('payload purity — the M6 serialization contract', () {
    // The on-disk record IS the payload M6 seals into a `bookmark:` record
    // (04 §2.4). Any local-only key or secure-bookmark blob leaking into
    // it would be a sync bug discovered one milestone late; this test is
    // the 07 §3.6 exit criterion.
    const syncedKeys = {
      'id',
      'kind',
      'label',
      'group',
      'color',
      'icon',
      'server',
      'localPath',
      'remotePath',
      'left',
      'right',
      'sync',
      'preferredPane',
      'sortKey',
      'createdAt',
      'updatedAt',
    };
    // 04 §2.3's device-local split, named so a regression reads as itself.
    const deviceLocalKeys = {
      'securityScopedBookmark',
      'scopedBookmark',
      'bookmarkData',
      'endpointPin',
      'endpointPins',
      'collapsed',
      'hidden',
      'viewState',
      'pathMissing',
      'deviceId',
      'probeEnabled',
      'hostKey',
      'secret',
      'password',
      'secretValue',
    };

    test('persisted records carry only synced keys, for every kind',
        () async {
      final path = pathIn('bookmarks.json');
      final bookmarks = _allKinds();
      final store = FileBookmarkStore(path: path);
      await store.upsertAll(bookmarks);

      final written =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      expect(written.keys.toSet(), {'version', 'bookmarks'});

      final records = (written['bookmarks'] as List).cast<Map>();
      expect(records, hasLength(bookmarks.length));
      for (final record in records) {
        expect(
          record.keys.toSet(),
          isNot(anyOf(deviceLocalKeys.map((k) => contains(k)))),
        );
        for (final key in record.keys) {
          expect(syncedKeys, contains(key), reason: 'key $key');
        }
      }
      // The persisted record is the model's payload verbatim — the store
      // appends nothing of its own.
      final byId = {for (final b in bookmarks) b.id: b};
      for (final record in records) {
        expect(record, equals(byId[record['id']]!.toJson()));
      }
    });

    test('the sealed-payload shape round-trips like 04 §2.4 records it',
        () async {
      // The sync envelope is {'kind': 'bookmark', 'data': toJson()} — the
      // inner map must never grow device-local keys.
      final bookmark = _allKinds().first;
      final envelope = {
        'kind': 'bookmark',
        'data': bookmark.toJson(),
      };
      final data = envelope['data'] as Map<String, dynamic>;
      expect(data.keys.toSet().difference(syncedKeys), isEmpty);
      expect(data.keys.toSet().intersection(deviceLocalKeys), isEmpty);
    });

    test(
      'no local-only key nests inside the workspace or server payloads',
      () {
        // The top-level key audit above does not reach inside `left`,
        // `right`, `server`, or `sync` — and M5's workspace record is
        // exactly where a nested location could smuggle a device-local
        // field. Walk every map key at every depth instead.
        Set<String> allKeys(Object? node) {
          final keys = <String>{};
          void walk(Object? value) {
            switch (value) {
              case Map():
                for (final entry in value.entries) {
                  keys.add(entry.key as String);
                  walk(entry.value);
                }
              case List():
                value.forEach(walk);
            }
          }

          walk(node);
          return keys;
        }

        for (final bookmark in _allKinds()) {
          final leaked = allKeys(
            bookmark.toJson(),
          ).intersection(deviceLocalKeys);
          expect(leaked, isEmpty, reason: bookmark.id);
        }

        // And the M5 additions specifically: a workspace location is
        // {server, path}, its server ref {serverConfigId, identity} —
        // nothing else may ride along.
        final workspace = _allKinds().firstWhere(
          (bookmark) => bookmark.kind == BookmarkKind.workspace,
        );
        final json = workspace.toJson();
        for (final side in const ['left', 'right']) {
          final location = json[side] as Map<String, dynamic>;
          for (final key in location.keys) {
            expect(
              {'server', 'path'},
              contains(key),
              reason: '$side.$key',
            );
          }
        }
      },
    );
  });

  group('ordering and grouping', () {
    test('load returns bookmarks sorted by sortKey with the id tiebreak',
        () async {
      final path = pathIn('bookmarks.json');
      File(path).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'bookmarks': [
            _localBookmark('z', sortKey: 'm').toJson(),
            _localBookmark('a', sortKey: 'm').toJson(),
            _localBookmark('n', sortKey: 'am').toJson(),
          ],
        }),
      );

      final loaded = await FileBookmarkStore(path: path).load();

      expect(loaded.map((bookmark) => bookmark.id), ['n', 'a', 'z']);
    });

    test('sections order groups by name, ungrouped last', () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([
        _localBookmark('u1', sortKey: 'am'),
        _localBookmark('w1', sortKey: 'm'),
        _localBookmark('w2', sortKey: 'q'),
        _localBookmark('z1', sortKey: 'u'),
      ]);
      await store.moveToGroup('w1', 'work');
      await store.moveToGroup('w2', 'Work');
      await store.moveToGroup('z1', 'Zulu');

      final sections = await store.sections();

      // `work`/`Work` are one group (case-insensitive key, first spelling
      // wins); the ungrouped remainder sorts last.
      expect(sections.map((section) => section.name), ['work', 'Zulu', null]);
      expect(sections[0].bookmarks.map((b) => b.id), ['w1', 'w2']);
      expect(sections[1].bookmarks.map((b) => b.id), ['z1']);
      expect(sections[2].bookmarks.map((b) => b.id), ['u1']);
    });

    test('an entirely ungrouped store reports one anonymous section',
        () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([_localBookmark('a', sortKey: 'm')]);

      final sections = await store.sections();

      expect(sections, hasLength(1));
      expect(sections.single.name, isNull);
      expect(sections.single.bookmarks.single.id, 'a');
    });

    test('groupNames lists distinct groups sorted', () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([
        _localBookmark('a', sortKey: 'm'),
        _localBookmark('b', sortKey: 'q'),
      ]);
      await store.moveToGroup('a', 'Zeta');
      await store.moveToGroup('b', 'Alpha');

      expect(await store.groupNames(), ['Alpha', 'Zeta']);
    });
  });

  group('CRUD and reorder', () {
    test('save stamps updatedAt and persists', () async {
      final path = pathIn('bookmarks.json');
      final stamp = DateTime.utc(2026, 9, 19, 10);
      final store = FileBookmarkStore(path: path, now: () => stamp);
      final bookmark = _localBookmark('a', sortKey: 'm');

      final saved = await store.save(bookmark);

      expect(saved.updatedAt, stamp);
      expect(saved.createdAt, bookmark.createdAt);
      final reloaded = await FileBookmarkStore(path: path).load();
      expect(reloaded.single.updatedAt, stamp);
    });

    test('upsertAll keeps the record timestamps verbatim', () async {
      // The materialization path (import today, M6's pulled-record apply
      // through [applySynced]) must not restamp — LWW compares this tuple.
      final path = pathIn('bookmarks.json');
      final store =
          FileBookmarkStore(path: path, now: () => DateTime.utc(2030));
      await store.upsertAll([_localBookmark('a', sortKey: 'm')]);

      expect((await store.byId('a'))!.updatedAt, _fixedNow);
    });

    test('remove deletes the row and reports whether it existed', () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([_localBookmark('a', sortKey: 'm')]);

      expect(await store.remove('a'), isTrue);
      expect(await store.remove('a'), isFalse);
      expect(await FileBookmarkStore(path: path).load(), isEmpty);
    });

    test('reorder mints a key between the named neighbors', () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([
        _localBookmark('a', sortKey: 'am'),
        _localBookmark('b', sortKey: 'an'),
        _localBookmark('c', sortKey: 'z'),
      ]);

      final moved = await store.reorder('c', beforeId: 'a', afterId: 'b');

      expect(moved.sortKey.compareTo('am') > 0, isTrue);
      expect(moved.sortKey.compareTo('an') < 0, isTrue);
      expect(
        (await store.load()).map((bookmark) => bookmark.id),
        ['a', 'c', 'b'],
      );
    });

    test('reorder to head and tail stays inside the group', () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([
        _localBookmark('a', sortKey: 'm'),
        _localBookmark('b', sortKey: 'q'),
      ]);

      final head = await store.reorder('b', afterId: 'a');
      expect(head.sortKey.compareTo('m') < 0, isTrue);
      final tail = await store.reorder('b', beforeId: 'a');
      expect(tail.sortKey.compareTo('m') > 0, isTrue);
    });

    test('reorder rejects a neighbor outside the bookmark\'s group',
        () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([
        _localBookmark('a', sortKey: 'm'),
        _localBookmark('b', sortKey: 'q'),
      ]);
      await store.moveToGroup('b', 'Elsewhere');

      await expectLater(
        store.reorder('a', beforeId: 'b'),
        throwsArgumentError,
      );
    });

    test('moveToGroup refiles and lands at the group tail', () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([
        _localBookmark('a', sortKey: 'm'),
        _localBookmark('b', sortKey: 'q'),
      ]);
      await store.moveToGroup('a', 'Work');

      final moved = await store.moveToGroup('b', 'Work');
      expect(moved.group, 'Work');
      expect(moved.sortKey.compareTo('m') > 0, isTrue);
      expect(
        (await store.sections()).single.bookmarks.map((b) => b.id),
        ['a', 'b'],
      );
    });

    test('moveToGroup to ungrouped drops the group', () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([_localBookmark('a', sortKey: 'm')]);
      await store.moveToGroup('a', 'Work');

      final moved = await store.moveToGroup('a', null);

      expect(moved.group, isNull);
      expect((await store.byId('a'))!.group, isNull);
    });

    test('group and reorder stamp updatedAt on the moved bookmark only',
        () async {
      final path = pathIn('bookmarks.json');
      final stamp = DateTime.utc(2026, 9, 19, 11);
      final store = FileBookmarkStore(path: path, now: () => stamp);
      await store.upsertAll([
        _localBookmark('a', sortKey: 'm'),
        _localBookmark('b', sortKey: 'q'),
      ]);

      final moved = await store.reorder('b', afterId: 'a');
      expect(moved.updatedAt, stamp);
      expect((await store.byId('a'))!.updatedAt, _fixedNow);
    });

    test('sortKeyForInsert appends at the named group\'s tail', () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.upsertAll([_localBookmark('a', sortKey: 'm')]);
      await store.moveToGroup('a', 'Work');

      final key = await store.sortKeyForInsert(group: 'Work');
      expect(key.compareTo('m') > 0, isTrue);
      // Ungrouped tail is unaffected by group members.
      final ungrouped = await store.sortKeyForInsert();
      expect(ungrouped, 'm');
    });
  });

  group('sortKey normalization', () {
    test('a non-minted on-disk sortKey is re-keyed in memory', () async {
      // Interim writers minted `sortKey: <uuid>`; a key outside the a–z
      // alphabet cannot participate in `sortKeyBetween`, so load repairs
      // it deterministically (04 §2.5) instead of breaking reorder.
      final path = pathIn('bookmarks.json');
      File(path).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'bookmarks': [
            _localBookmark('legacy', sortKey: 'x9-deadbeef').toJson(),
            _localBookmark('ok', sortKey: 'm').toJson(),
          ],
        }),
      );

      final store = FileBookmarkStore(path: path);
      final loaded = await store.load();

      final legacy = loaded.singleWhere((b) => b.id == 'legacy');
      expect(isValidSortKey(legacy.sortKey), isTrue);
      // Repaired keys land at the tail, after every valid key.
      expect(loaded.map((b) => b.id), ['ok', 'legacy']);

      // And the repair persists at the next write.
      await store.upsertAll([_localBookmark('new', sortKey: 'zz')]);
      final written = ((jsonDecode(File(path).readAsStringSync()) as Map)[
              'bookmarks'] as List)
          .cast<Map>()
          .singleWhere((record) => record['id'] == 'legacy');
      expect(isValidSortKey(written['sortKey'] as String), isTrue);
    });

    test('a loaded legacy key never reaches a reorder\'s neighbor read',
        () async {
      // The first mutation after opening a legacy store can be a drag:
      // moveToGroup reads the neighbors' keys before any write runs, so
      // load-time normalization (not the write path's) is what keeps the
      // interim uuid out of sortKeyBetween. `legacy` sits in the target
      // group, so the tail-key computation reads its key as a neighbor.
      final path = pathIn('bookmarks.json');
      File(path).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'bookmarks': [
            _localBookmark('legacy', group: 'Work', sortKey: 'x9-deadbeef')
                .toJson(),
            _localBookmark('ok', sortKey: 'm').toJson(),
          ],
        }),
      );
      final store = FileBookmarkStore(path: path);

      final moved = await store.moveToGroup('ok', 'Work');
      expect(isValidSortKey(moved.sortKey), isTrue);
      expect(
        (await store.sections()).single.bookmarks.map((b) => b.id),
        ['legacy', 'ok'],
      );
    });

    test('a synced record carrying an invalid key is repaired on apply',
        () async {
      // M6's pulled records are verbatim-applied — but a pulled interim
      // `sortKey: <uuid>` must still be normalized before it can poison a
      // later reorder, so the store normalizes the edited map, not just the
      // pre-edit one.
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      await store.applySynced([
        _localBookmark('ok', sortKey: 'm'),
        _localBookmark('pulled', sortKey: 'x9-pulled-uuid'),
      ]);

      // A same-group move reads the repaired key, never the uuid.
      final moved = await store.moveToGroup('ok', 'Work');
      expect(isValidSortKey(moved.sortKey), isTrue);
      await store.moveToGroup('pulled', 'Work');
      final sections = await store.sections();
      expect(sections.single.bookmarks.map((b) => b.id), ['ok', 'pulled']);
      for (final bookmark in sections.single.bookmarks) {
        expect(isValidSortKey(bookmark.sortKey), isTrue);
      }
    });
  });

  group('payload size cap', () {
    test('a payload over 64 KiB refuses to save (04 §2.5 hard cap)',
        () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      final huge = Bookmark(
        id: 'huge',
        kind: BookmarkKind.localFolder,
        label: 'x' * (70 * 1024),
        localPath: '~/big',
        sortKey: 'm',
        createdAt: _fixedNow,
        updatedAt: _fixedNow,
      );

      await expectLater(
        store.upsertAll([huge]),
        throwsA(isA<BookmarkTooLargeException>()),
      );
      await expectLater(
        store.save(huge),
        throwsA(isA<BookmarkTooLargeException>()),
      );
      expect(File(path).existsSync(), isFalse);
    });
  });

  group('change events — the M6 coordinator seam', () {
    test('local mutations emit saved and removed changes', () async {
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      final events = <BookmarkStoreChange>[];
      final sub = store.changes.listen(events.add);
      addTearDown(sub.cancel);

      await store.save(_localBookmark('a', sortKey: 'm'));
      await store.upsertAll([_localBookmark('b', sortKey: 'q')]);
      await store.moveToGroup('a', 'Work');
      await store.remove('b');

      expect(
        events.whereType<BookmarkSavedChange>().map((c) => c.bookmark.id),
        ['a', 'b', 'a'],
      );
      expect(events.whereType<BookmarkRemovedChange>().single.id, 'b');
    });

    test('the sync-apply path stays quiet', () async {
      // M6's coordinator marks dirty on local saves; a pulled record
      // applied back through the store must not re-fire it (04 §3.2's
      // store-behind-callback split).
      final path = pathIn('bookmarks.json');
      final store = FileBookmarkStore(path: path);
      final events = <BookmarkStoreChange>[];
      final sub = store.changes.listen(events.add);
      addTearDown(sub.cancel);

      await store.applySynced([_localBookmark('a', sortKey: 'm')]);
      await store.removeSynced('a');

      expect(events, isEmpty);
      expect(await store.load(), isEmpty);
    });
  });
}

/// An in-memory [SshConfigFileSource] (mirrors the core import suite's fake).
class _FakeSshConfigSource implements SshConfigFileSource {
  _FakeSshConfigSource(this.files);

  final Map<String, String> files;

  @override
  Future<String?> readText(String path) async => files[path];

  @override
  Future<List<String>?> listLexical(String directory) async => null;
}
