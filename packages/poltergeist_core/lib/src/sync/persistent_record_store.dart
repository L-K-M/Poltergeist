/// 04 §3.1 — `PersistentLocalRecordStore`: the JSON-file-backed
/// [LocalRecordStore] that gives the sync engine real dirty tracking,
/// delta pulls, and tombstone retention. Séance's app constructs a fresh
/// `InMemoryLocalRecordStore` per round (full pull every round, deletions
/// resurrected by the next pull); this store persists instead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart';

import '../transfer/transfer_journal.dart' show TransferJournalIo;

/// The bookkeeping beyond the pinned [LocalRecordStore] contract that
/// 04 §3.2's apply pass needs: the apply cursor (`lastAppliedSeq`,
/// persisted exactly like `highWaterSeq`), the full-resync reset, and the
/// displaced-winner resurface for a push that loses server-side.
abstract interface class SyncRecordStore implements LocalRecordStore {
  /// The highest server seq already materialized into the domain stores.
  /// [BookmarkCoordinator.applyPulled] advances it only past records that
  /// were applied or superseded that round — never past a seen-but-deferred
  /// one, which a delta pull would never re-deliver.
  Future<int> lastAppliedSeq();

  /// Persist the apply cursor. Monotone: a lower value is ignored; the
  /// full-resync fallback zeroes it through [resetSyncCursors] instead.
  Future<void> setLastAppliedSeq(int seq);

  /// Zero both cursors (04 §3.1's one-time full-resync fallback: the next
  /// pull runs `since = 0` and `applyPulled` re-scans the lifetime set —
  /// every record a no-op tie or a real apply).
  Future<void> resetSyncCursors();

  /// The pulled winner a local edit displaced, restored when that edit's
  /// push is rejected: the server still holds this copy, so it is the true
  /// winner and the losing edit must not keep its slot (04 §3.2's
  /// "re-evaluation when the pending local rival next pushes — including
  /// the push-ties-or-LOSES case"). Returns the restored record, or null.
  Future<EncryptedRecord?> restoreDisplaced(String id);

  /// Every displaced pulled winner currently parked behind a dirty local
  /// rival — the apply pass reports these as deferred (their re-check is
  /// triggered by the rival's next push, not by the seq scan).
  Future<List<EncryptedRecord>> displacedRecords();
}

/// A [SyncApi] implementation throws this from `pull` when the server
/// rejects or has expired the `since` cursor (events pruned past
/// `highWaterSeq`, a stream reset). The coordinator's round treats it as
/// the one-time full-resync trigger (04 §3.1): reset both cursors and
/// re-pull from zero.
final class SyncCursorRejectedException implements Exception {
  const SyncCursorRejectedException([this.message = 'sync cursor rejected']);

  final String message;

  @override
  String toString() => 'SyncCursorRejectedException: $message';
}

/// The quarantine name for a corrupt record store at [path]: a UTC stamp
/// plus an existence-checked counter so a same-timestamp second corruption
/// cannot overwrite the first rescue copy — which may hold the only copy
/// of unpushed dirty edits (04 §3.1). Exposed for tests.
String recordStoreQuarantinePath(String path, DateTime now, int n) =>
    '$path.corrupt-${_stamp(now)}-$n';

String _stamp(DateTime now) => now
    .toUtc()
    .toIso8601String()
    .replaceAll('-', '')
    .replaceAll(':', '')
    .replaceAll('.', '');

/// A [SyncRecordStore] backed by one JSON file:
///
/// ```json
/// { "version": 1,
///   "highWaterSeq": 41,
///   "lastAppliedSeq": 40,
///   "records":   [ {"...EncryptedRecord json...", "dirty": false} ],
///   "displaced": [ {"...EncryptedRecord json..."} ] }
/// ```
///
/// Written atomically after every mutation through the house temp+rename
/// writer ([TransferJournalIo.atomicRewrite]). Tombstones are retained
/// indefinitely (04 §3.2 — no GC: any window risks resurrecting a deletion
/// through a long-offline device). A corrupt file is quarantined under a
/// unique per-occurrence name and the store restarts empty; the caller
/// surfaces the durable Settings → Backup notice and drives
/// [BookmarkCoordinator.reSealAfterStoreLoss]. A newer `version` fails
/// closed in place — data this build must not overwrite.
final class PersistentLocalRecordStore implements SyncRecordStore {
  PersistentLocalRecordStore({
    required String path,
    Future<void> Function(File target, String contents)? atomicWriter,
    DateTime Function()? now,
    void Function(Object, StackTrace)? onError,
  }) : // Keep the filesystem path immutable and private.
       // ignore: prefer_initializing_formals
       _file = File(path),
       _atomicWriter =
           atomicWriter ?? const TransferJournalIo().atomicRewrite,
       _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _onError = onError;

