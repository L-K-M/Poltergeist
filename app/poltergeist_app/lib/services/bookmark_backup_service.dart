// 04 §3.3's `BookmarkBackupService`: the app-side owner of the Settings →
// Backup surface's lifecycle — enrollment over the #166 seams, the manual
// round behind "Back up now", the durable status and notice set, §4.1's
// typed-confirmation account deletion (separate mode only — §4.2 hides
// deletion in shared mode), and the §4.4 B→A switch driver.
//
// Scheduling (startup, 2 s debounce, 5 min periodic, queued flag) is a
// later slice: this lands the service, the status surface, and the manual
// round the enrolled state drives.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'settings_store.dart';
import 'sync_credentials.dart' show RetainedSyncTokenStore;
import 'sync_transport.dart';

/// The separate account's facts kept for §4.4's optional post-switch
/// delete — the retained token alone cannot reach it.
final class RetainedBackupAccount {
  const RetainedBackupAccount({required this.baseUrl, required this.username});

  final String baseUrl;
  final String username;
}

/// What one §4.4 B→A switch produced. The [held] locators are the
/// enrollment-pull quarantine — each needs an explicit adopt-fleet /
/// keep-local decision before the switch completes (never a click-through
/// non-error, per the §4.4 hold rule).
final class BackupSwitchOutcome {
  const BackupSwitchOutcome({
    required this.held,
    required this.passphraseUnverified,
    this.passphraseWarning,
  });

  /// Hosts whose enrollment pull quarantined a conflicting shared-account
  /// `hostkey:` record — the switch holds their pin re-seal until the user
  /// resolves each one.
  final List<HostKeyConflict> held;

  /// 04 §4.5's push-hold flag as the shared login left it.
  final bool passphraseUnverified;

  /// The §4.5 three-cause warning, when the trial-decrypt ran and failed.
  final String? passphraseWarning;
}

/// The enrolled-state facade the Settings → Backup section renders and the
/// round driver behind "Back up now". All durable state lives in the seams
/// (#166's `SyncEnrollmentState`/`SyncCredentialStore`, the §3.2 verdict
/// stores, the retained-token slot, and a handful of status keys in
/// settings) — this class holds no truth of its own.
final class BookmarkBackupService extends ChangeNotifier {
  BookmarkBackupService({
    required SyncCredentialStore credentials,
    required RetainedSyncTokenStore retainedTokens,
    required SyncEnrollmentState enrollmentState,
    required SyncRecordStore records,
    required Future<SyncRecordStore> Function() resetRecords,
    required SyncTrackingBookmarkStore bookmarks,
    required HostKeyStore hostKeys,
    required PinVerdictStore pinVerdicts,
    required SyncTripwireStore tripwires,
    required SyncTransportFactory transportFactory,
    required Future<List<int>?> Function() vaultKey,
    required SyncTrackingServerStore servers,
    required VaultStore vaultStore,
    SettingsStore? settings,
    String? Function()? recordQuarantinePath,
    DateTime Function()? now,
  })  : // Collaborator names stay public; the fields stay private.
        // ignore: prefer_initializing_formals
        _credentials = credentials,
        // ignore: prefer_initializing_formals
        _retainedTokens = retainedTokens,
        // ignore: prefer_initializing_formals
        _enrollmentState = enrollmentState,
        // ignore: prefer_initializing_formals
        _records = records,
        // ignore: prefer_initializing_formals
        _resetRecords = resetRecords,
        // ignore: prefer_initializing_formals
        _bookmarks = bookmarks,
        // ignore: prefer_initializing_formals
        _hostKeys = hostKeys,
        // ignore: prefer_initializing_formals
        _pinVerdicts = pinVerdicts,
        // ignore: prefer_initializing_formals
        _tripwires = tripwires,
        // ignore: prefer_initializing_formals
        _transportFactory = transportFactory,
        // ignore: prefer_initializing_formals
        _vaultKey = vaultKey,
        // ignore: prefer_initializing_formals
        _servers = servers,
        // ignore: prefer_initializing_formals
        _vaultStore = vaultStore,
        // ignore: prefer_initializing_formals
        _settings = settings,
        // ignore: prefer_initializing_formals
        _recordQuarantinePath = recordQuarantinePath,
        _now = now ?? DateTime.now;

