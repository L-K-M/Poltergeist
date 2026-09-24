/// 04 §3.2 — `BookmarkCoordinator`: the thin, kind-aware bridge between the
/// §3.1 record store and the domain stores. Change-driven on the way out
/// (`onBookmarkSaved`/`onBookmarkDeleted` seal exactly the edited row),
/// delta-scanned on the way in (`applyPulled` processes only records with
/// `seq > lastAppliedSeq`), and skip-and-preserve throughout: unknown
/// prefixes are never decrypted, decrypt failures are never rewritten, and
/// decrypt-success + strict-decode-failure raises the §4.2 durable
/// tripwire. Poltergeist writes `bookmark:` and `hostkey:` records in
/// either mode, and — since the §4.2 amendment — `serverConfig` (bare
/// prefixless ids) and `secret:` records in shared mode, making the
/// Séance server list bidirectional. `snippet:` stays read-never.
library;

import 'dart:math' show min;

import 'package:seance_core/seance_core.dart';

import '../sync/enrollment.dart';
import '../sync/persistent_record_store.dart';
import '../sync/record_crypto.dart';
import '../sync/seance_server_catalog.dart';
import '../sync/server_store.dart';
import '../sync/sync_verdicts.dart';
import 'bookmark_store.dart';

/// What one dispatch did with a record — drives the apply cursor, which
/// may pass anything but a deferral.
enum _ApplyOutcome { applied, skipped, deferred }

/// A pulled `hostkey:` record whose key conflicts with the locally trusted
/// pin for the same `host:port`. Re-derived by diffing the stored
/// `hostkey:` records against the TOFU store on every `applyPulled` (04
/// §3.2 — durable because it is *re-derived*, not because it is stored),
/// so the conflict resurfaces until the user resolves it.
final class HostKeyConflict {
  const HostKeyConflict({
    required this.locator,
    required this.local,
    required this.pulled,
  });

  /// `host:port` — the [HostKey.locator] spelling.
  final String locator;

  /// The pin this device currently trusts.
  final HostKey local;

  /// The key the winning `hostkey:` record carries.
  final HostKey pulled;
}

/// What one `applyPulled` pass did — the Settings → Backup surface reads
/// [pinConflicts] for the quarantine warning and the tripwire store for
/// decode failures.
final class ApplyReport {
  /// Record ids materialized this pass (upserts and tombstone removes).
  final Set<String> appliedIds = {};

  /// Record ids seen but not applied because a pending local edit or
  /// tombstone still out-tuples them — re-evaluated when the rival's push
  /// resolves, never by cursor advancement.
  final Set<String> deferredIds = {};

  /// The host-key quarantine diff, re-derived wholesale each pass.
  final List<HostKeyConflict> pinConflicts = [];
}

/// The result of one [BookmarkCoordinator.runRound]: pull/push bookkeeping
/// plus the apply report.
final class SyncRoundResult {
  const SyncRoundResult({
    required this.pulled,
    required this.pushed,
    required this.rounds,
    required this.report,
    required this.pushesHeld,
    required this.authFailed,
  });

  final int pulled;
  final int pushed;
  final int rounds;
  final ApplyReport report;

  /// True when the round ended with 04 §4.5's push hold still engaged —
  /// dirty records stay sealed locally until the passphrase verifies.
  final bool pushesHeld;

  /// True when the server rejected the bearer token (401 `unauthorized`):
  /// the account is dead or revoked — 04 §7.3's drop-to-local-only. The
  /// durable notice is raised on the enrollment state; there is no token
  /// refresh because server-side tokens never expire.
  final bool authFailed;
}

/// See the library doc. The coordinator never owns transport: [runRound]
/// takes the [SyncApi] seam per call and tests fake it.
final class BookmarkCoordinator {
  BookmarkCoordinator({
    required SyncRecordStore records,
    required SyncTrackingBookmarkStore bookmarks,
    required HostKeyStore hostKeys,
    required RecordCrypto crypto,
    required String deviceId,
    required PinVerdictStore pinVerdicts,
    required SyncTripwireStore tripwires,
    SeanceServerCatalog? catalog,
    SyncTrackingServerStore? servers,
    SecretVault? secrets,
    SyncEnrollmentState? enrollment,
    DateTime Function()? now,
    int maxRounds = 5,
  })  : // Collaborator names stay public; the fields stay private.
        // ignore: prefer_initializing_formals
        _records = records,
        // ignore: prefer_initializing_formals
        _bookmarks = bookmarks,
        // ignore: prefer_initializing_formals
        _hostKeys = hostKeys,
        // ignore: prefer_initializing_formals
        _crypto = crypto,
        // ignore: prefer_initializing_formals
        _deviceId = deviceId,
        // ignore: prefer_initializing_formals
        _pinVerdicts = pinVerdicts,
        // ignore: prefer_initializing_formals
        _tripwires = tripwires,
        // ignore: prefer_initializing_formals
        _catalog = catalog,
        // ignore: prefer_initializing_formals
        _servers = servers,
        // ignore: prefer_initializing_formals
        _secrets = secrets,
        // ignore: prefer_initializing_formals
        _enrollment = enrollment,
        _now = now ?? DateTime.now,
        // ignore: prefer_initializing_formals
        _maxRounds = maxRounds;

  static const _kindDelimiter = ':';
  static const _bookmarkPrefix = 'bookmark:';
  static const _hostKeyPrefix = 'hostkey:';
  static const _secretPrefix = 'secret:';

  final SyncRecordStore _records;
  final SyncTrackingBookmarkStore _bookmarks;
  final HostKeyStore _hostKeys;
  final RecordCrypto _crypto;
  final String _deviceId;
  final PinVerdictStore _pinVerdicts;
  final SyncTripwireStore _tripwires;

  /// Non-null in shared mode (04 §4.2): pulled prefixless `serverConfig`
  /// records materialize here. Null in separate mode, where prefixless ids
  /// are never decrypted at all.
  final SeanceServerCatalog? _catalog;

  /// Non-null in shared mode, paired with [_catalog]: the writable
  /// materialization of `serverConfig` records — the catalog is its sorted
  /// view. Also the plaintext source a corrected-passphrase re-seal reads.
  final SyncTrackingServerStore? _servers;

