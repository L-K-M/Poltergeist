import 'dart:io';
import 'dart:typed_data';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'fake_sync_api.dart';

final _key = List<int>.unmodifiable(List<int>.generate(32, (i) => i));
final _epoch = DateTime.utc(2026, 9, 20, 12);
final _epochMs = _epoch.millisecondsSinceEpoch;

/// A controllable wall clock shared by a "device"'s store and coordinator.
final class _Clock {
  _Clock(this.ms);
  int ms;
  DateTime call() => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// One "device": record store + bookmark store + pin store + coordinator.
final class _Device {
  _Device._();

  late final Directory dir;
  late PersistentLocalRecordStore records;
  late final FileBookmarkStore bookmarks;
  late final InMemoryHostKeyStore hostKeys;
  late final InMemoryPinVerdictStore verdicts;
  late final InMemorySyncTripwireStore tripwires;
  late final RecordCrypto crypto;
  late BookmarkCoordinator coordinator;
  late final _Clock clock;
  late final SeanceServerCatalog? catalog;
  late final String deviceId;

  static Future<_Device> create(
    Directory parent,
    String name, {
    bool shared = false,
  }) async {
    final device = _Device._()
      ..deviceId = 'device-$name'
      ..clock = _Clock(_epochMs);
    device.dir = await Directory('${parent.path}/$name').create();
    device.records = PersistentLocalRecordStore(
      path: '${device.dir.path}/sync_records.json',
      now: device.clock.call,
    );
    device.bookmarks = FileBookmarkStore(
      path: '${device.dir.path}/bookmarks.json',
      now: device.clock.call,
      syncDeviceId: () => device.deviceId,
    );
    device.hostKeys = InMemoryHostKeyStore();
    device.verdicts = InMemoryPinVerdictStore();
    device.tripwires = InMemorySyncTripwireStore();
    device.crypto = RecordCrypto(RecordCodec(_key));
    device.catalog = shared ? SeanceServerCatalog() : null;
    device.coordinator = BookmarkCoordinator(
      records: device.records,
      bookmarks: device.bookmarks,
      hostKeys: device.hostKeys,
      crypto: device.crypto,
      deviceId: device.deviceId,
      pinVerdicts: device.verdicts,
      tripwires: device.tripwires,
      catalog: device.catalog,
      now: device.clock.call,
    );
    return device;
  }
}

Bookmark _bookmark(String id, {String? label}) => Bookmark(
      id: id,
      kind: BookmarkKind.localFolder,
      label: label ?? id,
      localPath: '/home/user/$id',
      sortKey: 'm',
      createdAt: _epoch,
      updatedAt: _epoch,
    );

EncryptedRecord _enc(
  String id, {
  int updatedAt = 0,
  String deviceId = 'foreign-device',
  bool deleted = false,
  List<int>? blob,
}) =>
    EncryptedRecord(
      id: id,
      updatedAt: updatedAt,
      deviceId: deviceId,
      deleted: deleted,
      seq: null,
      blob: Uint8List.fromList(blob ?? const [9]),
    );

/// Seal a raw payload map (any kind name — incl. kinds this build does not
/// know) under [id], the way a foreign/newer client would.
Future<EncryptedRecord> _sealRaw(
  String id,
  Map<String, dynamic> payload, {
  int updatedAt = 0,
  String deviceId = 'foreign-device',
}) async =>
    EncryptedRecord(
      id: id,
      updatedAt: updatedAt,
      deviceId: deviceId,
      deleted: false,
      seq: null,
      blob: await VaultCrypto.sealJson(_key, payload),
    );

Future<EncryptedRecord> _sealBookmark(
  Bookmark bookmark, {
  int? updatedAt,
  String deviceId = 'foreign-device',
}) =>
    RecordCrypto(RecordCodec(_key)).seal(DecryptedRecord(
      id: 'bookmark:${bookmark.id}',
      kind: RecordKind.bookmark,
      updatedAt:
          updatedAt ?? bookmark.updatedAt.toUtc().millisecondsSinceEpoch,
      deviceId: deviceId,
      data: bookmark.toJson(),
    ));

/// Save locally and hand the stamped row to the coordinator — the same
/// pair `BookmarkStore.save` + `changes` performs in production.
Future<Bookmark> _save(_Device device, Bookmark bookmark) async {
  final saved = await device.bookmarks.save(bookmark);
  await device.coordinator.onBookmarkSaved(saved);
  return saved;
}

Future<void> _delete(_Device device, String id) async {
  await device.bookmarks.remove(id);
  await device.coordinator.onBookmarkDeleted(id);
}

void main() {
  late Directory tempDir;
  late FakeSyncApi server;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('coordinator_test');
    server = FakeSyncApi();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('dirty marking', () {
    test('onBookmarkSaved seals a bookmark record marked dirty', () async {
      final device = await _Device.create(tempDir, 'a');
      await _save(device, _bookmark('b1'));

      final dirty = await device.records.dirtyRecords();
      expect(dirty, hasLength(1));
      expect(dirty.single.id, 'bookmark:b1');
      final dec = await device.crypto.open(dirty.single);
      expect(dec.kind, RecordKind.bookmark);
      expect(dec.deviceId, device.deviceId);
      expect(Bookmark.fromJson(dec.data, recordId: dec.id).label, 'b1');
    });

    test('onBookmarkDeleted writes a real tombstone (empty blob, deleted)',
        () async {
      final device = await _Device.create(tempDir, 'a');
      await _save(device, _bookmark('b1'));
      await _delete(device, 'b1');

      final record = await device.records.getRecord('bookmark:b1');
      expect(record, isNotNull);
      expect(record!.deleted, isTrue);
      expect(record.blob, isEmpty);
      expect(await device.records.dirtyRecords(), isNotEmpty);
    });
  });

  group('two-device convergence', () {
    test('create, edit, and delete converge across devices', () async {
      final a = await _Device.create(tempDir, 'a');
      final b = await _Device.create(tempDir, 'b');

      await _save(a, _bookmark('shared', label: 'v1'));
      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect((await b.bookmarks.byId('shared'))!.label, 'v1');

      b.clock.ms += 1000;
      await _save(b, _bookmark('shared', label: 'v2'));
      await b.coordinator.runRound(server);
      await a.coordinator.runRound(server);
      expect((await a.bookmarks.byId('shared'))!.label, 'v2');

      a.clock.ms += 2000;
      await _delete(a, 'shared');
      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect(await b.bookmarks.byId('shared'), isNull);
      await b.coordinator.runRound(server);
      await a.coordinator.runRound(server);
      expect(await b.bookmarks.byId('shared'), isNull);
      expect(await a.bookmarks.byId('shared'), isNull);
    });

    test('a delete that loses LWW to a newer concurrent edit resolves to '
        'the edit — the bookmark reappears', () async {
      final a = await _Device.create(tempDir, 'a');
      final b = await _Device.create(tempDir, 'b');

      await _save(a, _bookmark('x'));
      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);

      a.clock.ms += 500;
      await _delete(a, 'x');
      b.clock.ms += 1000;
      await _save(b, _bookmark('x', label: 'edited'));

      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      await a.coordinator.runRound(server);

      expect((await a.bookmarks.byId('x'))!.label, 'edited');
      expect((await b.bookmarks.byId('x'))!.label, 'edited');
    });

    test('a tombstone that wins stays won — a stale live copy cannot '
        'displace it on the server or on a peer', () async {
      final a = await _Device.create(tempDir, 'a');
      final b = await _Device.create(tempDir, 'b');

      await _save(a, _bookmark('doomed'));
      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect(await b.bookmarks.byId('doomed'), isNotNull);

      a.clock.ms += 1000;
      await _delete(a, 'doomed');
      await a.coordinator.runRound(server);
      expect(server.records['bookmark:doomed']!.deleted, isTrue);

      // A stale live copy pushed by a device that never saw the delete:
      // it loses the same LWW compare on the server and never lands.
      final stale = await _sealBookmark(_bookmark('doomed', label: 'stale'),
          updatedAt: 5, deviceId: 'stale-device');
      expect(server.seed(stale), isFalse);
      expect(server.records['bookmark:doomed']!.deleted, isTrue);

      await b.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect(await b.bookmarks.byId('doomed'), isNull);
      // The tombstone record itself is retained indefinitely.
      expect(
          (await b.records.getRecord('bookmark:doomed'))!.deleted, isTrue);
    });
  });