  static const _storeVersion = 1;

  final File _file;
  final Future<void> Function(File target, String contents) _atomicWriter;
  final DateTime Function() _now;
  final void Function(Object, StackTrace)? _onError;

  final _records = <String, EncryptedRecord>{};
  final _dirty = <String>{};

  /// The pulled winners a dirty local edit displaced (04 §3.2's deferred
  /// re-check): when the local rival's push is rejected, the server's copy
  /// is still this record — [restoreDisplaced] puts it back so the losing
  /// edit cannot keep the slot or the materialized row.
  final _displaced = <String, EncryptedRecord>{};

  int _highWaterSeq = 0;
  int _lastAppliedSeq = 0;

  /// Set when a corrupt file was quarantined during load — the durable
  /// recovery-notice seam (04 §3.1): the app reads it once to surface the
  /// "deleted bookmarks may reappear" warning and trigger the re-seal.
  String? quarantinedPath;

  Future<void>? _loadFuture;
  Future<void> _writeTail = Future.value();

  @override
  Future<List<EncryptedRecord>> allRecords() async {
    await _ensureLoaded();
    await _writeTail;
    return List.unmodifiable(_records.values);
  }

  @override
  Future<EncryptedRecord?> getRecord(String id) async {
    await _ensureLoaded();
    await _writeTail;
    return _records[id];
  }

  @override
  Future<List<EncryptedRecord>> displacedRecords() async {
    await _ensureLoaded();
    await _writeTail;
    return List.unmodifiable(_displaced.values);
  }

  /// A local change: marks dirty and persists. When it evicts a clean
  /// pulled winner that still out-tuples it, that winner is stashed in
  /// [_displaced] — the local edit will lose to it server-side (the server
  /// holds exactly that copy), and a rejected push must be able to put the
  /// true winner back rather than diverge with the edit stuck dirty.
  @override
  Future<void> putLocal(EncryptedRecord record) =>
      _mutate(() {
        final existing = _records[record.id];
        if (existing != null &&
            !_dirty.contains(record.id) &&
            identical(Lww.resolve(existing, record), existing)) {
          _displaced[record.id] = existing;
        }
        _records[record.id] = record;
        _dirty.add(record.id);
      });

  /// A pulled record: stored clean. Never overwrites a dirty local that
  /// beats it — and a remote that loses to a pending local becomes the
  /// displaced resurface candidate, since it is the copy the server holds.
  @override
  Future<void> putRemote(EncryptedRecord record) =>
      _mutate(() {
        final existing = _records[record.id];
        if (existing != null &&
            !identical(Lww.resolve(existing, record), record)) {
          if (_dirty.contains(record.id)) {
            _displaced[record.id] = record;
          }
          return;
        }
        _records[record.id] = record;
        _dirty.remove(record.id);
        // The just-pulled record is the server's current winner: any
        // stashed rival predates it and can never resurface.
        _displaced.remove(record.id);
      });

  @override
  Future<List<EncryptedRecord>> dirtyRecords() async {
    await _ensureLoaded();
    await _writeTail;
    return List.unmodifiable(_dirty.map((id) => _records[id]!));
  }

  /// The server accepted the push: stamp the assigned seq, clear dirty,
  /// and drop any displaced rival — it can never win now.
  @override
  Future<void> markSynced(String id, int seq) => _mutate(() {
        final record = _records[id];
        if (record != null) _records[id] = record.withSeq(seq);
        _dirty.remove(id);
        _displaced.remove(id);
      });

  @override
  Future<int> highWaterSeq() async {
    await _ensureLoaded();
    await _writeTail;
    return _highWaterSeq;
  }

  @override
  Future<void> setHighWaterSeq(int seq) => _mutate(() {
        if (seq > _highWaterSeq) _highWaterSeq = seq;
      });

  @override
  Future<int> lastAppliedSeq() async {
    await _ensureLoaded();
    await _writeTail;
    return _lastAppliedSeq;
  }

  @override
  Future<void> setLastAppliedSeq(int seq) => _mutate(() {
        if (seq > _lastAppliedSeq) _lastAppliedSeq = seq;
      });

  @override
  Future<void> resetSyncCursors() => _mutate(() {
        _highWaterSeq = 0;
        _lastAppliedSeq = 0;
      });