  /// Non-null in shared mode when the vault has a key: pulled `secret:`
  /// records land here, and opted-in credentials publish from here.
  final SecretVault? _secrets;

  /// The durable enrollment state (04 §4.5): while `passphraseUnverified`
  /// holds, [runRound] holds all pushes and the deferred foreign-record
  /// check is the only way out besides re-enrollment. Null means never
  /// enrolled — nothing is held and no deferred check runs.
  final SyncEnrollmentState? _enrollment;

  final DateTime Function() _now;
  final int _maxRounds;

  /// A local save: seal the row under the `bookmark:` id with the row's own
  /// stamp and this install's authorship, and mark it dirty for the next
  /// push (04 §3.2 — `deviceId: deviceId`, always).
  Future<void> onBookmarkSaved(Bookmark bookmark) async {
    await _records.putLocal(await _crypto.seal(DecryptedRecord(
      id: '$_bookmarkPrefix${bookmark.id}',
      kind: RecordKind.bookmark,
      updatedAt: bookmark.updatedAt.toUtc().millisecondsSinceEpoch,
      deviceId: _deviceId,
      data: bookmark.toJson(),
    )));
  }

  /// A local delete: a real tombstone (empty blob, `deleted: true`) dated
  /// at the deletion — fixing the resurrection gap Séance's ephemeral
  /// store has. Tombstones are retained indefinitely: no GC window is safe
  /// while a long-offline device could still push the old row.
  Future<void> onBookmarkDeleted(String bookmarkId) async {
    await _records.putLocal(await _crypto.seal(DecryptedRecord(
      id: '$_bookmarkPrefix$bookmarkId',
      kind: RecordKind.bookmark,
      updatedAt: _now().toUtc().millisecondsSinceEpoch,
      deviceId: _deviceId,
      deleted: true,
    )));
  }

  /// A local server save in shared mode (04 §4.2, amended): persist the
  /// re-stamped row, then seal its prefixless `serverConfig` record dirty
  /// under that stamp and this install's authorship — the same
  /// change-driven write path [onBookmarkSaved] uses. An excluded server
  /// retracts instead: a tombstone dated at the edit drops the account
  /// copy while the local row survives (Séance's `_retract`), and the
  /// orphaned credential's record withdraws with it. A no-op in separate
  /// mode, where no server store exists.
  Future<void> onServerSaved(ServerConfig server) async {
    final store = _servers;
    if (store == null) return;
    final stored = await store.save(server);
    if (stored.excludeFromSync) {
      await _records.putLocal(await _crypto.seal(DecryptedRecord(
        id: stored.id,
        kind: RecordKind.serverConfig,
        updatedAt: stored.updatedAt,
        deviceId: _deviceId,
        deleted: true,
      )));
      await _retractOrphanedSecret(stored.secretRef, stored.updatedAt);
    } else {
      await _sealServerRecord(stored);
      // The opted-in credential travels with its server — re-dating past
      // this device's own earlier retraction when needed, or the fleet
      // keeps it withdrawn.
      final ref = stored.secretRef;
      if (stored.syncSecret && ref != null) await _publishSecret(ref);
    }
    await _refreshCatalog();
  }

  /// A local server delete: drop the row and seal a real tombstone dated
  /// at the deletion — same resurrection-gap fix as
  /// [onBookmarkDeleted] — then retract the orphaned credential's record.
  Future<void> onServerDeleted(ServerConfig server) async {
    final store = _servers;
    if (store == null) return;
    await store.remove(server.id);
    final deletedAt = _now().toUtc().millisecondsSinceEpoch;
    await _records.putLocal(await _crypto.seal(DecryptedRecord(
      id: server.id,
      kind: RecordKind.serverConfig,
      updatedAt: deletedAt,
      deviceId: _deviceId,
      deleted: true,
    )));
    await _retractOrphanedSecret(server.secretRef, deletedAt);
    await _refreshCatalog();
  }

  /// A credential the editor saved into the vault (via
  /// [SecretVault.putLocalSecret], so its own stamp advanced): publish it
  /// while a synced server opts it in — a credential edit on an excluded
  /// or non-`syncSecret` server stays local (Séance's
  /// `_publishableSecretRefs` rule). Null-safe when shared mode has no
  /// vault or store.
  Future<void> onServerSecretSaved(String secretId) async {
    if (_secrets == null || _servers == null) return;
    var publishable = false;
    for (final server in await _servers.load()) {
      if (!server.excludeFromSync &&
          server.syncSecret &&
          server.secretRef == secretId) {
        publishable = true;
        break;
      }
    }
    if (publishable) await _publishSecret(secretId);
  }

  /// Seal one server under its own stamp — the record id is the bare
  /// config id, Séance's convention: prefixless ids are `serverConfig`.
  Future<void> _sealServerRecord(ServerConfig server) async {
    await _records.putLocal(await _crypto.seal(DecryptedRecord(
      id: server.id,
      kind: RecordKind.serverConfig,
      updatedAt: server.updatedAt,
      deviceId: _deviceId,
      data: server.toJson(),
    )));
  }

  /// Seal the vault entry [ref] into its `secret:` record, dirty for the
  /// next push. An unreadable or absent entry publishes nothing — the
  /// pull side's repair path is what heals it. When this device's own
  /// earlier retraction still sits in the record store past the
  /// credential's stamp, re-date the credential past it (and persist the
  /// bump so vault and record agree): without the bump the tombstone
  /// wins LWW and the fleet keeps the credential withdrawn — Séance's
  /// `_reviveSecrets` case.
  Future<void> _publishSecret(String ref) async {
    final vault = _secrets;
    if (vault == null) return;
    final Secret? secret;
    try {
      secret = await vault.readableSecret(ref);
    } catch (_) {
      return;
    }
    if (secret == null) return;
    var stamped = secret;
    final existing = await _records.getRecord('$_secretPrefix$ref');
    if (existing != null &&
        existing.deleted &&
        existing.updatedAt >= stamped.updatedAt) {
      stamped = stamped.copyWith(updatedAt: existing.updatedAt + 1);
      try {
        await vault.putSecret(stamped);
      } catch (_) {
        // A vault that cannot take the bump still publishes nothing new;
        // the next round's pull-side repair gets another chance.
        return;
      }
    }
    await _records.putLocal(await _crypto.seal(DecryptedRecord(
      id: '$_secretPrefix$ref',
      kind: RecordKind.secret,
      updatedAt: stamped.updatedAt,
      deviceId: _deviceId,
      data: stamped.toJson(),
    )));
  }

