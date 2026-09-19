// Design B enrollment (04 §4.1/§4.5): the app-side bindings for the core
// credential/state seams. The bearer token and the passphrase-derived
// vault key live ONLY in the OS keystore (MasterKeyManager); the durable
// enrollment facts live in SettingsStore (settings.json) — never the
// other way around, and the token never touches a plain file.
import 'package:poltergeist_core/poltergeist_core.dart';

import 'secure_master_key.dart';
import 'settings_store.dart';
import 'uuid.dart';

/// The keystore sub-key for the sync bearer token — resolved against
/// MasterKeyManager's `poltergeist.apikey.` prefix, so the keystore entry
/// is `poltergeist.apikey.sync.token` (04 §4.5's name).
const String syncTokenKeyName = 'sync.token';

/// The [SyncCredentialStore] over the OS keystore: the session token and
/// the vault key live ONLY here — never settings.json, never the sync
/// record store.
final class SecureSyncCredentialStore implements SyncCredentialStore {
  SecureSyncCredentialStore({required MasterKeyManager keys})
      : // Keep the collaborator private.
        // ignore: prefer_initializing_formals
        _keys = keys;

  final MasterKeyManager _keys;

  /// Throws [KeystoreException] on a locked keystore — enrollment must
  /// fail loudly rather than drop a live session.
  @override
  Future<void> writeToken(String token) =>
      _keys.putApiKey(syncTokenKeyName, token);

  /// Tolerant like the keystore reads: a locked keyring reads as "not
  /// enrolled", and keystoreStatus carries the failure for the retry
  /// affordance.
  @override
  Future<String?> readToken() => _keys.getApiKey(syncTokenKeyName);

  /// Sign-out forgets the token locally; the server keeps it valid.
  @override
  Future<void> deleteToken() => _keys.deleteApiKey(syncTokenKeyName);

  /// The §4.5 re-key: the passphrase-derived vault key replaces the local
  /// master-key entry — the same keystore slot [MasterKeyManager]'s probe
  /// minted, so the vault follows the enrolled account key.
  @override
  Future<void> writeVaultKey(List<int> vaultKey) =>
      _keys.setKeystoreKey(vaultKey);
}

/// The [SyncEnrollmentState] over [SettingsStore] (settings.json): durable
/// account facts, the §4.5 push-hold flag, and the Settings → Backup
/// notice set. Never the bearer token — the keystore seam owns that.
final class SettingsSyncEnrollmentState implements SyncEnrollmentState {
  SettingsSyncEnrollmentState({required SettingsStore store})
      : // Keep the collaborator private.
        // ignore: prefer_initializing_formals
        _store = store;

  final SettingsStore _store;

  static const _deviceIdKey = 'poltergeist.sync.deviceId';
  static const _unverifiedKey = 'poltergeist.sync.passphraseUnverified';
  static const _noticesKey = 'poltergeist.sync.notices';
  static const _accountKey = 'poltergeist.sync.account';

  /// Minted once and persisted on first call, then stable forever —
  /// 04 §3.1's LWW authorship id is never regenerated casually.
  @override
  Future<String> deviceId() async {
    final existing = await _store.get<String>(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final minted = uuidV4();
    await _store.set(_deviceIdKey, minted);
    return minted;
  }

  @override
  Future<bool> passphraseUnverified() async =>
      await _store.get<bool>(_unverifiedKey) ?? false;

  @override
  Future<void> setPassphraseUnverified(bool value) =>
      _store.set(_unverifiedKey, value);

  @override
  Future<Set<String>> notices() async {
    final raw = await _store.get<List>(_noticesKey);
    return {for (final entry in raw ?? const []) '$entry'};
  }

  @override
  Future<void> setNotice(String notice, bool active) async {
    final next = await notices();
    if (active) {
      next.add(notice);
    } else {
      next.remove(notice);
    }
    // Sorted so the persisted form is stable across sessions.
    await _store.set(_noticesKey, next.toList()..sort());
  }

  @override
  Future<SyncAccount?> account() async {
    final raw = await _store.get<Map>(_accountKey);
    if (raw == null) return null;
    final baseUrl = raw['baseUrl'];
    final username = raw['username'];
    final mode = raw['mode'];
    // A partially-written or newer-schema entry reads as "not enrolled"
    // rather than crashing the round driver.
    if (baseUrl is! String || username is! String || mode is! String) {
      return null;
    }
    return SyncAccount(
      baseUrl: baseUrl,
      username: username,
      mode: SyncAccountMode.values.asNameMap()[mode] ??
          SyncAccountMode.separate,
    );
  }

  @override
  Future<void> setAccount(SyncAccount? account) => _store.set(
        _accountKey,
        account == null
            ? null
            : {
                'baseUrl': account.baseUrl,
                'username': account.username,
                'mode': account.mode.name,
              },
      );
}
