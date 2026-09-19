/// 04 §4.1/§4.5 — Design B enrollment: register/login against the Séance
/// sync server API surface, the KDF-downgrade refusal, trial-decrypt before
/// persisting, and the credential/state seams the app fills with the OS
/// keystore and settings. No Séance dependency beyond the pinned protocol
/// types — this works against any deployment of the server binary.
library;

import 'dart:convert';

import 'package:seance_core/seance_core.dart';

import 'persistent_record_store.dart';
import 'record_crypto.dart';

/// 04 §4.3's verbatim copy for 403 `registration_closed` on a Design B
/// register — the UI renders this string (ARB-mirrored when the settings
/// slice lands).
const String syncRegistrationClosedMessage =
    'This server has registration closed. If you run it: temporarily set '
    'SEANCE_OPEN_REGISTRATION=1, create the account, then close it again — '
    'while it is open, anyone who can reach the server can register, so '
    'close it as soon as you are done. If someone else runs it, ask them to '
    'create an account for you.';

/// 04 §4.5's decrypt-failure three-cause copy: wrong passphrase, corrupt
/// record, or newer schema — never a definitive wrong-passphrase verdict
/// (a record that decrypts proves the passphrase that sealed it, so the
/// verdict is reserved for the §4.2 decode-failure tripwire, which cannot
/// blame the passphrase).
const String syncPassphraseCheckFailedMessage =
    'The encryption passphrase could not decrypt this account\'s records. '
    'The passphrase may be wrong, the record may be corrupt, or it may use '
    'a newer schema.';

/// The durable "backup paused" status while `passphraseUnverified` holds
/// (04 §4.5) — the visible Settings → Backup state, never a silent stall.
const String syncBackupPausedMessage =
    'Backup paused until the passphrase is verified against the account\'s '
    'existing data.';

/// Mode-matched way-out copy for the paused status (04 §4.5): the account
/// needs a foreign record to verify against, and these say how to make one.
const String syncBackupPausedWayOutShared =
    'Open Séance on any device signed into this account and add or edit a '
    'server, then sync — backup resumes automatically.';
const String syncBackupPausedWayOutSeparate =
    'Open Poltergeist on another device signed into this account and add or '
    'edit a bookmark, then sync.';

/// Notice keys for [SyncEnrollmentState.setNotice] — stable identifiers the
/// settings surface maps to §4.3/§4.5/§7.3 copy. A notice clears only when
/// its condition provably resolves, never on dismissal.
const String syncNoticePassphraseCheckFailed = 'passphraseCheckFailed';
const String syncNoticeAccountAuthFailed = 'accountAuthFailed';

/// Which account posture the enrollment produced (04 §4): Design B is the
/// default; Design A lands behind the PR-S1 release gate.
enum SyncAccountMode { separate, shared }

/// The enrolled account facts — durable in app settings so a later round
/// driver finds the server and username without re-enrolling.
final class SyncAccount {
  const SyncAccount({
    required this.baseUrl,
    required this.username,
    required this.mode,
  });

  final String baseUrl;
  final String username;
  final SyncAccountMode mode;
}

/// The enrollment-time account endpoints (04 §4.5). Séance's
/// `HttpSyncClient` satisfies this shape; tests fake it. Extends [SyncApi]
/// so the enrollment's full pull and the coordinator's rounds share the
/// one transport seam.
abstract interface class SyncEnrollmentApi implements SyncApi {
  /// POST /v1/register — sets [token] on success.
  Future<void> register(RegisterRequest request);

  /// POST /v1/prelogin — the account's KDF salt/params; unauthenticated.
  Future<PreloginResponse> prelogin(String username);

  /// POST /v1/login — sets [token] on success.
  Future<void> login(LoginRequest request);

  /// The session bearer token the last register/login produced.
  String? get token;
}

/// The OS-keystore seam (04 §4.5): the ONLY place the bearer token and the
/// passphrase-derived vault key may persist — `poltergeist.apikey.sync.token`
/// and `poltergeist.vault.masterKey.v1` on the app side, over
/// flutter_secure_storage. Never a plain file.
abstract interface class SyncCredentialStore {
  /// Store the session bearer token. Throws when the keystore is down —
  /// enrollment must fail loudly rather than silently drop the session.
  Future<void> writeToken(String token);

  /// The stored token, or null when absent or the keystore is unavailable.
  Future<String?> readToken();

  /// Forget the token locally (sign-out; the server keeps it).
  Future<void> deleteToken();

  /// Replace the vault master key — the enrollment re-key to the
  /// passphrase-derived key (Séance's `_rekeyVault` keystore half; the
  /// caller re-keys the live vault with [EnrollmentResult.vaultKey]).
  Future<void> writeVaultKey(List<int> vaultKey);
}