  @override
  Future<EncryptedRecord?> restoreDisplaced(String id) async {
    await _ensureLoaded();
    if (_displaced[id] == null) return null;
    EncryptedRecord? restored;
    await _mutate(() {
      restored = _displaced.remove(id);
      if (restored != null) {
        _records[id] = restored!;
        _dirty.remove(id);
      }
    });
    return restored;
  }

  /// Every mutation is serialized and persisted atomically before the
  /// call returns — a crash mid-round can lose at most the in-flight
  /// mutation, never a torn document. The queue heals on a failed write so
  /// one transient error cannot wedge later writes; the caller sees the
  /// failure.
  Future<void> _mutate(void Function() edit) {
    final operation = _writeTail.then((_) async {
      await _ensureLoaded();
      edit();
      await _write();
    });
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _ensureLoaded() {
    final activeLoad = _loadFuture;
    if (activeLoad != null) return activeLoad;

    final load = _load();
    _loadFuture = load;
    unawaited(
      load.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // A transient filesystem failure must not poison later reads.
          if (identical(_loadFuture, load)) _loadFuture = null;
        },
      ),
    );
    return load;
  }

  Future<void> _load() async {
    _records.clear();
    _dirty.clear();
    _displaced.clear();
    _highWaterSeq = 0;
    _lastAppliedSeq = 0;
    quarantinedPath = null;

    late final String? contents;
    await _file.parent.create(recursive: true);
    contents = await _file.exists() ? await _file.readAsString() : null;
    if (contents == null) return;

    Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } catch (error, stack) {
      // Quarantine throws when the bad file cannot be moved aside, so the
      // load fails instead of starting empty over bytes it could not read.
      await _quarantine();
      _report(error, stack);
      return;
    }

    if (decoded is! Map) {
      await _quarantine();
      _report(
        const FormatException('record store root'),
        StackTrace.current,
      );
      return;
    }

    final doc = decoded.cast<String, dynamic>();
    final version = doc['version'];
    if (version != null && version != _storeVersion) {
      throw FormatException('record store version $version');
    }

    final records = doc['records'];
    final highWater = doc['highWaterSeq'];
    final lastApplied = doc['lastAppliedSeq'];
    final displaced = doc['displaced'];
    if (records is! List ||
        (highWater != null && highWater is! int) ||
        (lastApplied != null && lastApplied is! int) ||
        (displaced != null && displaced is! List)) {
      await _quarantine();
      _report(
        const FormatException('record store root'),
        StackTrace.current,
      );
      return;
    }

    try {
      for (final entry in records) {
        _readEntry(entry as Map<String, dynamic>);
      }
      if (displaced is List) {
        for (final entry in displaced) {
          final record =
              EncryptedRecord.fromJson((entry as Map).cast<String, dynamic>());
          _displaced[record.id] = record;
        }
      }
    } catch (error, stack) {
      await _quarantine();
      _report(error, stack);
      _records.clear();
      _dirty.clear();
      _displaced.clear();
      return;
    }

    _highWaterSeq = highWater as int? ?? 0;
    _lastAppliedSeq = lastApplied as int? ?? 0;
  }

  void _readEntry(Map<String, dynamic> json) {
    final dirty = json.remove('dirty');
    final record = EncryptedRecord.fromJson(json);
    _records[record.id] = record;
    if (dirty == true) _dirty.add(record.id);
  }

  Future<void> _write() => _atomicWriter(
        _file,
        jsonEncode({
          'version': _storeVersion,
          'highWaterSeq': _highWaterSeq,
          'lastAppliedSeq': _lastAppliedSeq,
          'records': [
            for (final record in _records.values)
              {...record.toJson(), 'dirty': _dirty.contains(record.id)},
          ],
          if (_displaced.isNotEmpty)
            'displaced': [
              for (final record in _displaced.values) record.toJson(),
            ],
        }),
      );

  /// Moves a corrupt store aside under a unique `corrupt-<stamp>-<n>` name
  /// so a repeated corruption can never overwrite the first rescue copy.
  /// Throws when the file cannot be moved: starting empty over bytes this
  /// version could not read would let the next write destroy them.
  Future<void> _quarantine() async {
    for (var n = 0;; n++) {
      final target = recordStoreQuarantinePath(_file.path, _now(), n);
      if (File(target).existsSync()) continue;
      await _file.rename(target);
      quarantinedPath = target;
      return;
    }
  }

  void _report(Object error, StackTrace stack) {
    try {
      _onError?.call(error, stack);
    } catch (_) {
      // Error reporting must never create a second unhandled async error.
    }
  }
}
