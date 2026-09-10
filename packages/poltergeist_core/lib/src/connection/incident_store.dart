import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'pool_key.dart';

/// One persisted trust incident (owner decision 2026-09-09, option 2a):
/// a declined changed-key block, stored device-local so it survives app
/// restarts (D19: nothing leaves the device).
///
/// Records are keyed by the bookmark-derived [serverId] — deleting a
/// bookmark cascades deletion of its record (3a). The endpoint identity
/// fields re-associate the record with the pool it blocks; two bookmarks
/// sharing a server each carry their own record, and the endpoint stays
/// blocked while any of them exists.
final class IncidentRecord {
  /// Bookmark-derived server identity — the cascade key.
  final String serverId;

  /// Endpoint identity, verbatim as the bookmark's config carried it.
  final String host;
  final int port;
  final String username;

  /// D10 seam: carried so a jump-hosted endpoint keys separately, never
  /// executed here.
  final String? jumpHostId;

  /// Fingerprint of the declined (changed) key.
  final String presentedFingerprintSha256;

  /// Fingerprint of the key pinned at decline time — the block detail's
  /// "pinned" half. Null when no pin existed.
  final String? pinnedFingerprintSha256;

  const IncidentRecord({
    required this.serverId,
    required this.host,
    required this.port,
    required this.username,
    this.jumpHostId,
    required this.presentedFingerprintSha256,
    this.pinnedFingerprintSha256,
  });

  /// The endpoint identity in normalized pool-key form — [PoolKey.normalize],
  /// the single factory configs key through, so a record written from one
  /// bookmark re-keys under the pool its siblings share.
  PoolKey get poolKey => PoolKey.normalize(
    host: host,
    port: port,
    username: username,
    jumpHostId: jumpHostId,
  );

  /// Strict decode: wrong-typed or out-of-range fields throw instead of
  /// half-loading (04 §2.1's decode posture, applied to the incident
  /// records the store persists).
  factory IncidentRecord.fromJson(Map<String, Object?> json) {
    final serverId = json['serverId'];
    final host = json['host'];
    final port = json['port'];
    final username = json['username'];
    final jumpHostId = json['jumpHostId'];
    final presented = json['presentedFingerprintSha256'];
    final pinned = json['pinnedFingerprintSha256'];
    if (serverId is! String ||
        serverId.isEmpty ||
        host is! String ||
        host.trim().isEmpty ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        username is! String ||
        username.trim().isEmpty ||
        (jumpHostId != null && jumpHostId is! String) ||
        presented is! String ||
        presented.isEmpty ||
        (pinned != null && (pinned is! String || pinned.isEmpty))) {
      throw const FormatException('Malformed incident record.');
    }
    return IncidentRecord(
      serverId: serverId,
      host: host,
      port: port,
      username: username,
      jumpHostId: jumpHostId as String?,
      presentedFingerprintSha256: presented,
      pinnedFingerprintSha256: pinned as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'serverId': serverId,
    'host': host,
    'port': port,
    'username': username,
    'jumpHostId': jumpHostId,
    'presentedFingerprintSha256': presentedFingerprintSha256,
    'pinnedFingerprintSha256': pinnedFingerprintSha256,
  };

  @override
  bool operator ==(Object other) =>
      other is IncidentRecord &&
      other.serverId == serverId &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.jumpHostId == jumpHostId &&
      other.presentedFingerprintSha256 == presentedFingerprintSha256 &&
      other.pinnedFingerprintSha256 == pinnedFingerprintSha256;

  @override
  int get hashCode => Object.hash(
    serverId,
    host,
    port,
    username,
    jumpHostId,
    presentedFingerprintSha256,
    pinnedFingerprintSha256,
  );

  @override
  String toString() =>
      'IncidentRecord($serverId, $host:$port, presented '
      '$presentedFingerprintSha256, pinned $pinnedFingerprintSha256)';
}

/// Persistence seam for declined trust incidents. The pool consumes it
/// through the manager; the engine wiring slice supplies the concrete
/// store (the app owns storage). Implementations must be fail-safe on
/// load: an unreadable or absent store reads as no incidents — never a
/// crash, never auto-trust.
///
/// Mutations to the same record must observe issue order: the manager
/// issues puts and removes without awaiting them, and a remove issued
/// after a newer put of the same serverId must never overtake it (the
/// shipped stores serialize internally).
abstract interface class IncidentStore {
  Future<List<IncidentRecord>> load();

  /// Upserts by [IncidentRecord.serverId].
  Future<void> put(IncidentRecord record);

  /// Deletes the stored record under [serverId] only when it belongs to
  /// [endpoint]: a bookmark re-pointed to a new endpoint keeps its new
  /// endpoint's record when an old endpoint's block lifts, while a stale
  /// payload of the same endpoint (a failed re-write) is still removed.
  Future<void> removeFor(String serverId, PoolKey endpoint);