  /// Retract a credential's `secret:` record when no synced server still
  /// references it — the withdrawal half of delete and exclusion. A
  /// still-synced sharer keeps the credential published (Séance's
  /// `syncedSecretRefs` rule, conservatively counting a sharer whose own
  /// `syncSecret` is off).
  Future<void> _retractOrphanedSecret(String? ref, int stamp) async {
    final store = _servers;
    if (ref == null || store == null) return;
    for (final server in await store.load()) {
      if (!server.excludeFromSync && server.secretRef == ref) return;
    }
    await _records.putLocal(await _crypto.seal(DecryptedRecord(
      id: '$_secretPrefix$ref',
      kind: RecordKind.secret,
      updatedAt: stamp,
      deviceId: _deviceId,
      deleted: true,
    )));
  }

  /// Repopulate the shared-mode catalog from the server store — the
  /// post-mutation and post-restart repaint path, before any round has
  /// run. A no-op outside shared mode.
  Future<void> rebuildCatalog() => _refreshCatalog();

  Future<void> _refreshCatalog() async {
    final catalog = _catalog;
    if (catalog != null) await _rebuildCatalog(catalog);
  }

  /// A locally made or re-trusted TOFU pin: publish it and clear any
  /// negative pin for the locator — explicit re-trust is the only thing
  /// that lifts the untrust verdict (04 §3.2). The pin record lands
  /// first: lifting the verdict before the replacement is durable would
  /// leave a window where a pulled rival key auto-applies.
  Future<void> onHostKeyPinned(HostKey pin) async {
    await _records.putLocal(await _crypto.seal(DecryptedRecord(
      id: pin.recordId,
      kind: RecordKind.hostKey,
      updatedAt: pin.pinnedAt,
      deviceId: _deviceId,
      data: pin.toJson(),
    )));
    await _pinVerdicts.removeNegativePin(pin.locator);
  }

  /// "Forget host": tombstone the pin's record AND record the durable
  /// negative pin. The tombstone alone cannot hold — a still-trusting peer
  /// habitually re-pushes its pin with a fresh stamp, and without the
  /// verdict the next diff would auto-apply the very key the user removed
  /// under MITM suspicion. Local de-trust is the caller's side of the
  /// contract: [HostKeyStore] offers no removal, so the app drops the pin
  /// through its own store alongside this call.
  Future<void> onHostKeyForgotten(String host, int port) async {
    await _pinVerdicts.addNegativePin(hostKeyLocator(host, port));
    await _records.putLocal(await _crypto.seal(DecryptedRecord(
      id: '$_hostKeyPrefix${hostKeyLocator(host, port)}',
      kind: RecordKind.hostKey,
      updatedAt: _now().toUtc().millisecondsSinceEpoch,
      deviceId: _deviceId,
      deleted: true,
    )));
  }

  /// Resolve a pin conflict by keeping the local pin: record the durable
  /// kept-verdict (the rejected fingerprint, so the *same* key returning
  /// stays resolved but a genuinely different one still warns) and re-push
  /// the kept pin under a fresh LWW tuple.
  Future<void> keepLocalPin(String host, int port) async {
    final locator = hostKeyLocator(host, port);
    final record = await _records.getRecord('$_hostKeyPrefix$locator');
    if (record != null && !record.deleted) {
      try {
        final dec = await _crypto.open(record);
        if (dec.kind == RecordKind.hostKey) {
          await _pinVerdicts.recordKeptVerdict(
              locator, HostKey.fromJson(dec.data).fingerprintSha256);
        }
      } catch (_) {
        // An unreadable quarantined record is still out-voted by the
        // re-push below; the verdict just cannot name it.
      }
    }
    final local = await _hostKeys.get(host, port);
    if (local == null) return;
    await _records.putLocal(await _crypto.seal(DecryptedRecord(
      id: local.recordId,
      kind: RecordKind.hostKey,
      updatedAt: _now().toUtc().millisecondsSinceEpoch,
      deviceId: _deviceId,
      data: local.toJson(),
    )));
  }

  /// Resolve a pin conflict by accepting the pulled key: install the
  /// record store's copy — no re-push, it already won LWW — and clear any
  /// negative pin, since accepting is explicit re-trust.
  Future<void> acceptPulledPin(String host, int port) async {
    final locator = hostKeyLocator(host, port);
    final record = await _records.getRecord('$_hostKeyPrefix$locator');
    if (record == null || record.deleted) return;
    final DecryptedRecord dec;
    try {
      dec = await _crypto.open(record);
    } catch (_) {
      // Quarantined/undecryptable record — nothing to accept. Mirrors the
      // defensive read in keepLocalPin.
      return;
    }
    if (dec.kind != RecordKind.hostKey) {
      throw FormatException('record ${record.id} is not a host key');
    }
    final pin = HostKey.fromJson(dec.data);
    await _pinVerdicts.removeNegativePin(locator);
    await _hostKeys.put(pin);
  }

  /// The host-key quarantine diff (04 §3.2): every stored `hostkey:`
  /// record's key against the local TOFU store, re-derived rather than
  /// remembered so a dismissed warning re-arms on the next round.
  Future<List<HostKeyConflict>> pinConflicts() async {
    final negative = await _pinVerdicts.negativePins();
    final conflicts = <HostKeyConflict>[];
    for (final record in await _records.allRecords()) {
      if (record.deleted || !record.id.startsWith(_hostKeyPrefix)) {
        continue;
      }
      final pin = await _decodePin(record);
      if (pin == null) continue;
      final local = await _hostKeys.get(pin.host, pin.port);
      if (local == null || !local.conflictsWith(pin)) continue;
      if (negative.contains(pin.locator)) continue;
      if (await _pinVerdicts.rejectedFingerprintFor(pin.locator) ==
          pin.fingerprintSha256) {
        continue;
      }
      conflicts.add(HostKeyConflict(
          locator: pin.locator, local: local, pulled: pin));
    }
    return conflicts;
  }

