import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

// The persisted incident record and its stores (owner decision 2a):
// device-local JSON, one record per bookmark id, atomic writes, owner-only
// on POSIX, fail-safe loading.

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
      expect(
        _record(host: '  Example.COM  ', username: ' Test ').poolKey,
        PoolKey(host: 'example.com', port: 22, username: 'Test'),
      );
    });

    test('rejects malformed records', () {
      Map<String, Object?> valid() => _record().toJson();

      final bad = <Map<String, Object?>>[
        valid()..['serverId'] = '',
        valid()..['host'] = 22,
        valid()..['port'] = '22',
        valid()..['port'] = 0,
        valid()..['port'] = 65536,
        valid()..['username'] = null,
        valid()..['jumpHostId'] = 42,
        valid()..['presentedFingerprintSha256'] = 3,
        valid()..['pinnedFingerprintSha256'] = 3,
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

      await store.remove('a');
      expect((await store.load()).map((r) => r.serverId), ['b']);
      await store.remove('missing');
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

      await reloaded.remove('a');
      final afterRemoval = FileIncidentStore(File(path));
      expect((await afterRemoval.load()).map((r) => r.serverId), ['b']);
    });

    test('serializes concurrent writes without interleaving', () async {
      final store = FileIncidentStore(File(path));
      await Future.wait([
        for (var i = 0; i < 10; i++) store.put(_record(serverId: 'bm$i')),
      ]);
      expect((await store.load()), hasLength(10));

      await Future.wait([for (var i = 0; i < 5; i++) store.remove('bm$i')]);
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