  /// Deletes every record owned by [serverId] — the bookmark-deletion
  /// cascade (3a), where the whole bookmark is gone.
  Future<void> removeAllFor(String serverId);
}

/// Session-only store (tests and the not-yet-wired engine default).
class InMemoryIncidentStore implements IncidentStore {
  final Map<String, IncidentRecord> _records = {};

  @override
  Future<List<IncidentRecord>> load() async => List.of(_records.values);

  @override
  Future<void> put(IncidentRecord record) async {
    _records[record.serverId] = record;
  }

  @override
  Future<void> removeFor(String serverId, PoolKey endpoint) async {
    final stored = _records[serverId];
    if (stored == null || stored.poolKey != endpoint) return;
    _records.remove(serverId);
  }

  @override
  Future<void> removeAllFor(String serverId) async {
    _records.remove(serverId);
  }
}

/// JSON-file [IncidentStore]. Writes are atomic (temp + rename) and
/// owner-only (0600) on desktop POSIX; Windows and mobile rely on their
/// per-user storage ACLs — the same conventions as the app-layer ported
/// file stores. Mutations serialize through one chain so concurrent
/// unawaited writes from the pool cannot interleave read-modify-write
/// flushes (03 §6's single-writer discipline for persisted stores).
///
/// Serialization is per instance: construct exactly one [FileIncidentStore]
/// per file — two instances over the same path race read-modify-write
/// flushes and lose each other's records. A file lock would not close that:
/// `dart:io`'s locks are per-process on POSIX, so two instances in one
/// process still race (STATUS records the measurement and the deferral).
class FileIncidentStore implements IncidentStore {
  final File file;

  /// Observes load failures (an unreadable file, a quarantined corrupt one)
  /// without changing the fail-safe result: the load still reads empty. The
  /// wiring slice surfaces a local notice through this hook — it is
  /// diagnostics, never telemetry (D19). Observer errors cannot break the
  /// load.
  final void Function(Object error)? onLoadError;

  final Map<String, IncidentRecord> _records = {};
  Future<void> _pending = Future<void>.value();
  bool _loaded = false;

  FileIncidentStore(this.file, {this.onLoadError});

  Future<void> _loadInner() async {
    if (_loaded) return;
    // Startup sweep: a crash mid-write can leave a `.tmp-*` file behind.
    // Only temps old enough to be abandoned go — a concurrent writer's
    // temp, in this process or another, must survive a reader's load.
    await _sweepOrphanedTemps(file);
    if (await file.exists()) {
      // Unreadable ≠ corrupt: a transient read failure (permissions, a
      // backup lock, EIO) rethrows and leaves the valid file in place so
      // a later session still loads it — only undecodable content
      // quarantines. Callers that must stay fail-safe (load) catch it.
      final bytes = await file.readAsBytes();
      final String contents;
      try {
        contents = utf8.decode(bytes);
      } on FormatException catch (error) {
        // Invalid UTF-8 is a torn write's artifact (a crash mid-character),
        // not a readable file: quarantine like any other corruption.
        _records.clear();
        await _quarantineCorruptFile(file);
        _reportLoadError(error);
        _loaded = true;
        return;
      }
      try {
        final list = jsonDecode(contents) as List;
        for (final entry in list) {
          final record = IncidentRecord.fromJson(
            (entry as Map).cast<String, Object?>(),
          );
          _records[record.serverId] = record;
        }
      } catch (error) {
        // Fail-safe: a corrupt store means no persisted incidents —
        // never a crash, never auto-trust. The corrupt file is moved
        // aside (best effort) so the evidence survives and a fresh write
        // cannot be confused with it.
        _records.clear();
        await _quarantineCorruptFile(file);
        _reportLoadError(error);
      }
    }
    _loaded = true;
  }

  Future<void> _flush() async {
    final contents = jsonEncode([
      for (final record in _records.values) record.toJson(),
    ]);
    await _writeAtomically(file, contents);
  }

  @override
  Future<List<IncidentRecord>> load() => _serialized(() async {
    try {
      await _loadInner();
    } on FileSystemException catch (error) {
      // The interface's fail-safe contract: unreadable reads as empty
      // for this session — the file stays intact for a later one.
      _reportLoadError(error);
      return const [];
    }
    return List.of(_records.values);
  });

  @override
  Future<void> put(IncidentRecord record) => _serialized(() async {
    await _loadInner();
    _records[record.serverId] = record;
    await _flush();
  });

  @override
  Future<void> removeFor(String serverId, PoolKey endpoint) =>
      _serialized(() async {
        await _loadInner();
        final stored = _records[serverId];
        if (stored == null || stored.poolKey != endpoint) return;
        _records.remove(serverId);
        await _flush();
      });

  @override
  Future<void> removeAllFor(String serverId) => _serialized(() async {
    await _loadInner();
    if (_records.remove(serverId) == null) return;
    await _flush();
  });

