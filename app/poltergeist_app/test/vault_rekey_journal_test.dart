// Ported from Séance app/seance_app/test/vault_rekey_journal_test.dart @
// ded9228 — the FileVaultStore journal cases verbatim; the AppServices
// groups adapted onto Poltergeist's seams (startup settle lives in
// main.dart, the re-key driver in SecureSyncCredentialStore).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/file_stores.dart';
import 'package:poltergeist_app/services/secure_master_key.dart';
import 'package:poltergeist_app/services/sync_credentials.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// An OS keystore that keeps what it is given, and can be locked the way an
/// auto-login Linux session leaves the login keyring.
class _Keystore extends FlutterSecureStorage {
  _Keystore();
  final Map<String, String> _map = {};
  bool locked = false;

  /// Runs just before a write is accepted, so a test can look at the vault
  /// directory at the exact instant the keystore is about to change.
  Future<void> Function()? onWrite;

  /// The keystore that refuses a write without storing anything — still
  /// readable, so it can testify afterwards.
  bool failWrite = false;

  /// The keystore that keeps the value and then reports failure anyway.
  bool throwAfterWrite = false;

  /// The keystore that keeps the value and then locks, so the write fails
  /// and the read that would testify about it fails too.
  bool lockAfterWrite = false;

  /// The keystore that ends up holding something other than what was
  /// written and reports the write as failed.
  String? substituteOnWrite;

  void _check() {
    if (locked) {
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
  }

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
    _check();
    return _map[key];
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
    _check();
    await onWrite?.call();
    if (failWrite) {
      throw PlatformException(code: 'Unknown', message: 'write refused');
    }
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
    if (substituteOnWrite != null) {
      _map[key] = substituteOnWrite!;
      throw PlatformException(code: 'Unknown', message: 'stored, then failed');
    }
    if (lockAfterWrite) {
      locked = true;
      throw PlatformException(code: 'KeyringLocked', message: 'KeyringLocked');
    }
    if (throwAfterWrite) {
      throw PlatformException(code: 'Unknown', message: 'stored, then failed');
    }
  }
}

