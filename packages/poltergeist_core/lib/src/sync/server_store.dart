/// The shared-mode `serverConfig` domain store (04 §4.2, amended): the
/// writable half of the Séance server catalog. It persists the pinned
/// [ServerConfig] model to one JSON file — the exact shape the coordinator
/// seals into prefixless records — and tracks the materialized LWW tuple
/// per id so the apply pass can tell a genuinely newer pulled record from
/// a stale copy of what a pending local edit or tombstone supersedes.
///
/// The shape mirrors [FileBookmarkStore]'s: atomic temp+rename writes, a
/// serialized write tail, quarantine-on-corruption, skip-and-preserve for
/// records this build cannot decode, and `syncDeviceId` bound late so a
/// non-sync install keeps the clean on-disk shape. Servers carry no
/// sortKey — Séance derives list order from the records themselves
/// (groups alphabetical, rows label-sorted) — so there is nothing to
/// normalize on write.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:seance_core/seance_core.dart';

import '../bookmarks/bookmark_store.dart' show BookmarkSyncTuple;
import '../transfer/transfer_journal.dart' show TransferJournalIo;

/// The materialized LWW tuple for one server id — the same
/// `(updatedAt, deviceId, deleted)` envelope bookkeeping the bookmark
/// store keeps. A typedef, not a second class: the coordinator's tuple
/// guard and the tuple JSON shape are identical for both kinds.
typedef ServerSyncTuple = BookmarkSyncTuple;

/// The server store plus the sync bookkeeping the coordinator needs:
/// the per-row materialized tuples and the record-carrying apply/remove
/// variants that persist the winning envelope's tuple with the row.
abstract interface class SyncTrackingServerStore {
  /// Every stored server, sorted by (label, id) — the order the catalog
  /// presents and the order Séance's own store answers with.
  Future<List<ServerConfig>> load();

  Future<ServerConfig?> byId(String id);

  /// A local create or edit: re-stamps `updatedAt` to now — or one tick
  /// past the stored row when the clock runs behind a pulled stamp, the
  /// same protection [SecretVault.putLocalSecret] gives credentials — and
  /// persists with a local-authorship tuple. Returns the stored record.
  Future<ServerConfig> save(ServerConfig server);

  /// A local delete: drops the row and records a tombstone tuple stamped
  /// by [deletionStamp], which is what stops a stale pulled copy
  /// resurrecting the server before the tombstone record itself has
  /// pushed. False when absent.
  Future<bool> remove(String id);

  /// The tuple last materialized for [id], or null when nothing about
  /// the row's sync authorship is known.
  Future<ServerSyncTuple?> syncTupleOf(String id);

  /// Every materialized tuple, including tombstone tuples — the recovery
  /// path's re-seal set.
  Future<Map<String, ServerSyncTuple>> syncTuples();

  /// Materialize a pulled winner verbatim — the record carries its own
  /// stamps — under the envelope tuple that beat the previous state.
  Future<void> applySyncedRecord(
      ServerConfig server, ServerSyncTuple winner);

  /// Materialize a pulled tombstone: the row drops and the winning
  /// tombstone tuple persists so a stale live record cannot resurrect it.
  Future<void> removeSyncedRecord(String id, ServerSyncTuple tombstone);
}

/// A deletion stamp that beats every version of the record this device
/// has seen — max(now, prior + 1), Séance's `_deletionStamp` — so a
/// same-ms tie or a clock trailing a peer's last edit cannot let the
/// live copy win LWW over its own tombstone, while a peer's genuinely
/// newer edit still does. Null [prior] entries (a row already gone) fall
/// back to "now", the honest floor.
int deletionStamp({required DateTime now, required Iterable<int?> prior}) {
  var stamp = now.toUtc().millisecondsSinceEpoch;
  for (final seen in prior) {
    if (seen != null && seen >= stamp) stamp = seen + 1;
  }
  return stamp;
}

/// The quarantine name for a corrupt store at [path]: UTC ISO-8601 with
/// `-`, `:`, and `.` stripped, matching the other file stores.
String serverStoreQuarantinePath(String path, DateTime now) =>
    '$path.corrupt-${_quarantineStamp(now)}';

String _quarantineStamp(DateTime now) => now
    .toUtc()
    .toIso8601String()
    .replaceAll('-', '')
    .replaceAll(':', '')
    .replaceAll('.', '');

/// JSON-file persistence for the pinned [ServerConfig] model. See the
/// library doc — the failure posture is [FileBookmarkStore]'s exactly:
/// unreadable rethrows, corrupt quarantines, newer `version` fails in
/// place, undecodable records preserve verbatim so a newer build's
/// fields survive a local re-save.
final class FileServerConfigStore implements SyncTrackingServerStore {
  FileServerConfigStore({
    required String path,
    Future<void> Function(File target, String contents)? atomicWriter,
    DateTime Function()? now,
    void Function(Object, StackTrace)? onError,
    String? Function()? syncDeviceId,
  }) : // Keep the filesystem path immutable and private.
       // ignore: prefer_initializing_formals
       _file = File(path),
       _atomicWriter =
           atomicWriter ?? const TransferJournalIo().atomicRewrite,
       _now = now ?? DateTime.now,
       // Keep the callbacks private while allowing test-only injection.
       // ignore: prefer_initializing_formals
       _onError = onError,
       // ignore: prefer_initializing_formals
       _syncDeviceId = syncDeviceId;

