// 04 §3.3/§4.4 service-level coverage: enrollment over the #166 seams,
// the manual round, sign-out/delete, and the B→A switch driver — every
// durable effect asserted against the real seams (in-memory record store,
// fake transport/server, temp-dir SettingsStore) rather than mocked
// internals.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/bookmark_backup_service.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_sync_backup.dart';

final _fixedNow = DateTime.utc(2026, 1, 1, 12);

Bookmark _bookmark(String id) => Bookmark(
      id: id,
      kind: BookmarkKind.remotePath,
      label: id,
      server: const BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: 'web.example.com',
          port: 22,
          username: 'deploy',
          authMethod: AuthMethod.privateKey,
        ),
      ),
      remotePath: '/',
      sortKey: id,
      createdAt: _fixedNow,
      updatedAt: _fixedNow,
    );

HostKey _pin(String host, String fingerprint) => HostKey(
      host: host,
      type: 'ssh-ed25519',
      fingerprintSha256: fingerprint,
      pinnedAt: 1000,
    );

final class _Harness {
  _Harness(Directory root)
      : settings = SettingsStore(path: '${root.path}/settings.json');

  final server = FakeSyncServer();
  final transports = <FakeSyncTransport>[];
  final credentials = FakeSyncCredentialStore();
  final retained = FakeRetainedSyncTokenStore();
  final state = FakeSyncEnrollmentState();
  final SettingsStore settings;
  final bookmarks = FakeSyncTrackingBookmarkStore();
  final hostKeys = InMemoryHostKeyStore();
  final pinVerdicts = InMemoryPinVerdictStore();
  final tripwires = InMemorySyncTripwireStore();
  var records = InMemorySyncRecordStore();
  var clock = _fixedNow;

  late final service = BookmarkBackupService(
    credentials: credentials,
    retainedTokens: retained,
    enrollmentState: state,
    records: records,
    resetRecords: () async => records = InMemorySyncRecordStore(),
    bookmarks: bookmarks,
    hostKeys: hostKeys,
    pinVerdicts: pinVerdicts,
    tripwires: tripwires,
    transportFactory: fakeTransportFactory(server, transports),
    vaultKey: () async => credentials.vaultKey,
    settings: settings,
    now: () => clock,
  );

  /// The switch tests' separate-mode starting point — a live token and
  /// a vault key under an enrolled separate-mode account.
  Future<void> enrollSeparateDirectly() async {
    state.enrolled = const SyncAccount(
      baseUrl: 'https://sync.example',
      username: 'old',
      mode: SyncAccountMode.separate,
    );
    credentials.token = 'sep-token';
    credentials.vaultKey = List.filled(32, 7);
    await service.load();
  }

  /// Seal [record] under the vault key the shared login will derive —
  /// the password and passphrase are deliberately the same string so the
  /// enrollment runs Argon2 once (the test still pays the minimum).
  Future<EncryptedRecord> fleetSealed(
    DecryptedRecord record, {
    int seq = 7,
  }) async {
    final keys = await VaultCrypto.deriveKeys(
      passphrase: 'pw',
      salt: List.filled(16, 0),
      params: const Argon2Params(),
    );
    final sealed = await RecordCrypto(RecordCodec(keys.vaultKey))
        .seal(record);
    return sealed.withSeq(seq);
  }
}

