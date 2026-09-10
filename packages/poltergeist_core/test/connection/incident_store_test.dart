import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

// The persisted incident record and its stores (owner decision 2a):
// device-local JSON, one record per bookmark id, atomic writes, owner-only
// on POSIX, fail-safe loading.

/// Must exceed the store's private abandonment bound (one hour) so the
/// sweep treats the temp as a crash artifact; a bound raised past this
/// fails the sweep test loudly instead of silently stopping it.
const _agedTemp = Duration(hours: 3);

IncidentRecord _record({
  String serverId = 'bm1',
  String host = 'example.com',
  int port = 22,
  String username = 'test',
  String? jumpHostId,
  String presented = 'SHA256:presented',
  String? pinned = 'SHA256:pinned',
}) => IncidentRecord(
  serverId: serverId,
  host: host,
  port: port,
  username: username,
  jumpHostId: jumpHostId,
  presentedFingerprintSha256: presented,
  pinnedFingerprintSha256: pinned,
);

void main() {
  group('IncidentRecord', () {
    test('round-trips through JSON verbatim', () {
      final record = _record(jumpHostId: 'jump-1', pinned: null);
      final decoded = IncidentRecord.fromJson(record.toJson());

      expect(decoded, record);
      expect(decoded.poolKey, record.poolKey);
      expect(
        record.poolKey,
        PoolKey(
          host: 'example.com',
          port: 22,
          username: 'test',
          jumpHostId: 'jump-1',
        ),
      );
    });

    test('normalizes the endpoint identity like PoolKey.of', () {
      // Parity with the factory live pools key under: any drift would
      // silently detach a persisted block from the pool it belongs to.
      final record = _record(host: '  Example.COM  ', username: ' Test ');
      final config = ServerConfig(
        id: 'bm1',
        label: 'bm1',
        host: record.host,
        port: record.port,
        username: record.username,
        authMethod: AuthMethod.privateKey,
        jumpHostId: record.jumpHostId,
        createdAt: 0,
        updatedAt: 0,
      );

      expect(record.poolKey, PoolKey.of(config));
      expect(
        record.poolKey,
        PoolKey(host: 'example.com', port: 22, username: 'Test'),
      );
    });

    test('rejects malformed records', () {
      Map<String, Object?> valid() => _record().toJson();

      final bad = <Map<String, Object?>>[
        valid()..['serverId'] = '',
        valid()..['host'] = 22,
        valid()..['host'] = '   ',
        valid()..['port'] = '22',
        valid()..['port'] = -1,
        valid()..['port'] = 0,
        valid()..['port'] = 65536,
        valid()..['username'] = null,
        valid()..['username'] = '   ',
        valid()..['jumpHostId'] = 42,
        valid()..['presentedFingerprintSha256'] = 3,
        valid()..['presentedFingerprintSha256'] = '',
        valid()..['pinnedFingerprintSha256'] = 3,
        valid()..['pinnedFingerprintSha256'] = '',
      ];
      for (final json in bad) {
        expect(
          () => IncidentRecord.fromJson(json),
          throwsFormatException,
          reason: 'must reject $json',
        );
      }
    });
  });

  group('InMemoryIncidentStore', () {
    test('loads, upserts by serverId, and removes', () async {
      final store = InMemoryIncidentStore();
      expect(await store.load(), isEmpty);

      await store.put(_record(serverId: 'a'));
      await store.put(_record(serverId: 'b', presented: 'SHA256:other'));
      await store.put(_record(serverId: 'a', pinned: null));
      expect(
        (await store.load()).map((r) => r.serverId),
        unorderedEquals(['a', 'b']),
      );
      expect(
        (await store.load())
            .singleWhere((r) => r.serverId == 'a')
            .pinnedFingerprintSha256,
        isNull,
      );

      await store.removeFor(
        'a',
        (await store.load()).singleWhere((r) => r.serverId == 'a').poolKey,
      );
      expect((await store.load()).map((r) => r.serverId), ['b']);
      await store.removeFor('missing', _record(serverId: 'missing').poolKey);

      // The scoped delete leaves a newer record under the same id alone:
      // a bookmark re-pointed to a new endpoint must not lose the new
      // endpoint's block when an old endpoint's block lifts.
      await store.put(_record(serverId: 'c', host: 'other.example'));
      await store.removeFor('c', _record(serverId: 'c').poolKey);
      expect(
        (await store.load()).singleWhere((r) => r.serverId == 'c').host,
        'other.example',
      );
      await store.removeAllFor('c');
      expect((await store.load()).map((r) => r.serverId), ['b']);
    });
  });

  group('FileIncidentStore', () {
    late Directory dir;
    late String path;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('incident-store-');
      path = '${dir.path}/incidents.json';
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on Object {
        // Best-effort test cleanup.
      }
    });

    test('an absent file loads empty', () async {
      expect(await FileIncidentStore(File(path)).load(), isEmpty);
    });

    test('persists across store instances', () async {
      await FileIncidentStore(File(path)).put(_record(serverId: 'a'));
      await FileIncidentStore(
        File(path),
      ).put(_record(serverId: 'b', pinned: null));

      final reloaded = FileIncidentStore(File(path));
      expect(
        (await reloaded.load()).map((r) => r.serverId),
        unorderedEquals(['a', 'b']),
      );

      await reloaded.removeFor(
        'a',
        (await reloaded.load()).singleWhere((r) => r.serverId == 'a').poolKey,
      );
      final afterRemoval = FileIncidentStore(File(path));
      expect((await afterRemoval.load()).map((r) => r.serverId), ['b']);
    });

    test('removeFor skips a record of a different endpoint', () async {
      final store = FileIncidentStore(File(path));
      await store.put(_record(serverId: 'a', host: 'other.example'));

      // The endpoint guard (and its early-return-before-flush) must hold
      // for the file store too, not only the in-memory one.
      await store.removeFor('a', _record(serverId: 'a').poolKey);

      final reloaded = FileIncidentStore(File(path));
      expect((await reloaded.load()).single.host, 'other.example');
      await store.removeFor('a', _record(host: 'other.example').poolKey);
      expect(await FileIncidentStore(File(path)).load(), isEmpty);
    });

    test('serializes concurrent writes without interleaving', () async {
      final store = FileIncidentStore(File(path));
      await Future.wait([
        for (var i = 0; i < 10; i++) store.put(_record(serverId: 'bm$i')),
      ]);
      expect((await store.load()), hasLength(10));

      await Future.wait([
        for (var i = 0; i < 5; i++)
          store.removeFor('bm$i', _record(serverId: 'bm$i').poolKey),
      ]);
      expect((await store.load()), hasLength(5));
    });

    test('a corrupt file loads empty and is quarantined', () async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString('not json at all');

      expect(await FileIncidentStore(file).load(), isEmpty);
      expect(await file.exists(), isFalse);

      final quarantined = await dir
          .list()
          .where((entry) => entry.path.contains('.corrupt-'))
          .toList();
      expect(quarantined, hasLength(1));
      expect(
        await File(quarantined.single.path).readAsString(),
        'not json at all',
      );
    });

    test(
      'an invalid-UTF-8 file quarantines and later writes recover',
      () async {
        final file = File(path);
        await file.parent.create(recursive: true);
        // A torn write's artifact: valid JSON prefix, then a half character.
        await file.writeAsBytes([...utf8.encode('[{"serverId":"a"}]'), 0xFF]);

        expect(await FileIncidentStore(file).load(), isEmpty);
        expect(await file.exists(), isFalse);

        // The store must not stay wedged: a fresh write lands cleanly.
        await FileIncidentStore(file).put(_record(serverId: 'b'));
        expect((await FileIncidentStore(file).load()).map((r) => r.serverId), [
          'b',
        ]);
      },
    );

    test('writes land owner-only on POSIX', () async {
      if (!Platform.isLinux && !Platform.isMacOS) {
        markTestSkipped('owner-only modes apply on desktop POSIX only');
        return;
      }

      final store = FileIncidentStore(File(path));
      await store.put(_record());
      final mode = FileStat.statSync(path).mode;
      expect(mode & 0x1FF, 0x180, reason: 'expected mode 0600, got $mode');
    });

    test('an unreadable file loads empty and stays in place', () async {
      if (!Platform.isLinux && !Platform.isMacOS) {
        markTestSkipped('mode-000 read denial applies on desktop POSIX only');
        return;
      }
      final uid = await Process.run('id', ['-u']);
      if ((uid.stdout as String).trim() == '0') {
        markTestSkipped('chmod 000 does not deny reads when running as root');
        return;
      }

      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString('[]');
      await Process.run('chmod', ['--', '000', file.path]);
      addTearDown(() => Process.run('chmod', ['--', '600', file.path]));

      // Unreadable ≠ corrupt: the load reads empty, the valid file stays.
      expect(await FileIncidentStore(file).load(), isEmpty);
      expect(await file.exists(), isTrue);
      final quarantine = await dir
          .list()
          .where((entry) => entry.path.contains('.corrupt-'))
          .toList();
      expect(quarantine, isEmpty);
    });

    test(
      'load failures reach the observer without changing the result',
      () async {
      final file = File(path);
      await file.parent.create(recursive: true);

      // Undecodable content: quarantine, empty load, and the error itself.
      await file.writeAsString('not json at all');
      final corrupt = <Object>[];
      expect(
        await FileIncidentStore(file, onLoadError: corrupt.add).load(),
        isEmpty,
      );
      expect(corrupt, hasLength(1));
      expect(corrupt.single, isA<FormatException>());

      // A torn write's invalid UTF-8 reports the same way.
      final quarantine = await dir
          .list()
          .where((entry) => entry.path.contains('.corrupt-'))
          .toList();
      await quarantine.single.delete();
      await file.writeAsBytes([...utf8.encode('[]'), 0xFF]);
      final torn = <Object>[];
      expect(
        await FileIncidentStore(file, onLoadError: torn.add).load(),
        isEmpty,
      );
      expect(torn.single, isA<FormatException>());
    });

    test(
      'an unreadable file reports a FileSystemException to the observer',
      () async {
      if (!Platform.isLinux && !Platform.isMacOS) {
        markTestSkipped('mode-000 read denial applies on desktop POSIX only');
        return;
      }
      if (await _runningAsRoot()) {
        markTestSkipped('chmod 000 does not deny reads when running as root');
        return;
      }

      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString('[]');
      await Process.run('chmod', ['--', '000', file.path]);
      addTearDown(() => Process.run('chmod', ['--', '600', file.path]));

      final observed = <Object>[];
      expect(
        await FileIncidentStore(file, onLoadError: observed.add).load(),
        isEmpty,
      );
      expect(observed.single, isA<FileSystemException>());
    });

    test('a throwing observer cannot break the fail-safe load', () async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString('not json at all');

      expect(
        await FileIncidentStore(file, onLoadError: (_) {
          throw StateError('The observer is diagnostics, not control flow.');
        }).load(),
        isEmpty,
      );
    });

    test('write failures are not load errors', () async {
      if (!Platform.isLinux && !Platform.isMacOS) {
        markTestSkipped('mode-500 write denial applies on desktop POSIX only');
        return;
      }
      if (await _runningAsRoot()) {
        markTestSkipped('chmod 500 does not deny writes when running as root');
        return;
      }

      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString('[]');
      final observed = <Object>[];
      final store = FileIncidentStore(file, onLoadError: observed.add);
      expect(await store.load(), isEmpty);

      // A read-only directory fails the temp create: the write propagates
      // (persistence is not fail-safe) and the load hook stays silent.
      await Process.run('chmod', ['--', '500', dir.path]);
      addTearDown(() => Process.run('chmod', ['--', '700', dir.path]));
      await expectLater(
        store.put(_record()),
        throwsA(isA<FileSystemException>()),
      );
      expect(observed, isEmpty);
    });

    test('load sweeps an abandoned temp and spares live ones', () async {
      final file = File(path);
      await file.parent.create(recursive: true);

      // A crash mid-write: the litter this store's own startup sweep owns.
      final abandoned = File('$path.tmp-abandoned');
      await abandoned.writeAsString('partial');
      await abandoned.setLastModified(DateTime.now().subtract(_agedTemp));

      // A write in flight right now — a reader's sweep must not take it,
      // or the writer's rename fails and the record is lost.
      final live = File('$path.tmp-live');
      await live.writeAsString('partial');

      // Another store's temp is that store's sweep's business.
      final sibling = File('${dir.path}/other.json.tmp-abandoned');
      await sibling.writeAsString('partial');
      await sibling.setLastModified(DateTime.now().subtract(_agedTemp));

      expect(await FileIncidentStore(file).load(), isEmpty);
      expect(await abandoned.exists(), isFalse);
      expect(await live.exists(), isTrue);
      expect(await sibling.exists(), isTrue);
    });

    test('the sweep matches a bare relative filename', () async {
      // A basename-only target's parent is '.', and listing '.' yields
      // './incidents.json.tmp-…': an unresolved prefix matches nothing, so
      // the sweep would silently never run for a relative wiring.
      final previous = Directory.current;
      Directory.current = dir;
      addTearDown(() => Directory.current = previous);

      final abandoned = File('incidents.json.tmp-abandoned');
      await abandoned.writeAsString('partial');
      await abandoned.setLastModified(DateTime.now().subtract(_agedTemp));
      final live = File('incidents.json.tmp-live');
      await live.writeAsString('partial');

      expect(await FileIncidentStore(File('incidents.json')).load(), isEmpty);
      expect(await abandoned.exists(), isFalse);
      expect(await live.exists(), isTrue);
    });

    test('an atomic write leaves no partial file behind', () async {
      final store = FileIncidentStore(File(path));
      await store.put(_record(serverId: 'a'));
      await store.put(_record(serverId: 'b', presented: 'SHA256:again'));

      final contents = jsonDecode(await File(path).readAsString()) as List;
      expect(contents, hasLength(2));
      final leftovers = await dir
          .list()
          .where((entry) => entry.path.contains('.tmp-'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });
}

Future<bool> _runningAsRoot() async {
  final uid = await Process.run('id', ['-u']);
  return (uid.stdout as String).trim() == '0';
}