Secret secret(String id) =>
    Secret(id: id, kind: SecretKind.password, value: 'value-$id');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late File vaultFile;
  late File journalFile;
  late List<int> oldKey;
  late List<int> newKey;
  late _Keystore keystore;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('poltergeist-rekey-');
    keystore = _Keystore();
    vaultFile = File('${directory.path}/vault.json');
    journalFile = File('${vaultFile.path}.rekey');
    oldKey = secureRandomBytes(32);
    newKey = secureRandomBytes(32);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  /// The state a process leaves behind when it dies inside the re-key: both
  /// generations staged, and whatever the keystore had got to by then.
  Future<void> crashMidRekey({required List<int> installed}) async {
    final store = FileVaultStore(vaultFile);
    await SecretVault(store, oldKey).putSecrets([secret('a'), secret('b')]);
    await store.stageRekey(currentKey: oldKey, newKey: newKey);
    await MasterKeyManager(keystore).setKeystoreKey(installed);
  }

  group('FileVaultStore re-key journal', () {
    test('a crash before the keystore write leaves the old key working',
        () async {
      await crashMidRekey(installed: oldKey);

      // A fresh store is the next launch: it finds the journal and settles it
      // against the key the keystore actually kept.
      final reopened = FileVaultStore(vaultFile);
      expect(await reopened.settleRekey(oldKey), VaultRekeyOutcome.adopted);
      final vault = SecretVault(reopened, oldKey);
      expect((await vault.getSecret('a'))!.value, 'value-a');
      expect((await vault.getSecret('b'))!.value, 'value-b');
      expect(await journalFile.exists(), isFalse);
    });

    test('a crash after the keystore write leaves the new key working',
        () async {
      await crashMidRekey(installed: newKey);

      final reopened = FileVaultStore(vaultFile);
      expect(await reopened.settleRekey(newKey), VaultRekeyOutcome.adopted);
      final vault = SecretVault(reopened, newKey);
      expect((await vault.getSecret('a'))!.value, 'value-a');
      expect((await vault.getSecret('b'))!.value, 'value-b');
      expect(await journalFile.exists(), isFalse);

      // The generation actually committed to the vault file is the new one,
      // so the next launch needs no journal to read it.
      final next = SecretVault(FileVaultStore(vaultFile), newKey);
      expect((await next.getSecret('a'))!.value, 'value-a');
    });

    test('a key matching neither generation drops the journal, not the '
        'vault', () async {
      await crashMidRekey(installed: oldKey);

      // Neither staged generation can be opened, so neither is recoverable.
      // What matters is that the store does not stay wedged behind a journal
      // nothing can clear.
      final reopened = FileVaultStore(vaultFile);
      expect(await reopened.settleRekey(secureRandomBytes(32)),
          VaultRekeyOutcome.discarded);
      expect(await journalFile.exists(), isFalse);
      expect(
          directory.listSync().any((f) => f.path.contains('.corrupt')),
          isTrue);

      // The stored vault is untouched: staging never wrote it.
      expect(
          (await SecretVault(reopened, oldKey).getSecret('a'))!.value,
          'value-a');
      // And ordinary mutations are allowed again.
      await SecretVault(reopened, oldKey).putSecret(secret('c'));
      expect(
          (await SecretVault(reopened, oldKey).getSecret('c'))!.value,
          'value-c');
    });

    test('a stray or damaged journal never blocks a vault read', () async {
      await SecretVault(FileVaultStore(vaultFile), oldKey)
          .putSecret(secret('a'));
      // The trap this guards: a journal no code path created and none could
      // clear, failing every read from here on.
      await journalFile.writeAsString('not json at all');

      final vault = SecretVault(FileVaultStore(vaultFile), oldKey);
      expect((await vault.getSecret('a'))!.value, 'value-a');
      expect(await journalFile.exists(), isFalse);
      expect(
          directory.listSync().any((f) => f.path.contains('.corrupt')),
          isTrue);
    });

    test('an entry the current key cannot open survives the re-key',
        () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('live'));
      // An orphan left sealed under a key nobody holds any more. Re-keying
      // must not fail on it, and must not delete it either.
      await SecretVault(store, secureRandomBytes(32))
          .putSecret(secret('lost'));

      await store.stageRekey(currentKey: oldKey, newKey: newKey);
      expect(await store.settleRekey(newKey), VaultRekeyOutcome.adopted);

      final vault = SecretVault(store, newKey);
      expect((await vault.getSecret('live'))!.value, 'value-live');
      expect(await store.getSecretBlob('lost'), isNotNull);
    });

    test('credentials are not mutable while a re-key is staged', () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('a'));
      await store.stageRekey(currentKey: oldKey, newKey: newKey);

      // A write now would persist the stored generation, which settling may
      // then replace with the staged one, silently undoing it.
      await expectLater(
        () => SecretVault(store, oldKey).putSecret(secret('b')),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        () => store.stageRekey(currentKey: oldKey, newKey: newKey),
        throwsA(isA<StateError>()),
      );
    });

    test('the journal stores no plaintext', () async {
      final store = FileVaultStore(vaultFile);
      await SecretVault(store, oldKey).putSecret(secret('a'));
      await store.stageRekey(currentKey: oldKey, newKey: newKey);

      final staged = await journalFile.readAsString();
      expect(staged, isNot(contains('value-a')));
      // Both halves: the journal carries a generation under each key, so a
      // writer that leaked key material would leak either one.
      expect(staged, isNot(contains(base64.encode(newKey))));
      expect(staged, isNot(contains(base64.encode(oldKey))));
    });

    test('a valid journal never blocks a vault read', () async {
      await crashMidRekey(installed: oldKey);

      // The damaged-journal case is covered above; this is the other half,
      // and the reason staging leaves `vault.json` alone. The unwired code
      // made the sidecar authoritative and refused every read while one
      // existed.
      final vault = SecretVault(FileVaultStore(vaultFile), oldKey);
      expect((await vault.getSecret('a'))!.value, 'value-a');
      expect(await journalFile.exists(), isTrue);
    });

    test('settling again after a crash mid-commit is harmless', () async {
      await crashMidRekey(installed: newKey);
      final staged = await journalFile.readAsString();
      expect(await FileVaultStore(vaultFile).settleRekey(newKey),
          VaultRekeyOutcome.adopted);
      // settleRekey flushes the vault and *then* clears the sidecar, so a
      // process dying between the two leaves a journal beside a vault that
      // already holds the adopted generation. The next launch settles it
      // again, which has to be a no-op rather than a second rewrite.
      await journalFile.writeAsString(staged);

      final reopened = FileVaultStore(vaultFile);
      expect(await reopened.settleRekey(newKey), VaultRekeyOutcome.adopted);
      expect((await SecretVault(reopened, newKey).getSecret('a'))!.value,
          'value-a');
      expect(await journalFile.exists(), isFalse);
    });

    test('a journal that is not even valid UTF-8 is damage, not a failed '
        'read', () async {
      await crashMidRekey(installed: oldKey);
      // `readAsString` reports malformed UTF-8 as a FileSystemException, the
      // same type a locked or unreadable file raises. Reading bytes and
      // decoding them here is what keeps the two apart, so this content has
      // to be quarantined like any other damage rather than retried forever.
      await journalFile.writeAsBytes([0xff, 0xfe, 0xfd]);

      final store = FileVaultStore(vaultFile);
      expect(await store.settleRekey(oldKey), VaultRekeyOutcome.none);
      expect(
          (await SecretVault(store, oldKey).getSecret('a'))!.value,
          'value-a');
      expect(await journalFile.exists(), isFalse);
      expect(
          directory.listSync().any((f) => f.path.contains('.corrupt')),
          isTrue);
    });
  });

  group('SecureSyncCredentialStore re-keys through the journal', () {
    late FileVaultStore vaultStore;
    late SecureSyncCredentialStore credentials;

    setUp(() {
      vaultStore = FileVaultStore(vaultFile);
      credentials = SecureSyncCredentialStore(
        keys: MasterKeyManager(keystore),
        vaultJournal: vaultStore,
      );
    });

    /// A vault holding one credential, opened by the key the keystore
    /// holds.
    Future<void> enrolled() async {
      await MasterKeyManager(keystore).setKeystoreKey(oldKey);
      await SecretVault(vaultStore, oldKey).putSecret(secret('a'));
    }

    test('both generations are staged before the keystore is changed',
        () async {
      await enrolled();
      // The whole point of the journal is that it is durable *first*. Read
      // the sidecar at the moment the keystore write begins: staged after
      // it, this finds nothing and the crash window is still open.
      String? stagedAtWrite;
      keystore.onWrite = () async {
        if (await journalFile.exists()) {
          stagedAtWrite = await journalFile.readAsString();
        }
      };

      await credentials.writeVaultKey(newKey);

      expect(stagedAtWrite, isNotNull);
      expect(stagedAtWrite, contains(RegExp(r'"version"\s*:\s*1')));
      expect((await SecretVault(vaultStore, newKey).getSecret('a'))!.value,
          'value-a');
      expect(await journalFile.exists(), isFalse);
    });

    test('a keyring that refuses the new key leaves the old one working',
        () async {
      await enrolled();
      // Refuses the write but stays readable: it can still testify that
      // the old key is the installed one, so the refusal settles cleanly
      // onto the generation that key opens.
      keystore.failWrite = true;

      await expectLater(() => credentials.writeVaultKey(newKey),
          throwsA(isA<KeystoreException>()));

      expect(
          (await SecretVault(vaultStore, oldKey).getSecret('a'))!.value,
          'value-a');
      // Settled, not merely abandoned: the journal resolved against the
      // key the keyring actually kept and is gone.
      expect(await journalFile.exists(), isFalse);
    });

    test('a refused re-key retries cleanly once the keyring allows it',
        () async {
      await enrolled();
      keystore.failWrite = true;
      await expectLater(() => credentials.writeVaultKey(newKey),
          throwsA(isA<KeystoreException>()));

      keystore.failWrite = false;
      await credentials.writeVaultKey(newKey);

      expect((await SecretVault(vaultStore, newKey).getSecret('a'))!.value,
          'value-a');
      expect(await journalFile.exists(), isFalse);
    });

    test('a keyring that stores the key and then throws settles on it',
        () async {
      await enrolled();
      keystore.throwAfterWrite = true;

      await expectLater(() => credentials.writeVaultKey(newKey),
          throwsA(isA<KeystoreException>()));

      // The keystore kept the new key, so the new generation is the one
      // that has to win — reading the keystore back is what tells them
      // apart, and settling on the old key here would orphan the vault.
      expect((await SecretVault(vaultStore, newKey).getSecret('a'))!.value,
          'value-a');
      expect(await journalFile.exists(), isFalse);
    });

    test('a keyring that commits and then cannot testify keeps the '
        'journal', () async {
      await enrolled();
      keystore.lockAfterWrite = true;

      await expectLater(() => credentials.writeVaultKey(newKey),
          throwsA(isA<KeystoreException>()));

      // The one state no witness can resolve: the new key is installed,
      // and the keyring that would say so is locked. Settling on the old
      // key here would commit the vault to a generation the keystore
      // cannot open and clear the only copy of the other one.
      expect(await journalFile.exists(), isTrue);
      // Staging never wrote the vault file, so this session keeps reading
      // through the generation that is still stored.
      expect(
          (await SecretVault(vaultStore, oldKey).getSecret('a'))!.value,
          'value-a');

      // The next launch, once the keyring is back: it settles against the
      // key the keystore really kept, and the new generation wins after
      // all.
      keystore.locked = false;
      keystore.lockAfterWrite = false;
      final reopened = FileVaultStore(vaultFile);
      final installed = await MasterKeyManager(keystore).probeKeystore();
      expect(await reopened.settleRekey(installed!),
          VaultRekeyOutcome.adopted);
      expect((await SecretVault(reopened, newKey).getSecret('a'))!.value,
          'value-a');
      expect(await journalFile.exists(), isFalse);
    });

    test('a locked keystore cannot even begin the re-key', () async {
      await enrolled();
      keystore.locked = true;

      // probeKeystore reads null, so no journal is staged and nothing is
      // written: the failure is the locked vault's, not a half-done swap.
      await expectLater(() => credentials.writeVaultKey(newKey),
          throwsA(isA<VaultLockedException>()));
      expect(await journalFile.exists(), isFalse);
      expect(
          (await SecretVault(vaultStore, oldKey).getSecret('a'))!.value,
          'value-a');
    });
  });
}
