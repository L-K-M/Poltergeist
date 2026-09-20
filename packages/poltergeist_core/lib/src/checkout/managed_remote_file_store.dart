import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:seance_core/seance_core.dart';

import '../fs/local_fs_safety.dart';
import '../transfer/transfer_journal.dart';
import 'managed_remote_file.dart';

// Ported from Séance
// app/seance_app/lib/services/managed_remote_file_store.dart @ 2e6d1f1
// with the Poltergeist lifecycle hardening 06 §3.2/§3.7 require
// (generation epochs, abandoned markers, the safe sweep carve-out,
// the cross-process lock, upload snapshots, and the recovered-file
// listing); see docs/PORTS.md.

const _indexVersion = 1;

/// Computes a SHA-256 without loading the checkout into memory.
Future<String> streamedFileSha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// A payload-bearing checkout directory the index lost track of (06 §3.7's
/// recovered-edit surface): the dir kept its plaintext but no record
/// names it, so it is preserved for explicit review — never silently
/// deleted, never silently uploadable.
final class RecoveredCheckout {
  const RecoveredCheckout({
    required this.directory,
    required this.files,
    required this.totalBytes,
  });

  /// The checkout-root-relative directory key (the record id's hash).
  final String directory;

  /// The preserved payload names inside [directory] (checkout files and
  /// anything else a foreign writer left — markers excluded).
  final List<String> files;
  final int totalBytes;
}

/// Durable local index and checkout lifecycle for externally edited files.
///
/// The caller supplies app-support locations so platform path lookup remains
/// at the composition boundary and tests can use isolated temporary
/// directories.
///
/// Poltergeist lifecycle rules layered on the Séance port (06 §3.2):
///
/// - A fresh unique [generation] per store lifecycle stamps each new
///   checkout directory's `.poltergeist-epoch` marker; the load-time
///   sweep deletes only directories still carrying the
///   `.poltergeist-abandoned` in-flight marker (a crash mid-checkout —
///   no record ever committed) or directories that carry no payload
///   (markers alone don't count). Every other unindexed directory —
///   old-epoch or markerless — is preserved and surfaced through
///   [listRecovered].
/// - `createUploadSnapshot` writes the upload's frozen content next to
///   the checkout as `<name>.poltergeist-<uuid>.upload`; a load sweep
///   removes those exact generated siblings (plus `.edit`/`.backup`
///   shapes) from indexed dirs — never a bare `.poltergeist-` prefix,
///   so a real file named `.poltergeist-notes` is untouched.
/// - The whole store sits behind a cross-process exclusive lock file so
///   a second instance fails fast instead of racing the index.
class ManagedRemoteFileStore {
  /// The epoch marker inside each managed checkout directory: its content
  /// is the creating lifecycle's [generation].
  static const String epochMarkerName = '.poltergeist-epoch';

  /// The in-flight marker [prepareCheckout] drops and [clearCheckoutInFlight]
  /// removes once the record commits; a directory still carrying it at load
  /// was abandoned mid-checkout and is swept wholesale.
  static const String abandonedMarkerName = '.poltergeist-abandoned';

  /// Generated temp names the watchers must ignore and the load sweep may
  /// delete — exactly the shapes this codebase mints: the upload/edit/
  /// backup siblings (`<name>.poltergeist-<token>.<kind>`) and the
  /// local-filesystem's pipe temps (`.poltergeist-<8 hex>.tmp`), where the
  /// token is a uuid or the safety layer's 8-hex shape. Deliberately NOT a
  /// `.poltergeist-` prefix match — a checkout file legitimately named
  /// `.poltergeist-notes` must stay watchable, and a checkout name that
  /// happens to carry the generated shape is still reconciled because the
  /// watch filter never applies it to the record's own basename (06 §3.3).
  static final RegExp generatedTempName = RegExp(
    r'\.poltergeist-[0-9a-f-]{8,36}\.(upload|edit|backup|tmp)$',
  );

  /// The cross-process store lock, next to the index file.
  static String lockPathFor(File indexFile) => '${indexFile.path}.lock';

  final File indexFile;
  final Directory checkoutRoot;

  /// Unique per store lifecycle — stamped into new epoch markers so a
  /// load-time sweep can tell "created by this generation" from
  /// "survived an earlier one" (06 §3.2).
  final String generation;

  /// The atomic-writer seam shared with the transfer journal and the
  /// record stores (temp + fsync + rename + dir fsync). The managed
  /// index always writes owner-only (06 §3.1 — it maps the remote paths
  /// the user edits); the flag is part of the seam so an injected writer
  /// sees the requirement.
  final Future<void> Function(
    File target,
    String contents, {
    bool restrictToOwner,
  })
  _atomicWriter;

  /// Injectable for tests; defaults to the system clock.
  final DateTime Function() _now;

  /// The held exclusive lock — null until the first serialized operation
  /// opens it, and only when [useLock] is on.
  RandomAccessFile? _lockFile;
  final bool useLock;

