@Tags(['integration'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:seance_core/seance_core.dart' as seance;
import 'package:test/test.dart';

/// 07 §3.7's first exit criterion names `seance_sync_server` in Docker.
/// Where Docker exists, point [POLTERGEIST_SYNC_SERVER] at a container or
/// a locally-launched binary — either way the client under test is the
/// pinned `HttpSyncClient` speaking the real protocol over a socket to the
/// real server build, never a fake. Run one with:
///
///   dart compile exe \
///     SEANCE_CHECKOUT/packages/seance_sync_server/bin/seance_sync_server.dart
///   SEANCE_OPEN_REGISTRATION=1 SEANCE_BIND=127.0.0.1 SEANCE_PORT=8799 \
///     ./seance-sync   # omit --db: in-memory storage needs no libsqlite3
///
///   POLTERGEIST_SYNC_SERVER=http://127.0.0.1:8799 \
///     dart test --tags integration \
///       packages/poltergeist_core/test/integration/sync_server_convergence_test.dart
const _serverVariable = 'POLTERGEIST_SYNC_SERVER';

final _epoch = DateTime.utc(2026, 9, 20, 12);
final _epochMs = _epoch.millisecondsSinceEpoch;

/// A controllable wall clock shared by a "device"'s stores, the same shape
/// the fake-server coordinator suite uses — LWW ordering stays exact.
final class _Clock {
  _Clock(this.ms);
  int ms;
  DateTime call() => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// The keystore seam, in memory: enrollment must be able to persist the
/// token and vault key, and nothing here may touch disk.
final class _MemoryCredentials implements SyncCredentialStore {
  String? token;
  List<int>? vaultKey;

  @override
  Future<void> writeToken(String token) async => this.token = token;
  @override
  Future<String?> readToken() async => token;
  @override
  Future<void> deleteToken() async => token = null;
  @override
  Future<void> writeVaultKey(List<int> vaultKey) async =>
      this.vaultKey = List.of(vaultKey);
}

/// The durable enrollment-state seam, in memory.
final class _MemoryEnrollmentState implements SyncEnrollmentState {
  _MemoryEnrollmentState(this.id);

  final String id;
  bool unverified = false;
  final Set<String> raised = {};
  SyncAccount? enrolled;

  @override
  Future<String> deviceId() async => id;
  @override
  Future<bool> passphraseUnverified() async => unverified;
  @override
  Future<void> setPassphraseUnverified(bool value) async =>
      unverified = value;
  @override
  Future<Set<String>> notices() async => Set.of(raised);
  @override
  Future<void> setNotice(String notice, bool active) async =>
      active ? raised.add(notice) : raised.remove(notice);
  @override
  Future<SyncAccount?> account() async => enrolled;
  @override
  Future<void> setAccount(SyncAccount? account) async => enrolled = account;
}

/// One Poltergeist "device" enrolled against the real server: a real
/// `PersistentLocalRecordStore` file, real `FileBookmarkStore`, in-memory
/// pins/verdicts/tripwires, and a coordinator rebuilt per vault key the way
/// the app recomposes after enrollment.
final class _Device {
  _Device._();

  late final Directory dir;
  late final PersistentLocalRecordStore records;
  late final FileBookmarkStore bookmarks;
  late final InMemoryHostKeyStore hostKeys;
  late final InMemoryPinVerdictStore verdicts;
  late final InMemorySyncTripwireStore tripwires;
  late final _MemoryCredentials credentials;
  late final _MemoryEnrollmentState state;
  late final SyncEnrollment enrollment;
  late final _Clock clock;
  late final SeanceServerCatalog? catalog;

  static Future<_Device> create(Directory parent, String name,
      {bool shared = false}) async {
    final device = _Device._()
      ..clock = _Clock(_epochMs);
    device.dir = await Directory('${parent.path}/$name').create();
    device.records = PersistentLocalRecordStore(
      path: '${device.dir.path}/sync_records.json',
      now: device.clock.call,
    );
    device.bookmarks = FileBookmarkStore(
      path: '${device.dir.path}/bookmarks.json',
      now: device.clock.call,
      syncDeviceId: () => device.state.id,
    );
    device.hostKeys = InMemoryHostKeyStore();
    device.verdicts = InMemoryPinVerdictStore();
    device.tripwires = InMemorySyncTripwireStore();
    device.credentials = _MemoryCredentials();
    device.state = _MemoryEnrollmentState('device-$name');
    device.enrollment = SyncEnrollment(
      credentials: device.credentials,
      state: device.state,
      records: device.records,
    );
    device.catalog = shared ? SeanceServerCatalog() : null;
    return device;
  }

  BookmarkCoordinator coordinatorFor(List<int> vaultKey) =>
      BookmarkCoordinator(
        records: records,
        bookmarks: bookmarks,
        hostKeys: hostKeys,
        crypto: RecordCrypto(RecordCodec(vaultKey)),
        deviceId: state.id,
        pinVerdicts: verdicts,
        tripwires: tripwires,
        catalog: catalog,
        enrollment: state,
        now: clock.call,
      );
}

/// `HttpSyncClient` carries every member [SyncEnrollmentApi] declares but
/// implements only `SyncApi` — the app's `HttpSyncTransport` solves the
/// same nominal-typing gap with a marker subclass; same trick here.
final class _HttpEnrollmentClient extends HttpSyncClient
    implements SyncEnrollmentApi {
  _HttpEnrollmentClient({required super.baseUrl});
}

/// The Séance `ConfigStore` the "patched Séance" side reads: an in-memory
/// server list behind the pinned interface — the records it produces are
/// Séance's own coordinator output, not a hand-built wire shape.
final class _ListConfigStore extends seance.ConfigStore {
  final _servers = <String, ServerConfig>{};

  @override
  Future<List<ServerConfig>> listServers() async => _servers.values.toList();
  @override
  Future<ServerConfig?> getServer(String id) async => _servers[id];
  @override
  Future<void> putServer(ServerConfig config) async =>
      _servers[config.id] = config;
  @override
  Future<void> deleteServer(String id) async => _servers.remove(id);
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

Future<Bookmark> _save(_Device device, Bookmark bookmark) async {
  final saved = await device.bookmarks.save(bookmark);
  return saved;
}

/// A sealed record authored the way a foreign client would, pushed straight
/// to the real server — the tombstone-stays-won and skip-preserve probes.
Future<EncryptedRecord> _sealRaw(
  List<int> vaultKey,
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
      blob: await VaultCrypto.sealJson(vaultKey, payload),
    );

Future<EncryptedRecord> _sealBookmark(
  List<int> vaultKey,
  Bookmark bookmark, {
  int? updatedAt,
  String deviceId = 'foreign-device',
}) =>
    RecordCrypto(RecordCodec(vaultKey)).seal(DecryptedRecord(
      id: 'bookmark:${bookmark.id}',
      kind: RecordKind.bookmark,
      updatedAt:
          updatedAt ?? bookmark.updatedAt.toUtc().millisecondsSinceEpoch,
      deviceId: deviceId,
      data: bookmark.toJson(),
    ));

/// The server-side truth for an id: the one record a full pull returns.
Future<EncryptedRecord> _serverRecord(HttpSyncClient api, String id) async {
  final response = await api.pull(since: 0);
  return response.records.singleWhere((r) => r.id == id);
}

void main() {
  final baseUrl = Platform.environment[_serverVariable];
  final enabled = baseUrl != null && baseUrl.isNotEmpty;
  final skipReason =
      'Set $_serverVariable to a running seance_sync_server URL to enable.';

  late Directory tempDir;
  final clients = <HttpSyncClient>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_server_test');
  });

  tearDown(() async {
    for (final client in clients) {
      client.close();
    }
    clients.clear();
    await tempDir.delete(recursive: true);
  });

  _HttpEnrollmentClient client() {
    final api = _HttpEnrollmentClient(baseUrl: baseUrl!);
    clients.add(api);
    return api;
  }

  String freshUser(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-'
      '${secureRandomBytes(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  test(
    'create, edit, and delete converge through the real server; a winning '
    'tombstone stays won',
    () async {
      final username = freshUser('convergence');
      const password = 'correct horse battery staple';
      final a = await _Device.create(tempDir, 'a');
      final b = await _Device.create(tempDir, 'b');
      final apiA = client();
      final apiB = client();

      // A registers on the real server (the production enrollment path,
      // Argon2 included), writes a bookmark, pushes it.
      final enrolledA = await a.enrollment.registerSeparate(
        api: apiA,
        baseUrl: baseUrl!,
        username: username,
        password: password,
        encryptionPassphrase: password,
      );
      final coordinatorA = a.coordinatorFor(enrolledA.vaultKey);
      var saved = await _save(a, _bookmark('shared', label: 'v1'));
      await coordinatorA.onBookmarkSaved(saved);
      await coordinatorA.runRound(apiA);

      // B logs into the same account: the real trial-decrypt verifies its
      // passphrase against A's record before enrollment persists.
      final enrolledB = await b.enrollment.login(
        api: apiB,
        baseUrl: baseUrl,
        username: username,
        password: password,
        encryptionPassphrase: password,
        mode: SyncAccountMode.separate,
      );
      expect(enrolledB.passphraseUnverified, isFalse);
      final coordinatorB = b.coordinatorFor(enrolledB.vaultKey);
      await coordinatorB.runRound(apiB);
      expect((await b.bookmarks.byId('shared'))!.label, 'v1');

      // An edit on B converges back to A.
      b.clock.ms += 1000;
      saved = await _save(b, _bookmark('shared', label: 'v2'));
      await coordinatorB.onBookmarkSaved(saved);
      await coordinatorB.runRound(apiB);
      await coordinatorA.runRound(apiA);
      expect((await a.bookmarks.byId('shared'))!.label, 'v2');

      // A delete on A lands as a real tombstone on the server and
      // converges on B.
      a.clock.ms += 2000;
      await a.bookmarks.remove('shared');
      await coordinatorA.onBookmarkDeleted('shared');
      await coordinatorA.runRound(apiA);
      expect((await _serverRecord(apiA, 'bookmark:shared')).deleted, isTrue);
      await coordinatorB.runRound(apiB);
      expect(await b.bookmarks.byId('shared'), isNull);

      // A stale live copy pushed by a device that never saw the delete
      // loses the same LWW compare on the real server — the tombstone
      // stays won there and on both devices.
      final stale = await _sealBookmark(
        enrolledA.vaultKey,
        _bookmark('shared', label: 'stale'),
        updatedAt: 5,
        deviceId: 'stale-device',
      );
      final rejected = await apiA.push([stale]);
      expect(rejected.results.single.accepted, isFalse);
      expect((await _serverRecord(apiA, 'bookmark:shared')).deleted, isTrue);
      await coordinatorB.runRound(apiB);
      await coordinatorA.runRound(apiA);
      expect(await b.bookmarks.byId('shared'), isNull);
      expect(await a.bookmarks.byId('shared'), isNull);
      expect((await _serverRecord(apiA, 'bookmark:shared')).deleted, isTrue);
    },
    skip: enabled ? false : skipReason,
  );

  test(
    'a flurb-kind record survives real rounds byte-identical; a malformed '
    'known kind skips without aborting',
    () async {
      final username = freshUser('preserve');
      const password = 'correct horse battery staple';
      final device = await _Device.create(tempDir, 'c');
      final api = client();

      final enrolled = await device.enrollment.registerSeparate(
        api: api,
        baseUrl: baseUrl!,
        username: username,
        password: password,
        encryptionPassphrase: password,
      );
      final coordinator = device.coordinatorFor(enrolled.vaultKey);

      // Foreign-authored records land on the real server first.
      final flurb = await _sealRaw(
        enrolled.vaultKey,
        'flurb:x1',
        {'kind': 'flurb', 'data': {'what': 'ever'}},
        updatedAt: _epochMs + 1,
      );
      final malformed = await _sealRaw(
        enrolled.vaultKey,
        'bookmark:bad',
        {'kind': 'bookmark', 'data': {'id': 'bad'}},
        updatedAt: _epochMs + 2,
      );
      final good = await _sealBookmark(
        enrolled.vaultKey,
        _bookmark('good', label: 'ok'),
        updatedAt: _epochMs + 3,
      );
      final seeded = await api.push([flurb, malformed, good]);
      expect(seeded.results.every((r) => r.accepted), isTrue);

      // The round applies the good record, skips the malformed one with a
      // tripwire, and preserves the flurb untouched — over real HTTP.
      final result = await coordinator.runRound(api);
      expect((await device.bookmarks.byId('good'))!.label, 'ok');
      expect(result.report.appliedIds, contains('bookmark:good'));
      expect(await device.tripwires.trippedIds(), contains('bookmark:bad'));
      final localFlurb = await device.records.getRecord('flurb:x1');
      expect(localFlurb!.blob, flurb.blob);

      // More rounds — including a push of this device's own write — never
      // re-mint the flurb's server sequence number: it is never re-pushed,
      // never tombstoned, never decoded.
      final saved = await _save(device, _bookmark('mine'));
      await coordinator.onBookmarkSaved(saved);
      final flurbSeq = (await _serverRecord(api, 'flurb:x1')).seq;
      await coordinator.runRound(api);
      await coordinator.runRound(api);
      final after = await _serverRecord(api, 'flurb:x1');
      expect(after.seq, flurbSeq);
      expect(after.blob, flurb.blob);
      expect(await device.tripwires.trippedIds(),
          isNot(contains('flurb:x1')));
    },
    skip: enabled ? false : skipReason,
  );

  test(
    'shared mode materializes a patched Séance\'s records: the catalog '
    'renders and a synced pin pre-answers TOFU',
    () async {
      final username = freshUser('shared');
      const password = 'correct horse battery staple';

      // The account the "patched Séance" writes to — registered exactly as
      // Séance's own enrollment does (the same derive SyncEnrollment runs).
      final apiS = client();
      final salt = secureRandomBytes(16);
      const params = Argon2Params();
      final keys = await VaultCrypto.deriveKeys(
        passphrase: password,
        salt: salt,
        params: params,
      );
      await apiS.register(RegisterRequest(
        username: username,
        authVerifier: base64.encode(keys.authVerifier),
        argonSalt: base64.encode(salt),
        argonParams: params,
      ));
      final vaultKey = keys.vaultKey;

      // The patched Séance: the pinned seance_core SyncCoordinator itself,
      // publishing a serverConfig and a hostkey pin to the real server.
      final config = ServerConfig(
        id: 'fleet-web',
        label: 'Fleet web',
        host: 'web.internal',
        port: 22,
        username: 'deploy',
        createdAt: _epochMs,
        updatedAt: _epochMs + 1,
      );
      final pin = HostKey(
        host: 'web.internal',
        port: 22,
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:fleetpin',
        pinnedAt: _epochMs + 1,
      );
      final configStore = _ListConfigStore();
      await configStore.putServer(config);
      final seancePins = InMemoryHostKeyStore();
      await seancePins.put(pin);
      final seanceCoordinator = seance.SyncCoordinator(
        configStore: configStore,
        hostKeyStore: seancePins,
        codec: RecordCodec(vaultKey),
        local: seance.InMemoryLocalRecordStore(),
        deviceId: 'seance-device',
      );
      await seanceCoordinator.run(apiS);

      // Poltergeist joins the shared account: the login's trial-decrypt
      // proves the passphrase against Séance's own prefixless record.
      final device = await _Device.create(tempDir, 'd', shared: true);
      final apiD = client();
      final enrolled = await device.enrollment.login(
        api: apiD,
        baseUrl: baseUrl!,
        username: username,
        password: password,
        encryptionPassphrase: password,
        mode: SyncAccountMode.shared,
      );
      expect(enrolled.passphraseUnverified, isFalse);
      final coordinator = device.coordinatorFor(vaultKey);
      await coordinator.runRound(apiD);

      // The catalog materializes the pulled serverConfig, and the synced
      // pin pre-answers TOFU for a host presenting that fingerprint —
      // connecting needs no first-use prompt.
      expect(device.catalog!.servers.single.id, 'fleet-web');
      final stored = await device.hostKeys.get('web.internal', 22);
      expect(stored!.fingerprintSha256, 'SHA256:fleetpin');
      final decision = await TofuVerifier(device.hostKeys).check(HostKey(
        host: 'web.internal',
        port: 22,
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:fleetpin',
        pinnedAt: 0,
      ));
      expect(decision.verdict, HostKeyVerdict.trusted);

      // Séance's excludeFromSync retraction is a real tombstone; the next
      // round removes the catalog entry.
      await configStore.putServer(
          config.copyWith(excludeFromSync: true, updatedAt: _epochMs + 2));
      await seanceCoordinator.run(apiS);
      await coordinator.runRound(apiD);
      expect(device.catalog!.servers, isEmpty);
    },
    skip: enabled ? false : skipReason,
  );
}