  /// §3.1's corruption recovery: re-seal every materialized tuple —
  /// content and tombstones alike — with the row's *persisted winning*
  /// `(updatedAt, deviceId)`, never this install's id unconditionally
  /// (that would flip the fleet-wide tie-break on rows a remote device
  /// authored). Every record lands dirty, so the next round re-pushes the
  /// set — content-identical for already-synced rows, harmless under LWW.
  /// Returns the number of records re-sealed.
  Future<int> reSealAfterStoreLoss() async {
    final tuples = await _bookmarks.syncTuples();
    final rows = {for (final b in await _bookmarks.load()) b.id: b};
    var resealed = 0;
    for (final entry in tuples.entries) {
      final tuple = entry.value;
      final row = rows[entry.key];
      if (tuple.deleted) {
        await _records.putLocal(await _crypto.seal(DecryptedRecord(
          id: '$_bookmarkPrefix${entry.key}',
          kind: RecordKind.bookmark,
          updatedAt: tuple.updatedAt,
          deviceId: tuple.deviceId,
          deleted: true,
        )));
        resealed++;
      } else if (row != null) {
        await _records.putLocal(await _crypto.seal(DecryptedRecord(
          id: '$_bookmarkPrefix${entry.key}',
          kind: RecordKind.bookmark,
          updatedAt: tuple.updatedAt,
          deviceId: tuple.deviceId,
          data: row.toJson(),
        )));
        resealed++;
      }
    }
    // Shared mode's second materialized set: the server store's tuples
    // re-seal under their own bare ids with the persisted winning
    // authorship, exactly like the bookmark pass above.
    final servers = _servers;
    if (servers != null) {
      final serverTuples = await servers.syncTuples();
      final serverRows = {for (final s in await servers.load()) s.id: s};
      for (final entry in serverTuples.entries) {
        final tuple = entry.value;
        final row = serverRows[entry.key];
        await _records.putLocal(await _crypto.seal(
          row == null || tuple.deleted
              ? DecryptedRecord(
                  id: entry.key,
                  kind: RecordKind.serverConfig,
                  updatedAt: tuple.updatedAt,
                  deviceId: tuple.deviceId,
                  deleted: true,
                )
              : DecryptedRecord(
                  id: entry.key,
                  kind: RecordKind.serverConfig,
                  updatedAt: tuple.updatedAt,
                  deviceId: tuple.deviceId,
                  data: row.toJson(),
                ),
        ));
        resealed++;
      }
      // Credentials the vault still holds re-seal through the publish
      // path — it re-sources the plaintext and lands the record dirty.
      for (final server in serverRows.values) {
        final ref = server.secretRef;
        if (!server.excludeFromSync && server.syncSecret && ref != null) {
          await _publishSecret(ref);
        }
      }
    }
    return resealed;
  }

  /// §4.5's release path: after a corrected passphrase verifies, every
  /// still-dirty record may have been sealed under the *unverified* key —
  /// pushing it would poison the fleet with ciphertext no correct
  /// passphrase reads. Re-seal each pending write under the coordinator's
  /// current vault key before the next round can push it. A record that
  /// already opens under the verified key is skipped (sealed
  /// post-correction); a stale-key record's plaintext is re-sourced from
  /// the materialized stores; the envelope's `(updatedAt, deviceId)` is
  /// preserved verbatim so the re-seal keeps the exact same LWW tuple —
  /// no re-stamp, no tie-break flip. A stale-key record whose plaintext
  /// no store can supply stays dirty — releasing it would push the
  /// corruption the hold existed to prevent (unreachable in separate
  /// mode: every local-write path produces `bookmark:`/`hostkey:` ids,
  /// which always have a materialized source).
  Future<int> reSealPendingWrites() async {
    var resealed = 0;
    for (final record in await _records.dirtyRecords()) {
      final prefix = _prefixOf(record.id);
      if (record.deleted) {
        final kind = switch (prefix) {
          'bookmark' => RecordKind.bookmark,
          'hostkey' => RecordKind.hostKey,
          'secret' => RecordKind.secret,
          null => RecordKind.serverConfig,
          _ => null,
        };
        if (kind == null) continue;
        await _records.putLocal(await _crypto.seal(DecryptedRecord(
          id: record.id,
          kind: kind,
          updatedAt: record.updatedAt,
          deviceId: record.deviceId,
          deleted: true,
        )));
        resealed++;
        continue;
      }
      // A record that already opens under the verified key needs nothing —
      // it was sealed post-correction. Only a decrypt failure (stale key)
      // needs the plaintext re-sourced below.
      try {
        await _crypto.open(record);
        continue;
      } catch (_) {
        // Sealed under the unverified key: re-source the plaintext.
      }
      switch (prefix) {
        case 'bookmark':
          final row =
              await _bookmarks.byId(record.id.substring(_bookmarkPrefix.length));
          if (row == null) continue;
          await _records.putLocal(await _crypto.seal(DecryptedRecord(
            id: record.id,
            kind: RecordKind.bookmark,
            updatedAt: record.updatedAt,
            deviceId: record.deviceId,
            data: row.toJson(),
          )));
          resealed++;
        case 'hostkey':
          HostKey? pin;
          for (final key in await _hostKeys.all()) {
            if (key.recordId == record.id) pin = key;
          }
          if (pin == null) continue;
          await _records.putLocal(await _crypto.seal(DecryptedRecord(
            id: record.id,
            kind: RecordKind.hostKey,
            updatedAt: record.updatedAt,
            deviceId: record.deviceId,
            data: pin.toJson(),
          )));
          resealed++;
        case 'secret':
          final Secret? secret;
          try {
            secret = await _secrets?.readableSecret(
                record.id.substring(_secretPrefix.length));
          } catch (_) {
            continue;
          }
          if (secret == null) continue;
          await _records.putLocal(await _crypto.seal(DecryptedRecord(
            id: record.id,
            kind: RecordKind.secret,
            updatedAt: record.updatedAt,
            deviceId: record.deviceId,
            data: secret.toJson(),
          )));
          resealed++;
        case null:
          final row = await _servers?.byId(record.id);
          if (row == null) continue;
          // An excluded server's stale live record re-seals as the
          // retraction the store says it should be — re-pushing live
          // payload would un-exclude it on the fleet.
          await _records.putLocal(await _crypto.seal(
            row.excludeFromSync
                ? DecryptedRecord(
                    id: record.id,
                    kind: RecordKind.serverConfig,
                    updatedAt: record.updatedAt,
                    deviceId: record.deviceId,
                    deleted: true,
                  )
                : DecryptedRecord(
                    id: record.id,
                    kind: RecordKind.serverConfig,
                    updatedAt: record.updatedAt,
                    deviceId: record.deviceId,
                    data: row.toJson(),
                  ),
          ));
          resealed++;
      }
    }
    return resealed;
  }