  group('skip-and-preserve', () {
    test('a flurb-kind record survives rounds byte-identical', () async {
      final device = await _Device.create(tempDir, 'a');
      final flurb = await _sealRaw(
          'flurb:x1', {'kind': 'flurb', 'data': {'what': 'ever'}});
      server.seed(flurb);

      await device.coordinator.runRound(server);
      await _save(device, _bookmark('mine'));
      await device.coordinator.runRound(server);
      await device.coordinator.runRound(server);

      expect(server.records['flurb:x1']!.blob, flurb.blob);
      final local = await device.records.getRecord('flurb:x1');
      expect(local!.blob, flurb.blob);
      // Never re-pushed, never tombstoned, never decoded.
      expect((await device.records.dirtyRecords()).map((r) => r.id),
          isNot(contains('flurb:x1')));
      expect(await device.tripwires.trippedIds(), isEmpty);
    });

    test('a malformed bookmark record is skipped without aborting the round',
        () async {
      final device = await _Device.create(tempDir, 'a');
      final malformed = await _sealRaw(
          'bookmark:bad', {'kind': 'bookmark', 'data': {'id': 'bad'}});
      final good = await _sealBookmark(_bookmark('good', label: 'ok'));
      server.seed(malformed);
      server.seed(good);

      final result = await device.coordinator.runRound(server);
      expect(await device.records.getRecord('bookmark:bad'), isNotNull);
      expect(await device.tripwires.trippedIds(), contains('bookmark:bad'));
      expect((await device.bookmarks.byId('good'))!.label, 'ok');
      expect(result.report.appliedIds, contains('bookmark:good'));
    });

    test('a relabeled secret under a bookmark: id is never applied',
        () async {
      final device = await _Device.create(tempDir, 'a');
      final relabeled = await _sealRaw('bookmark:sneaky',
          {'kind': 'secret', 'data': {'id': 's1', 'blob': 'hunter2'}});
      server.seed(relabeled);

      await device.coordinator.runRound(server);
      expect(await device.bookmarks.byId('sneaky'), isNull);
      expect(await device.bookmarks.load(), isEmpty);
      expect(
          await device.tripwires.trippedIds(), contains('bookmark:sneaky'));
      expect((await device.records.getRecord('bookmark:sneaky'))!.blob,
          relabeled.blob);
    });

    test('an undecryptable bookmark record is preserved without tripping',
        () async {
      final device = await _Device.create(tempDir, 'a');
      final foreignKey = List<int>.generate(32, (i) => 255 - i);
      server.seed(_enc(
        'bookmark:sealed',
        updatedAt: 1,
        blob: await VaultCrypto.sealJson(
            foreignKey, {'kind': 'bookmark', 'data': {}}),
      ));

      await device.coordinator.runRound(server);
      expect(await device.records.getRecord('bookmark:sealed'), isNotNull);
      expect(await device.tripwires.trippedIds(), isEmpty);
      expect(await device.bookmarks.load(), isEmpty);
    });
  });