  static const _versionKey = 'version';
  static const _serversKey = 'servers';
  static const _syncTuplesKey = 'syncTuples';
  static const _storeVersion = 1;

  final File _file;
  final Future<void> Function(File target, String contents) _atomicWriter;
  final DateTime Function() _now;
  final void Function(Object, StackTrace)? _onError;

  /// This install's sync device id, bound late like the bookmark store's:
  /// a null callback result leaves tuple writes out entirely so installs
  /// that never configure sync keep the clean document shape.
  final String? Function()? _syncDeviceId;

  final _servers = <String, ServerConfig>{};
  final _syncTuples = <String, ServerSyncTuple>{};

  /// Records that failed to decode, kept verbatim so a re-save cannot
  /// drop a server written by a newer Poltergeist or Séance.
  final _preserved = <Object?>[];

  Future<void>? _loadFuture;
  Future<void> _writeTail = Future.value();

  @override
  Future<List<ServerConfig>> load() async {
    await _ensureLoaded();
    // Read-your-writes: a load racing a queued write waits for the tail
    // (already error-healed) instead of returning pre-write state.
    await _writeTail;
    return List.unmodifiable(_sorted());
  }

  @override
  Future<ServerConfig?> byId(String id) async {
    await _ensureLoaded();
    await _writeTail;
    return _servers[id];
  }

  @override
  Future<ServerConfig> save(ServerConfig server) async {
    await _ensureLoaded();
    await _writeTail;
    // The stamp must outrank what the store already knows: a device
    // whose clock trails a pulled `updatedAt` would otherwise stamp its
    // own edit to *lose* against the copy it is editing.
    final stamp = max(
        _now().toUtc().millisecondsSinceEpoch,
        (_servers[server.id]?.updatedAt ?? 0) + 1);
    final stored = server.copyWith(updatedAt: stamp);
    await _writeNext(
      (next) => next[stored.id] = stored,
      syncEdit: (tuples) {
        final tuple = _localTuple(stamp);
        if (tuple != null) tuples[stored.id] = tuple;
      },
    );
    return stored;
  }

  @override
  Future<bool> remove(String id) async {
    await _ensureLoaded();
    await _writeTail;
    if (!_servers.containsKey(id)) return false;
    var removed = false;
    // Stamped past every version this store has seen — max(now, prior +
    // 1), the rule save() uses: a bare "now" on a clock trailing the
    // row's pulled stamp would lose LWW to the very copy it deletes and
    // resurrect the server. A peer's genuinely newer edit still wins.
    final tombstone = _localTombstone(deletionStamp(
        now: _now(),
        prior: [_servers[id]?.updatedAt, _syncTuples[id]?.updatedAt]));
    await _writeNext(
      (next) {
        removed = next.remove(id) != null;
      },
      syncEdit: (tuples) {
        if (removed && tombstone != null) tuples[id] = tombstone;
      },
    );
    return removed;
  }

  @override
  Future<void> applySyncedRecord(
      ServerConfig server, ServerSyncTuple winner) async {
    await _ensureLoaded();
    await _writeNext(
      (next) => next[server.id] = server,
      syncEdit: (tuples) => tuples[server.id] = winner,
    );
  }

  @override
  Future<void> removeSyncedRecord(
      String id, ServerSyncTuple tombstone) async {
    await _ensureLoaded();
    await _writeTail;
    // Idempotency: a re-pulled tombstone that already matches the
    // materialized state must not trigger another disk write.
    if (!_servers.containsKey(id) && _syncTuples[id] == tombstone) return;
    await _writeNext(
      (next) => next.remove(id),
      syncEdit: (tuples) => tuples[id] = tombstone,
    );
  }

  @override
  Future<ServerSyncTuple?> syncTupleOf(String id) async {
    await _ensureLoaded();
    await _writeTail;
    return _syncTuples[id];
  }

  @override
  Future<Map<String, ServerSyncTuple>> syncTuples() async {
    await _ensureLoaded();
    await _writeTail;
    return Map.unmodifiable(_syncTuples);
  }

  /// The tuple a local write materializes: the row's stamp under this
  /// install's device id — the same tuple the coordinator seals into the
  /// record, so store and record never disagree on authorship.
  ServerSyncTuple? _localTuple(int updatedAtMs) {
    final deviceId = _syncDeviceId?.call();
    if (deviceId == null) return null;
    return ServerSyncTuple(updatedAt: updatedAtMs, deviceId: deviceId);
  }

  ServerSyncTuple? _localTombstone(int updatedAtMs) {
    final deviceId = _syncDeviceId?.call();
    if (deviceId == null) return null;
    return ServerSyncTuple(
      updatedAt: updatedAtMs,
      deviceId: deviceId,
      deleted: true,
    );
  }

