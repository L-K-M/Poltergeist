import 'dart:io';
import 'dart:typed_data';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'fake_enrollment_api.dart';

final _epoch = DateTime.utc(2026, 9, 20, 12);
final _epochMs = _epoch.millisecondsSinceEpoch;

/// A controllable wall clock shared by a device's store and coordinator.
final class _Clock {
  _Clock(this.ms);
  int ms;
  DateTime call() => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// The keystore seam fake: token and vault key land in memory, and every
/// persisted string is captured so a test can prove the bearer token never
/// reaches a disk-bound store.
final class FakeSyncCredentialStore implements SyncCredentialStore {
  String? token;
  List<int>? vaultKey;
  var tokenDeletes = 0;

  @override
  Future<void> writeToken(String value) async {
    token = value;
  }

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> deleteToken() async {
    tokenDeletes++;
    token = null;
  }

  @override
  Future<void> writeVaultKey(List<int> key) async {
    vaultKey = key;
  }
}

/// Durable enrollment state fake — stands in for the app-settings-backed
/// implementation. Every persisted value is captured verbatim so the
/// token-not-on-disk assertion can sweep it.
final class FakeSyncEnrollmentState implements SyncEnrollmentState {
  String id;
  var unverified = false;
  final noticeSet = <String>{};
  SyncAccount? accountValue;

  /// Every value handed to a persistence call — the disk-write sweep.
  final persisted = <Object?>[];

  FakeSyncEnrollmentState(this.id);

  @override
  Future<String> deviceId() async {
    persisted.add(id);
    return id;
  }

  @override
  Future<bool> passphraseUnverified() async => unverified;

  @override
  Future<void> setPassphraseUnverified(bool value) async {
    unverified = value;
    persisted.add(value);
  }

  @override
  Future<Set<String>> notices() async => Set.of(noticeSet);

  @override
  Future<void> setNotice(String notice, bool active) async {
    if (active) {
      noticeSet.add(notice);
    } else {
      noticeSet.remove(notice);
    }
    persisted.add('$notice=$active');
  }

  @override
  Future<SyncAccount?> account() async => accountValue;

  @override
  Future<void> setAccount(SyncAccount? value) async {
    accountValue = value;
    if (value != null) {
      persisted.addAll([value.baseUrl, value.username, value.mode.name]);
    }
  }
}

/// One enrolled-capable "device": record store on a real file (so the
/// token-not-on-disk sweep has bytes to read), bookmark/pin stores, the
/// keystore + enrollment-state fakes, and a coordinator rebuilt on demand
/// for whatever vault key enrollment derived.
final class _Device {
  _Device._();

  late final Directory dir;
  late final PersistentLocalRecordStore records;
  late final FileBookmarkStore bookmarks;
  late final InMemoryHostKeyStore hostKeys;
  late final InMemoryPinVerdictStore verdicts;
  late final InMemorySyncTripwireStore tripwires;
  late final FakeSyncCredentialStore credentials;
  late final FakeSyncEnrollmentState state;
  late final SyncEnrollment enrollment;
  late final _Clock clock;

  /// The crypto the *currently enrolled* key produces — rebuilt by
  /// [coordinatorFor] after every enrollment, the way the app recomposes
  /// its coordinator when the vault key changes.
  late RecordCrypto crypto;

  static Future<_Device> create(Directory parent, String name) async {
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
    device.credentials = FakeSyncCredentialStore();
    device.state = FakeSyncEnrollmentState('device-$name');
    device.enrollment = SyncEnrollment(
      credentials: device.credentials,
      state: device.state,
      records: device.records,
    );
    return device;
  }

  BookmarkCoordinator coordinatorFor(List<int> vaultKey) {
    crypto = RecordCrypto(RecordCodec(vaultKey));
    return BookmarkCoordinator(
      records: records,
      bookmarks: bookmarks,
      hostKeys: hostKeys,
      crypto: crypto,
      deviceId: state.id,
      pinVerdicts: verdicts,
      tripwires: tripwires,
      enrollment: state,
      now: clock.call,
    );
  }

