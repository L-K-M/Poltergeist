/// 04 §3.2 — `BookmarkCoordinator`: the thin, kind-aware bridge between the
/// §3.1 record store and the domain stores. Change-driven on the way out
/// (`onBookmarkSaved`/`onBookmarkDeleted` seal exactly the edited row),
/// delta-scanned on the way in (`applyPulled` processes only records with
/// `seq > lastAppliedSeq`), and skip-and-preserve throughout: unknown
/// prefixes are never decrypted, decrypt failures are never rewritten, and
/// decrypt-success + strict-decode-failure raises the §4.2 durable
/// tripwire. Poltergeist writes `bookmark:` records and `hostkey:` records
/// only — never `serverConfig`, `secret`, or `snippet`.
library;

import 'dart:math' show min;

import 'package:seance_core/seance_core.dart';

import '../sync/persistent_record_store.dart';
import '../sync/record_crypto.dart';
import '../sync/seance_server_catalog.dart';
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
  });

  final int pulled;
  final int pushed;
  final int rounds;
  final ApplyReport report;
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
        _now = now ?? DateTime.now,
        // ignore: prefer_initializing_formals
        _maxRounds = maxRounds;

  static const _kindDelimiter = ':';
  static const _bookmarkPrefix = 'bookmark:';
  static const _hostKeyPrefix = 'hostkey:';

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
    return resealed;
  }

  /// One sync round over the [api] seam: delta pull off `highWaterSeq`
  /// (with the one-time full-resync fallback when the cursor is rejected),
  /// merge into the store, push the dirty set, then materialize. Loops
  /// while progress is being made, bounded by [BookmarkCoordinator]'s
  /// `maxRounds`.
  Future<SyncRoundResult> runRound(SyncApi api) async {
    final report = ApplyReport();
    var pulled = 0;
    var pushed = 0;
    var rounds = 0;
    while (rounds < _maxRounds) {
      rounds++;
      final roundPulled = await _pullOnce(api);
      pulled += roundPulled;
      final dirty = await _records.dirtyRecords();
      var progressed = roundPulled > 0;
      if (dirty.isNotEmpty) {
        final response = await api.push(dirty);
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
              switch (await _dispatch(restored, report)) {
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
      // No durable state changed this round (nothing pulled, nothing
      // accepted, nothing restored): the next iteration would replay the
      // identical delta pull and push, so stop instead of spinning to the
      // rounds cap. Rejected dirt stays dirty for the next sync.
      if (!progressed) break;
    }
    await _applyPulledInto(report);
    return SyncRoundResult(
        pulled: pulled, pushed: pushed, rounds: rounds, report: report);
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
  /// a deferred record's re-check is the rival's next push instead).
  Future<void> _applyPulledInto(ApplyReport report) async {
    final cursor = await _records.lastAppliedSeq();
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
    for (final record in pending) {
      final outcome = await _dispatch(record, report);
      if (outcome == _ApplyOutcome.deferred) {
        report.deferredIds.add(record.id);
        blockedAt =
            blockedAt == null ? record.seq : min(blockedAt, record.seq!);
        continue;
      }
      if (outcome == _ApplyOutcome.applied) {
        report.appliedIds.add(record.id);
      }
      if (blockedAt == null && record.seq! > advanceTo) {
        advanceTo = record.seq!;
      }
    }

    // The other deferral channel: pulled losers parked behind a dirty local
    // rival. They are outside the seq scan (not stored), but they are still
    // seen-but-deferred — report them and keep the cursor honest below
    // them.
    for (final displaced in await _records.displacedRecords()) {
      final seq = displaced.seq;
      if (seq != null && seq > cursor) {
        report.deferredIds.add(displaced.id);
        blockedAt = blockedAt == null ? seq : min(blockedAt, seq);
      }
    }
    if (blockedAt != null && advanceTo >= blockedAt) {
      advanceTo = blockedAt - 1;
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
  /// the decrypted kind decides whether it is applied. `secret:`,
  /// `snippet:`, and unrecognized `<prefix>:` ids — and prefixless ids in
  /// separate mode — are skip-preserved without ever being opened.
  Future<_ApplyOutcome> _dispatch(
      EncryptedRecord record, ApplyReport report) async {
    final prefix = _prefixOf(record.id);
    if (record.deleted) {
      // Tombstones carry no sealed kind, so the prefix alone routes them —
      // and only `bookmark:` tombstones delete anything. A `hostkey:` (or
      // `secret:`/`snippet:`) tombstone is deliberately a no-op: the
      // envelope's `deleted` flag is the one signal a sync server can
      // assert entirely on its own, and honouring it would hand it a
      // primitive for stripping this device's pins.
      if (prefix == 'bookmark') return _applyBookmarkTombstone(record);
      return _ApplyOutcome.skipped;
    }
    return switch (prefix) {
      'bookmark' => await _applyBookmarkRecord(record),
      'hostkey' => await _applyHostKeyRecord(record),
      // Prefixless is Séance's actual serverConfig convention — decrypt it
      // only when a catalog exists to materialize into (shared mode).
      null => _catalog != null
          ? await _applyServerConfigRecord(record)
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

  Future<_ApplyOutcome> _applyBookmarkRecord(EncryptedRecord record) async {
    final dec = await _openForApply(record);
    if (dec == null) return _ApplyOutcome.skipped;
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

  Future<_ApplyOutcome> _applyHostKeyRecord(EncryptedRecord record) async {
    final dec = await _openForApply(record);
    if (dec == null) return _ApplyOutcome.skipped;
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

  Future<_ApplyOutcome> _applyServerConfigRecord(
      EncryptedRecord record) async {
    final dec = await _openForApply(record);
    if (dec == null) return _ApplyOutcome.skipped;
    if (dec.kind != RecordKind.serverConfig) {
      await _tripwires.trip(record.id);
      return _ApplyOutcome.skipped;
    }
    try {
      final config = ServerConfig.fromJson(dec.data);
      if (config.id != record.id) {
        await _tripwires.trip(record.id);
        return _ApplyOutcome.skipped;
      }
    } catch (_) {
      await _tripwires.trip(record.id);
      return _ApplyOutcome.skipped;
    }
    await _tripwires.clear(record.id);
    // The catalog itself is rebuilt wholesale below; reaching here means
    // the record strict-decoded, which is all the apply pass must judge.
    return _ApplyOutcome.applied;
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

  /// Rebuild the shared-mode catalog from the store's prefixless records —
  /// live configs materialize, tombstoned and undecodable ones do not.
  Future<void> _rebuildCatalog(SeanceServerCatalog catalog) async {
    final servers = <ServerConfig>[];
    for (final record in await _records.allRecords()) {
      if (record.deleted || _prefixOf(record.id) != null) continue;
      final dec = await _openForApply(record);
      if (dec == null || dec.kind != RecordKind.serverConfig) continue;
      try {
        final config = ServerConfig.fromJson(dec.data);
        if (config.id == record.id) {
          await _tripwires.clear(record.id);
          servers.add(config);
        }
      } catch (_) {
        // Left to the apply scan's tripwire.
      }
    }
    catalog.replace(servers);
  }
}