  /// One sync round over the [api] seam: delta pull off `highWaterSeq`
  /// (with the one-time full-resync fallback when the cursor is rejected),
  /// merge into the store, push the dirty set, then materialize. Loops
  /// while progress is being made, bounded by [BookmarkCoordinator]'s
  /// `maxRounds`. While 04 §4.5's `passphraseUnverified` hold is set the
  /// push half is skipped entirely — nothing sealed under an unproven key
  /// leaves the device — and the round ends with the deferred
  /// foreign-record check. A 401 `unauthorized` is a dead or revoked
  /// account (tokens never expire server-side, so there is no refresh):
  /// the durable notice is raised and the round ends — local-only.
  Future<SyncRoundResult> runRound(SyncApi api) async {
    final report = ApplyReport();
    var pulled = 0;
    var pushed = 0;
    var rounds = 0;
    var authFailed = false;
    while (rounds < _maxRounds) {
      rounds++;
      final int roundPulled;
      try {
        roundPulled = await _pullOnce(api);
      } on ApiError catch (error) {
        if (error.code != 'unauthorized') rethrow;
        authFailed = true;
        break;
      }
      // A good pull proves the token lives — lift a stale auth notice.
      await _setNotice(syncNoticeAccountAuthFailed, false);
      pulled += roundPulled;
      var progressed = roundPulled > 0;
      if (!await _pushesHeld()) {
        final dirty = await _records.dirtyRecords();
        if (dirty.isNotEmpty) {
          final PushResponse response;
          try {
            response = await api.push(dirty);
          } on ApiError catch (error) {
            if (error.code != 'unauthorized') rethrow;
            authFailed = true;
            break;
          }
          for (final result in response.results) {
            if (result.accepted) {
              pushed++;
              progressed = true;
              await _records.markSynced(result.id, result.seq);
            } else {
              // The push lost server-side LWW: the copy the server actually
              // holds is the displaced pulled winner, so put it back —
              // leaving the losing edit in place would diverge the fleet
              // (04 §3.2's push-ties-or-loses re-check). A rejection with no
              // displaced winner stays dirty for the next pull to reconcile.
              final restored = await _records.restoreDisplaced(result.id);
              if (restored != null) {
                progressed = true;
                switch (await _dispatch(restored, report,
                    holdActive: false)) {
                  case _ApplyOutcome.applied:
                    report.appliedIds.add(restored.id);
                  case _ApplyOutcome.deferred:
                    report.deferredIds.add(restored.id);
                  case _ApplyOutcome.skipped:
                }
              }
            }
          }
        }
      }
      // No durable state changed this round (nothing pulled, nothing
      // accepted, nothing restored): the next iteration would replay the
      // identical delta pull and push, so stop instead of spinning to the
      // rounds cap. Rejected dirt stays dirty for the next sync.
      if (!progressed) break;
    }
    await _applyPulledInto(report);
    await _deferredPassphraseCheck();
    if (authFailed) {
      await _setNotice(syncNoticeAccountAuthFailed, true);
    }
    return SyncRoundResult(
      pulled: pulled,
      pushed: pushed,
      rounds: rounds,
      report: report,
      pushesHeld: await _pushesHeld(),
      authFailed: authFailed,
    );
  }

  /// 04 §4.5's hold: while `passphraseUnverified` is set, no push leaves
  /// the device — the first push under a wrong key would itself be the
  /// corruption (records no correct-passphrase device could ever read).
  Future<bool> _pushesHeld() async =>
      await _enrollment?.passphraseUnverified() ?? false;

  Future<void> _setNotice(String notice, bool active) async {
    final enrollment = _enrollment;
    if (enrollment == null) return;
    // Skip the durable write when nothing changes — a good pull reaches
    // here every round, and an unconditional set is a settings-file write
    // (and observer notification) per round for the app's lifetime.
    if ((await enrollment.notices()).contains(notice) == active) return;
    await enrollment.setNotice(notice, active);
  }

  /// The deferred trial-decrypt (04 §4.5): while the hold stands, the flag
  /// clears only on a **foreign** non-tombstone record that decrypts — this
  /// device's own output would vacuously clear it under whatever key sealed
  /// it. Every foreign candidate on a decryptable id is tried (a corrupt
  /// one cannot condemn the passphrase — the three-cause copy exists
  /// precisely because a single failure is ambiguous); a success clears
  /// the hold and the notice, and when every candidate fails the durable
  /// Settings → Backup error is raised with pushes still held.
  Future<void> _deferredPassphraseCheck() async {
    final enrollment = _enrollment;
    if (enrollment == null || !await enrollment.passphraseUnverified()) {
      return;
    }
    final candidates = [
      for (final record in await _records.allRecords())
        if (!record.deleted &&
            record.blob.isNotEmpty &&
            record.deviceId != _deviceId &&
            isDecryptableSyncId(record.id))
          record,
    ]..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    var sawFailure = false;
    for (final record in candidates) {
      var verified = false;
      try {
        await _crypto.open(record);
        verified = true;
      } catch (_) {
        sawFailure = true;
      }
      if (!verified) continue;
      // The passphrase is verified — but the hold is the only gate
      // keeping stale-key ciphertext offline. Re-seal held writes
      // BEFORE lifting the flag: a clear-then-reseal window would let
      // the next round push whatever the unverified key sealed — the
      // fleet-poisoning the hold exists to prevent. Deliberately outside
      // the try: a re-seal failure must not masquerade as a passphrase
      // failure — it propagates and leaves the hold standing.
      await reSealPendingWrites();
      await enrollment.setPassphraseUnverified(false);
      await enrollment.setNotice(syncNoticePassphraseCheckFailed, false);
      return;
    }
    if (sawFailure) {
      await enrollment.setNotice(syncNoticePassphraseCheckFailed, true);
    }
  }