  /// Every byte the device persisted anywhere outside the keystore seam —
  /// a recursive walk so side files (journals, temp artifacts) can't
  /// escape the token-leak sweep.
  Future<List<String>> diskContents() async {
    final contents = <String>[];
    await for (final entity
        in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) contents.add(await entity.readAsString());
    }
    contents.addAll(state.persisted.map((v) => '$v'));
    return contents;
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

Future<EncryptedRecord> _sealBookmark(
  Bookmark bookmark,
  List<int> vaultKey, {
  String deviceId = 'foreign-device',
}) =>
    RecordCrypto(RecordCodec(vaultKey)).seal(DecryptedRecord(
      id: 'bookmark:${bookmark.id}',
      kind: RecordKind.bookmark,
      updatedAt: bookmark.updatedAt.toUtc().millisecondsSinceEpoch,
      deviceId: deviceId,
      data: bookmark.toJson(),
    ));

Future<EncryptedRecord> _sealPin(
  HostKey pin,
  List<int> vaultKey, {
  String deviceId = 'foreign-device',
}) =>
    RecordCrypto(RecordCodec(vaultKey)).seal(DecryptedRecord(
      id: pin.recordId,
      kind: RecordKind.hostKey,
      updatedAt: pin.pinnedAt,
      deviceId: deviceId,
      data: pin.toJson(),
    ));

HostKey _pin(String host, String fp, {int pinnedAt = 1}) => HostKey(
      host: host,
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: fp,
      pinnedAt: pinnedAt,
    );

void main() {
  late Directory tempDir;
  late FakeEnrollmentApi server;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('enrollment_test');
    server = FakeEnrollmentApi();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('register (04 §4.1)', () {
    test('registers, stores the token and vault key in the keystore, and '
        'never sets the verification flag', () async {
      final device = await _Device.create(tempDir, 'a');

      final result = await device.enrollment.registerSeparate(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-a1b2c3d4',
        password: 'account-pw',
        encryptionPassphrase: 'account-pw',
      );

      expect(result.passphraseUnverified, isFalse);
      expect(result.passphraseWarning, isNull);
      expect(server.registerCalls, 1);
      expect(device.credentials.token, 'token-1');
      expect(device.credentials.vaultKey, isNotNull);
      expect(device.credentials.vaultKey, hasLength(32));
      expect(await device.state.deviceId(), 'device-a');
      final account = await device.state.account();
      expect(account!.username, 'ghost-a1b2c3d4');
      expect(account.mode, SyncAccountMode.separate);
      expect(await device.state.passphraseUnverified(), isFalse);
      // Registration mints the passphrase: no pull is needed to verify.
      expect(server.pullCalls, 0);
    });

    test('403 registration_closed surfaces the §4.3 copy verbatim and '
        'persists nothing', () async {
      final device = await _Device.create(tempDir, 'a');
      server.registrationClosed = true;

      await expectLater(
        () => device.enrollment.registerSeparate(
          api: server,
          baseUrl: 'https://sync.example.com',
          username: 'ghost-a1b2c3d4',
          password: 'pw',
          encryptionPassphrase: 'pw',
        ),
        throwsA(isA<RegistrationClosedException>().having(
            (e) => e.message, 'message', syncRegistrationClosedMessage)),
      );
      expect(device.credentials.token, isNull);
      expect(await device.state.account(), isNull);
      // "Persists nothing" pins the whole durable surface — flag and
      // notices untouched too, not just the keystore and account.
      expect(device.state.unverified, isFalse);
      expect(device.state.noticeSet, isEmpty);
    });
  });

  group('login (04 §4.5)', () {
    test('round-trips prelogin → derive → login → full pull → trial-decrypt '
        '→ persist', () async {
      final device = await _Device.create(tempDir, 'a');
      final account =
          await server.addAccount(username: 'ghost-1', password: 'pw');
      final vaultKey = account.keys.vaultKey;
      server.seed(await _sealBookmark(_bookmark('remote'), vaultKey));

      final result = await device.enrollment.login(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-1',
        password: 'pw',
        encryptionPassphrase: 'pw',
        mode: SyncAccountMode.separate,
      );

      expect(result.passphraseUnverified, isFalse);
      expect(server.preloginCalls, 1);
      expect(server.pullCursors, [0]);
      expect(device.credentials.token, 'token-1');
      expect(device.credentials.vaultKey, vaultKey);
      // The pulled record is in the record store, merged clean.
      expect(await device.records.getRecord('bookmark:remote'), isNotNull);
      expect(await device.records.highWaterSeq(), greaterThan(0));

      // …and the next round applies it.
      final coordinator = device.coordinatorFor(result.vaultKey);
      await coordinator.runRound(server);
      expect(await device.bookmarks.byId('remote'), isNotNull);
    });

    test('a genuinely empty account proceeds with the flag set — the hold '
        'is the protection', () async {
      final device = await _Device.create(tempDir, 'a');
      await server.addAccount(username: 'ghost-1', password: 'pw');

      final result = await device.enrollment.login(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-1',
        password: 'pw',
        encryptionPassphrase: 'pw',
        mode: SyncAccountMode.separate,
      );

      expect(result.passphraseUnverified, isTrue);
      expect(result.passphraseWarning, isNull);
      expect(device.credentials.token, isNotNull);
      expect(await device.state.passphraseUnverified(), isTrue);
    });

    test('a wrong account password fails at login — nothing persists',
        () async {
      final device = await _Device.create(tempDir, 'a');
      await server.addAccount(username: 'ghost-1', password: 'pw');

      await expectLater(
        () => device.enrollment.login(
          api: server,
          baseUrl: 'https://sync.example.com',
          username: 'ghost-1',
          password: 'not-the-password',
          encryptionPassphrase: 'pw',
          mode: SyncAccountMode.separate,
        ),
        throwsA(isA<ApiError>()),
      );
      // The api minted no token, and nothing durable was written.
      expect(device.credentials.token, isNull);
      expect(await device.state.account(), isNull);
    });

    test('a pull failure mid-login persists no token — the keystore write '
        'comes after the check', () async {
      final device = await _Device.create(tempDir, 'a');
      await server.addAccount(username: 'ghost-1', password: 'pw');
      server.nextPullError =
          const ApiError(code: 'server_error', message: 'boom');

      await expectLater(
        () => device.enrollment.login(
          api: server,
          baseUrl: 'https://sync.example.com',
          username: 'ghost-1',
          password: 'pw',
          encryptionPassphrase: 'pw',
          mode: SyncAccountMode.separate,
        ),
        throwsA(isA<ApiError>()),
      );
      // api.login minted a session token, but enrollment never reaches
      // _persist — the session must not linger in the keystore.
      expect(device.credentials.token, isNull);
      expect(await device.state.account(), isNull);
    });

    test('a KDF downgrade is refused loudly — no derive, no login, no token',
        () async {
      final device = await _Device.create(tempDir, 'a');
      await server.addAccount(username: 'ghost-1', password: 'pw');
      server.preloginParamsOverride = const Argon2Params.fast();

      await expectLater(
        () => device.enrollment.login(
          api: server,
          baseUrl: 'https://sync.example.com',
          username: 'ghost-1',
          password: 'pw',
          encryptionPassphrase: 'pw',
          mode: SyncAccountMode.separate,
        ),
        throwsA(isA<KdfDowngradeException>()),
      );
      expect(server.loginCalls, 0);
      expect(device.credentials.token, isNull);
      expect(await device.state.account(), isNull);
    });

    test('trial-decrypt failure warns with the three-cause copy, proceeds '
        'with the flag, and holds pushes', () async {
      final device = await _Device.create(tempDir, 'a');
      final account =
          await server.addAccount(username: 'ghost-1', password: 'pw');
      // Sealed under a different key: the entered passphrase cannot
      // decrypt it — corrupt record and wrong passphrase look alike here.
      final otherKey = secureRandomBytes(32);
      server.seed(await _sealBookmark(_bookmark('foreign'), otherKey));
      // The salt only proves the fixture is genuinely foreign —
      // enrollment must not consult it.
      expect(account.salt, isNotEmpty);

      final result = await device.enrollment.login(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-1',
        password: 'pw',
        encryptionPassphrase: 'pw',
        mode: SyncAccountMode.separate,
      );

      expect(result.passphraseUnverified, isTrue);
      expect(result.passphraseWarning, syncPassphraseCheckFailedMessage);
      // The durable Settings → Backup error is raised, not just the
      // transient warning on the result.
      expect(await device.state.notices(),
          contains(syncNoticePassphraseCheckFailed));
      // Enrollment completed — the token is enrolled — but the failing
      // record is preserved, not materialized, and pushes are held.
      expect(device.credentials.token, isNotNull);
      final coordinator = device.coordinatorFor(result.vaultKey);
      final round = await coordinator.runRound(server);
      expect(round.pushesHeld, isTrue);
      expect(server.pushCalls, 0);
      expect(await device.bookmarks.byId('foreign'), isNull);
      expect(await device.records.getRecord('bookmark:foreign'), isNotNull);
    });

    test('the trial never touches secret:/snippet:/unknown-prefix ids',
        () async {
      final device = await _Device.create(tempDir, 'a');
      await server.addAccount(username: 'ghost-1', password: 'pw');
      // A decryptable candidate would pass under the right key; make the
      // ONLY candidates never-decrypt ids so the flag must still set.
      final wrongKey = secureRandomBytes(32);
      for (final id in ['secret:s1', 'snippet:s2', 'flurb:x']) {
        server.seed(EncryptedRecord(
          id: id,
          updatedAt: 1,
          deviceId: 'foreign-device',
          deleted: false,
          seq: null,
          blob: Uint8List.fromList(await VaultCrypto.sealJson(
              wrongKey, {'kind': 'x', 'data': {}})),
        ));
      }

      final result = await device.enrollment.login(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-1',
        password: 'pw',
        encryptionPassphrase: 'pw',
        mode: SyncAccountMode.separate,
      );

      // No decryptable candidate → flag set with no warning, exactly like
      // the empty-account case.
      expect(result.passphraseUnverified, isTrue);
      expect(result.passphraseWarning, isNull);
    });
  });

  group('push hold and the deferred foreign-record check (04 §4.5)', () {
    test('a wrong passphrase against an empty account pushes nothing',
        () async {
      final device = await _Device.create(tempDir, 'a');
      await server.addAccount(username: 'ghost-1', password: 'pw');

      final result = await device.enrollment.login(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-1',
        password: 'pw',
        encryptionPassphrase: 'wrong-passphrase',
        mode: SyncAccountMode.separate,
      );
      expect(result.passphraseUnverified, isTrue);

      final coordinator = device.coordinatorFor(result.vaultKey);
      final saved = await device.bookmarks.save(_bookmark('local'));
      await coordinator.onBookmarkSaved(saved);
      final round = await coordinator.runRound(server);

      expect(round.pushesHeld, isTrue);
      expect(server.pushCalls, 0);
      expect(server.records, isEmpty);
      // The edit stays sealed and dirty for the release path.
      expect(await device.records.dirtyRecords(), isNotEmpty);
    });

    test('a self-authored record does not clear the flag', () async {
      final device = await _Device.create(tempDir, 'a');
      await server.addAccount(username: 'ghost-1', password: 'pw');
      final result = await device.enrollment.login(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-1',
        password: 'pw',
        encryptionPassphrase: 'wrong-passphrase',
        mode: SyncAccountMode.separate,
      );

      // A record this device sealed decrypts under whatever key sealed
      // it — it must not vacuously bless the passphrase.
      final coordinator = device.coordinatorFor(result.vaultKey);
      final saved = await device.bookmarks.save(_bookmark('mine'));
      await coordinator.onBookmarkSaved(saved);
      await coordinator.runRound(server);

      expect(await device.state.passphraseUnverified(), isTrue);
      expect(server.pushCalls, 0);
    });

    test('a foreign hostkey: record clears the flag and releases pushes',
        () async {
      final device = await _Device.create(tempDir, 'a');
      final account =
          await server.addAccount(username: 'ghost-1', password: 'pw');
      final vaultKey = account.keys.vaultKey;
      // Only decryptable foreign record is a pin — the account whose
      // servers were all deleted (04 §4.5's pinned case). The entered
      // passphrase is RIGHT; the flag stood only because enrollment had
      // no decryptable candidate at the time.
      final result = await device.enrollment.login(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-1',
        password: 'pw',
        encryptionPassphrase: 'pw',
        mode: SyncAccountMode.separate,
      );
      expect(result.passphraseUnverified, isTrue);

      final coordinator = device.coordinatorFor(result.vaultKey);
      final saved = await device.bookmarks.save(_bookmark('queued'));
      await coordinator.onBookmarkSaved(saved);
      await coordinator.runRound(server);
      expect(server.pushCalls, 0);

      server.seed(await _sealPin(
          _pin('h.example.com', 'SHA256:FLEET'), vaultKey));
      final round = await coordinator.runRound(server);

      expect(await device.state.passphraseUnverified(), isFalse);
      expect(round.pushesHeld, isFalse);
      // The released push lands on the next round; the pin applied.
      expect(await device.hostKeys.get('h.example.com', 22), isNotNull);
      await coordinator.runRound(server);
      expect(server.records['bookmark:queued'], isNotNull);
    });

    test('a failing foreign record raises the durable error with pushes '
        'still held', () async {
      final device = await _Device.create(tempDir, 'a');
      await server.addAccount(username: 'ghost-1', password: 'pw');
      // Enroll under the wrong passphrase on an empty account.
      final result = await device.enrollment.login(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-1',
        password: 'pw',
        encryptionPassphrase: 'wrong-passphrase',
        mode: SyncAccountMode.separate,
      );
      final coordinator = device.coordinatorFor(result.vaultKey);
      await coordinator.runRound(server);
      expect(await device.state.notices(), isNot(contains(
          syncNoticePassphraseCheckFailed)));

      // A foreign record arrives that the held key cannot decrypt.
      final wrongKey = secureRandomBytes(32);
      server.seed(await _sealBookmark(_bookmark('foreign'), wrongKey));
      final round = await coordinator.runRound(server);

      expect(round.pushesHeld, isTrue);
      expect(await device.state.passphraseUnverified(), isTrue);
      expect(await device.state.notices(),
          contains(syncNoticePassphraseCheckFailed));
      expect(server.pushCalls, 0);
    });

    test('records pulled under a wrong passphrase apply once the '
        'passphrase is corrected', () async {
      final device = await _Device.create(tempDir, 'a');
      final account =
          await server.addAccount(username: 'ghost-1', password: 'pw');
      final vaultKey = account.keys.vaultKey;
      server.seed(await _sealBookmark(
          _bookmark('fleet', label: 'v1'), vaultKey));

      // First enrollment: wrong passphrase → flag, record skip-preserved.
      final wrong = await device.enrollment.login(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-1',
        password: 'pw',
        encryptionPassphrase: 'wrong-passphrase',
        mode: SyncAccountMode.separate,
      );
      var coordinator = device.coordinatorFor(wrong.vaultKey);
      await coordinator.runRound(server);
      expect(await device.bookmarks.byId('fleet'), isNull);
      // A local edit sealed under the wrong key is held dirty.
      final saved = await device.bookmarks.save(_bookmark('local'));
      await coordinator.onBookmarkSaved(saved);
      await coordinator.runRound(server);
      expect(server.pushCalls, 0);

      // Corrected passphrase re-runs enrollment's full pull (since = 0).
      final right = await device.enrollment.login(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-1',
        password: 'pw',
        encryptionPassphrase: 'pw',
        mode: SyncAccountMode.separate,
      );
      expect(right.passphraseUnverified, isFalse);
      expect(server.pullCursors.last, 0);

      // The dirty record was sealed under the wrong key — re-seal pending
      // writes under the verified key before any held push is released.
      coordinator = device.coordinatorFor(right.vaultKey);
      await coordinator.reSealPendingWrites();
      final round = await coordinator.runRound(server);

      // The skip-preserved record applied; the re-sealed edit pushed and
      // decrypts under the real account key.
      expect((await device.bookmarks.byId('fleet'))!.label, 'v1');
      expect(round.pushed, greaterThan(0));
      final pushed = server.records['bookmark:local']!;
      final dec = await RecordCodec(vaultKey).decrypt(pushed);
      expect(Bookmark.fromJson(dec.data, recordId: dec.id).id, 'local');
    });
  });

  group('dead account (04 §7.3)', () {
    test('a 401 on pull drops to local-only with a durable notice', () async {
      final device = await _Device.create(tempDir, 'a');
      final result = await device.enrollment.registerSeparate(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-2',
        password: 'pw',
        encryptionPassphrase: 'pw',
      );
      final coordinator = device.coordinatorFor(result.vaultKey);

      server.nextPullError =
          const ApiError(code: 'unauthorized', message: 'Invalid token');
      final round = await coordinator.runRound(server);

      expect(round.authFailed, isTrue);
      expect(await device.state.notices(),
          contains(syncNoticeAccountAuthFailed));
      // §7.3's local-only posture keeps the token — the account may
      // recover, and the very next good pull proves it did.
      expect(device.credentials.tokenDeletes, 0);
      await coordinator.runRound(server);
      expect(await device.state.notices(),
          isNot(contains(syncNoticeAccountAuthFailed)));
    });

    test('a 401 on push ends the round with the same notice', () async {
      final device = await _Device.create(tempDir, 'a');
      final result = await device.enrollment.registerSeparate(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-2',
        password: 'pw',
        encryptionPassphrase: 'pw',
      );
      final coordinator = device.coordinatorFor(result.vaultKey);
      final saved = await device.bookmarks.save(_bookmark('held'));
      await coordinator.onBookmarkSaved(saved);

      server.nextPushError =
          const ApiError(code: 'unauthorized', message: 'Invalid token');
      final round = await coordinator.runRound(server);

      expect(round.authFailed, isTrue);
      expect(await device.state.notices(),
          contains(syncNoticeAccountAuthFailed));
      // The rejected dirt stays dirty for the recovered round.
      expect(await device.records.dirtyRecords(), isNotEmpty);
      await coordinator.runRound(server);
      expect(server.records['bookmark:held'], isNotNull);
    });
  });

  group('keystore confinement', () {
    test('the bearer token never lands on disk outside the keystore seam',
        () async {
      final device = await _Device.create(tempDir, 'a');
      final result = await device.enrollment.registerSeparate(
        api: server,
        baseUrl: 'https://sync.example.com',
        username: 'ghost-3',
        password: 'pw',
        encryptionPassphrase: 'pw',
      );
      final coordinator = device.coordinatorFor(result.vaultKey);
      final saved = await device.bookmarks.save(_bookmark('synced'));
      await coordinator.onBookmarkSaved(saved);
      await coordinator.runRound(server);

      final token = device.credentials.token!;
      expect(token, isNotEmpty);
      for (final contents in await device.diskContents()) {
        expect(contents, isNot(contains(token)),
            reason: 'token leaked into a persisted document');
      }
    });
  });
}