  final SyncCredentialStore _credentials;
  final RetainedSyncTokenStore _retainedTokens;
  final SyncEnrollmentState _enrollmentState;
  SyncRecordStore _records;
  final Future<SyncRecordStore> Function() _resetRecords;
  final SyncTrackingBookmarkStore _bookmarks;
  final HostKeyStore _hostKeys;
  final PinVerdictStore _pinVerdicts;
  final SyncTripwireStore _tripwires;
  final SyncTransportFactory _transportFactory;
  final Future<List<int>?> Function() _vaultKey;

  /// The shared-mode `serverConfig` domain store (04 §4.2, amended): the
  /// coordinator materializes pulled servers into it and seals local
  /// edits out of it. Persisted in `servers.json` beside bookmarks.json.
  final SyncTrackingServerStore _servers;

  /// The vault's blob store — paired with the resolved key in
  /// [_rebuildCoordinator] to make the [SecretVault] the coordinator and
  /// the editor write through.
  final VaultStore _vaultStore;
  final SettingsStore? _settings;
  final String? Function()? _recordQuarantinePath;
  final DateTime Function() _now;

  static const _lastSyncAtKey = 'poltergeist.sync.lastSyncAt';
  static const _lastSyncErrorKey = 'poltergeist.sync.lastSyncError';
  static const _retainedAccountKey = 'poltergeist.sync.retainedAccount';
  static const _switchSyncedKey = 'poltergeist.sync.switchSynced';

  SyncAccount? _account;
  Set<String> _notices = const {};
  bool _passphraseUnverified = false;
  List<HostKeyConflict> _pinConflicts = const [];
  Set<String> _trippedIds = const {};
  String? _quarantinedPath;
  RetainedBackupAccount? _retainedAccount;
  bool _retainedTokenAvailable = false;
  bool _sharedSyncSucceeded = false;

  bool _syncing = false;
  DateTime? _lastSyncAt;
  String? _lastSyncError;

  BookmarkCoordinator? _coordinator;
  RecordCrypto? _crypto;

  /// The shared-mode credential vault the coordinator and the server
  /// editor write through — rebuilt on every coordinator rebind so it
  /// always holds the current account key. Null outside shared mode or
  /// while the keystore is unavailable.
  SecretVault? _secretVault;

  /// The shared-mode vault, for the server editor's credential fields.
  SecretVault? get secretVault => _secretVault;

  /// The enrolled account, or null before first enrollment.
  SyncAccount? get account => _account;

  /// The durable `syncNotice…` keys currently raised.
  Set<String> get notices => _notices;

  /// 04 §4.5's push hold — the paused status shows while set.
  bool get passphraseUnverified => _passphraseUnverified;

  /// The §3.2 host-key quarantine, re-derived by the coordinator.
  List<HostKeyConflict> get pinConflicts => _pinConflicts;

  /// The §4.2 decode tripwire's record ids.
  Set<String> get trippedIds => _trippedIds;

  /// The §3.1 corrupt-store quarantine path, when the record store
  /// quarantined a corrupt file during load.
  String? get quarantinedPath => _quarantinedPath;

  /// A round is running.
  bool get syncing => _syncing;

  /// Last completed round's wall time (persisted across restarts).
  DateTime? get lastSyncAt => _lastSyncAt;

  /// Last round's failure description (persisted; cleared on success).
  String? get lastSyncError => _lastSyncError;

  /// The separate account kept for §4.4's optional delete, when a B→A
  /// switch left one behind.
  RetainedBackupAccount? get retainedAccount => _retainedAccount;

  /// The §4.4 delete offer's gate: a retained account exists with its
  /// token AND the first shared-account sync has succeeded — a failed
  /// switch can never destroy the only backup.
  bool get deleteSeparateOffered =>
      _retainedAccount != null &&
      _retainedTokenAvailable &&
      _sharedSyncSucceeded;

  /// The Séance server catalog materialized in shared mode (read-only).
  SeanceServerCatalog? _catalog;

  /// Shared mode's catalog, for the surfaces §4.2 unlocks.
  SeanceServerCatalog? get catalog => _catalog;