void main() {
  late Directory temp;
  late _Harness h;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('backup-service-test');
    h = _Harness(temp);
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  group('enrollment (04 §4.1/§4.5)', () {
    test('registerSeparate persists token, vault key, and the separate '
        'account', () async {
      await h.service.registerSeparate(
        baseUrl: 'https://sync.example',
        username: 'ghost-abcd1234',
        // Same string twice → one Argon2 run (the minimum params still
        // run for real).
        password: 'pw',
        encryptionPassphrase: 'pw',
      );

      expect(h.server.registerCalls, 1);
      expect(h.credentials.token, 'token-ghost-abcd1234');
      expect(h.credentials.vaultKey, hasLength(32));
      final account = h.service.account!;
      expect(account.mode, SyncAccountMode.separate);
      expect(account.username, 'ghost-abcd1234');
      expect(h.service.passphraseUnverified, isFalse);
      // Every transport the service made was released.
      expect(
        h.transports,
        everyElement(
            predicate<FakeSyncTransport>((t) => t.closed)),
      );
    });

    test('loginAccount holds pushes when the trial-decrypt fails', () async {
      // A record no key can open: the trial-decrypt candidate.
      h.server.records.add(EncryptedRecord(
        id: 'bookmark:foreign',
        updatedAt: 1,
        deviceId: 'other',
        deleted: false,
        seq: 3,
        blob: Uint8List.fromList([1, 2, 3]),
      ));

      final result = await h.service.loginAccount(
        baseUrl: 'https://sync.example',
        username: 'shared-user',
        password: 'pw',
        encryptionPassphrase: 'pw',
        mode: SyncAccountMode.shared,
      );

      expect(result.passphraseUnverified, isTrue);
      expect(result.passphraseWarning, syncPassphraseCheckFailedMessage);
      expect(h.service.passphraseUnverified, isTrue);
      expect(
          h.service.notices, contains(syncNoticePassphraseCheckFailed));
      expect(h.service.account!.mode, SyncAccountMode.shared);
      // Shared mode materializes the Séance server catalog.
      expect(h.service.catalog, isNotNull);
      // §4.5's hold: a dirty local record must not reach the server
      // while the passphrase is unverified.
      final bookmark = _bookmark('held');
      final crypto =
          RecordCrypto(RecordCodec(h.credentials.vaultKey!));
      await h.records.putLocal(await crypto.seal(DecryptedRecord(
        id: 'bookmark:held',
        kind: RecordKind.bookmark,
        updatedAt: _fixedNow.millisecondsSinceEpoch,
        deviceId: 'test-device',
        data: bookmark.toJson(),
      )));
      await h.service.backUpNow();
      expect(h.server.pushed.map((r) => r.id),
          isNot(contains('bookmark:held')));
    });

    test('a below-minimum prelogin refuses to derive (KDF downgrade)',
        () async {
      h.server.argonParams = const Argon2Params.fast();
      await expectLater(
        h.service.loginAccount(
          baseUrl: 'https://sync.example',
          username: 'u',
          password: 'pw',
          encryptionPassphrase: 'pw',
          mode: SyncAccountMode.separate,
        ),
        throwsA(isA<KdfDowngradeException>()),
      );
      expect(h.state.enrolled, isNull);
      expect(h.credentials.token, isNull);
    });

    test('a closed registration surfaces the §4.3 exception', () async {
      h.server.registrationClosed = true;
      await expectLater(
        h.service.registerSeparate(
          baseUrl: 'https://sync.example',
          username: 'u',
          password: 'pw',
          encryptionPassphrase: 'pw',
        ),
        throwsA(isA<RegistrationClosedException>()),
      );
    });
  });

  group('round, sign-out, delete (04 §3.3/§4.1/§4.2)', () {
    test('backUpNow returns null while unenrolled', () async {
      await h.service.load();
      expect(await h.service.backUpNow(), isNull);
    });

    test('a round pushes the dirty set and stamps lastSyncAt', () async {
      await h.enrollSeparateDirectly();
      // A dirty record, sealed under the enrolled key exactly like the
      // coordinator's onBookmarkSaved does for a local edit.
      final bookmark = _bookmark('b1');
      final crypto =
          RecordCrypto(RecordCodec(h.credentials.vaultKey!));
      await h.records.putLocal(await crypto.seal(DecryptedRecord(
        id: 'bookmark:b1',
        kind: RecordKind.bookmark,
        updatedAt: _fixedNow.millisecondsSinceEpoch,
        deviceId: 'test-device',
        data: bookmark.toJson(),
      )));

      final result = await h.service.backUpNow();
      expect(result, isNotNull);
      expect(h.server.pushed.map((r) => r.id), ['bookmark:b1']);
      expect(h.service.lastSyncAt, _fixedNow);
      expect(h.service.lastSyncError, isNull);
      // A separate-mode success never arms the §4.4 delete offer.
      expect(h.service.deleteSeparateOffered, isFalse);
    });

    test('a 401 round raises the durable dead-account notice', () async {
      await h.enrollSeparateDirectly();
      h.server.unauthorized = true;
      final result = await h.service.backUpNow();
      expect(result, isNotNull);
      expect(result!.authFailed, isTrue);
      expect(h.service.notices, contains(syncNoticeAccountAuthFailed));
    });

    test('signOut forgets the token, account, and last-round status',
        () async {
      await h.enrollSeparateDirectly();
      final bookmark = _bookmark('b1');
      final crypto =
          RecordCrypto(RecordCodec(h.credentials.vaultKey!));
      await h.records.putLocal(await crypto.seal(DecryptedRecord(
        id: 'bookmark:b1',
        kind: RecordKind.bookmark,
        updatedAt: _fixedNow.millisecondsSinceEpoch,
        deviceId: 'test-device',
        data: bookmark.toJson(),
      )));
      await h.service.backUpNow();
      expect(h.service.lastSyncAt, isNotNull);

      await h.service.signOut();
      expect(h.credentials.token, isNull);
      expect(h.service.account, isNull);
      // The old account's bookkeeping must not leak into the next
      // enrollment's status line.
      expect(h.service.lastSyncAt, isNull);
      expect(h.service.lastSyncError, isNull);
    });

    test('resolvePinConflict throws when nothing is enrolled', () async {
      await h.service.load();
      final pin = _pin('conflict.example.com', 'SHA256:x');
      await expectLater(
        h.service.resolvePinConflict(
          HostKeyConflict(
            locator: pin.locator,
            local: pin,
            pulled: pin,
          ),
          keepLocal: true,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('deleteSeparateAccount requires the typed account name', () async {
      await h.enrollSeparateDirectly();
      await expectLater(
        h.service.deleteSeparateAccount(confirmedName: 'not-old'),
        throwsA(isA<ArgumentError>()),
      );
      expect(h.server.deleteAccountCalls, 0);

      await h.service.deleteSeparateAccount(confirmedName: 'old');
      expect(h.server.deleteAccountCalls, 1);
      // The delete transport authenticated with the live session token.
      expect(h.transports.last.token, 'sep-token');
      expect(h.service.account, isNull);
      expect(h.credentials.token, isNull);
    });

    test('account deletion does not exist in shared mode', () async {
      h.state.enrolled = const SyncAccount(
        baseUrl: 'https://sync.example',
        username: 'fleet',
        mode: SyncAccountMode.shared,
      );
      h.credentials.token = 't';
      h.credentials.vaultKey = List.filled(32, 1);
      await h.service.load();
      await expectLater(
        h.service.deleteSeparateAccount(confirmedName: 'fleet'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('B→A switch (04 §4.4)', () {
    test('requires a separate-mode account', () async {
      await h.service.load();
      await expectLater(
        h.service.switchToShared(
          baseUrl: 'https://sync.example',
          username: 'u',
          password: 'pw',
          encryptionPassphrase: 'pw',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('the full sequence: retain → wipe → shared login → dirty-mark → '
        're-seal non-held pins → hold the conflict', () async {
      await h.enrollSeparateDirectly();
      h.bookmarks.inner.bookmarks = [_bookmark('b1')];
      h.hostKeys.put(_pin('conflict.example.com', 'SHA256:local'));
      h.hostKeys.put(_pin('quiet.example.com', 'SHA256:quiet'));
      // A legacy record the wipe must destroy.
      await h.records.putLocal(EncryptedRecord(
        id: 'bookmark:legacy',
        updatedAt: 1,
        deviceId: 'test-device',
        deleted: false,
        seq: null,
        blob: Uint8List.fromList([9]),
      ));
      // The fleet's conflicting pin for the same locator, sealed under
      // the vault key the shared login derives.
      h.server.records.add(await h.fleetSealed(DecryptedRecord(
        id: 'hostkey:conflict.example.com:22',
        kind: RecordKind.hostKey,
        updatedAt: 4000,
        deviceId: 'fleet-device',
        data: _pin('conflict.example.com', 'SHA256:fleet').toJson(),
      )));
      h.server.seq = 7;

      final outcome = await h.service.switchToShared(
        baseUrl: 'https://sync.example',
        username: 'fleet',
        password: 'pw',
        encryptionPassphrase: 'pw',
      );

      // 1. The separate token was parked before the enrollment write.
      expect(h.retained.token, 'sep-token');
      expect(h.service.retainedAccount!.username, 'old');
      // 2. The live slot now holds the shared session.
      expect(h.credentials.token, 'token-fleet');
      expect(h.service.account!.mode, SyncAccountMode.shared);
      // 3. The login pulled since=0 (full pull) and the trial-decrypt
      //    verified the passphrase against the fleet record.
      expect(h.server.pullSinces, contains(0));
      expect(outcome.passphraseUnverified, isFalse);
      // 4. The quarantined conflict is held, unresolved.
      expect(outcome.held.map((c) => c.locator),
          ['conflict.example.com:22']);
      expect(h.service.pinConflicts, hasLength(1));
      // 5. The delete offer waits on a proven shared sync.
      expect(h.service.deleteSeparateOffered, isFalse);

      // 6. Push what the switch dirtied: the local bookmark and the
      //    non-held pin — never the held locator, never the wiped legacy.
      await h.service.backUpNow();
      final pushedIds = h.server.pushed.map((r) => r.id).toSet();
      expect(pushedIds, containsAll(
          ['bookmark:b1', 'hostkey:quiet.example.com:22']));
      expect(pushedIds, isNot(contains('hostkey:conflict.example.com:22')));
      expect(pushedIds, isNot(contains('bookmark:legacy')));

      // 7. The proven shared sync arms the delete offer.
      expect(h.service.deleteSeparateOffered, isTrue);
    });

    test('adopt-fleet installs the pulled pin without re-pushing it',
        () async {
      await h.enrollSeparateDirectly();
      h.hostKeys.put(_pin('conflict.example.com', 'SHA256:local'));
      h.server.records.add(await h.fleetSealed(DecryptedRecord(
        id: 'hostkey:conflict.example.com:22',
        kind: RecordKind.hostKey,
        updatedAt: 4000,
        deviceId: 'fleet-device',
        data: _pin('conflict.example.com', 'SHA256:fleet').toJson(),
      )));

      var outcome = await h.service.switchToShared(
        baseUrl: 'https://sync.example',
        username: 'fleet',
        password: 'pw',
        encryptionPassphrase: 'pw',
      );
      // Adopt the fleet pin: installed locally, no re-push needed.
      await h.service.resolvePinConflict(outcome.held.single,
          keepLocal: false);
      expect(h.service.pinConflicts, isEmpty);
      expect(
        (await h.hostKeys.get('conflict.example.com', 22))!
            .fingerprintSha256,
        'SHA256:fleet',
      );
      // The fleet record is already on the server — the next round must
      // not push it back as a local write.
      await h.service.backUpNow();
      expect(h.server.pushed.map((r) => r.id),
          isNot(contains('hostkey:conflict.example.com:22')));
    });

    test('keep-local records the kept verdict and re-pushes the pin',
        () async {
      await h.enrollSeparateDirectly();
      h.hostKeys.put(_pin('conflict.example.com', 'SHA256:local'));
      h.server.records.add(await h.fleetSealed(DecryptedRecord(
        id: 'hostkey:conflict.example.com:22',
        kind: RecordKind.hostKey,
        updatedAt: 4000,
        deviceId: 'fleet-device',
        data: _pin('conflict.example.com', 'SHA256:fleet').toJson(),
      )));

      final outcome = await h.service.switchToShared(
        baseUrl: 'https://sync.example',
        username: 'fleet',
        password: 'pw',
        encryptionPassphrase: 'pw',
      );
      await h.service.resolvePinConflict(outcome.held.single,
          keepLocal: true);

      expect(h.service.pinConflicts, isEmpty);
      // The durable verdict names the rejected fingerprint.
      expect(
        await h.pinVerdicts
            .rejectedFingerprintFor('conflict.example.com:22'),
        'SHA256:fleet',
      );
      // The kept pin re-sealed dirty → the next round re-pushes it.
      await h.service.backUpNow();
      expect(h.server.pushed.map((r) => r.id),
          contains('hostkey:conflict.example.com:22'));
      expect(
        (await h.hostKeys.get('conflict.example.com', 22))!
            .fingerprintSha256,
        'SHA256:local',
      );
    });

    test('the retained delete uses the parked token and needs the typed '
        'name; declining drops the token without deleting', () async {
      await h.enrollSeparateDirectly();
      await h.service.switchToShared(
        baseUrl: 'https://sync.example',
        username: 'fleet',
        password: 'pw',
        encryptionPassphrase: 'pw',
      );
      await h.service.backUpNow(); // prove the switch → arm the offer

      // Decline: token dropped, account untouched, offer gone.
      await h.service.declineRetainedDelete();
      expect(h.retained.token, isNull);
      expect(h.service.retainedAccount, isNull);
      expect(h.service.deleteSeparateOffered, isFalse);
      expect(h.server.deleteAccountCalls, 0);
    });

    test('a proven switch can delete the retained account by typed name',
        () async {
      await h.enrollSeparateDirectly();
      await h.service.switchToShared(
        baseUrl: 'https://sync.example',
        username: 'fleet',
        password: 'pw',
        encryptionPassphrase: 'pw',
      );
      await h.service.backUpNow();
      expect(h.service.deleteSeparateOffered, isTrue);

      await expectLater(
        h.service.deleteRetainedSeparateAccount(confirmedName: 'nope'),
        throwsA(isA<ArgumentError>()),
      );
      await h.service.deleteRetainedSeparateAccount(confirmedName: 'old');
      expect(h.server.deleteAccountCalls, 1);
      // The delete transport carried the PARKED token, not the live one.
      expect(h.transports.last.token, 'sep-token');
      expect(h.retained.token, isNull);
      expect(h.service.retainedAccount, isNull);
    });

    test('a switch failure retains the separate account facts', () async {
      await h.enrollSeparateDirectly();
      h.server.unauthorized = true; // shared login will 401
      await expectLater(
        h.service.switchToShared(
          baseUrl: 'https://sync.example',
          username: 'fleet',
          password: 'pw',
          encryptionPassphrase: 'pw',
        ),
        throwsA(isA<ApiError>()),
      );
      // The retained token was parked before the failed enrollment and
      // the separate session was restored — the old account still works.
      expect(h.retained.token, 'sep-token');
      expect(h.credentials.token, 'sep-token');
      expect(h.service.account!.mode, SyncAccountMode.separate);
      expect(h.service.retainedAccount!.username, 'old');
      expect(h.service.deleteSeparateOffered, isFalse);
    });
  });
}