  /// The pull half of a round, with §3.1's one-time full-resync fallback:
  /// a rejected `since` cursor resets both cursors and re-pulls from zero,
  /// so `applyPulled` re-scans the lifetime set.
  Future<int> _pullOnce(SyncApi api) async {
    PullResponse response;
    try {
      response = await api.pull(since: await _records.highWaterSeq());
    } on SyncCursorRejectedException {
      await _records.resetSyncCursors();
      response = await api.pull(since: 0);
    }
    var snapshot = await _records.highWaterSeq();
    for (final remote in response.records) {
      final seq = remote.seq;
      if (seq != null && seq > snapshot) snapshot = seq;
      // The store merges under the same Lww the server ran — a loser is
      // dropped or parked behind the dirty rival it lost to.
      await _records.putRemote(remote);
    }
    await _records.setHighWaterSeq(snapshot);
    return response.records.length;
  }

  /// Materialize pulled records — see [applyPulled].
  Future<ApplyReport> applyPulled() async {
    final report = ApplyReport();
    await _applyPulledInto(report);
    return report;
  }

  /// The apply pass (04 §3.2): dispatch every stored record with
  /// `seq > lastAppliedSeq` in seq order, then advance the cursor — but
  /// only past records that were applied or terminally skipped, never past
  /// a seen-but-deferred one (a delta pull never re-delivers a passed seq;
  /// a deferred record's re-check is the rival's next push instead). While
  /// §4.5's passphrase hold stands a decrypt failure defers rather than
  /// skips — it is not terminal, and the corrected-passphrase re-pull must
  /// find the record still ahead of the apply cursor.
  Future<void> _applyPulledInto(ApplyReport report) async {
    final cursor = await _records.lastAppliedSeq();
    final holdActive = await _pushesHeld();
    final dirtyIds =
        (await _records.dirtyRecords()).map((r) => r.id).toSet();
    final pending = [
      for (final record in await _records.allRecords())
        if (record.seq != null &&
            record.seq! > cursor &&
            !dirtyIds.contains(record.id))
          record,
    ]..sort((a, b) => a.seq!.compareTo(b.seq!));

    var advanceTo = cursor;
    int? blockedAt;
    Future<void> account(EncryptedRecord record, _ApplyOutcome outcome) async {
      if (outcome == _ApplyOutcome.deferred) {
        report.deferredIds.add(record.id);
        blockedAt =
            blockedAt == null ? record.seq : min(blockedAt!, record.seq!);
        return;
      }
      if (outcome == _ApplyOutcome.applied) {
        report.appliedIds.add(record.id);
      }
      if (blockedAt == null && record.seq! > advanceTo) {
        advanceTo = record.seq!;
      }
    }

    // `account` is awaited per record; `seq` is non-null by construction
    // of `pending`/`secretPending` (filtered above).

    // `secret:` records apply after every other dispatch: the exclusion
    // shield judges them against the round's *final* server set, not the
    // store as their seq position found it.
    final secretPending = <EncryptedRecord>[];
    for (final record in pending) {
      if (_prefixOf(record.id) == 'secret') {
        secretPending.add(record);
        continue;
      }
      await account(
          record, await _dispatch(record, report, holdActive: holdActive));
    }
    for (final record in secretPending) {
      await account(record,
          await _applySecretRecord(record, holdActive: holdActive));
    }

    // The other deferral channel: pulled losers parked behind a dirty local
    // rival. They are outside the seq scan (not stored), but they are still
    // seen-but-deferred — report them and keep the cursor honest below
    // them.
    for (final displaced in await _records.displacedRecords()) {
      final seq = displaced.seq;
      if (seq != null && seq > cursor) {
        report.deferredIds.add(displaced.id);
        blockedAt = blockedAt == null ? seq : min(blockedAt!, seq);
      }
    }
    final blocked = blockedAt;
    if (blocked != null && advanceTo >= blocked) {
      advanceTo = blocked - 1;
    }
    if (advanceTo > cursor) {
      await _records.setLastAppliedSeq(advanceTo);
    }

    report.pinConflicts.addAll(await pinConflicts());
    final catalog = _catalog;
    if (catalog != null) await _rebuildCatalog(catalog);
  }

  /// Route one record by its plaintext id prefix — *before* decrypting
  /// (04 §3.2): the prefix decides whether a record is decrypted at all,
  /// the decrypted kind decides whether it is applied. `snippet:` and
  /// unrecognized `<prefix>:` ids — and `secret:`/prefixless ids outside
  /// shared mode (no vault / no server store) — are skip-preserved
  /// without ever being opened.
  /// [holdActive] is §4.5's `passphraseUnverified` state: a decrypt
  /// failure under it is seen-but-deferred, not skipped — the record may
  /// simply be sealed under the passphrase the user has not yet typed
  /// right, and re-enrollment must find it ahead of the apply cursor.
  Future<_ApplyOutcome> _dispatch(EncryptedRecord record, ApplyReport report,
      {required bool holdActive}) async {
    final prefix = _prefixOf(record.id);
    if (record.deleted) {
      // Tombstones carry no sealed kind, so the prefix alone routes them.
      // `bookmark:` and prefixless (`serverConfig`) tombstones apply —
      // configs already carry the breach-tolerant exposure of an envelope
      // a sync server can assert on its own (Séance applies them the same
      // way). `hostkey:`, `secret:` and `snippet:` tombstones stay no-ops:
      // honouring those would hand the server a primitive for stripping
      // this device's pins or vault.
      if (prefix == 'bookmark') return _applyBookmarkTombstone(record);
      if (prefix == null) return _applyServerConfigTombstone(record);
      return _ApplyOutcome.skipped;
    }
    return switch (prefix) {
      'bookmark' =>
        await _applyBookmarkRecord(record, holdActive: holdActive),
      'hostkey' =>
        await _applyHostKeyRecord(record, holdActive: holdActive),
      // Credentials materialize into the vault — skipped when shared
      // mode has none to write to.
      'secret' => _secrets != null
          ? await _applySecretRecord(record, holdActive: holdActive)
          : _ApplyOutcome.skipped,
      // Prefixless is Séance's actual serverConfig convention — decrypt it
      // only when a server store exists to materialize into (shared mode).
      null => _servers != null
          ? await _applyServerConfigRecord(record, holdActive: holdActive)
          : _ApplyOutcome.skipped,
      _ => _ApplyOutcome.skipped,
    };
  }