  /// Load all durable state and build the coordinator when the vault key
  /// is readable. Called once at composition and again on refresh needs.
  Future<void> load() async {
    await _rebuildCoordinator();
    // Repopulate the catalog from the server store before the first
    // round runs — locally saved servers persist across restarts.
    await _coordinator?.rebuildCatalog();
    await refresh();
  }

  /// Re-read every durable input and re-notify. Cheap: the reads are the
  /// seams' own caches plus one settings decode.
  Future<void> refresh() async {
    _account = await _enrollmentState.account();
    _notices = await _enrollmentState.notices();
    _passphraseUnverified = await _enrollmentState.passphraseUnverified();
    _trippedIds = await _tripwires.trippedIds();
    final coordinator = _coordinator;
    _pinConflicts =
        coordinator == null ? const [] : await coordinator.pinConflicts();
    _quarantinedPath = _recordQuarantinePath?.call();
    _retainedAccount = await _loadRetainedAccount();
    _retainedTokenAvailable = await _retainedTokens.read() != null;
    _sharedSyncSucceeded =
        await _settings?.get<bool>(_switchSyncedKey) ?? false;
    final atMs = await _settings?.get<int>(_lastSyncAtKey);
    _lastSyncAt = atMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(atMs, isUtc: true);
    _lastSyncError = await _settings?.get<String>(_lastSyncErrorKey);
    notifyListeners();
  }

  /// Shared-mode server writes (04 §4.2, amended): the catalog's row
  /// verbs and the server editor route through these, never the store
  /// directly — the coordinator persists the row AND seals its record
  /// dirty for the next round in one call. A no-op outside shared mode.
  Future<void> saveServer(ServerConfig server) async {
    await _coordinator?.onServerSaved(server);
  }

  /// Delete a shared-mode server: drops the row and seals the tombstone
  /// that propagates the delete to the fleet (and retracts the orphaned
  /// credential's record).
  Future<void> deleteServer(ServerConfig server) async {
    await _coordinator?.onServerDeleted(server);
  }

  /// Save a credential the server editor entered: writes the vault with
  /// its own advancing stamp, then publishes the `secret:` record while
  /// a synced server opts it in. Throws when the vault has no key.
  Future<void> saveServerSecret(Secret secret) async {
    final vault = _secretVault;
    if (vault == null) {
      throw StateError('the vault is unavailable — cannot save secrets');
    }
    await vault.putLocalSecret(secret,
        updatedAt: _now().toUtc().millisecondsSinceEpoch);
    await _coordinator?.onServerSecretSaved(secret.id);
  }

  /// The credential a `secretRef` names, for the editor's fields — null
  /// when absent or the vault is locked.
  Future<Secret?> serverSecretById(String id) async {
    final vault = _secretVault;
    if (vault == null) return null;
    try {
      return await vault.getSecret(id);
    } catch (_) {
      return null;
    }
  }

  /// The coordinator re-binds whenever the account, vault key, or record
  /// store changed — each enrollment and the §4.4 wipe produce a new one.
  /// A missing vault key (keystore down) leaves it null: the enrolled
  /// state still renders and rounds fail honestly rather than sealing
  /// under a fabricated key.
  Future<void> _rebuildCoordinator() async {
    final account = await _enrollmentState.account();
    final key = account == null ? null : await _vaultKey();
    if (account == null || key == null) {
      _coordinator = null;
      _crypto = null;
      _catalog = null;
      _secretVault = null;
      return;
    }
    final crypto = RecordCrypto(RecordCodec(key));
    _crypto = crypto;
    final shared = account.mode == SyncAccountMode.shared;
    _catalog = shared ? SeanceServerCatalog() : null;
    _secretVault = shared ? SecretVault(_vaultStore, key) : null;
    _coordinator = BookmarkCoordinator(
      records: _records,
      bookmarks: _bookmarks,
      hostKeys: _hostKeys,
      crypto: crypto,
      deviceId: await _enrollmentState.deviceId(),
      pinVerdicts: _pinVerdicts,
      tripwires: _tripwires,
      catalog: _catalog,
      servers: shared ? _servers : null,
      secrets: _secretVault,
      enrollment: _enrollmentState,
      now: _now,
    );
  }

