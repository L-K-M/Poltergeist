import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

final _fixedNow = DateTime.utc(2026, 9, 20, 12);

/// Separator-robust basename (listSync joins with the host separator).
String _basenameOf(String path) => path.split(RegExp(r'[\\/]')).last;

EncryptedRecord _record(
  String id, {
  int updatedAt = 100,
  String deviceId = 'device-a',
  bool deleted = false,
  int? seq,
  List<int>? blob,
}) =>
    EncryptedRecord(
      id: id,
      updatedAt: updatedAt,
      deviceId: deviceId,
      deleted: deleted,
      seq: seq,
      blob: Uint8List.fromList(blob ?? const [1, 2, 3]),
    );

EncryptedRecord _tombstone(
  String id, {
  int updatedAt = 100,
  String deviceId = 'device-a',
  int? seq,
}) =>
    EncryptedRecord(
      id: id,
      updatedAt: updatedAt,
      deviceId: deviceId,
      deleted: true,
      seq: seq,
      blob: Uint8List(0),
    );

void main() {
  late Directory tempDir;
  late String path;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('record_store_test');
    path = '${tempDir.path}/sync_records.json';
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  PersistentLocalRecordStore open({
    DateTime Function()? now,
    void Function(Object, StackTrace)? onError,
  }) =>
      PersistentLocalRecordStore(path: path, now: now, onError: onError);

  group('mutation and reload', () {
    test('persists records, dirty flags, and both cursors across reload',
        () async {
      final store = open();
      await store.putLocal(_record('bookmark:a', updatedAt: 50));
      await store.putRemote(_record('bookmark:b', updatedAt: 60, seq: 7));
      await store.setHighWaterSeq(9);
      await store.setLastAppliedSeq(8);

      final reloaded = open();
      final records = await reloaded.allRecords();
      expect(records, hasLength(2));
      expect((await reloaded.dirtyRecords()).map((r) => r.id),
          ['bookmark:a']);
      expect(await reloaded.highWaterSeq(), 9);
      expect(await reloaded.lastAppliedSeq(), 8);
      expect(
          (await reloaded.getRecord('bookmark:b'))!.seq, 7);
    });

    test('markSynced clears dirty and stamps the server seq', () async {
      final store = open();
      await store.putLocal(_record('bookmark:a'));
      await store.markSynced('bookmark:a', 12);

      final reloaded = open();
      expect(await reloaded.dirtyRecords(), isEmpty);
      expect((await reloaded.getRecord('bookmark:a'))!.seq, 12);
    });

    test('highWaterSeq and lastAppliedSeq only advance', () async {
      final store = open();
      await store.setHighWaterSeq(10);
      await store.setHighWaterSeq(5);
      await store.setLastAppliedSeq(9);
      await store.setLastAppliedSeq(3);
      expect(await store.highWaterSeq(), 10);
      expect(await store.lastAppliedSeq(), 9);
    });

    test('resetSyncCursors zeroes both cursors for a full resync', () async {
      final store = open();
      await store.setHighWaterSeq(10);
      await store.setLastAppliedSeq(9);
      await store.resetSyncCursors();
      expect(await store.highWaterSeq(), 0);
      expect(await store.lastAppliedSeq(), 0);
      // The reset must be durable: a restart cannot resurrect stale
      // cursors and skip the records that needed re-pulling.
      final reloaded = open();
      expect(await reloaded.highWaterSeq(), 0);
      expect(await reloaded.lastAppliedSeq(), 0);
    });
  });

  group('atomic writes', () {
    test('every mutation leaves a complete JSON document on disk', () async {
      final store = open();
      await store.putLocal(_record('bookmark:a'));
      final decoded =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      expect(decoded['version'], 1);
      expect(decoded['highWaterSeq'], 0);
      expect(decoded['lastAppliedSeq'], 0);
      expect(decoded['records'], hasLength(1));
      expect(decoded['records'][0]['dirty'], isTrue);
    });

    test('no stray temp siblings remain after writes', () async {
      final store = open();
      await store.putLocal(_record('bookmark:a'));
      await store.putRemote(_record('bookmark:b', seq: 3));
      final siblings =
          tempDir.listSync().map((entity) => _basenameOf(entity.path)).toList();
      expect(siblings, ['sync_records.json']);
    });
  });

  group('LWW merge and tombstones', () {
    test('putRemote stores a winning pulled record clean', () async {
      final store = open();
      await store.putLocal(_record('bookmark:a', updatedAt: 10));
      await store.putRemote(_record('bookmark:a', updatedAt: 20, seq: 4));
      expect((await store.getRecord('bookmark:a'))!.updatedAt, 20);
      expect(await store.dirtyRecords(), isEmpty);
    });

    test('putRemote never overwrites a dirty local record that beats it',
        () async {
      final store = open();
      await store.putLocal(_record('bookmark:a', updatedAt: 30));
      await store.putRemote(_record('bookmark:a', updatedAt: 20, seq: 4));
      final kept = await store.getRecord('bookmark:a');
      expect(kept!.updatedAt, 30);
      expect(await store.dirtyRecords(), isNotEmpty);
    });

    test('a losing pulled record is stashed as the displaced winner',
        () async {
      final store = open();
      await store.putLocal(_record('bookmark:a', updatedAt: 30));
      // The server's copy loses to the dirty local — but it is still the
      // record the server holds, and must resurface if the push is rejected.
      await store.putRemote(_record('bookmark:a', updatedAt: 20, seq: 4));

      // Restore through a freshly opened store: the stash must round-trip
      // through disk, since the pull cursor has already moved past its seq.
      final reloaded = open();
      final restored = await reloaded.restoreDisplaced('bookmark:a');
      expect(restored, isNotNull);
      expect(restored!.updatedAt, 20);
      expect(restored.seq, 4);
      expect(await reloaded.dirtyRecords(), isEmpty);
      // Consume-on-restore: a second call must not resurrect a stale copy.
      expect(await reloaded.restoreDisplaced('bookmark:a'), isNull);
    });

    test('putLocal evicting a clean pulled winner stashes it displaced',
        () async {
      final store = open();
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      // A clock-skewed local edit loses to the pulled winner's tuple.
      await store.putLocal(_record('bookmark:a', updatedAt: 100));

      expect((await store.dirtyRecords()).single.updatedAt, 100);
      final reloaded = open();
      final restored = await reloaded.restoreDisplaced('bookmark:a');
      expect(restored!.updatedAt, 200);
      expect(restored.seq, 5);
      expect(await reloaded.dirtyRecords(), isEmpty);
    });

    test('restoreDisplaced waits for a queued write that stashes the winner',
        () async {
      final store = open();
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      // Queue the displacing putLocal: the stash lands inside the
      // serialized write, so restoreDisplaced must drain the write tail
      // before answering.
      final put = store.putLocal(_record('bookmark:a', updatedAt: 100));
      final restored = await store.restoreDisplaced('bookmark:a');
      expect(restored, isNotNull);
      expect(restored!.updatedAt, 200);
      await put;
    });

    test('restoreDisplaced is null when nothing was displaced', () async {
      final store = open();
      await store.putLocal(_record('bookmark:a', updatedAt: 30));
      expect(await store.restoreDisplaced('bookmark:a'), isNull);
    });

    test('markSynced drops the displaced stash once the push is accepted',
        () async {
      final store = open();
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      await store.putLocal(_record('bookmark:a', updatedAt: 300));
      // A winning local edit is accepted — the displaced copy is dead.
      await store.markSynced('bookmark:a', 9);
      expect(await store.restoreDisplaced('bookmark:a'), isNull);
    });

    test('tombstone wins over an older pulled edit and stays in the store',
        () async {
      final store = open();
      await store.putLocal(_tombstone('bookmark:a', updatedAt: 50));
      await store.putRemote(_record('bookmark:a', updatedAt: 40, seq: 3));
      final kept = await store.getRecord('bookmark:a');
      expect(kept!.deleted, isTrue);
      expect(kept.updatedAt, 50);
      // The tombstone is retained indefinitely — never GC'd.
      expect(await store.allRecords(), hasLength(1));
    });

    test('a newer pulled edit legitimately beats a tombstone', () async {
      final store = open();
      await store.putLocal(_tombstone('bookmark:a', updatedAt: 10));
      await store.putRemote(_record('bookmark:a', updatedAt: 20, seq: 6));
      expect((await store.getRecord('bookmark:a'))!.deleted, isFalse);
    });

    test('LWW tie breaks on deviceId', () async {
      final store = open();
      await store.putRemote(
          _record('bookmark:a', updatedAt: 10, deviceId: 'zzz', seq: 1));
      await store.putRemote(
          _record('bookmark:a', updatedAt: 10, deviceId: 'aaa', seq: 2));
      expect((await store.getRecord('bookmark:a'))!.deviceId, 'zzz');
    });
  });

  group('corrupt-store quarantine', () {
    test('a corrupt file is quarantined and the store restarts empty',
        () async {
      File(path).writeAsStringSync('{not json');
      final errors = <Object>[];
      final store = open(
          now: () => _fixedNow, onError: (error, _) => errors.add(error));

      expect(await store.allRecords(), isEmpty);
      expect(errors, hasLength(1));

      final quarantined = tempDir
          .listSync()
          .map((entity) => _basenameOf(entity.path))
          .where((name) => name.contains('.corrupt-'))
          .toList();
      expect(quarantined, hasLength(1));
      expect(quarantined.single, startsWith('sync_records.json.corrupt-'));
      expect(store.quarantinedPath, isNotNull);
    });

    test('a same-timestamp second corruption gets a distinct counter name',
        () async {
      File(path).writeAsStringSync('{not json');
      await open(now: () => _fixedNow).allRecords();

      // Corrupt the freshly recreated file at the same injected instant.
      File(path).writeAsStringSync('["still not a map doc"');
      await open(now: () => _fixedNow).allRecords();

      final quarantined = tempDir
          .listSync()
          .map((entity) => _basenameOf(entity.path))
          .where((name) => name.contains('.corrupt-'))
          .toList();
      expect(quarantined, hasLength(2));
    });

    test('a document with no version field is quarantined, not adopted',
        () async {
      // A versionless map was never written by this build — it quarantines
      // like any other malformed root rather than loading as v1.
      File(path).writeAsStringSync(
          '{"highWaterSeq":0,"lastAppliedSeq":0,"records":[]}');
      final errors = <Object>[];
      final store =
          open(now: () => _fixedNow, onError: (error, _) => errors.add(error));
      expect(await store.allRecords(), isEmpty);
      expect(errors, hasLength(1));
      expect(
          tempDir
              .listSync()
              .where((e) => _basenameOf(e.path).contains('.corrupt-')),
          hasLength(1));
    });

    test('a double version equal to the store version still quarantines',
        () async {
      // JSON 1.0 decodes as a double; numeric equality with 1 must not
      // adopt the foreign document as v1.
      File(path).writeAsStringSync(
          '{"version":1.0,"highWaterSeq":0,"lastAppliedSeq":0,'
          '"records":[]}');
      final errors = <Object>[];
      final store =
          open(now: () => _fixedNow, onError: (error, _) => errors.add(error));
      expect(await store.allRecords(), isEmpty);
      expect(errors, hasLength(1));
      expect(
          tempDir
              .listSync()
              .where((e) => _basenameOf(e.path).contains('.corrupt-')),
          hasLength(1));
    });

    test('a non-int watermark field is quarantined, not cast', () async {
      File(path).writeAsStringSync(
          '{"version":1,"highWaterSeq":"oops","lastAppliedSeq":0,'
          '"records":[]}');
      final errors = <Object>[];
      final store =
          open(now: () => _fixedNow, onError: (error, _) => errors.add(error));
      expect(await store.allRecords(), isEmpty);
      expect(await store.highWaterSeq(), 0);
      expect(errors, hasLength(1));
      expect(
          tempDir
              .listSync()
              .where((e) => _basenameOf(e.path).contains('.corrupt-')),
          hasLength(1));
    });

    test('a newer document version fails closed without quarantining',
        () async {
      File(path).writeAsStringSync(
          '{"version":2,"highWaterSeq":0,"lastAppliedSeq":0,"records":[]}');
      final store = open(now: () => _fixedNow);
      await expectLater(store.allRecords(), throwsFormatException);
      // The unreadable newer file stays put rather than being moved aside.
      expect(File(path).readAsStringSync(), contains('"version":2'));
    });
  });
}