/// Durable enrollment state in app settings — never the §3.1 record store:
/// its corruption quarantine restarts empty and must not erase the hold.
abstract interface class SyncEnrollmentState {
  /// This install's LWW-authorship id — minted (uuidV4) and persisted on
  /// first call, then stable forever (04 §3.1: never regenerate casually).
  Future<String> deviceId();

  /// 04 §4.5's push-hold flag: while set, the round loop holds all pushes
  /// and a deferred foreign-record check is the only way out besides
  /// re-enrollment with the correct passphrase.
  Future<bool> passphraseUnverified();

  Future<void> setPassphraseUnverified(bool value);

  /// The durable Settings → Backup notices currently raised (the
  /// `syncNotice…` keys).
  Future<Set<String>> notices();

  /// Raise ([active] true) or clear a durable notice.
  Future<void> setNotice(String notice, bool active);

  /// The enrolled account, or null before first enrollment.
  Future<SyncAccount?> account();

  Future<void> setAccount(SyncAccount? account);
}

/// What one enrollment call established.
final class EnrollmentResult {
  const EnrollmentResult({
    required this.passphraseUnverified,
    required this.vaultKey,
    this.passphraseWarning,
  });

  /// 04 §4.5's flag — pushes stay held until a foreign record verifies the
  /// passphrase or re-enrollment corrects it.
  final bool passphraseUnverified;

  /// The passphrase-derived vault key — hand it to the vault re-key path
  /// and the coordinator's [RecordCrypto]; it persists only through
  /// [SyncCredentialStore.writeVaultKey], never a plain file.
  final List<int> vaultKey;

  /// Non-null only when the trial-decrypt ran and failed — the §4.5
  /// three-cause copy the UI shows. An empty account (no decryptable
  /// candidate) sets [passphraseUnverified] with a null warning.
  final String? passphraseWarning;
}

/// Base type for enrollment refusals — the UI switches on the subtype, the
/// message is the spec copy.
sealed class SyncEnrollmentException implements Exception {
  const SyncEnrollmentException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 04 §4.5's KDF-downgrade refusal: prelogin returned Argon2 parameters
/// weaker than [Argon2Params.minimum]. Never derive, never enroll — a
/// malicious/compromised server could otherwise force cheap brute-force
/// parameters.
final class KdfDowngradeException extends SyncEnrollmentException {
  KdfDowngradeException(this.offered)
      : super('The sync server returned weaker password-hashing parameters '
            'than Poltergeist accepts — refusing to derive your key '
            '(possible downgrade attack).');

  /// The below-minimum parameters the server offered.
  final Argon2Params offered;
}

/// 403 `registration_closed` (04 §4.3) — the message is the verbatim copy.
final class RegistrationClosedException extends SyncEnrollmentException {
  const RegistrationClosedException() : super(syncRegistrationClosedMessage);
}

/// The Design B enrollment driver (04 §4.1/§4.5). Owns no transport: the
/// [SyncEnrollmentApi] seam comes per call like [BookmarkCoordinator]'s.
final class SyncEnrollment {
  const SyncEnrollment({
    required SyncCredentialStore credentials,
    required SyncEnrollmentState state,
    required SyncRecordStore records,
  })  : // Collaborator names stay public; the fields stay private.
        // ignore: prefer_initializing_formals
        _credentials = credentials,
        // ignore: prefer_initializing_formals
        _state = state,
        // ignore: prefer_initializing_formals
        _records = records;

  final SyncCredentialStore _credentials;
  final SyncEnrollmentState _state;
  final SyncRecordStore _records;