  group('tuple guard and deferral', () {
    test('a pulled record losing to a materialized tombstone tuple defers '
        'instead of resurrecting the row', () async {
      final device = await _Device.create(tempDir, 'a');
      await _save(device, _bookmark('gone'));
      device.clock.ms += 1000;
      // The delete materializes the tombstone tuple; the coordinator's
      // dirty tombstone has not landed yet (the save/remove gap).
      await device.bookmarks.remove('gone');

      // A pulled live record older than the deletion wins the store merge
      // against the pre-delete row but must not resurrect it.
      final stale =
          (await _sealBookmark(_bookmark('gone'), updatedAt: 5)).withSeq(3);
      await device.records.putRemote(stale);

      final report = await device.coordinator.applyPulled();
      expect(report.deferredIds, contains('bookmark:gone'));
      expect(await device.bookmarks.byId('gone'), isNull);
      expect(await device.records.lastAppliedSeq(), 0);

      // Once the tombstone lands and pushes, the deferral resolves.
      await device.coordinator.onBookmarkDeleted('gone');
      await device.coordinator.runRound(server);
      expect(await device.bookmarks.byId('gone'), isNull);
      expect(await device.records.lastAppliedSeq(), greaterThan(0));
    });

    test('a rejected push resurfaces the evicted pulled winner', () async {
      final device = await _Device.create(tempDir, 'a');
      final winner = await _sealBookmark(
          _bookmark('r', label: 'remote'),
          updatedAt: _epochMs + 100000,
          deviceId: 'device-b');
      server.seed(winner);
      await device.coordinator.runRound(server);
      expect((await device.bookmarks.byId('r'))!.label, 'remote');

      // This device's clock is behind: its edit loses server-side.
      device.clock.ms = _epochMs + 10;
      await _save(device, _bookmark('r', label: 'local-loser'));

      await device.coordinator.runRound(server);
      expect((await device.bookmarks.byId('r'))!.label, 'remote');
      expect(await device.records.dirtyRecords(), isEmpty);
      expect(
          (await device.records.getRecord('bookmark:r'))!.deviceId,
          'device-b');
    });

    test('LWW ties apply idempotently and advance the cursor', () async {
      final device = await _Device.create(tempDir, 'a');
      await _save(device, _bookmark('tie'));
      await device.coordinator.runRound(server);
      final cursor = await device.records.lastAppliedSeq();
      expect(cursor, greaterThan(0));

      final result = await device.coordinator.runRound(server);
      expect(result.report.deferredIds, isEmpty);
      expect(await device.records.lastAppliedSeq(), cursor);
    });
  });