  List<ServerConfig> _sorted() => _servers.values.toList()
    ..sort((a, b) {
      final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
    });

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

  /// One serialized mutation — [FileBookmarkStore._writeNext]'s shape:
  /// the edit mutates a copy, the file write lands before the in-memory
  /// swap (a failed write leaves state intact), and the sync-tuple edit
  /// joins the same atomic document so row and tuple can never diverge
  /// on disk.
  Future<Map<String, ServerConfig>> _writeNext(
    void Function(Map<String, ServerConfig> next) edit, {
    void Function(Map<String, ServerSyncTuple> tuples)? syncEdit,
  }) {
    final operation = _writeTail.then((_) async {
      final next = Map<String, ServerConfig>.of(_servers);
      final nextTuples = Map<String, ServerSyncTuple>.of(_syncTuples);
      edit(next);
      syncEdit?.call(nextTuples);
      await _write(next, nextTuples);
      _servers
        ..clear()
        ..addAll(next);
      _syncTuples
        ..clear()
        ..addAll(nextTuples);
      return next;
    });
    // The calling service owns write-error reporting; this only heals
    // the queue so one failure cannot wedge every later write.
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _load() async {
    // A retried load (a previous attempt failed on the read) must start
    // from a clean slate so partially populated state can never be
    // double-appended.
    _servers.clear();
    _preserved.clear();
    _syncTuples.clear();

    // Read failures propagate: the store must not overwrite data it
    // could not read.
    await _file.parent.create(recursive: true);
    final contents = await _file.exists() ? await _file.readAsString() : null;
    if (contents == null) return;

    Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } catch (error, stack) {
      // Quarantine throws when the bad file cannot be moved aside, so
      // the load fails instead of starting empty over bytes it could
      // not read.
      await _quarantine();
      _report(error, stack);
      return;
    }

    if (decoded is! Map) {
      await _quarantine();
      _report(
        const FormatException('server store root'),
        StackTrace.current,
      );
      return;
    }

    // A newer store format is data this version must not overwrite:
    // fail in place like an unreadable file.
    final version = decoded[_versionKey];
    if (version != null && version != _storeVersion) {
      throw FormatException('server store version $version');
    }

    if (decoded[_serversKey] is! List) {
      await _quarantine();
      _report(
        const FormatException('server store root'),
        StackTrace.current,
      );
      return;
    }

    for (final record in decoded[_serversKey] as List) {
      final server = _decode(record);
      if (server == null) {
        _preserved.add(record);
      } else {
        _servers[server.id] = server;
      }
    }

    // The tuple map is auxiliary, rebuildable bookkeeping (the record
    // store is the merge authority), so a malformed entry is dropped
    // rather than quarantining the whole document over it — reported,
    // so silent sync-state loss stays diagnosable.
    final tuples = decoded[_syncTuplesKey];
    if (tuples is Map) {
      for (final entry in tuples.entries) {
        final id = entry.key;
        final tuple = ServerSyncTuple.fromJson(entry.value);
        if (id is String && tuple != null) {
          _syncTuples[id] = tuple;
        } else {
          _report(
            FormatException('dropped malformed sync tuple for $id'),
            StackTrace.current,
          );
        }
      }
    }
  }

  /// Decodes one stored record; null when it cannot be trusted — the
  /// skip-and-preserve posture: never throw away a record this version
  /// does not understand.
  ServerConfig? _decode(Object? record) {
    if (record is! Map) return null;
    final json = record.cast<String, dynamic>();
    final id = json['id'];
    if (id is! String) return null;
    try {
      return ServerConfig.fromJson(json);
    } on Object {
      return null;
    }
  }

  Future<void> _write(
    Map<String, ServerConfig> servers,
    Map<String, ServerSyncTuple> tuples,
  ) {
    final sorted = servers.values.toList()
      ..sort((a, b) {
        final byLabel =
            a.label.toLowerCase().compareTo(b.label.toLowerCase());
        return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
      });
    return _atomicWriter(
      _file,
      jsonEncode({
        _versionKey: _storeVersion,
        _serversKey: [
          for (final server in sorted) server.toJson(),
          ..._preserved,
        ],
        // Omitted while empty so an install that never configures sync
        // keeps writing the exact clean document shape.
        if (tuples.isNotEmpty)
          _syncTuplesKey: {
            for (final entry in tuples.entries)
              entry.key: entry.value.toJson(),
          },
      }),
    );
  }

  /// Moves a corrupt store aside so a bad file cannot wedge startup.
  /// Throws when the file cannot be moved: starting empty over bytes
  /// this version could not read would let the next save overwrite them.
  Future<void> _quarantine() =>
      _file.rename(serverStoreQuarantinePath(_file.path, _now()));

  void _report(Object error, StackTrace stack) {
    try {
      _onError?.call(error, stack);
    } catch (_) {
      // Error reporting must never create a second unhandled async error.
    }
  }
}