  /// The substring before the **first** colon — a `hostkey:[2001:db8::1]:22`
  /// id contains several, and anything but the first segment would
  /// misroute it.
  static String? _prefixOf(String id) {
    final colon = id.indexOf(_kindDelimiter);
    return colon < 0 ? null : id.substring(0, colon);
  }

  /// The §3.2 tuple guard, shared by upsert and tombstone: a pulled record
  /// applies when its `(updatedAt, deviceId)` beats or ties the tuple last
  /// materialized into the bookmark store. A tie is the same winning
  /// envelope arriving again — idempotent by construction.
  static bool _outranksMaterialized(
          EncryptedRecord record, BookmarkSyncTuple? materialized) =>
      materialized == null ||
      record.updatedAt > materialized.updatedAt ||
      (record.updatedAt == materialized.updatedAt &&
          record.deviceId.compareTo(materialized.deviceId) >= 0);

  Future<_ApplyOutcome> _applyBookmarkRecord(EncryptedRecord record,
      {required bool holdActive}) async {
    final dec = await _openForApply(record);
    if (dec == null) {
      return holdActive ? _ApplyOutcome.deferred : _ApplyOutcome.skipped;
    }
    if (dec.kind != RecordKind.bookmark) {
      // Decrypt-success + prefix/kind mismatch: the primary in-place
      // corruption signature (04 §3.2's relabeled-secret case).
      await _tripwires.trip(record.id);
      return _ApplyOutcome.skipped;
    }
    final Bookmark bookmark;
    try {
      // Strict decode — fail loud, never default a malformed field.
      bookmark = Bookmark.fromJson(dec.data, recordId: record.id);
    } catch (_) {
      await _tripwires.trip(record.id);
      return _ApplyOutcome.skipped;
    }
    // It pulled and strict-decoded: lift any past tripwire on this id.
    await _tripwires.clear(record.id);
    if (!_outranksMaterialized(
        record, await _bookmarks.syncTupleOf(bookmark.id))) {
      return _ApplyOutcome.deferred;
    }
    await _bookmarks.applySyncedRecords([
      (
        bookmark: bookmark,
        winner: BookmarkSyncTuple(
            updatedAt: record.updatedAt, deviceId: record.deviceId),
      ),
    ]);
    return _ApplyOutcome.applied;
  }

  Future<_ApplyOutcome> _applyBookmarkTombstone(EncryptedRecord record) async {
    // The stripped id is exactly the payload id that
    // Bookmark.fromJson(recordId:) validates the envelope against, so a
    // tombstone and a live upsert key the same materialized row.
    final bookmarkId = record.id.substring(_bookmarkPrefix.length);
    if (!_outranksMaterialized(
        record, await _bookmarks.syncTupleOf(bookmarkId))) {
      return _ApplyOutcome.deferred;
    }
    await _bookmarks.removeSyncedRecord(
      bookmarkId,
      BookmarkSyncTuple(
          updatedAt: record.updatedAt,
          deviceId: record.deviceId,
          deleted: true),
    );
    return _ApplyOutcome.applied;
  }

  Future<_ApplyOutcome> _applyHostKeyRecord(EncryptedRecord record,
      {required bool holdActive}) async {
    final dec = await _openForApply(record);
    if (dec == null) {
      return holdActive ? _ApplyOutcome.deferred : _ApplyOutcome.skipped;
    }
    if (dec.kind != RecordKind.hostKey) {
      await _tripwires.trip(record.id);
      return _ApplyOutcome.skipped;
    }
    final HostKey pin;
    try {
      pin = HostKey.fromJson(dec.data);
    } catch (_) {
      await _tripwires.trip(record.id);
      return _ApplyOutcome.skipped;
    }
    // A pin stores under its payload's locator: a record whose envelope id
    // names a different one would plant trust for an address nothing ever
    // named.
    if (record.id != pin.recordId) {
      await _tripwires.trip(record.id);
      return _ApplyOutcome.skipped;
    }
    await _tripwires.clear(record.id);
    // Auto-apply requires no negative pin: the untrust verdict holds the
    // record unapplied until the user explicitly re-trusts.
    if ((await _pinVerdicts.negativePins()).contains(pin.locator)) {
      return _ApplyOutcome.skipped;
    }
    final local = await _hostKeys.get(pin.host, pin.port);
    if (local != null && local.conflictsWith(pin)) {
      // A conflicting pin is quarantined unapplied — reported through the
      // re-derived diff, never silently trusted.
      return _ApplyOutcome.skipped;
    }
    await _hostKeys.put(pin);
    return _ApplyOutcome.applied;
  }

  Future<_ApplyOutcome> _applyServerConfigRecord(EncryptedRecord record,
      {required bool holdActive}) async {
    final store = _servers;
    if (store == null) return _ApplyOutcome.skipped;
    final dec = await _openForApply(record);
    if (dec == null) {
      return holdActive ? _ApplyOutcome.deferred : _ApplyOutcome.skipped;
    }
    if (dec.kind != RecordKind.serverConfig) {
      await _tripwires.trip(record.id);
      return _ApplyOutcome.skipped;
    }
    final ServerConfig config;
    try {
      config = ServerConfig.fromJson(dec.data);
      if (config.id != record.id) {
        throw const FormatException('serverConfig id mismatch');
      }
    } catch (_) {
      await _tripwires.trip(record.id);
      return _ApplyOutcome.skipped;
    }
    await _tripwires.clear(record.id);
    // The exclusion shield runs before the tuple guard: a locally
    // excluded server keeps its row but must never re-materialize pulled
    // state. Its retraction re-dates past a winning pulled copy — once,
    // then settles; the rival pushes at a fixed stamp, so nothing bids
    // back (Séance's `rescheduleOutranked` escalation).
    final local = await store.byId(config.id);
    if (local != null && local.excludeFromSync) {
      if (record.updatedAt >= local.updatedAt) {
        await _records.putLocal(await _crypto.seal(DecryptedRecord(
          id: record.id,
          kind: RecordKind.serverConfig,
          updatedAt: record.updatedAt + 1,
          deviceId: _deviceId,
          deleted: true,
        )));
      }
      return _ApplyOutcome.skipped;
    }
    if (!_outranksMaterialized(
        record, await store.syncTupleOf(config.id))) {
      return _ApplyOutcome.deferred;
    }
    await store.applySyncedRecord(
      config,
      ServerSyncTuple(
          updatedAt: record.updatedAt, deviceId: record.deviceId),
    );
    return _ApplyOutcome.applied;
  }

