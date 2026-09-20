// Design B enrollment (04 §4.1/§4.5): the app-side bindings for the core
// credential/state seams. The bearer token and the passphrase-derived
// vault key live ONLY in the OS keystore (MasterKeyManager); the durable
// enrollment facts live in SettingsStore (settings.json) — never the
// other way around, and the token never touches a plain file.
import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';

import 'secure_master_key.dart';
import 'settings_store.dart';
import 'uuid.dart';

/// The keystore sub-key for the sync bearer token — resolved against
/// MasterKeyManager's `poltergeist.apikey.` prefix, so the keystore entry
/// is `poltergeist.apikey.sync.token` (04 §4.5's name).
const String syncTokenKeyName = 'sync.token';

/// The keystore sub-key for §4.4's retained separate-account token —
/// `poltergeist.apikey.sync.token.retained.v1`. The B→A switch parks the
/// separate token here before the shared enrollment overwrites the live
/// slot, so the optional post-switch delete can still authenticate.
const String retainedSyncTokenKeyName = 'sync.token.retained.v1';

/// The §4.4 retained-token seam: a second keystore slot the B→A switch
/// fills and the optional delete step (or the decline) empties.
abstract interface class RetainedSyncTokenStore {
  /// Park the separate account's bearer token. Throws on a locked
  /// keystore like the live-token write.
  Future<void> write(String token);

  /// The parked token, or null when absent or the keystore is unavailable.
  Future<String?> read();

  /// Drop the parked token — the delete completed or the user declined.
  Future<void> clear();
}

/// The [RetainedSyncTokenStore] over the OS keystore — same posture as
/// [SecureSyncCredentialStore]: writes throw, reads tolerate.
final class SecureRetainedSyncTokenStore implements RetainedSyncTokenStore {
  SecureRetainedSyncTokenStore({required MasterKeyManager keys})
      : // Keep the collaborator private.
        // ignore: prefer_initializing_formals
        _keys = keys;

  final MasterKeyManager _keys;

  @override
  Future<void> write(String token) =>
      _keys.putApiKey(retainedSyncTokenKeyName, token);

  @override
  Future<String?> read() => _keys.getApiKey(retainedSyncTokenKeyName);

  @override
  Future<void> clear() => _keys.deleteApiKey(retainedSyncTokenKeyName);
}

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
  /// 04 §3.1's LWW authorship id is never regenerated casually. The
  /// read-then-write is memoized through a shared future: two overlapping
  /// first calls would otherwise each mint a UUID, and a record sealed
  /// under the discarded id would read as foreign forever — including to
  /// §4.5's hold-clearing check, which a self-authored record must never
  /// satisfy. (Production wiring should still share ONE instance: the
  /// memo narrows the cross-instance window, it cannot close it.)
  Future<String>? _deviceIdFuture;

  @override
  Future<String> deviceId() {
    final active = _deviceIdFuture;
    if (active != null) return active;
    final created = _loadOrCreateDeviceId();
    _deviceIdFuture = created;
    unawaited(
      created.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // A failed mint must not poison later calls — the next one
          // re-reads the store and retries.
          if (identical(_deviceIdFuture, created)) _deviceIdFuture = null;
        },
      ),
    );
    return created;
  }

  String? _cachedDeviceId;

  /// The minted id once [deviceId] has resolved — the synchronous
  /// binding `FileBookmarkStore.syncDeviceId` needs (a tuple write
  /// cannot await). Null until enrollment or a backup-service load
  /// forces the first resolution; installs that never enroll keep the
  /// §3.4 clean-disk shape.
  String? get cachedDeviceId => _cachedDeviceId;

  Future<String> _loadOrCreateDeviceId() async {
    final existing = await _store.get<String>(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return _cachedDeviceId = existing;
    }
    final minted = uuidV4();
    await _store.set(_deviceIdKey, minted);
    return _cachedDeviceId = minted;
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

  /// Notice mutations are serialized per instance: a read-modify-write
  /// racing another update could otherwise lose one of them.
  Future<void> _noticeTail = Future.value();

  @override
  Future<void> setNotice(String notice, bool active) {
    final operation = _noticeTail.then((_) async {
      final next = await notices();
      if (active ? !next.add(notice) : !next.remove(notice)) {
        return; // Already in the target state — no durable write needed.
      }
      // Sorted so the persisted form is stable across sessions.
      await _store.set(_noticesKey, next.toList()..sort());
    });
    // Heal the chain so one failed write cannot wedge later updates.
    _noticeTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  @override
  Future<SyncAccount?> account() async {
    final raw = await _store.get<Map>(_accountKey);
    if (raw == null) return null;
    final baseUrl = raw['baseUrl'];
    final username = raw['username'];
    final mode = raw['mode'];
    // A partially-written or newer-schema entry reads as "not enrolled"
    // rather than crashing the round driver — including an unrecognized
    // mode name, which must NOT silently degrade to `separate` (the
    // self-healing path is re-login, which rewrites the entry under the
    // current schema).
    if (baseUrl is! String || username is! String || mode is! String) {
      return null;
    }
    final parsedMode = SyncAccountMode.values.asNameMap()[mode];
    if (parsedMode == null) return null;
    return SyncAccount(
      baseUrl: baseUrl,
      username: username,
      mode: parsedMode,
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
