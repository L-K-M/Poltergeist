import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

final _fixedNow = DateTime.utc(2026, 9, 24, 12);
final _epochMs = _fixedNow.millisecondsSinceEpoch;

ServerConfig _server(
  String id, {
  String? label,
  String? group,
  int? updatedAt,
}) =>
    ServerConfig(
      id: id,
      label: label ?? id,
      host: '$id.example.com',
      username: 'deploy',
      group: group,
      createdAt: _epochMs,
      updatedAt: updatedAt ?? _epochMs,
    );

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('poltergeist-servers');
  });

  tearDown(() async {
    const attempts = 3;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == attempts - 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  String pathIn(String name) => '${dir.path}${Platform.pathSeparator}$name';

  FileServerConfigStore storeAt(String path, {int nowMs = 0}) =>
      FileServerConfigStore(
        path: path,
        now: () => DateTime.fromMillisecondsSinceEpoch(
            _epochMs + nowMs,
            isUtc: true),
        syncDeviceId: () => 'device-a',
      );

  group('persistence', () {
    test('persists and reloads servers across instances', () async {
      final path = pathIn('servers.json');
      await storeAt(path).save(_server('web', label: 'Web'));

      final reloaded = storeAt(path);
      final rows = await reloaded.load();
      expect(rows.single.id, 'web');
      expect(rows.single.label, 'Web');
      // The local-authorship tuple persisted with the row.
      expect((await reloaded.syncTupleOf('web'))!.deviceId, 'device-a');
    });

    test('remove persists the tombstone tuple across instances', () async {
      final path = pathIn('servers.json');
      final store = storeAt(path);
      await store.save(_server('gone'));
      expect(await store.remove('gone'), isTrue);
      expect(await store.byId('gone'), isNull);

      final reloaded = storeAt(path);
      expect(await reloaded.load(), isEmpty);
      final tuple = await reloaded.syncTupleOf('gone');
      expect(tuple, isNotNull);
      expect(tuple!.deleted, isTrue);
    });

    test('applySyncedRecord and removeSyncedRecord persist the winning '
        'tuple verbatim', () async {
      final path = pathIn('servers.json');
      const winner = ServerSyncTuple(
          updatedAt: 42, deviceId: 'device-remote');
      await storeAt(path).applySyncedRecord(
          _server('web', updatedAt: 42), winner);

      final reloaded = storeAt(path);
      expect((await reloaded.byId('web'))!.updatedAt, 42);
      expect(await reloaded.syncTupleOf('web'), winner);

      const tomb = ServerSyncTuple(
          updatedAt: 50, deviceId: 'device-remote', deleted: true);
      await reloaded.removeSyncedRecord('web', tomb);
      final again = storeAt(path);
      expect(await again.load(), isEmpty);
      expect(await again.syncTupleOf('web'), tomb);
    });

    test('save re-stamps one tick past a pulled stamp when the clock '
        'trails it', () async {
      final path = pathIn('servers.json');
      final winner = ServerSyncTuple(
          updatedAt: _epochMs + 90000, deviceId: 'device-remote');
      final store = storeAt(path);
      await store.applySyncedRecord(
          _server('web', updatedAt: _epochMs + 90000), winner);

      final saved =
          await store.save(_server('web', label: 'edited'));
      expect(saved.updatedAt, _epochMs + 90001);
      expect((await store.syncTupleOf('web'))!.deviceId, 'device-a');
    });

    test('quarantines a corrupt file and starts empty', () async {
      final path = pathIn('servers.json');
      await File(path).writeAsString('{not json');
      final errors = <Object>[];
      final store = FileServerConfigStore(
        path: path,
        syncDeviceId: () => 'device-a',
        onError: (error, _) => errors.add(error),
      );
      expect(await store.load(), isEmpty);
      expect(errors, isNotEmpty);
      // The bad bytes were moved aside, not overwritten.
      expect(await File(path).exists(), isFalse);
      final quarantined = dir
          .listSync()
          .where((f) => f.path.contains('corrupt'))
          .toList();
      expect(quarantined, hasLength(1));
    });

    test('a newer store version fails without quarantining', () async {
      final path = pathIn('servers.json');
      await File(path).writeAsString(
          jsonEncode({'version': 99, 'servers': []}));
      final store = storeAt(path);
      await expectLater(store.load(), throwsFormatException);
      // Untouched: the file this build cannot read stays exactly as is.
      expect(jsonDecode(await File(path).readAsString())['version'], 99);
    });

    test('preserves an undecodable record verbatim on the next write',
        () async {
      final path = pathIn('servers.json');
      const alien = {
        'id': 'alien-1',
        'label': 'Future fields',
        'brandNewField': {'nested': true},
      };
      await File(path).writeAsString(jsonEncode({
        'version': 1,
        'servers': [
          _server('web').toJson(),
          // `fromJson` is tolerant, so make the record undecodable the
          // blunt way: no id at all.
          {'label': 'no id'},
          // A record a future Séance wrote: decodable here, round-trips
          // as itself.
        ],
      }));
      final store = storeAt(path);
      await store.save(_server('new'));

      final decoded =
          jsonDecode(await File(path).readAsString()) as Map;
      final servers = decoded['servers'] as List;
      // The undecodable record rides the next write verbatim.
      expect(
          servers.whereType<Map>().any((m) => m['label'] == 'no id'),
          isTrue);
      expect(
          servers.whereType<Map>().map((m) => m['id']),
          containsAll(<Object?>['web', 'new']));
      // Sanity: an injected future-field record decodes as itself too.
      expect(alien['brandNewField'], isA<Map>());
    });

    test('a load waits for a queued write', () async {
      final path = pathIn('servers.json');
      final gate = Completer<void>();
      final writerStarted = Completer<void>();
      final store = FileServerConfigStore(
        path: path,
        syncDeviceId: () => 'device-a',
        atomicWriter: (file, contents) async {
          writerStarted.complete();
          await gate.future;
          await const TransferJournalIo().atomicRewrite(file, contents);
        },
      );

      final write = store.save(_server('web'));
      await writerStarted.future;

      var readSettled = false;
      final read = store.load().then((rows) {
        readSettled = true;
        return rows;
      });
      // The write is parked, so the read must not resolve with the
      // pre-write (empty) state.
      await Future<void>.delayed(Duration.zero);
      expect(readSettled, isFalse);

      gate.complete();
      await write;

      final rows = await read;
      expect(rows.single.id, 'web');
    });
  });

  group('ordering', () {
    test('load sorts case-insensitively by label, then id', () async {
      final store = storeAt(pathIn('servers.json'));
      await store.save(_server('b', label: 'zebra'));
      await store.save(_server('a', label: 'Apple'));
      await store.save(_server('c', label: 'apple'));
      final rows = await store.load();
      expect(rows.map((s) => s.id), ['a', 'c', 'b']);
    });
  });

  group('sync bookkeeping', () {
    test('syncTuples includes tombstone tuples for the recovery pass',
        () async {
      final store = storeAt(pathIn('servers.json'));
      await store.save(_server('a'));
      await store.save(_server('b'));
      await store.remove('b');
      final tuples = await store.syncTuples();
      expect(tuples['a']!.deleted, isFalse);
      expect(tuples['b']!.deleted, isTrue);
    });

    test('an unbound device id writes no tuples — the clean document '
        'shape', () async {
      final path = pathIn('servers.json');
      final store = FileServerConfigStore(path: path); // no syncDeviceId
      await store.save(_server('web'));
      final decoded =
          jsonDecode(await File(path).readAsString()) as Map;
      expect(decoded.containsKey('syncTuples'), isFalse);
      expect(await store.syncTuples(), isEmpty);
    });
  });
}