  group('delta bookkeeping', () {
    test('pulls are deltas off highWaterSeq and the apply cursor persists',
        () async {
      final device = await _Device.create(tempDir, 'a');
      server.seed(await _sealBookmark(_bookmark('p1'), updatedAt: 1));
      await device.coordinator.runRound(server);
      expect(await device.records.highWaterSeq(), greaterThan(0));
      expect(await device.records.lastAppliedSeq(), greaterThan(0));

      // A restarted store carries both cursors: the next pull is a delta.
      final restarted = PersistentLocalRecordStore(
          path: '${device.dir.path}/sync_records.json');
      expect(await restarted.highWaterSeq(), greaterThan(0));
      device.records = restarted;
      device.coordinator = BookmarkCoordinator(
        records: restarted,
        bookmarks: device.bookmarks,
        hostKeys: device.hostKeys,
        crypto: device.crypto,
        deviceId: device.deviceId,
        pinVerdicts: device.verdicts,
        tripwires: device.tripwires,
        catalog: device.catalog,
        now: device.clock.call,
      );
      final result = await device.coordinator.runRound(server);
      // A true delta: nothing new on the server, nothing re-applies.
      expect(result.report.appliedIds, isEmpty);
      expect(await device.bookmarks.byId('p1'), isNotNull);
    });

    test('a rejected cursor triggers a one-time full resync', () async {
      final device = await _Device.create(tempDir, 'a');
      server.seed(await _sealBookmark(_bookmark('r1'), updatedAt: 1));
      server.seed(await _sealBookmark(_bookmark('r2'), updatedAt: 2));
      await device.coordinator.runRound(server);
      expect(await device.bookmarks.load(), hasLength(2));

      server.nextPullError = const SyncCursorRejectedException();
      await device.coordinator.runRound(server);
      expect(await device.bookmarks.load(), hasLength(2));
      expect(await device.records.highWaterSeq(), greaterThan(0));
      // The resync retry must have pulled from zero — prove it, don't
      // assume the pre-existing state survived on its own.
      expect(server.pullCursors, contains(0));
      // Recovery continues: new records land on the next normal round.
      server.seed(await _sealBookmark(_bookmark('r3'), updatedAt: 3));
      await device.coordinator.runRound(server);
      expect(await device.bookmarks.byId('r3'), isNotNull);
      expect(await device.bookmarks.load(), hasLength(3));
    });

    test('a rejected push with no displaced rival ends the round', () async {
      final device = await _Device.create(tempDir, 'a');
      await _save(device, _bookmark('stuck'));
      server.rejectPushes = true;

      final result = await device.coordinator.runRound(server);
      // The identical pull+push would replay unchanged, so one iteration
      // is the whole round — the losing edit stays dirty for next sync.
      expect(result.rounds, 1);
      expect(server.pushCalls, 1);
      expect((await device.records.dirtyRecords()).single.id,
          'bookmark:stuck');
    });
  });