  final Map<String, ManagedRemoteFile> _files = {};
  Future<void> _operationTail = Future<void>.value();
  bool _loaded = false;
  bool _closed = false;

  /// Preserved unindexed directories observed at load — the §3.7
  /// recovered-edit surface. Recomputed by [listRecovered].
  List<RecoveredCheckout> _recovered = const [];

  ManagedRemoteFileStore({
    required this.indexFile,
    required this.checkoutRoot,
    String? generation,
    this.useLock = true,
    this.saveTempWindow = const Duration(milliseconds: 600),
    Future<void> Function(File target, String contents, {bool restrictToOwner})?
    atomicWriter,
    DateTime Function()? now,
  }) : generation = generation ?? uuidV4(),
       _atomicWriter = atomicWriter ?? const TransferJournalIo().atomicRewrite,
       _now = now ?? DateTime.now;

  /// The in-flight-save guard window (06 §2.1 step 5): a `.edit`/
  /// `.backup` sibling touched within this span may belong to a save
  /// still executing — the reconcile sweep leaves it alone so a
  /// reconcile running mid-save can neither reap a live temp nor
  /// crash-recover a live `.backup`. Matches §3.3's watch debounce.
  final Duration saveTempWindow;

  /// The lock's identity for callers that report it (diagnostics only).
  File get lockFile => File(lockPathFor(indexFile));

  /// Preserved unindexed checkout directories from the last load/list.
  List<RecoveredCheckout> get recovered => List.unmodifiable(_recovered);