  /// Runs one operation after every mutation queued before it, and keeps
  /// the chain alive when an operation fails — a failed write must not
  /// wedge the store for later callers.
  Future<T> _serialized<T>(Future<T> Function() operation) {
    final run = _pending.then((_) => operation());
    _pending = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Observer errors cannot replace or interrupt the fail-safe load.
  void _reportLoadError(Object error) {
    try {
      onLoadError?.call(error);
    } on Object {
      // The observer is diagnostics, not control flow.
    }
  }
}

/// How old a `.tmp-*` file must be before the sweep treats it as a crashed
/// process's litter. One atomic write creates, fills, and renames its temp
/// within milliseconds, so this bound sits orders of magnitude above any
/// write in flight — in this process or another. A sweep without it deletes
/// a concurrent writer's temp and fails its write (observed: a second store
/// instance reading while the first persisted).
const _abandonedTempAge = Duration(hours: 1);

/// Deletes this target's orphaned `.tmp-*` files (parity with the ported
/// atomic-file helper's crash posture). Best-effort: a failed sweep must not
/// break loading, and a temp that is too young or undeletable is swept on a
/// later startup.
Future<void> _sweepOrphanedTemps(File target) async {
  // Resolve once: a directory listing yields parent-joined paths, so a bare
  // relative target ('incidents.json', parent '.') would never match its own
  // temps ('./incidents.json.tmp-…') and the sweep would silently do nothing.
  final resolved = target.absolute;
  final prefix = '${resolved.path}.tmp-';
  final abandonedBefore = DateTime.now().subtract(_abandonedTempAge);
  try {
    final parent = resolved.parent;
    if (!await parent.exists()) return;
    await for (final entry in parent.list(followLinks: false)) {
      if (entry is! File) continue;
      // Scoped to this target: a sibling store's temp belongs to its own
      // sweep, and may belong to a write in flight right now.
      if (!entry.path.startsWith(prefix)) continue;

      final DateTime modified;
      try {
        modified = await entry.lastModified();
      } on Object {
        // An unreadable mtime is not proof of abandonment.
        continue;
      }
      // A future stamp (a clock step) reads as young, so it stays too.
      if (modified.isAfter(abandonedBefore)) continue;

      try {
        await entry.delete();
      } on Object {
        // Best-effort: a temp we cannot delete is retried next startup.
      }
    }
  } on Object {
    // The sweep is hygiene; the load must still proceed.
  }
}

Future<void> _writeAtomically(File target, String contents) async {
  await target.parent.create(recursive: true);

  // Temp + rename, so a crash mid-write leaves the previous file intact.
  final temporary = await _createExclusiveTemp(target);
  try {
    // Restrict the empty file before contents become visible.
    await _restrictToOwner(temporary);
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(target.path);
  } on Object {
    // Cleanup is best-effort so it cannot hide the persistence failure.
    try {
      if (await temporary.exists()) await temporary.delete();
    } on Object {
      // The original write or rename failure is the actionable error.
    }
    rethrow;
  }
}

const _tempNameRetries = 3;

/// Exclusive creation with a random suffix; collisions are essentially
/// impossible, and the bounded retry makes even them harmless.
Future<File> _createExclusiveTemp(File target) async {
  for (var attempt = 0; attempt < _tempNameRetries; attempt++) {
    final temporary = File('${target.path}.tmp-${_randomHexSuffix()}');
    try {
      await temporary.create(exclusive: true);
      return temporary;
    } on PathExistsException {
      if (attempt + 1 == _tempNameRetries) rethrow;
    }
  }
  // The loop returns or rethrows on its final attempt.
  throw StateError('Exhausted temp-file retries without an outcome.');
}

String _randomHexSuffix() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(16).toRadixString(16));
  }
  return buffer.toString();
}

/// Owner-only mode bits (0600) on desktop POSIX, mirroring the app-layer
/// port's posture. A failed or unavailable chmod aborts the write: the
/// record either lands owner-only or not at all.
Future<void> _restrictToOwner(File file) async {
  if (!Platform.isLinux && !Platform.isMacOS) return;
  ProcessResult result;
  try {
    result = await Process.run('chmod', ['--', '600', file.path]);
  } on ProcessException catch (error) {
    throw FileSystemException(
      'chmod is unavailable; cannot restrict the incident store to the '
      'owner (${error.message})',
      file.path,
    );
  }
  if (result.exitCode != 0) {
    throw FileSystemException(
      'Could not restrict the incident store to the owner.',
      file.path,
    );
  }
}

/// Moves a corrupt store aside with a UTC stamp (a repeated corruption
/// never overwrites the previous evidence); best-effort — if it cannot be
/// moved, the caller still starts empty.
Future<void> _quarantineCorruptFile(File file) async {
  try {
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll('-', '')
        .replaceAll(':', '')
        .replaceAll('.', '');
    await file.rename('${file.path}.corrupt-$stamp');
  } catch (_) {
    // Best effort: if we can't move it aside, the caller still starts empty.
  }
}