  group('hostkey records', () {
    HostKey pin(String host, String fp, {int pinnedAt = 1}) => HostKey(
          host: host,
          port: 22,
          type: 'ssh-ed25519',
          fingerprintSha256: fp,
          pinnedAt: pinnedAt,
        );

    Future<EncryptedRecord> pinRecord(HostKey key,
            {String deviceId = 'foreign-device'}) =>
        RecordCrypto(RecordCodec(_key)).seal(DecryptedRecord(
          id: key.recordId,
          kind: RecordKind.hostKey,
          updatedAt: key.pinnedAt,
          deviceId: deviceId,
          data: key.toJson(),
        ));

    test('a pulled pin installs when no local pin or negative verdict exists',
        () async {
      final device = await _Device.create(tempDir, 'a');
      server.seed(await pinRecord(pin('h.example.com', 'SHA256:AAA')));
      await device.coordinator.runRound(server);
      expect(
          (await device.hostKeys.get('h.example.com', 22))!
              .fingerprintSha256,
          'SHA256:AAA');
    });

    test('a conflicting pin is quarantined, not applied', () async {
      final device = await _Device.create(tempDir, 'a');
      await device.hostKeys.put(pin('h.example.com', 'SHA256:LOCAL'));
      server.seed(await pinRecord(pin('h.example.com', 'SHA256:PULLED')));

      final result = await device.coordinator.runRound(server);
      expect(
          (await device.hostKeys.get('h.example.com', 22))!
              .fingerprintSha256,
          'SHA256:LOCAL');
      expect(
          result.report.pinConflicts.single.locator, 'h.example.com:22');
    });

    test('a negative pin holds the pulled record unapplied', () async {
      final device = await _Device.create(tempDir, 'a');
      await device.verdicts.addNegativePin('h.example.com:22');
      server.seed(await pinRecord(pin('h.example.com', 'SHA256:PULLED')));

      await device.coordinator.runRound(server);
      expect(await device.hostKeys.get('h.example.com', 22), isNull);
    });

    test('a kept-local verdict resolves a repeating conflict quietly',
        () async {
      final device = await _Device.create(tempDir, 'a');
      await device.hostKeys.put(pin('h.example.com', 'SHA256:LOCAL'));
      server.seed(await pinRecord(pin('h.example.com', 'SHA256:PULLED')));
      await device.coordinator.runRound(server);

      await device.coordinator.keepLocalPin('h.example.com', 22);
      final result = await device.coordinator.runRound(server);
      expect(result.report.pinConflicts, isEmpty);
      expect(
          (await device.hostKeys.get('h.example.com', 22))!
              .fingerprintSha256,
          'SHA256:LOCAL');
    });

    test('a hostkey tombstone never deletes a local pin', () async {
      final device = await _Device.create(tempDir, 'a');
      await device.hostKeys.put(pin('h.example.com', 'SHA256:LOCAL'));
      server.seed(EncryptedRecord(
        id: 'hostkey:h.example.com:22',
        updatedAt: 99999,
        deviceId: 'anyone',
        deleted: true,
        seq: null,
        blob: Uint8List(0),
      ));
      await device.coordinator.runRound(server);
      expect(
          (await device.hostKeys.get('h.example.com', 22))!
              .fingerprintSha256,
          'SHA256:LOCAL');
    });

    test('onHostKeyPinned pushes the pin and clears a negative verdict',
        () async {
      final device = await _Device.create(tempDir, 'a');
      await device.verdicts.addNegativePin('h.example.com:22');
      await device.coordinator
          .onHostKeyPinned(pin('h.example.com', 'SHA256:NEW', pinnedAt: 7));
      expect(await device.verdicts.negativePins(), isEmpty);
      final record =
          await device.records.getRecord('hostkey:h.example.com:22');
      expect(record, isNotNull);
      expect(record!.deleted, isFalse);
      expect(await device.records.dirtyRecords(), isNotEmpty);
    });
  });