  /// A pulled `serverConfig` tombstone deletes the materialized row under
  /// the same tuple guard an upsert uses — with Séance's two exceptions:
  /// a locally excluded row never drops (the tombstone is this device's
  /// own retraction echoing back), and an own-deviceId tombstone over a
  /// live local row is a reversed exclusion — the live record re-dates
  /// past it rather than honouring a decision the user undid.
  Future<_ApplyOutcome> _applyServerConfigTombstone(
      EncryptedRecord record) async {
    final store = _servers;
    if (store == null) return _ApplyOutcome.skipped;
    final local = await store.byId(record.id);
    if (local != null && local.excludeFromSync) {
      return _ApplyOutcome.skipped;
    }
    if (local != null && record.deviceId == _deviceId) {
      final revived = local.copyWith(updatedAt: record.updatedAt + 1);
      await store.applySyncedRecord(
        revived,
        ServerSyncTuple(
            updatedAt: revived.updatedAt, deviceId: _deviceId),
      );
      await _sealServerRecord(revived);
      return _ApplyOutcome.applied;
    }
    if (!_outranksMaterialized(
        record, await store.syncTupleOf(record.id))) {
      return _ApplyOutcome.deferred;
    }
    await store.removeSyncedRecord(
      record.id,
      ServerSyncTuple(
          updatedAt: record.updatedAt,
          deviceId: record.deviceId,
          deleted: true),
    );
    return _ApplyOutcome.applied;
  }

  /// A pulled `secret:` record materializes into the vault under Séance's
  /// two guards: the exclusion shield (a credential referenced only by
  /// excluded servers never lands), and the freshness floor (a strictly
  /// newer local edit is never overwritten — the record layer's own
  /// tie-break cannot protect a credential this device does not publish).
  /// Tombstones stay no-ops here — vault material is not something an
  /// envelope-only signal may strip.
  Future<_ApplyOutcome> _applySecretRecord(EncryptedRecord record,
      {required bool holdActive}) async {
    final vault = _secrets;
    if (vault == null || record.deleted) return _ApplyOutcome.skipped;
    final dec = await _openForApply(record);
    if (dec == null) {
      return holdActive ? _ApplyOutcome.deferred : _ApplyOutcome.skipped;
    }
    if (dec.kind != RecordKind.secret) {
      await _tripwires.trip(record.id);
      return _ApplyOutcome.skipped;
    }
    final Secret secret;
    try {
      secret = Secret.fromJson(dec.data);
      if (record.id != '$_secretPrefix${secret.id}') {
        throw const FormatException('secret id mismatch');
      }
    } catch (_) {
      await _tripwires.trip(record.id);
      return _ApplyOutcome.skipped;
    }
    await _tripwires.clear(record.id);
    if (await _isShieldedSecret(secret.id)) return _ApplyOutcome.skipped;
    try {
      final existing = await vault.readableSecret(secret.id);
      if (existing != null && existing.updatedAt > dec.updatedAt) {
        return _ApplyOutcome.skipped;
      }
      // Persist the envelope stamp so a later local edit can never
      // manufacture a "newer" version out of an unrelated save —
      // Séance's rule for legacy records whose payload carries no stamp.
      await vault.putSecret(secret.copyWith(updatedAt: dec.updatedAt));
    } catch (_) {
      // A locked or failing vault leaves the record stored but
      // unapplied; skipping keeps the pass alive rather than stranding
      // the cursor — Séance's per-record `skip` posture.
      return _ApplyOutcome.skipped;
    }
    return _ApplyOutcome.applied;
  }

  /// True when every stored reference to [ref] is excluded — the shield
  /// that keeps a retracted credential's pulled copies out of the vault.
  Future<bool> _isShieldedSecret(String ref) async {
    final store = _servers;
    if (store == null) return false;
    var shielded = false;
    for (final server in await store.load()) {
      if (server.secretRef != ref) continue;
      if (!server.excludeFromSync) return false;
      shielded = true;
    }
    return shielded;
  }

  /// Decrypt for application: a failure means the record is not for this
  /// vault key (or is corrupt ciphertext) — preserved untouched, and NOT
  /// the tripwire (that is decrypt-success + decode-failure).
  Future<DecryptedRecord?> _openForApply(EncryptedRecord record) async {
    try {
      return await _crypto.open(record);
    } catch (_) {
      return null;
    }
  }

  /// Decode a stored `hostkey:` record for the quarantine diff — null on
  /// any failure (the tripwire is the apply scan's job, not the diff's).
  Future<HostKey?> _decodePin(EncryptedRecord record) async {
    try {
      final dec = await _crypto.open(record);
      if (dec.kind != RecordKind.hostKey) return null;
      final pin = HostKey.fromJson(dec.data);
      return record.id == pin.recordId ? pin : null;
    } catch (_) {
      return null;
    }
  }

  /// Rebuild the shared-mode catalog from the server store. First a
  /// backfill pass adopts any decodable prefixless record with no
  /// materialized tuple — pulled by a build that predates the writable
  /// store, or otherwise never dispatched past the apply cursor — under
  /// its own envelope tuple; waiting for a seq the cursor already passed
  /// would leave the catalog empty until the next upstream edit.
  Future<void> _rebuildCatalog(SeanceServerCatalog catalog) async {
    final store = _servers;
    if (store == null) {
      catalog.replace(const []);
      return;
    }
    for (final record in await _records.allRecords()) {
      if (record.deleted || _prefixOf(record.id) != null) continue;
      final dec = await _openForApply(record);
      if (dec == null || dec.kind != RecordKind.serverConfig) continue;
      try {
        final config = ServerConfig.fromJson(dec.data);
        if (config.id != record.id) continue;
        if (await store.syncTupleOf(config.id) != null) continue;
        await _tripwires.clear(record.id);
        await store.applySyncedRecord(
          config,
          ServerSyncTuple(
              updatedAt: record.updatedAt, deviceId: record.deviceId),
        );
      } catch (_) {
        // Left to the apply scan's tripwire.
      }
    }
    catalog.replace(await store.load());
  }
}