  SyncEnrollment _enrollment() => SyncEnrollment(
        credentials: _credentials,
        state: _enrollmentState,
        records: _records,
      );

  /// A durable-state mutation must never overlap an in-flight round: the
  /// round's writes and status bookkeeping belong to the account it
  /// started under, and enrollment swaps the seams beneath it.
  void _requireNotSyncing() {
    if (_syncing) {
      throw StateError('a backup round is in flight');
    }
  }

  /// §4.1's separate-account registration: salt → derive → register →
  /// persist, then materialize the (empty) pull so the enrolled state is
  /// immediately consistent.
  Future<EnrollmentResult> registerSeparate({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) async {
    _requireNotSyncing();
    final api = _transportFactory(baseUrl);
    try {
      final result = await _enrollment().registerSeparate(
        api: api,
        baseUrl: baseUrl,
        username: username,
        password: password,
        encryptionPassphrase: encryptionPassphrase,
      );
      await _afterEnrollment();
      return result;
    } finally {
      api.close();
    }
  }

  /// §4.5's login path for both modes: prelogin → KDF-downgrade refusal →
  /// derive → login → full pull → trial-decrypt → persist with the hold
  /// flag reflecting the outcome.
  Future<EnrollmentResult> loginAccount({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
    required SyncAccountMode mode,
  }) async {
    _requireNotSyncing();
    final api = _transportFactory(baseUrl);
    try {
      final result = await _enrollment().login(
        api: api,
        baseUrl: baseUrl,
        username: username,
        password: password,
        encryptionPassphrase: encryptionPassphrase,
        mode: mode,
      );
      await _afterEnrollment();
      return result;
    } finally {
      api.close();
    }
  }

  /// Enrollment's full pull already merged ciphertext; materialize it so
  /// pin conflicts and the tripwire surface at enrollment time, then
  /// refresh the rendered state.
  Future<void> _afterEnrollment() async {
    await _rebuildCoordinator();
    await _coordinator?.applyPulled();
    await refresh();
  }

  /// §3.3's manual round: delta pull, push the dirty set (held while
  /// `passphraseUnverified` stands), materialize, and record the status
  /// the enrolled surface reads. A 401 leaves the durable dead-account
  /// notice raised by the coordinator.
  Future<SyncRoundResult?> backUpNow() async {
    final account = _account;
    final coordinator = _coordinator;
    if (_syncing || account == null || coordinator == null) return null;
    _syncing = true;
    try {
      // Inside the try: a throwing listener must not strand _syncing.
      notifyListeners();
      final token = await _credentials.readToken();
      if (token == null) {
        throw StateError('enrolled without a session token');
      }
      final api = _transportFactory(account.baseUrl, token: token);
      try {
        final result = await coordinator.runRound(api);
        _lastSyncAt = _now().toUtc();
        _lastSyncError = null;
        await _persistStatus();
        if (account.mode == SyncAccountMode.shared && !result.authFailed) {
          // §4.4: the optional delete offer unlocks only after the first
          // shared sync succeeds — never while the switch is unproven.
          _sharedSyncSucceeded = true;
          await _settings?.set(_switchSyncedKey, true);
        }
        await refresh();
        return result;
      } finally {
        api.close();
      }
    } catch (error) {
      _lastSyncError = '$error';
      await _persistStatus();
      await refresh();
      rethrow;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _persistStatus() async {
    await _settings?.setAll({
      _lastSyncAtKey: _lastSyncAt?.millisecondsSinceEpoch,
      _lastSyncErrorKey: _lastSyncError,
    });
  }

  /// §4.2's "Sign out on this device": forgets the local token and keys;
  /// server data untouched. The last-round status goes with it — a later
  /// enrollment must not inherit the old account's sync bookkeeping.
  Future<void> signOut() async {
    _requireNotSyncing();
    await _credentials.deleteToken();
    await _enrollmentState.setAccount(null);
    _coordinator = null;
    _crypto = null;
    _catalog = null;
    _secretVault = null;
    _lastSyncAt = null;
    _lastSyncError = null;
    await _persistStatus();
    await refresh();
  }

  /// §4.1's "Delete backup account…" — separate mode only (§4.2 never
  /// exposes deletion on a shared account), guarded by typed confirmation
  /// of the account name. Deletes only Poltergeist's data, then forgets
  /// the session locally.
  Future<void> deleteSeparateAccount({required String confirmedName}) async {
    _requireNotSyncing();
    final account = _account;
    if (account == null || account.mode != SyncAccountMode.separate) {
      throw StateError('account deletion exists only in separate mode');
    }
    if (confirmedName.trim() != account.username) {
      throw ArgumentError('typed confirmation must equal the account name');
    }
    final token = await _credentials.readToken();
    if (token == null) {
      throw StateError('enrolled without a session token');
    }
    final api = _transportFactory(account.baseUrl, token: token);
    try {
      await api.deleteAccount();
    } finally {
      api.close();
    }
    await signOut();
  }

  /// 04 §4.4's B→A switch, step for step:
  /// retain the separate token in its own keystore slot → local sign-out
  /// (token kept) → wipe + re-create the §3.1 record store and reset
  /// `highWaterSeq` (undecryptable-key residue and the hostkey: LWW-shadow
  /// hazard the spec names) → shared login (the §4.5 full pull, since=0)
  /// → applyPulled so a conflicting shared `hostkey:` record quarantines
  /// at enrollment time through §3.2's normal path → mark every local
  /// bookmark dirty under its existing `bookmark:<uuid>` id → re-seal
  /// every local TOFU pin under a fresh LWW tuple on this deviceId —
  /// EXCEPT the quarantine's held locators, whose re-seal waits on the
  /// user's adopt-fleet / keep-local decision.
  Future<BackupSwitchOutcome> switchToShared({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) async {
    final account = _account;
    if (account == null || account.mode != SyncAccountMode.separate) {
      throw StateError('the switch requires a separate-mode account');
    }
    _requireNotSyncing();
    _syncing = true;
    try {
      // Inside the try: a throwing listener must not strand _syncing.
      notifyListeners();
      // 1. Retain the separate account's token BEFORE the enrollment write
      //    could overwrite it (04 §4.4: it lives in the keystore, not the
      //    §3.1 store the wipe clears; server-side tokens never expire, so
      //    the optional delete can wait until the switch is proven).
      final retained = await _credentials.readToken();
      if (retained != null) {
        await _retainedTokens.write(retained);
        await _settings?.set(_retainedAccountKey, {
          'baseUrl': account.baseUrl,
          'username': account.username,
        });
        // The delete offer re-arms only after a shared sync succeeds.
        _sharedSyncSucceeded = false;
        await _settings?.set(_switchSyncedKey, false);
      }
      // 2. Local sign-out only — the separate account stays on the server.
      await _credentials.deleteToken();
      // 3. Wipe and re-create the record store; a fresh instance resets
      //    highWaterSeq with it. The pre-wipe store stays alive in the
      //    coordinator — restore it if the switch dies before the shared
      //    account persists, so the separate enrollment keeps working.
      final previous = _records;
      _records = await _resetRecords();
      // 4. Log into the Séance account (§4.5 — full pull merges into the
      //    fresh store before any persist).
      final api = _transportFactory(baseUrl);
      try {
        final result = await _enrollment().login(
          api: api,
          baseUrl: baseUrl,
          username: username,
          password: password,
          encryptionPassphrase: encryptionPassphrase,
          mode: SyncAccountMode.shared,
        );
        // 5. Rebind the coordinator over the fresh store, new key, and the
        //    shared-mode catalog.
        await _rebuildCoordinator();
        final coordinator = _coordinator;
        final crypto = _crypto;
        if (coordinator == null || crypto == null) {
          throw StateError('enrolled without a readable vault key');
        }
        // 6. Materialize the enrollment pull first — a conflicting shared
        //    hostkey: record quarantines at enrollment time through §3.2's
        //    normal path, BEFORE the re-seal push could win it.
        await coordinator.applyPulled();
        // 7. Mark every local bookmark dirty under its existing
        //    bookmark:<uuid> id — no re-derivation, no namespacing.
        for (final bookmark in await _bookmarks.load()) {
          await coordinator.onBookmarkSaved(bookmark);
        }
        // 8. The hold set is recomputed from the pull, never snapshotted.
        final held = await coordinator.pinConflicts();
        final heldLocators =
            {for (final conflict in held) conflict.locator};
        // 9. Re-seal every non-held local pin under a fresh LWW tuple on
        //    this deviceId so hosts verified in separate mode reach the
        //    shared fleet.
        final deviceId = await _enrollmentState.deviceId();
        for (final pin in await _hostKeys.all()) {
          if (heldLocators.contains(pin.locator)) continue;
          await _records.putLocal(await crypto.seal(DecryptedRecord(
            id: pin.recordId,
            kind: RecordKind.hostKey,
            updatedAt: _now().toUtc().millisecondsSinceEpoch,
            deviceId: deviceId,
            data: pin.toJson(),
          )));
        }
        await refresh();
        return BackupSwitchOutcome(
          held: held,
          passphraseUnverified: result.passphraseUnverified,
          passphraseWarning: result.passphraseWarning,
        );
      } catch (_) {
        // A login that never persisted leaves the separate account live:
        // hand back its store and its session so the switch's preserve
        // step did its job — the old account keeps working untouched.
        // A persisted shared account instead needs a CONSISTENT shared
        // state: rebind the coordinator over the new store and key so the
        // service never pairs the shared token with the wiped store's
        // stale separate-mode coordinator. Either way, re-sync the
        // rendered state from durable truth.
        final persisted = await _enrollmentState.account();
        if (persisted?.mode == SyncAccountMode.shared) {
          await _rebuildCoordinator();
        } else {
          _records = previous;
          if (retained != null) {
            await _credentials.writeToken(retained);
          }
          await _rebuildCoordinator();
        }
        await refresh();
        rethrow;
      } finally {
        api.close();
      }
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// Resolve one quarantined pin — a §4.4 held locator or an ordinary
  /// §3.2 conflict the enrolled surface warned about: adopt the pulled
  /// pin (install it, no re-seal) or keep the local pin (re-seal and
  /// push — a deliberate override).
  Future<void> resolvePinConflict(
    HostKeyConflict conflict, {
    required bool keepLocal,
  }) async {
    final coordinator = _coordinator;
    if (coordinator == null) {
      throw StateError('not enrolled — cannot resolve a pin conflict');
    }
    if (keepLocal) {
      await coordinator.keepLocalPin(
          conflict.local.host, conflict.local.port);
    } else {
      await coordinator.acceptPulledPin(
          conflict.pulled.host, conflict.pulled.port);
    }
    await refresh();
  }

  /// The §4.4 optional step after a proven switch: DELETE /v1/account on
  /// the separate account using the retained token, guarded by typed
  /// confirmation of that account's name.
  Future<void> deleteRetainedSeparateAccount({
    required String confirmedName,
  }) async {
    _requireNotSyncing();
    final retained = _retainedAccount;
    if (retained == null) {
      throw StateError('no retained separate account');
    }
    if (confirmedName.trim() != retained.username) {
      throw ArgumentError('typed confirmation must equal the account name');
    }
    final token = await _retainedTokens.read();
    if (token == null) {
      throw StateError('retained account without a retained token');
    }
    final api = _transportFactory(retained.baseUrl, token: token);
    try {
      await api.deleteAccount();
    } finally {
      api.close();
    }
    await _forgetRetainedAccount();
    await refresh();
  }

  /// Declining the §4.4 delete leaves the old account untouched —
  /// Poltergeist never auto-deletes it, and dropping the retained token
  /// here is what makes "removing it later requires re-enrolling into it
  /// first" literally true.
  Future<void> declineRetainedDelete() async {
    await _forgetRetainedAccount();
    await refresh();
  }

  Future<void> _forgetRetainedAccount() async {
    await _retainedTokens.clear();
    await _settings?.set(_retainedAccountKey, null);
    _retainedAccount = null;
    _retainedTokenAvailable = false;
  }

  Future<RetainedBackupAccount?> _loadRetainedAccount() async {
    final raw = await _settings?.get<Map>(_retainedAccountKey);
    if (raw == null) return null;
    final baseUrl = raw['baseUrl'];
    final username = raw['username'];
    if (baseUrl is! String || username is! String) return null;
    return RetainedBackupAccount(baseUrl: baseUrl, username: username);
  }
}