  group('serverConfig catalog (shared mode)', () {
    ServerConfig config(String id, String label) => ServerConfig(
          id: id,
          label: label,
          host: '$id.example.com',
          port: 22,
          username: 'u',
          authMethod: AuthMethod.privateKey,
          syncSecret: false,
          createdAt: 1,
          updatedAt: 1,
        );

    test('pulled serverConfig records materialize the catalog', () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      server.seed(await RecordCrypto(RecordCodec(_key)).seal(DecryptedRecord(
        id: 'srv-uuid-1',
        kind: RecordKind.serverConfig,
        updatedAt: 1,
        deviceId: 'seance-device',
        data: config('srv-uuid-1', 'web').toJson(),
      )));
      await device.coordinator.runRound(server);
      expect(device.catalog!.servers.single.label, 'web');
    });

    test('a serverConfig tombstone removes the catalog entry', () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      server.seed(await RecordCrypto(RecordCodec(_key)).seal(DecryptedRecord(
        id: 'srv-uuid-1',
        kind: RecordKind.serverConfig,
        updatedAt: 1,
        deviceId: 'seance-device',
        data: config('srv-uuid-1', 'web').toJson(),
      )));
      await device.coordinator.runRound(server);
      expect(device.catalog!.servers, hasLength(1));

      server.seed(EncryptedRecord(
        id: 'srv-uuid-1',
        updatedAt: 2,
        deviceId: 'seance-device',
        deleted: true,
        seq: null,
        blob: Uint8List(0),
      ));
      await device.coordinator.runRound(server);
      expect(device.catalog!.servers, isEmpty);
    });

    test('separate mode never decrypts prefixless ids', () async {
      final device = await _Device.create(tempDir, 'a');
      server.seed(_enc('opaque-id', updatedAt: 1, blob: [1, 2, 3]));
      await device.coordinator.runRound(server);
      // The prefixless record is preserved verbatim, never decrypted.
      expect((await device.records.getRecord('opaque-id'))!.blob,
          Uint8List.fromList([1, 2, 3]));
      expect(await device.tripwires.trippedIds(), isEmpty);
    });
  });

  group('corruption recovery', () {
    test('reSealAfterStoreLoss restamps rows with their persisted tuples',
        () async {
      final a = await _Device.create(tempDir, 'a');
      final b = await _Device.create(tempDir, 'b');
      await _save(b, _bookmark('fromb', label: 'remote'));
      await b.coordinator.runRound(server);
      await a.coordinator.runRound(server);

      final tuple = await a.bookmarks.syncTupleOf('fromb');
      expect(tuple!.deviceId, b.deviceId);

      await File('${a.dir.path}/sync_records.json')
          .writeAsString('{corrupt');
      final restored = PersistentLocalRecordStore(
          path: '${a.dir.path}/sync_records.json');
      expect(await restored.allRecords(), isEmpty);
      a.records = restored;
      a.coordinator = BookmarkCoordinator(
        records: restored,
        bookmarks: a.bookmarks,
        hostKeys: a.hostKeys,
        crypto: a.crypto,
        deviceId: a.deviceId,
        pinVerdicts: a.verdicts,
        tripwires: a.tripwires,
        catalog: a.catalog,
        now: a.clock.call,
      );

      await a.coordinator.reSealAfterStoreLoss();
      final resealed = await restored.getRecord('bookmark:fromb');
      expect(resealed, isNotNull);
      expect(resealed!.deviceId, b.deviceId);
      expect(resealed.updatedAt, tuple.updatedAt);
      expect(await restored.dirtyRecords(), isNotEmpty);
    });
  });
}