  /// Register a fresh separate-mode account (04 §4.1): mint a 16-byte salt,
  /// derive both keys, POST /v1/register, then persist. A fresh
  /// registration never sets the unverified flag — the passphrase is
  /// minted here, so there is nothing to verify against.
  Future<EnrollmentResult> registerSeparate({
    required SyncEnrollmentApi api,
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) async {
    final salt = secureRandomBytes(16);
    const params = Argon2Params();
    final keys = await _deriveSyncKeys(
      password: password,
      encryptionPassphrase: encryptionPassphrase,
      salt: salt,
      params: params,
    );
    try {
      await api.register(RegisterRequest(
        username: username,
        authVerifier: base64.encode(keys.authVerifier),
        argonSalt: base64.encode(salt),
        argonParams: params,
      ));
    } on ApiError catch (error) {
      if (error.code == 'registration_closed') {
        throw const RegistrationClosedException();
      }
      rethrow;
    }
    await _persist(
      api: api,
      baseUrl: baseUrl,
      username: username,
      mode: SyncAccountMode.separate,
      vaultKey: keys.vaultKey,
    );
    await _state.setPassphraseUnverified(false);
    return EnrollmentResult(passphraseUnverified: false, vaultKey: keys.vaultKey);
  }

  /// Enrol against an existing account (04 §4.5, mirroring Séance's
  /// `loginSync`): prelogin → refuse any KDF downgrade → derive both keys →
  /// login → a **full** pull (`since = 0`, always — a retained highWaterSeq
  /// must never produce an empty pull that skips the check) → trial-decrypt
  /// the first non-tombstone record on a decryptable id → persist with the
  /// hold flag reflecting the outcome. An immediate trial failure warns
  /// with the three-cause copy and proceeds held, never aborts.
  Future<EnrollmentResult> login({
    required SyncEnrollmentApi api,
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
    required SyncAccountMode mode,
  }) async {
    final pre = await api.prelogin(username);
    if (!pre.argonParams.meetsMinimum(Argon2Params.minimum)) {
      throw KdfDowngradeException(pre.argonParams);
    }
    final keys = await _deriveSyncKeys(
      password: password,
      encryptionPassphrase: encryptionPassphrase,
      salt: base64.decode(pre.argonSalt),
      params: pre.argonParams,
    );
    await api.login(LoginRequest(
      username: username,
      authVerifier: base64.encode(keys.authVerifier),
    ));

    final response = await api.pull(since: 0);
    // The trial-decrypt: the FIRST non-tombstone record on a decryptable
    // id decides — kind-agnostic across prefixless/bookmark:/hostkey:,
    // never secret:/snippet:/unrecognized (§3.2's never-decrypt dispatch
    // binds enrollment too). Auth success cannot prove the E2E passphrase.
    var unverified = true;
    String? warning;
    final crypto = RecordCrypto(RecordCodec(keys.vaultKey));
    for (final record in response.records) {
      if (record.deleted || record.blob.isEmpty) continue;
      if (!isDecryptableSyncId(record.id)) continue;
      try {
        await crypto.open(record);
        unverified = false;
      } catch (_) {
        warning = syncPassphraseCheckFailedMessage;
      }
      break;
    }

    // Only now persist: the pulled ciphertext merges into the §3.1 store
    // (skip-preserved records re-apply once the passphrase is corrected),
    // then the token, vault key, device id, account, and flag.
    var snapshot = await _records.highWaterSeq();
    for (final record in response.records) {
      final seq = record.seq;
      if (seq != null && seq > snapshot) snapshot = seq;
      await _records.putRemote(record);
    }
    await _records.setHighWaterSeq(snapshot);
    await _persist(
      api: api,
      baseUrl: baseUrl,
      username: username,
      mode: mode,
      vaultKey: keys.vaultKey,
    );
    await _state.setPassphraseUnverified(unverified);
    if (!unverified) {
      await _state.setNotice(syncNoticePassphraseCheckFailed, false);
    }
    return EnrollmentResult(
      passphraseUnverified: unverified,
      vaultKey: keys.vaultKey,
      passphraseWarning: warning,
    );
  }

  /// Séance's `_deriveSyncKeys`: the password derives the auth verifier,
  /// the encryption passphrase derives the vault key — and an account whose
  /// two are the same string runs Argon2 once, preserving the keys existing
  /// single-passphrase accounts already have.
  static Future<({List<int> authVerifier, List<int> vaultKey})>
      _deriveSyncKeys({
    required String password,
    required String encryptionPassphrase,
    required List<int> salt,
    required Argon2Params params,
  }) async {
    final authKeys = await VaultCrypto.deriveKeys(
      passphrase: password,
      salt: salt,
      params: params,
    );
    if (password == encryptionPassphrase) {
      return (
        authVerifier: authKeys.authVerifier,
        vaultKey: authKeys.vaultKey,
      );
    }
    final encryptionKeys = await VaultCrypto.deriveKeys(
      passphrase: encryptionPassphrase,
      salt: salt,
      params: params,
    );
    return (
      authVerifier: authKeys.authVerifier,
      vaultKey: encryptionKeys.vaultKey,
    );
  }

  /// The §4.5 "Then:" tail: bearer token to the keystore, vault master key
  /// to the keystore, device id minted if absent, account facts recorded.
  /// A keystore failure throws — a half-persisted enrollment is worse than
  /// a loud refusal.
  Future<void> _persist({
    required SyncEnrollmentApi api,
    required String baseUrl,
    required String username,
    required SyncAccountMode mode,
    required List<int> vaultKey,
  }) async {
    final token = api.token;
    if (token == null) {
      throw StateError('enrollment succeeded without a session token');
    }
    await _credentials.writeToken(token);
    await _credentials.writeVaultKey(vaultKey);
    await _state.deviceId();
    await _state.setAccount(
        SyncAccount(baseUrl: baseUrl, username: username, mode: mode));
    await _state.setNotice(syncNoticeAccountAuthFailed, false);
  }
}
