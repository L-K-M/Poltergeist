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
  late final FileServerConfigStore? servers;
  late final SecretVault? secrets;
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
    device.servers = shared
        ? FileServerConfigStore(
            path: '${device.dir.path}/servers.json',
            now: device.clock.call,
            syncDeviceId: () => device.deviceId,
          )
        : null;
    device.secrets =
        shared ? SecretVault(InMemoryVaultStore(), _key) : null;
    device.coordinator = BookmarkCoordinator(
      records: device.records,
      bookmarks: device.bookmarks,
      hostKeys: device.hostKeys,
      crypto: device.crypto,
      deviceId: device.deviceId,
      pinVerdicts: device.verdicts,
      tripwires: device.tripwires,
      catalog: device.catalog,
      servers: device.servers,
      secrets: device.secrets,
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

ServerConfig _server(
  String id, {
  String? label,
  String? group,
  String? secretRef,
  bool syncSecret = false,
  bool excludeFromSync = false,
}) =>
    ServerConfig(
      id: id,
      label: label ?? id,
      host: '$id.example.com',
      username: 'deploy',
      group: group,
      secretRef: secretRef,
      syncSecret: syncSecret,
      excludeFromSync: excludeFromSync,
      createdAt: _epochMs,
      updatedAt: _epochMs,
    );

Future<EncryptedRecord> _sealServer(
  ServerConfig server, {
  int? updatedAt,
  String deviceId = 'foreign-device',
  bool deleted = false,
}) =>
    RecordCrypto(RecordCodec(_key)).seal(DecryptedRecord(
      id: server.id,
      kind: RecordKind.serverConfig,
      updatedAt: updatedAt ?? server.updatedAt,
      deviceId: deviceId,
      deleted: deleted,
      // A tombstone carries no payload — `data` stays absent.
      data: deleted ? const {} : server.toJson(),
    ));

Secret _secret(String id, {int? updatedAt}) => Secret(
      id: id,
      kind: SecretKind.password,
      value: 'value-$id',
      updatedAt: updatedAt ?? _epochMs,
    );

Future<EncryptedRecord> _sealSecret(
  Secret secret, {
  int? updatedAt,
  String deviceId = 'foreign-device',
  bool deleted = false,
}) =>
    RecordCrypto(RecordCodec(_key)).seal(DecryptedRecord(
      id: 'secret:${secret.id}',
      kind: RecordKind.secret,
      updatedAt: updatedAt ?? secret.updatedAt,
      deviceId: deviceId,
      deleted: deleted,
      data: deleted ? const {} : secret.toJson(),
    ));

/// The shared-mode save pair the app service performs: persist + seal.
Future<ServerConfig> _saveServer(_Device device, ServerConfig server) async {
  await device.coordinator.onServerSaved(server);
  return (await device.servers!.byId(server.id))!;
}

Future<void> _deleteServer(_Device device, ServerConfig server) =>
    device.coordinator.onServerDeleted(server);

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

  group('serverConfig write path (04 §4.2, amended)', () {
    test('onServerSaved seals a prefixless record marked dirty and '
        'refreshes the catalog', () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      await _saveServer(device, _server('web', label: 'Web', group: 'prod'));

      final dirty = await device.records.dirtyRecords();
      expect(dirty.single.id, 'web');
      final dec = await device.crypto.open(dirty.single);
      expect(dec.kind, RecordKind.serverConfig);
      expect(dec.deviceId, device.deviceId);
      expect(ServerConfig.fromJson(dec.data).group, 'prod');
      expect(device.catalog!.byId('web')!.label, 'Web');
    });

    test('create, edit, and delete converge across shared devices',
        () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      final b = await _Device.create(tempDir, 'b', shared: true);

      await _saveServer(a, _server('web', label: 'v1', group: 'prod'));
      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect((await b.servers!.byId('web'))!.label, 'v1');
      expect(b.catalog!.byId('web')!.group, 'prod');

      b.clock.ms += 1000;
      await _saveServer(b, _server('web', label: 'v2'));
      await b.coordinator.runRound(server);
      await a.coordinator.runRound(server);
      expect((await a.servers!.byId('web'))!.label, 'v2');

      a.clock.ms += 2000;
      await _deleteServer(a, (await a.servers!.byId('web'))!);
      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect(await b.servers!.byId('web'), isNull);
      expect(b.catalog!.byId('web'), isNull);
    });

    test('a stale pulled copy cannot resurrect a deleted server', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await _saveServer(a, _server('doomed'));
      await a.coordinator.runRound(server);
      a.clock.ms += 1000;
      await _deleteServer(a, (await a.servers!.byId('doomed'))!);
      await a.coordinator.runRound(server);
      expect(server.records['doomed']!.deleted, isTrue);

      // A device that never saw the delete pushes an older live copy:
      // it loses the same LWW compare server-side and never lands.
      expect(
        server.seed(await _sealServer(_server('doomed'),
            updatedAt: 5, deviceId: 'stale-device')),
        isFalse,
      );
      final b = await _Device.create(tempDir, 'b', shared: true);
      await b.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect(await b.servers!.byId('doomed'), isNull);
      // The tombstone tuple itself is retained in the store.
      expect(
          (await b.servers!.syncTupleOf('doomed'))!.deleted, isTrue);
    });

    test('an excluded server seals a retraction, never live payload',
        () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      final b = await _Device.create(tempDir, 'b', shared: true);
      await _saveServer(a, _server('web', label: 'Web'));
      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect(await b.servers!.byId('web'), isNotNull);

      // Exclude: the account copy retracts under a tombstone while the
      // local row survives and stays in this device's catalog.
      a.clock.ms += 1000;
      await a.coordinator.onServerSaved(
          (await a.servers!.byId('web'))!.copyWith(
        excludeFromSync: true,
        updatedAt: a.clock.ms,
      ));
      final retracted = await a.records.getRecord('web');
      expect(retracted!.deleted, isTrue);
      expect((await a.servers!.byId('web'))!.excludeFromSync, isTrue);
      expect(a.catalog!.byId('web'), isNotNull);

      await a.coordinator.runRound(server);
      await b.coordinator.runRound(server);
      expect(await b.servers!.byId('web'), isNull);
    });

    test('a pulled live record never replaces an excluded local row',
        () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await _saveServer(a, _server('web', label: 'mine'));
      a.clock.ms += 1000;
      await a.coordinator.onServerSaved(
          (await a.servers!.byId('web'))!.copyWith(
        excludeFromSync: true,
        updatedAt: a.clock.ms,
      ));

      // A pulled live copy newer than the local stamp still loses to
      // the privacy boundary — and the retraction re-dates once to win
      // the fleet's LWW rather than bidding forever.
      server.seed(await _sealServer(_server('web', label: 'theirs'),
          updatedAt: a.clock.ms + 5000));
      await a.coordinator.runRound(server);
      final local = await a.servers!.byId('web');
      expect(local!.label, 'mine');
      expect(local.excludeFromSync, isTrue);
      final counter = await a.records.getRecord('web');
      expect(counter!.deleted, isTrue);
      expect(counter.deviceId, a.deviceId);
      // The re-dated tombstone lands on the server, settling the duel.
      await a.coordinator.runRound(server);
      expect(server.records['web']!.deleted, isTrue);
    });

    test('an own-device tombstone over a live row revives rather than '
        'deleting (reversed exclusion)', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await _saveServer(a, _server('web', label: 'back'));
      // The fleet still holds this device's earlier exclusion
      // tombstone; the user re-included locally, so the live row must
      // win — re-dated past the tombstone and re-sealed for the push.
      server.seed(EncryptedRecord(
        id: 'web',
        updatedAt: _epochMs + 500,
        deviceId: a.deviceId,
        deleted: true,
        seq: null,
        blob: Uint8List(0),
      ));
      await a.coordinator.runRound(server);
      final row = await a.servers!.byId('web');
      expect(row, isNotNull);
      expect(row!.updatedAt, greaterThan(_epochMs + 500));
      final resealed = await a.records.getRecord('web');
      expect(resealed!.deleted, isFalse);
      expect(resealed.deviceId, a.deviceId);
    });

    test('server writes are no-ops outside shared mode', () async {
      final device = await _Device.create(tempDir, 'a');
      await device.coordinator.onServerSaved(_server('web'));
      await device.coordinator.onServerDeleted(_server('web'));
      await device.coordinator.onServerSecretSaved('s1');
      expect(await device.records.allRecords(), isEmpty);
    });

    test('rebuildCatalog repopulates from the store before any round',
        () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      await _saveServer(device, _server('web', label: 'Web'));
      final fresh = SeanceServerCatalog();
      final restarted = BookmarkCoordinator(
        records: device.records,
        bookmarks: device.bookmarks,
        hostKeys: device.hostKeys,
        crypto: device.crypto,
        deviceId: device.deviceId,
        pinVerdicts: device.verdicts,
        tripwires: device.tripwires,
        catalog: fresh,
        servers: device.servers,
        secrets: device.secrets,
        now: device.clock.call,
      );
      await restarted.rebuildCatalog();
      expect(fresh.byId('web')!.label, 'Web');
    });

    test('a prefixless record the apply cursor already passed backfills '
        'under its own tuple', () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      // Sealed by a catalog-only build: stored with a seq the apply
      // cursor has long passed, no materialized tuple.
      await device.records.putRemote(
          (await _sealServer(_server('old', label: 'Old'), updatedAt: 3))
              .withSeq(1));
      await device.records.setLastAppliedSeq(5);

      await device.coordinator.rebuildCatalog();
      expect(device.catalog!.byId('old')!.label, 'Old');
      expect((await device.servers!.syncTupleOf('old'))!.deviceId,
          'foreign-device');
    });
  });

  group('secret records (04 §4.2, amended)', () {
    test('a syncSecret server publishes its credential with the config',
        () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      final b = await _Device.create(tempDir, 'b', shared: true);
      await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
      await _saveServer(
          a, _server('web', secretRef: 's1', syncSecret: true));

      await a.coordinator.runRound(server);
      expect(server.records.containsKey('secret:s1'), isTrue);
      await b.coordinator.runRound(server);
      expect(await b.servers!.byId('web'), isNotNull);
      expect((await b.secrets!.getSecret('s1'))!.value, 'value-s1');
    });

    test('a credential stays published while a synced sharer remains',
        () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await a.secrets!
          .putLocalSecret(_secret('shared-s'), updatedAt: _epochMs);
      await _saveServer(
          a, _server('web-a', secretRef: 'shared-s', syncSecret: true));
      await _saveServer(
          a, _server('web-b', secretRef: 'shared-s', syncSecret: true));
      await a.coordinator.runRound(server);
      expect(server.records['secret:shared-s']!.deleted, isFalse);

      // Exclude one sharer — the credential must NOT retract while
      // web-b still syncs it.
      a.clock.ms += 1000;
      await a.coordinator.onServerSaved(
          (await a.servers!.byId('web-a'))!.copyWith(
        excludeFromSync: true,
        updatedAt: a.clock.ms,
      ));
      expect((await a.records.getRecord('web-a'))!.deleted, isTrue);
      expect(
          (await a.records.getRecord('secret:shared-s'))!.deleted,
          isFalse);
    });

    test('excluding the last synced sharer retracts the secret record',
        () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
      await _saveServer(
          a, _server('web', secretRef: 's1', syncSecret: true));
      a.clock.ms += 1000;
      await a.coordinator.onServerSaved(
          (await a.servers!.byId('web'))!.copyWith(
        excludeFromSync: true,
        updatedAt: a.clock.ms,
      ));
      expect((await a.records.getRecord('secret:s1'))!.deleted, isTrue);
      // The vault copy itself is local material — untouched.
      expect(await a.secrets!.getSecret('s1'), isNotNull);
    });

    test('deleting the server retracts its orphaned credential', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
      await _saveServer(
          a, _server('web', secretRef: 's1', syncSecret: true));
      await _deleteServer(a, (await a.servers!.byId('web'))!);
      expect((await a.records.getRecord('web'))!.deleted, isTrue);
      expect((await a.records.getRecord('secret:s1'))!.deleted, isTrue);
    });

    test('re-including after a retraction re-dates the credential past '
        'it', () async {
      final a = await _Device.create(tempDir, 'a', shared: true);
      await a.secrets!.putLocalSecret(_secret('s1'), updatedAt: _epochMs);
      await _saveServer(
          a, _server('web', secretRef: 's1', syncSecret: true));
      a.clock.ms += 1000;
      await a.coordinator.onServerSaved(
          (await a.servers!.byId('web'))!.copyWith(
        excludeFromSync: true,
        updatedAt: a.clock.ms,
      ));
      final tombstone = await a.records.getRecord('secret:s1');
      expect(tombstone!.deleted, isTrue);

      a.clock.ms += 1000;
      await a.coordinator.onServerSaved(
          (await a.servers!.byId('web'))!.copyWith(
        excludeFromSync: false,
        updatedAt: a.clock.ms,
      ));
      final revived = await a.records.getRecord('secret:s1');
      expect(revived!.deleted, isFalse);
      expect(revived.updatedAt, greaterThan(tombstone.updatedAt));
      // The vault copy carries the bumped stamp, so vault and record
      // agree on the credential's version.
      expect((await a.secrets!.getSecret('s1'))!.updatedAt,
          greaterThan(tombstone.updatedAt));
    });

    test('an excluded-only credential is shielded from pulled '
        'application', () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      await device.servers!.save(
          _server('priv', secretRef: 's1', excludeFromSync: true));
      server.seed(
          await _sealSecret(_secret('s1'), updatedAt: _epochMs + 1));
      await device.coordinator.runRound(server);
      expect(await device.secrets!.getSecret('s1'), isNull);
    });

    test('a newer local credential is never overwritten by a stale '
        'pull', () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      await device.secrets!.putLocalSecret(
          _secret('s1', updatedAt: _epochMs + 9000),
          updatedAt: _epochMs + 9000);
      // A non-excluded sharer exists so the shield does not hide the
      // record — the freshness floor is what protects the edit.
      await _saveServer(device, _server('web', secretRef: 's1'));
      server.seed(
          await _sealSecret(_secret('s1'), updatedAt: _epochMs + 1));
      await device.coordinator.runRound(server);
      expect((await device.secrets!.getSecret('s1'))!.updatedAt,
          _epochMs + 9000);
    });

    test('secret tombstones are no-ops — vault material survives',
        () async {
      final device = await _Device.create(tempDir, 'a', shared: true);
      await device.secrets!
          .putLocalSecret(_secret('s1'), updatedAt: _epochMs);
      server.seed(EncryptedRecord(
        id: 'secret:s1',
        updatedAt: _epochMs + 99999,
        deviceId: 'anyone',
        deleted: true,
        seq: null,
        blob: Uint8List(0),
      ));
      await device.coordinator.runRound(server);
      expect(await device.secrets!.getSecret('s1'), isNotNull);
    });

    test('a pulled secret never lands on a device without a vault',
        () async {
      final device = await _Device.create(tempDir, 'a');
      server.seed(
          await _sealSecret(_secret('s1'), updatedAt: _epochMs + 1));
      await device.coordinator.runRound(server);
      // Preserved verbatim, never decrypted, never tripped.
      expect(await device.tripwires.trippedIds(), isEmpty);
      expect(
          (await device.records.getRecord('secret:s1'))!.blob, isNotEmpty);
    });
  });
}
