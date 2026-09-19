import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:poltergeist_app/services/secure_master_key.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/sync_credentials.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// In-memory keystore that can be "locked" on demand — the same shape the
/// keystore-resilience fakes use, plus delete for the sign-out path.
class _ToggleableKeystore extends FlutterSecureStorage {
  _ToggleableKeystore();
  final Map<String, String> map = {};
  bool locked = false;

  PlatformException _lockError() =>
      PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (locked) throw _lockError();
    return map[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (locked) throw _lockError();
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (locked) throw _lockError();
    map.remove(key);
  }
}

void main() {
  group('SecureSyncCredentialStore (04 §4.5)', () {
    test('token write/read/delete round-trips under the §4.5 keystore name',
        () async {
      final keystore = _ToggleableKeystore();
      final store =
          SecureSyncCredentialStore(keys: MasterKeyManager(keystore));

      await store.writeToken('token-abc');
      expect(keystore.map.keys,
          contains('poltergeist.apikey.sync.token'));
      expect(await store.readToken(), 'token-abc');

      await store.deleteToken();
      expect(await store.readToken(), isNull);
      expect(keystore.map, isNot(contains('poltergeist.apikey.sync.token')));
    });

    test('a locked keystore fails writes loudly, reads and deletes tolerate',
        () async {
      final keystore = _ToggleableKeystore()..locked = true;
      final keys = MasterKeyManager(keystore);
      final store = SecureSyncCredentialStore(keys: keys);

      // Enrollment must fail loudly rather than drop a live session.
      await expectLater(
        () => store.writeToken('token-abc'),
        throwsA(isA<KeystoreException>()),
      );
      expect(await store.readToken(), isNull);
      await store.deleteToken();
      expect(keys.keystoreStatus, KeystoreStatus.unavailable);
    });

    test('writeVaultKey lands under the vault master-key entry', () async {
      final keystore = _ToggleableKeystore();
      final store =
          SecureSyncCredentialStore(keys: MasterKeyManager(keystore));

      await store.writeVaultKey(List.filled(32, 9));
      expect(keystore.map.keys, contains('poltergeist.vault.masterKey.v1'));
    });
  });

  group('SettingsSyncEnrollmentState (04 §4.5)', () {
    late Directory dir;
    late File settingsFile;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sync_credentials_test');
      settingsFile = File('${dir.path}/settings.json');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    SettingsSyncEnrollmentState newState() =>
        SettingsSyncEnrollmentState(store: SettingsStore(
          path: settingsFile.path,
          now: () => DateTime.utc(2026, 9, 20, 12),
        ));

    test('the device id mints once and survives a fresh instance', () async {
      final first = await newState().deviceId();
      expect(first, isNotEmpty);
      expect(await newState().deviceId(), first);
    });

    test('hold flag, notices, and account round-trip durably', () async {
      final state = newState();

      expect(await state.passphraseUnverified(), isFalse);
      await state.setPassphraseUnverified(true);
      await state.setNotice(syncNoticePassphraseCheckFailed, true);
      await state.setAccount(const SyncAccount(
        baseUrl: 'https://sync.example.com',
        username: 'ghost-a1b2c3d4',
        mode: SyncAccountMode.separate,
      ));

      final reloaded = newState();
      expect(await reloaded.passphraseUnverified(), isTrue);
      expect(await reloaded.notices(),
          contains(syncNoticePassphraseCheckFailed));
      final account = await reloaded.account();
      expect(account!.username, 'ghost-a1b2c3d4');
      expect(account.mode, SyncAccountMode.separate);

      await reloaded.setNotice(syncNoticePassphraseCheckFailed, false);
      await reloaded.setAccount(null);
      expect(await newState().notices(),
          isNot(contains(syncNoticePassphraseCheckFailed)));
      expect(await newState().account(), isNull);
    });

    test('nothing persisted outside the keystore contains the token',
        () async {
      final keystore = _ToggleableKeystore();
      final credentials =
          SecureSyncCredentialStore(keys: MasterKeyManager(keystore));
      final state = newState();
      const token = 'bearer-9f8e7d6c';

      await credentials.writeToken(token);
      await state.deviceId();
      await state.setPassphraseUnverified(true);
      await state.setNotice(syncNoticePassphraseCheckFailed, true);
      await state.setAccount(const SyncAccount(
        baseUrl: 'https://sync.example.com',
        username: 'ghost-a1b2c3d4',
        mode: SyncAccountMode.separate,
      ));

      expect(await settingsFile.readAsString(), isNot(contains(token)));
    });
  });
}