  /// Returns a stable root-relative path for a checkout. Hashing [id] avoids
  /// treating externally supplied identifiers as filesystem path components.
  ///
  /// The sanitizer's contract is pinned by 06 §3.1 and diverges from
  /// Séance's helper in two recorded ways (PORTS.md): a Windows reserved
  /// device name keeps its extension under a `file-` prefix (`nul.conf` →
  /// `file-nul.conf`) instead of collapsing to a fixed replacement —
  /// matched case-insensitively on the stem before the first dot against
  /// the full 09 §3.5 reserved list (CONIN$/CONOUT$/CLOCK$ and the
  /// superscript COM¹–³/LPT¹–³ spellings included) — and an overlong name
  /// is truncated to the 255-byte NAME_MAX floor on a codepoint boundary
  /// rather than failing the checkout with a raw OS error. Truncation
  /// collisions are harmless: the hash-keyed directory is unique per
  /// record.
  String checkoutPathFor({required String id, required String fileName}) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty');
    final directory = sha256.convert(utf8.encode(id)).toString();
    var safeName = fileName.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_');
    safeName = safeName.replaceFirst(RegExp(r'[. ]+$'), '_');
    if (safeName.isEmpty || safeName == '.' || safeName == '..') {
      safeName = 'remote-file';
    }
    // Win32 ignores trailing dots and spaces in the stem ('aux .txt' is
    // as reserved as 'aux.txt'), so strip them before the match — the
    // same pre-match normalization [validateLocalName] applies.
    final stem = safeName.split('.').first.replaceAll(RegExp(r'[ .]+$'), '');
    if (windowsReservedName.hasMatch(stem)) {
      safeName = 'file-$safeName';
    }
    return '$directory/${_truncateToNameMax(safeName)}';
  }

  /// Resolves a validated relative identity without touching the filesystem.
  File checkoutFile(String localPath) {
    final segments = _validateRelativePath(localPath);
    final file = File(_join(checkoutRoot.absolute.path, segments));
    if (file.absolute.path == indexFile.absolute.path) {
      throw ArgumentError.value(
        localPath,
        'localPath',
        'Must not resolve to the index file',
      );
    }
    return file;
  }

  /// The absolute directory a checkout's watcher subscribes to — the
  /// parent of [checkoutFile], watched rather than the file itself so
  /// atomic-replacement saves are observed (06 §3.3).
  Directory checkoutDirectory(String localPath) =>
      checkoutFile(localPath).parent;

  /// Creates the checkout's containing directory and drops the lifecycle
  /// markers 06 §3.2 prescribes BEFORE the payload exists: the epoch
  /// stamp (this lifecycle's [generation]) and the abandoned marker a
  /// crash mid-download leaves behind for the load-time sweep.
  Future<void> prepareCheckout(String localPath) => _serialized(() async {
    await _loadUnlocked();
    final segments = _validateRelativePath(localPath);
    await _ensureSafeParents(localPath);
    final dir = checkoutFile(localPath).parent;
    await File(
      _join(dir.path, const [epochMarkerName]),
    ).writeAsString(generation);
    // The abandoned marker rides every new checkout dir; dirs being
    // reused for a second checkout of the same id are not re-marked,
    // and a dir already holding payload (a preserved recovered dir)
    // must never be marked — the load sweep would delete that payload
    // wholesale.
    if (segments.length > 1) {
      final marker = File(_join(dir.path, const [abandonedMarkerName]));
      if (!await marker.exists() && !await _dirHasPayload(dir)) {
        await marker.create();
      }
    }
  });

  /// True when [dir] holds anything beyond the lifecycle markers — the
  /// recovered-payload test [prepareCheckout] must not re-mark over.
  Future<bool> _dirHasPayload(Directory dir) async {
    if (await FileSystemEntity.type(dir.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    await for (final child in dir.list(followLinks: false)) {
      final name = p.basename(child.path);
      if (name == epochMarkerName || name == abandonedMarkerName) {
        continue;
      }
      return true;
    }
    return false;
  }

  /// The record write landed — the checkout dir is a completed managed
  /// checkout, no longer a crash-sweeptable in-flight one.
  Future<void> clearCheckoutInFlight(String localPath) => _serialized(() async {
    await _loadUnlocked();
    final marker = File(
      _join(checkoutFile(localPath).parent.path, const [abandonedMarkerName]),
    );
    if (await marker.exists()) await marker.delete();
  });

  /// Creates a new empty checkout file without following existing symlinks.
  Future<File> createCheckout(String localPath, {bool exclusive = true}) =>
      _serialized(() async {
        await _loadUnlocked();
        final file = checkoutFile(localPath);
        await _ensureSafeParents(localPath);
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type != FileSystemEntityType.notFound) {
          if (type != FileSystemEntityType.file || exclusive) {
            throw FileSystemException(
              'Checkout path already exists',
              file.path,
            );
          }
          return file;
        }

        await file.create(exclusive: true);
        final createdType = await FileSystemEntity.type(
          file.path,
          followLinks: false,
        );
        if (createdType != FileSystemEntityType.file) {
          throw FileSystemException(
            'Checkout path is not a regular file',
            file.path,
          );
        }
        return file;
      });

  /// The frozen upload content (06 §3.4): a `<name>.poltergeist-<uuid>.upload`
  /// sibling copy made while the record lock is held, so the queued upload
  /// reads bytes that cannot be edited mid-transfer — and so the
  /// reconciliation's "dirty while uploading" question compares the
  /// live checkout against the frozen digest.
  Future<File> createUploadSnapshot(String localPath) => _serialized(() async {
    await _loadUnlocked();
    final source = checkoutFile(localPath);
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('Checkout file does not exist', source.path);
    }
    final snapshot = File('${source.path}.poltergeist-${uuidV4()}.upload');
    // A frozen plaintext copy of private content — the same 0600 the
    // checkout file itself carries (06 §3.1). Restrict before copying so
    // the plaintext is never on disk with looser permissions; File.copy
    // truncates the destination without resetting its mode.
    await snapshot.create(exclusive: true);
    await restrictLocalPathPermissions(snapshot.path, '600');
    await source.copy(snapshot.path);
    return snapshot;
  });

  /// Deletes only the validated checkout and then prunes empty directories.
  /// A symlink at the final path is unlinked; it is never followed.
  Future<void> deleteCheckout(String localPath) =>
      _serialized(() => _deleteCheckoutUnlocked(localPath));

  /// Removes a preserved recordless directory wholesale — the explicit
  /// "discard recovered plaintext" verb. The [directory] identity is a
  /// single validated segment; nothing outside [checkoutRoot] can be
  /// named through it.
  Future<void> deleteRecovered(String directory) => _serialized(() async {
    await _loadUnlocked();
    final segments = _validateRelativePath(directory);
    if (segments.length != 1) {
      throw ArgumentError.value(
        directory,
        'directory',
        'Must be a single checkout directory',
      );
    }
    final dir = Directory(_join(checkoutRoot.absolute.path, [segments.single]));
    if (await FileSystemEntity.type(dir.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      await dir.delete(recursive: true);
    }
    _recovered = _recovered
        .where((entry) => entry.directory != segments.single)
        .toList();
  });

  Future<ManagedRemoteFile?> get(String id) => _serialized(() async {
    await _loadUnlocked();
    return _files[id];
  });

  Future<List<ManagedRemoteFile>> list({
    String? serverId,
    String? editSessionId,
  }) => _serialized(() async {
    await _loadUnlocked();
    return _filteredFiles(serverId: serverId, editSessionId: editSessionId);
  });

  Future<List<ManagedRemoteFile>> listForServer(String serverId) =>
      list(serverId: serverId);

  Future<List<ManagedRemoteFile>> listForSession(
    String editSessionId, {
    String? serverId,
  }) => list(serverId: serverId, editSessionId: editSessionId);

  /// Re-enumerates the preserved recordless directories under
  /// [checkoutRoot] — the §3.7 recovery list a fresh surface reads.
  /// Marker files are never reported as payload.
  Future<List<RecoveredCheckout>> listRecovered() => _serialized(() async {
    await _loadUnlocked();
    await _enumerateRecovered();
    return List.unmodifiable(_recovered);
  });

  /// Inserts or replaces a record and atomically commits the complete index.
  ///
  /// Uniqueness is enforced on the live key (serverId, editSessionId,
  /// remotePath) among non-[ManagedRemoteFile.displaced] records — a
  /// displaced record keeps its remotePath as display target but no
  /// longer occupies the slot (06 §3.5).
  Future<void> put(ManagedRemoteFile file) => _serialized(() async {
    await _loadUnlocked();
    _validateFile(file);
    if (_liveConflictFor(file) != null) {
      throw StateError(
        'A managed checkout already exists for ${file.remotePath}',
      );
    }
    await _flushReplacing(file);
  });

  /// Like [put], but a live conflict is resolved by persisting the
  /// incoming record [ManagedRemoteFile.displaced] instead of throwing —
  /// the raced-checkout commit rule (06 §3.5). The decision and the write
  /// share one serialized section so a concurrent commit cannot slip
  /// between the check and the flush. Returns the persisted record.
  Future<ManagedRemoteFile> putOrDisplace(ManagedRemoteFile file) =>
      _serialized(() async {
        await _loadUnlocked();
        _validateFile(file);
        final effective = _liveConflictFor(file) == null
            ? file
            : file.copyWith(displaced: true);
        await _flushReplacing(effective);
        return effective;
      });

  /// The live record occupying `file`'s (serverId, editSessionId,
  /// remotePath) slot, or null — displaced records on either side do not
  /// participate (06 §3.5).
  ManagedRemoteFile? _liveConflictFor(ManagedRemoteFile file) {
    for (final existing in _files.values) {
      if (existing.id != file.id &&
          !existing.displaced &&
          !file.displaced &&
          existing.serverId == file.serverId &&
          existing.editSessionId == file.editSessionId &&
          existing.remotePath == file.remotePath) {
        return existing;
      }
    }
    return null;
  }

  /// Inserts `file` and flushes, restoring the prior entry on failure.
  /// Caller must hold the serialization.
  Future<void> _flushReplacing(ManagedRemoteFile file) async {
    final previous = _files[file.id];
    _files[file.id] = file;
    try {
      await _flushUnlocked();
    } catch (_) {
      if (previous == null) {
        _files.remove(file.id);
      } else {
        _files[file.id] = previous;
      }
      rethrow;
    }
  }

  /// Replaces an existing record. Unlike [put], a missing id is an error.
  /// The same live-key uniqueness holds — [update] cannot displace a
  /// record into a collision.
  Future<void> update(ManagedRemoteFile file) => _serialized(() async {
    await _loadUnlocked();
    if (!_files.containsKey(file.id)) {
      throw StateError('Managed remote file ${file.id} does not exist');
    }
    _validateFile(file);
    if (_liveConflictFor(file) != null) {
      throw StateError(
        'A managed checkout already exists for ${file.remotePath}',
      );
    }
    await _flushReplacing(file);
  });

  /// Removes a record. Plaintext is deleted before the index entry so a
  /// failed filesystem operation cannot silently orphan a checkout.
  Future<ManagedRemoteFile?> remove(String id, {bool deleteCheckout = true}) =>
      _serialized(() async {
        await _loadUnlocked();
        final previous = _files[id];
        if (previous == null) return null;
        if (deleteCheckout) {
          await _deleteCheckoutUnlocked(previous.localPath);
        }
        _files.remove(id);
        try {
          await _flushUnlocked();
        } catch (_) {
          _files[id] = previous;
          rethrow;
        }
        return previous;
      });

  /// Recomputes runtime state for one checkout. Missing files are not dirty;
  /// they are reported separately through [ManagedRemoteFile.missing].
  ///
  /// This is local rehashing only — it never touches [remoteSnapshot], so
  /// a `needsReconcile` record keeps its degraded mark until the manager's
  /// remote re-stat/hash repair clears it (06 §3.4).
  Future<ManagedRemoteFile?> reconcile(String id) => _serialized(() async {
    await _loadUnlocked();
    final file = _files[id];
    if (file == null) return null;
    return _reconcileUnlocked(file);
  });

  Future<List<ManagedRemoteFile>> reconcileAll({
    String? serverId,
    String? editSessionId,
  }) => _serialized(() async {
    await _loadUnlocked();
    final files = _filteredFiles(
      serverId: serverId,
      editSessionId: editSessionId,
    );
    final reconciled = <ManagedRemoteFile>[];
    for (final file in files) {
      reconciled.add(await _reconcileUnlocked(file));
    }
    return reconciled;
  });

  /// Accepts the current local contents as the new persisted baseline.
  Future<ManagedRemoteFile?> updateBaseline(String id) => _serialized(() async {
    await _loadUnlocked();
    final current = _files[id];
    if (current == null) return null;
    final local = await _safeRegularFile(current.localPath);
    if (local == null) {
      throw FileSystemException(
        'Checkout file does not exist',
        checkoutFile(current.localPath).path,
      );
    }
    final updated = current.copyWith(
      baselineSha256: await streamedFileSha256(local),
      dirty: false,
      missing: false,
    );
    _files[id] = updated;
    try {
      await _flushUnlocked();
    } catch (_) {
      _files[id] = current;
      rethrow;
    }
    return updated;
  });

  /// Releases the cross-process lock. Store ops after [close] fail fast —
  /// a second store over the same index must see the lock held until
  /// this one lets go.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _operationTail;
    final lock = _lockFile;
    _lockFile = null;
    if (lock != null) {
      try {
        await lock.unlock();
      } finally {
        await lock.close();
      }
      // `_lockFile != null` iff this store put its path in _heldPaths —
      // a store that never held the lock must not erase a live peer's
      // same-process registration.
      _heldPaths.remove(lockFile.absolute.path);
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        if (_closed) {
          throw StateError('the managed checkout store is closed');
        }
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  /// In-process lock registry — dart:io's file lock uses POSIX `fcntl`
  /// semantics (per-process, not per-open-description), so two stores in
  /// one isolate would never contend; this guard gives same-process
  /// opens the same fail-fast the OS lock gives cross-process ones.
  static final Set<String> _heldPaths = <String>{};

  /// Acquires the cross-process lock once — before the index is read and
  /// before the sweep touches anything — so a second instance's writer
  /// can never interleave with this one's load (06 §3.2).
  Future<void> _acquireLock() async {
    if (!useLock || _lockFile != null) return;
    final lockFile = File(lockPathFor(indexFile));
    if (!_heldPaths.add(lockFile.absolute.path)) {
      throw FileSystemException(
        'the managed checkout store is locked by another instance',
        lockFile.path,
      );
    }
    await lockFile.parent.create(recursive: true);
    final raf = await lockFile.open(mode: FileMode.write);
    try {
      // dart:io exposes only the blocking lock; bound the wait so a
      // live peer process fails this one fast instead of hanging
      // startup behind a lock it will never surrender.
      await raf.lock(FileLock.exclusive).timeout(const Duration(seconds: 2));
    } on Object {
      _heldPaths.remove(lockFile.absolute.path);
      await raf.close();
      throw FileSystemException(
        'the managed checkout store is locked by another process',
        lockFile.path,
      );
    }
    _lockFile = raf;
  }

  Future<void> _loadUnlocked() async {
    if (_loaded) return;
    await _acquireLock();
    var canSweepUnindexed = true;
    if (await indexFile.exists()) {
      try {
        final decoded = jsonDecode(await indexFile.readAsString());
        if (decoded is! Map) {
          throw const FormatException('Managed-file index must be an object');
        }
        final json = decoded.cast<String, dynamic>();
        if (json['version'] != _indexVersion) {
          throw FormatException(
            'Unsupported managed-file index version: ${json['version']}',
          );
        }
        final entries = json['files'];
        if (entries is! List) {
          throw const FormatException(
            'Managed-file index files must be a list',
          );
        }
        for (final entry in entries) {
          if (entry is! Map) {
            throw const FormatException('Managed-file entry must be an object');
          }
          final file = ManagedRemoteFile.fromJson(
            entry.cast<String, dynamic>(),
          );
          _validateFile(file);
          if (_files.containsKey(file.id)) {
            throw FormatException('Duplicate managed-file id: ${file.id}');
          }
          _files[file.id] = file;
        }
      } catch (_) {
        _files.clear();
        await _quarantineCorruptFile(indexFile);
        // Without a trustworthy index, any checkout may contain the only copy
        // of an edit. Preserve all plaintext directories for manual recovery.
        canSweepUnindexed = false;
      }
    }
    // The index's directory and the checkout root hold only private
    // bookkeeping and plaintext — owner-only like the artifacts inside
    // (06 §3.1). Best-effort: a chmod failure here must not wedge the
    // load; the per-file restricts still carry the invariant.
    try {
      await restrictLocalPathPermissions(indexFile.parent.path, '700');
      await restrictLocalPathPermissions(checkoutRoot.path, '700');
    } on FileSystemException {
      // Non-fatal — the per-artifact restricts enforce the payload.
    }
    if (canSweepUnindexed) {
      await _sweepUnindexedCheckouts();
      await _sweepGeneratedTemps();
    }
    await _enumerateRecovered();
    _loaded = true;
  }

  /// The epoch/abandoned-marker sweep (06 §3.2), run once at load before
  /// any operation is accepted:
  ///
  /// - a directory still carrying `.poltergeist-abandoned` was a checkout
  ///   that never committed its record — delete it wholesale;
  /// - an unindexed directory with real payload (old-epoch or markerless)
  ///   is preserved for [listRecovered] — never deleted;
  /// - the only removable leftovers are empty dirs (marker files don't
  ///   count as payload) and non-payload marker files at the root.
  Future<void> _sweepUnindexedCheckouts() async {
    final rootType = await FileSystemEntity.type(
      checkoutRoot.path,
      followLinks: false,
    );
    if (rootType != FileSystemEntityType.directory) return;
    final retained = {
      for (final file in _files.values) file.localPath.split('/').first,
    };
    await for (final entity in checkoutRoot.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (retained.contains(name)) continue;
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        final dir = Directory(entity.path);
        final abandoned = await File(
          _join(dir.path, const [abandonedMarkerName]),
        ).exists();
        if (abandoned) {
          await dir.delete(recursive: true);
          continue;
        }
        // Payload test: anything that is not the bare epoch marker keeps
        // the directory alive for the recovered-edit surface.
        var hasPayload = false;
        await for (final child in dir.list(followLinks: false)) {
          if (p.basename(child.path) == epochMarkerName) continue;
          hasPayload = true;
          break;
        }
        if (!hasPayload) {
          await dir.delete(recursive: true);
        }
        // Payload-bearing unindexed dirs stay — `_enumerateRecovered`
        // reports them.
      }
      // Markerless foreign files at the root are preserved, never
      // deleted — the sweep only removes what this store created.
    }
  }

  /// Deletes generated temp siblings inside indexed checkout dirs —
  /// `<name>.poltergeist-<token>.(upload|edit|backup|tmp)` exactly, and
  /// never the record's own basename even when it carries that shape
  /// (a remote file legitimately named `x.poltergeist-deadbeef.tmp`
  /// is still the checkout payload — 06 §3.3's exact-shape rule).
  Future<void> _sweepGeneratedTemps() async {
    // Keyed by each record's parent directory (not just the top-level
    // segment) so nested layouts sweep their own dir and a retained
    // basename shields only siblings in the same directory.
    final retained = <String, Set<String>>{};
    for (final file in _files.values) {
      final segments = file.localPath.split('/');
      final parent = segments.take(segments.length - 1).join('/');
      (retained[parent] ??= {}).add(segments.last);
    }
    for (final entry in retained.entries) {
      final parts = entry.key.isEmpty ? const <String>[] : entry.key.split('/');
      final dir = Directory(_join(checkoutRoot.absolute.path, parts));
      if (await FileSystemEntity.type(dir.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      await for (final child in dir.list(followLinks: false)) {
        if (child is! File) continue;
        final name = p.basename(child.path);
        if (entry.value.contains(name)) continue;
        if (!generatedTempName.hasMatch(name)) continue;
        try {
          await child.delete();
        } on FileSystemException {
          // Best effort — a locked temp retries on the next load.
        }
      }
    }
  }

  /// Rebuilds the §3.7 recovered list: unindexed payload-bearing dirs,
  /// plus root-level files foreign to the store are intentionally NOT
  /// listed (nothing about them is a checkout).
  Future<void> _enumerateRecovered() async {
    final rootType = await FileSystemEntity.type(
      checkoutRoot.path,
      followLinks: false,
    );
    final recovered = <RecoveredCheckout>[];
    if (rootType == FileSystemEntityType.directory) {
      final retained = {
        for (final file in _files.values) file.localPath.split('/').first,
      };
      await for (final entity in checkoutRoot.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (retained.contains(name)) continue;
        if (await FileSystemEntity.type(entity.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          continue;
        }
        final dir = Directory(entity.path);
        final files = <String>[];
        var totalBytes = 0;
        await for (final child in dir.list(followLinks: false)) {
          final childName = p.basename(child.path);
          // Markers are lifecycle bookkeeping, never payload. Generated-
          // temp-shaped names ARE listed here — an unindexed directory
          // cannot distinguish crashed-transfer debris from a recovered
          // edit carrying that shape, and the §3.7 surface exists to
          // disclose rather than silently discard.
          if (childName == epochMarkerName ||
              childName == abandonedMarkerName) {
            continue;
          }
          files.add(childName);
          if (child is File) {
            try {
              totalBytes += await child.length();
            } on FileSystemException {
              // A racing unlink — the listing is a snapshot anyway.
            }
          }
        }
        if (files.isNotEmpty) {
          recovered.add(
            RecoveredCheckout(
              directory: name,
              files: files..sort(),
              totalBytes: totalBytes,
            ),
          );
        }
      }
    }
    _recovered = recovered..sort((a, b) => a.directory.compareTo(b.directory));
  }

  /// A corrupt index is quarantined — never overwritten in place (the
  /// same rule the record store follows: the bad file may hold the only
  /// map to unpushed edits). The name carries a UTC stamp plus a counter
  /// so a same-second second corruption cannot clobber the first rescue.
  Future<void> _quarantineCorruptFile(File file) async {
    if (!await file.exists()) return;
    // Bounded: a pathological directory of pre-seeded candidates must
    // not stall the corrupt-index rescue path this function protects.
    for (var n = 0; n < 100; n++) {
      final candidate = File('${file.path}.corrupt-${_stamp(_now())}-$n');
      if (await candidate.exists()) continue;
      await file.rename(candidate.path);
      // Explicit post-move chmod, never rename-preserved modes: a
      // quarantined index predating the restrict helper would otherwise
      // keep whatever laxer mode it had (06 §3.1). Best-effort only —
      // the file is already safely quarantined and a failed chmod must
      // not wedge the load.
      try {
        await restrictLocalPathPermissions(candidate.path, '600');
      } on FileSystemException {
        // The quarantine itself succeeded; the next write re-tightens.
      }
      return;
    }
    throw FileSystemException(
      'Unable to quarantine corrupt index: candidate names exhausted',
      file.path,
    );
  }

  static String _stamp(DateTime now) => now
      .toUtc()
      .toIso8601String()
      .replaceAll('-', '')
      .replaceAll(':', '')
      .replaceAll('.', '');

  Future<void> _flushUnlocked() async {
    final files = _files.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    await _atomicWriter(
      indexFile,
      jsonEncode({
        'version': _indexVersion,
        'files': files.map((file) => file.toJson()).toList(),
      }),
      restrictToOwner: true,
    );
  }

  List<ManagedRemoteFile> _filteredFiles({
    String? serverId,
    String? editSessionId,
  }) {
    final files =
        _files.values
            .where(
              (file) =>
                  (serverId == null || file.serverId == serverId) &&
                  (editSessionId == null ||
                      file.editSessionId == editSessionId),
            )
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return files;
  }

  /// The per-checkout `.edit`/`.backup` sweep 06 §2.1 step 5 prescribes,
  /// run inside the serialized section as part of every reconcile:
  ///
  /// - Only the record's OWN basename's generated siblings are touched —
  ///   `<name>.poltergeist-<token>.edit|backup` exactly. A foreign stem
  ///   (or the record basename itself, decoy-shaped or not) is never
  ///   swept: inside checkout dirs the sweep deletes only what the save
  ///   dance created.
  /// - Anything touched within [saveTempWindow] may belong to a save
  ///   still executing — the whole pass skips that target (the
  ///   in-flight-save guard), so a reconcile landing mid-dance can
  ///   neither reap a live temp nor "recover" a live `.backup`.
  /// - Beside a live target the siblings are stale temps — deleted.
  /// - Beside a MISSING target a `.backup` is the sole surviving
  ///   pre-save copy (a crash landed between the `file → backup` and
  ///   `temp → file` renames): it is renamed back onto the target, and a
  ///   `.edit` sibling — the just-saved content — follows onto the
  ///   target so the subsequent rehash marks the copy dirty and §3.3's
  ///   prompt routes it through §3.4's conflict flow. Neither is
  ///   deleted. A `.edit` WITHOUT a `.backup` cannot be a completed
  ///   save (the dance only removes the target after the temp is
  ///   written, hashed, and the backup rename has landed) — it is
  ///   possibly torn and is preserved untouched, never applied.
  ///
  /// All sibling failures are tolerated: the sweep is janitorial and a
  /// failed delete or restore must never mask the reconcile itself.
  Future<void> _sweepSaveTemps(ManagedRemoteFile managed) async {
    try {
      final directory = checkoutDirectory(managed.localPath);
      final targetName = p.basename(managed.localPath);
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      final edits = <File>[];
      final backups = <File>[];
      await for (final child in directory.list(followLinks: false)) {
        if (child is! File) continue;
        final name = p.basename(child.path);
        // Stem-match the record's basename: `target.poltergeist-<tok>.edit`.
        if (!name.startsWith('$targetName.poltergeist-') ||
            !generatedTempName.hasMatch(name)) {
          continue;
        }
        if (name.endsWith('.edit')) {
          edits.add(child);
        } else if (name.endsWith('.backup')) {
          backups.add(child);
        }
      }
      if (edits.isEmpty && backups.isEmpty) return;
      // The in-flight-save guard: any sibling inside the window freezes
      // the whole pass — a save's own `.edit`/`.backup` pair shares one
      // recency, so checking the freshest sibling covers the set.
      final now = _now();
      for (final sibling in [...edits, ...backups]) {
        FileStat stat;
        try {
          stat = await sibling.stat();
        } on FileSystemException {
          continue; // vanished mid-list — nothing to guard
        }
        if (now.difference(stat.modified) < saveTempWindow) return;
      }
      final target = checkoutFile(managed.localPath);
      if (await FileSystemEntity.type(target.path, followLinks: false) ==
          FileSystemEntityType.file) {
        for (final sibling in [...edits, ...backups]) {
          try {
            await sibling.delete();
          } on FileSystemException {
            // A locked stray retries on the next reconcile.
          }
        }
        return;
      }
      // Crash-state restore (06 §2.1 step 5), beside a missing target:
      // a lone `.backup` is the sole surviving pre-save copy — renamed
      // back onto the target. With a `.edit` sibling present the save
      // had already sealed its temp before the crash, so the just-saved
      // content completes onto the target instead — the rehash marks
      // the copy dirty and §3.3's prompt routes it through §3.4's
      // conflict flow — while the `.backup` is left in place rather
      // than deleted: the pre-save copy survives until the next pass's
      // normal stale-temp reaping. A `.edit` WITHOUT a `.backup` cannot
      // be a completed save (the dance removes the target only after
      // the temp is sealed and the backup rename has landed) — it is
      // possibly torn and is preserved untouched, never applied.
      try {
        if (edits.isNotEmpty && backups.isNotEmpty) {
          await edits.first.rename(target.path);
        } else if (edits.isEmpty && backups.isNotEmpty) {
          await backups.first.rename(target.path);
        }
      } on FileSystemException {
        // A racing recreate — leave everything for the next pass.
      }
    } on FileSystemException {
      // Janitorial: a sweep failure must never mask the reconcile.
    }
  }

  Future<ManagedRemoteFile> _reconcileUnlocked(
    ManagedRemoteFile managed,
  ) async {
    // The §2.1 step-5 sweep runs BEFORE the rehash: a restored `.backup`
    // or a completed `.edit` must land before the digest comparison so
    // the recovered content drives the dirty verdict.
    await _sweepSaveTemps(managed);
    final local = await _safeRegularFile(managed.localPath);
    if (local == null) {
      final missing = managed.copyWith(dirty: false, missing: true);
      _files[managed.id] = missing;
      return missing;
    }

    try {
      final digest = await streamedFileSha256(local);
      final reconciled = managed.copyWith(
        dirty: digest != managed.baselineSha256,
        missing: false,
      );
      _files[managed.id] = reconciled;
      return reconciled;
    } on FileSystemException {
      if (await _safeRegularFile(managed.localPath) == null) {
        final missing = managed.copyWith(dirty: false, missing: true);
        _files[managed.id] = missing;
        return missing;
      }
      rethrow;
    }
  }

  void _validateFile(ManagedRemoteFile file) {
    try {
      file.validate();
      checkoutFile(file.localPath);
    } on FormatException catch (error) {
      throw ArgumentError.value(file, 'file', error.message);
    }
  }

  Future<void> _ensureSafeParents(String localPath) async {
    final segments = _validateRelativePath(localPath);
    final root = checkoutRoot.absolute;
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'Checkout root is not a real directory',
        root.path,
      );
    }

    var path = root.path;
    for (final segment in segments.take(segments.length - 1)) {
      path = _join(path, [segment]);
      var type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(path).create();
        type = await FileSystemEntity.type(path, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Checkout path contains a non-directory or symlink',
          path,
        );
      }
    }
  }

  Future<File?> _safeRegularFile(String localPath) async {
    final segments = _validateRelativePath(localPath);
    var path = checkoutRoot.absolute.path;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    for (final segment in segments.take(segments.length - 1)) {
      path = _join(path, [segment]);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return null;
      }
    }
    final file = checkoutFile(localPath);
    return await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file
        ? file
        : null;
  }

  Future<void> _deleteCheckoutUnlocked(String localPath) async {
    final segments = _validateRelativePath(localPath);
    final root = checkoutRoot.absolute;
    var path = root.path;
    final parents = <Directory>[];
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    for (final segment in segments.take(segments.length - 1)) {
      path = _join(path, [segment]);
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Refusing to follow an unsafe checkout path',
          path,
        );
      }
      parents.add(Directory(path));
    }

    final target = checkoutFile(localPath);
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.file) {
      await target.delete();
    } else if (targetType == FileSystemEntityType.link) {
      await Link(target.path).delete();
    } else if (targetType != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Refusing to delete a non-file checkout',
        target.path,
      );
    }

    for (final parent in parents.reversed) {
      try {
        await parent.delete();
      } on FileSystemException {
        break;
      }
    }
  }
}

List<String> _validateRelativePath(String localPath) {
  if (localPath.isEmpty ||
      localPath.startsWith('/') ||
      localPath.startsWith('\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(localPath) ||
      localPath.contains('\\') ||
      localPath.contains('\u0000')) {
    throw ArgumentError.value(
      localPath,
      'localPath',
      'Must be a safe root-relative path',
    );
  }
  final segments = localPath.split('/');
  if (segments.any(
    (segment) =>
        segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        RegExp(r'[:*?"<>|]').hasMatch(segment) ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        windowsReservedName.hasMatch(
          segment.split('.').first.replaceAll(RegExp(r'[ .]+$'), ''),
        ) ||
        RegExp(r'[\x00-\x1f]').hasMatch(segment),
  )) {
    throw ArgumentError.value(
      localPath,
      'localPath',
      'Contains an unsafe path component',
    );
  }
  return segments;
}

String _join(String base, Iterable<String> segments) =>
    <String>[base, ...segments].join(Platform.pathSeparator);

/// Truncates [name] to the 255-byte NAME_MAX floor (03 §2.3's constant)
/// on a codepoint boundary, then re-strips the trailing dots/spaces the
/// cut may have produced — a truncated name must still satisfy
/// [_validateRelativePath] on the next load.
String _truncateToNameMax(String name) {
  const maxBytes = 255;
  var bytes = 0;
  var units = 0;
  for (final rune in name.runes) {
    bytes += rune <= 0x7f
        ? 1
        : rune <= 0x7ff
        ? 2
        : rune <= 0xffff
        ? 3
        : 4;
    if (bytes > maxBytes) break;
    units += rune > 0xffff ? 2 : 1;
  }
  if (units >= name.length) return name;
  final truncated = name
      .substring(0, units)
      .replaceFirst(RegExp(r'[. ]+$'), '');
  return truncated.isEmpty ? 'remote-file' : truncated;
}
