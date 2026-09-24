import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:seance_core/seance_core.dart';

import '../connection/connection_manager.dart';
import '../editor/built_in_text_document.dart';
import '../fs/content_digest.dart';
import '../fs/local_fs_safety.dart';
import '../transfer/transfer_queue.dart';
import '../transfer/transfer_task.dart';
import 'managed_checkout_spec.dart';
import 'managed_remote_file.dart';
import 'managed_remote_file_store.dart';

// Ported from Séance
// app/seance_app/lib/services/remote_files_controller.dart @ 2e6d1f1
// (the managed-checkout pipeline: checkoutRemoteFile, uploadLocalCopy,
// _watchCheckout/_scheduleCheckoutReconcile/_restoreLocalCopies,
// renameEntry's local-copy re-keying, _sameSnapshot); see docs/PORTS.md.

/// Core-side owner of the managed checkout pipeline (06 §3, 03 §6).
///
/// Responsibilities, all ported from Séance's `remote_files_controller`
/// checkout pipeline and hardened per the plan:
///
/// - `checkout` materializes a remote file into the durable store via a
///   journaled, queue-visible download (`enqueueManagedCheckout`) — never
///   invisible I/O — and records `editSessionId = serverId`: checkout
///   identity is per server, stable across pane/tab/editor churn (06
///   §3.2 — it is never derived from a pane or tab id).
/// - Parent-directory watching with a per-checkout debounce (default
///   600 ms): any event other than exact generated temp names rehashes
///   the checkout and marks it dirty. Nothing ever auto-uploads.
/// - `reconcileOnResume` rehashes every record (foreground/resume and
///   post-launch), and repairs `needsReconcile` snapshots through a
///   remote re-stat plus a streamed remote hash — local rehashing alone
///   never blesses a degraded remote baseline.
/// - `uploadLocalCopy` is the explicit save: frozen `.upload` snapshot →
///   remote preflight stat → queue-visible priority upload carrying the
///   record's snapshot as `expectedTarget` — the destination adapter's
///   mandatory content-hash check is the conflict authority (D7). A
///   remote change, a deletion, or a content tamper under identical
///   metadata blocks the save with a `conflict` error; only an explicit
///   `overwriteRemoteChanges` drops the CAS.
/// - `migrateRename` re-keys records — and in-flight checkouts — when a
///   remote file or directory is renamed; a path claimed by an arrival
///   displaces the occupant rather than overwriting its record.
final class CheckoutManager {
  CheckoutManager({
    required this._store,
    required this._connections,
    required this._queue,
    Stream<FileSystemEvent> Function(String directoryPath)? watchDirectory,
    this.watchDebounce = const Duration(milliseconds: 600),
    this.watchReconcileMaxDelay = const Duration(seconds: 10),
    this.freeSpaceBytes,
    this.onError,
  }) : _watchDirectory = watchDirectory ?? _defaultWatch;

  final ManagedRemoteFileStore _store;
  final ConnectionManager _connections;
  final ManagedCheckoutQueue _queue;
  final Stream<FileSystemEvent> Function(String directoryPath) _watchDirectory;

  /// Per-checkout debounce — injectable so tests never pay real 600 ms.
  final Duration watchDebounce;

  /// Starvation bound on the debounce: continuous sibling noise must
  /// not postpone reconciliation forever — the first pending event
  /// stamps a deadline, and resets past it fire immediately.
  final Duration watchReconcileMaxDelay;

  /// Free-space probe for the app-support volume (06 §3.2's preflight);
  /// null degrades to surfacing the write failure.
  final Future<int?> Function(String path)? freeSpaceBytes;
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Mirror of the store's records, keyed by record id — displaced
  /// records included (they remain tracked and watchable).
  final Map<String, ManagedRemoteFile> _records = {};

  /// (serverId, remotePath) → in-flight checkout. The flight's remotePath
  /// is mutable: a `migrateRename` arriving mid-download retargets it so
  /// the record commits under the post-rename path (06 §3.5).
  final Map<(String, String), _CheckoutFlight> _checkoutFlights = {};

  /// checkoutId → in-flight save's serializing future.
  final Map<String, Future<bool>> _uploadFlights = {};

  /// checkoutId → the `overwriteRemoteChanges` flag the in-flight save
  /// was started with — dedupe may only coalesce identical semantics.
  final Map<String, bool> _uploadFlightFlags = {};

  /// taskId → the completer a `checkout`/`uploadLocalCopy` caller awaits.
  final Map<String, _PendingTransfer> _pendingTransfers = {};

  final Map<String, StreamSubscription<FileSystemEvent>> _watches = {};
  final Map<String, Timer> _debounces = {};
  final Map<String, DateTime> _reconcileDeadlines = {};
  final StreamController<void> _changes = StreamController.broadcast();
  StreamSubscription<TransferQueueEvent>? _queueSubscription;
  bool _started = false;
  bool _disposed = false;

  /// Broadcast on every visible state change — the app controller
  /// re-reads the snapshot getters; the record set itself is the truth.
  Stream<void> get changes => _changes.stream;

  /// Every tracked record across servers — displaced ones included
  /// (they remain watched and still save toward their original
  /// remotePath under CAS). The app-wide dirty-prompt scan (06 §3.3)
  /// is its consumer; per-server surfaces keep using [copiesFor].
  List<ManagedRemoteFile> get records => List.unmodifiable(_records.values);

  /// Live (non-displaced) checkouts of one server, keyed by remotePath —
  /// Séance's `localCopies` shape.
  Map<String, ManagedRemoteFile> copiesFor(String serverId) => {
    for (final record in _records.values)
      if (record.serverId == serverId && !record.displaced)
        record.remotePath: record,
  };

  /// Re-keyed records whose remotePath a rename arrival claimed — the
  /// §3.7 review surface lists these as recovered edits; they are still
  /// watched and still save toward their original remotePath under CAS.
  List<ManagedRemoteFile> displacedFor(String serverId) => _records.values
      .where((r) => r.serverId == serverId && r.displaced)
      .toList();

  /// Preserved recordless checkout payloads — never uploadable, only
  /// reviewable/disposable through [forgetRecovered].
  Future<List<RecoveredCheckout>> recoveredCheckouts() =>
      _store.listRecovered();

  /// The live record for one remote path, or null — displaced records
  /// never answer here (their slot is reclaimed by the arrival).
  ManagedRemoteFile? checkoutFor(String serverId, String remotePath) =>
      copiesFor(serverId)[remotePath];

  /// The local file a record's bytes live in — validated, never
  /// caller-constructed.
  File localFile(ManagedRemoteFile record) =>
      _store.checkoutFile(record.localPath);

  /// The local file a recovered payload's bytes live in — the §3.7
  /// review surface's `Open` target, validated the same way. `name`
  /// carries the same single-segment rule as [forgetRecoveredFile] —
  /// the recovered listing is flat, so both verbs share one grammar.
  File recoveredFile(RecoveredCheckout recovered, String name) {
    if (name.split('/').length != 1) {
      throw ArgumentError.value(name, 'name', 'Must be a single file name');
    }
    return _store.checkoutFile('${recovered.directory}/$name');
  }

  /// Loads persisted records, reconciles them, starts watchers, and
  /// subscribes to the queue — once. Call after construction, before
  /// any checkout.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _queueSubscription = _queue.events.listen(
      _onQueueEvent,
      onError: (Object error, StackTrace stack) {
        onError?.call(error, stack);
      },
    );
    await _restoreRecords();
  }

  Future<void> _restoreRecords() async {
    final restored = await _store.reconcileAll();
    if (_disposed) return;
    for (final record in restored) {
      _records[record.id] = record;
      _watch(record);
    }
    _emitChange();
    // Degraded snapshots repair against the remote — fire and forget per
    // server so a dead server cannot stall startup; failures keep the
    // mark and report through onError.
    for (final record in restored) {
      if (record.needsReconcile) {
        unawaited(_repairRemote(record));
      }
    }
  }

  /// Résumé/foreground entry point (06 §3.3): rehash every record, repair
  /// degraded snapshots, surface the result. Watch failure never reaches
  /// here silently — reconcile-on-resume is the designed fallback.
  Future<void> reconcileOnResume() async {
    if (_disposed) return;
    final updated = await _store.reconcileAll();
    if (_disposed) return;
    for (final record in updated) {
      _records[record.id] = record;
      _watch(record);
    }
    _emitChange();
    for (final record in updated) {
      if (record.needsReconcile) {
        await _repairRemote(record);
      }
    }
  }

  /// Downloads [entry] into the managed store as a durable checkout, or
  /// returns the existing/in-flight record for the same
  /// (serverId, remotePath) — pane/tab churn dedupes onto the per-server
  /// record, never forks a second checkout (06 §3.2).
  Future<ManagedRemoteFile> checkout({
    required String serverId,
    required RemoteFileEntry entry,
    int? maximumBytes,
  }) async {
    if (entry.type != RemoteFileType.file) {
      throw StateError('Only regular remote files can be opened for editing.');
    }
    final existing = _records.values.where(
      (r) =>
          r.serverId == serverId && !r.displaced && r.remotePath == entry.path,
    );
    if (existing.isNotEmpty) return existing.first;
    final key = (serverId, entry.path);
    final inFlight = _checkoutFlights[key];
    if (inFlight != null) return inFlight.completer.future;

    final flight = _CheckoutFlight(entry.path);
    // A failed flight may have no dedupe waiter — swallow this
    // subscription's copy so the error isn't reported unhandled; real
    // callers still receive it through their own await.
    flight.completer.future.ignore();
    _checkoutFlights[key] = flight;
    try {
      final record = await _checkout(
        serverId,
        entry,
        flight,
        maximumBytes: maximumBytes,
      );
      if (!flight.completer.isCompleted) {
        flight.completer.complete(record);
      }
      return record;
    } catch (error, stack) {
      if (!flight.completer.isCompleted) {
        flight.completer.completeError(error, stack);
      }
      rethrow;
    } finally {
      // A migrateRename may have re-keyed (or bridged) this flight
      // mid-download — remove it wherever it sits, and never a
      // different flight that reoccupied the original key.
      _checkoutFlights.removeWhere((_, v) => identical(v, flight));
    }
  }

  Future<ManagedRemoteFile> _checkout(
    String serverId,
    RemoteFileEntry entry,
    _CheckoutFlight flight, {
    int? maximumBytes,
  }) async {
    final id = uuidV4();
    final localPath = _store.checkoutPathFor(id: id, fileName: entry.name);
    if (maximumBytes != null &&
        entry.size != null &&
        entry.size! > maximumBytes) {
      throw CheckoutLimitException(
        'The file is larger than the $maximumBytes-byte editor limit.',
      );
    }
    await _store.prepareCheckout(localPath);
    final local = await _store.createCheckout(localPath);
    await restrictLocalPathPermissions(local.parent.path, '700');
    // Restrict before the download writes plaintext — a chmod only
    // after the transfer would leave a world-readable window under a
    // default umask.
    await restrictLocalPathPermissions(local.path, '600');
    try {
      // Preflight free space on the app-support volume when the remote
      // declared a size — a null probe result degrades to the write
      // failure (06 §3.2's stated fallback).
      final probe = freeSpaceBytes;
      if (entry.size != null && probe != null) {
        final free = await probe(_store.checkoutRoot.absolute.path);
        if (free != null && free < entry.size!) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.other,
            operation: 'checkout',
            path: entry.path,
            message:
                'Not enough free space for "${entry.name}" '
                '(${entry.size} bytes).',
          );
        }
      }
      final task = _queue.enqueueManagedCheckout(
        ManagedCheckoutSpec(
          checkoutId: id,
          serverId: serverId,
          remotePath: flight.remotePath,
          localPath: local.path,
          direction: ManagedCheckoutDirection.download,
          expectedSize: entry.size,
          // The stream cap is the unknown-size guard: a listing entry
          // with no size aborts mid-download at the limit (06 §3.2).
          maximumBytes: maximumBytes,
        ),
      );
      RemoteFileEntry remoteEntry;
      try {
        remoteEntry = await _awaitTask(task);
      } on RemoteFileException catch (error, stackTrace) {
        // The stream cap aborts an unknown-size download mid-pipe and
        // the queue's error attribution wraps the typed limit error
        // ('transfer source: …'). The partial file cannot re-derive it —
        // the cap counts bytes READ while BoundedTransferSink may hold
        // the tail unflushed — so the pin is the cap's own §3.2 message
        // suffix, which only MaximumByteSink produces. The cap value is
        // pinned too: a differently-shaped limit error is not this
        // call's to re-label.
        if (maximumBytes != null &&
            error.message.endsWith('$maximumBytes-byte editor limit.')) {
          Error.throwWithStackTrace(
            CheckoutLimitException(
              'The file is larger than the $maximumBytes-byte '
              'editor limit.',
            ),
            stackTrace,
          );
        }
        rethrow;
      }
      if (maximumBytes != null) {
        final length = await local.length();
        if (length > maximumBytes) {
          throw CheckoutLimitException(
            'The file is larger than the $maximumBytes-byte editor limit.',
          );
        }
      }
      await restrictLocalPathPermissions(local.path, '600');
      final digest = await streamedFileSha256(local);
      // The record's snapshot is remote truth: path/name/mtime/mode from
      // the post-download stat, with the downloaded bytes' digest stamped
      // as contentSha256 — the CAS authority for every later save.
      final snapshot = RemoteFileEntry(
        path: flight.remotePath,
        name: remoteBasename(flight.remotePath),
        type: RemoteFileType.file,
        size: remoteEntry.size,
        uid: remoteEntry.uid,
        gid: remoteEntry.gid,
        accessedAt: remoteEntry.accessedAt,
        modifiedAt: remoteEntry.modifiedAt,
        mode: remoteEntry.mode,
        contentSha256: remoteEntry.contentSha256 ?? digest,
      );
      var record = ManagedRemoteFile(
        id: id,
        serverId: serverId,
        editSessionId: serverId,
        remotePath: flight.remotePath,
        localPath: localPath,
        remoteSnapshot: snapshot,
        baselineSha256: digest,
      );
      if (_disposed) {
        throw StateError('The file session closed before checkout completed.');
      }
      // 06 §3.5's final-key re-validation runs inside the store's
      // serialized section: a rename race may have seated another live
      // record on this path while the download ran — the commit decides
      // and persists displaced atomically, never racing the mirror.
      record = await _store.putOrDisplace(record);
      await _store.clearCheckoutInFlight(localPath);
      if (_disposed) {
        await _store.remove(record.id);
        throw StateError('The file session closed before checkout completed.');
      }
      _records[record.id] = record;
      _watch(record);
      _emitChange();
      return record;
    } catch (_) {
      await _store.deleteCheckout(localPath);
      rethrow;
    }
  }

  /// The explicit save (06 §3.4): freezes the checkout into a `.upload`
  /// snapshot, preflights the remote against the recorded snapshot, and
  /// enqueues the CAS-guarded upload. Returns false when the record
  /// vanished while the call was in flight; throws
  /// [RemoteFileException] `conflict` when the remote moved under the
  /// checkout — the caller's conflict flow decides between retrying with
  /// `overwriteRemoteChanges` or discarding.
  Future<bool> uploadLocalCopy(
    ManagedRemoteFile copy, {
    bool overwriteRemoteChanges = false,
  }) async {
    var inFlight = _uploadFlights[copy.id];
    while (inFlight != null) {
      // Never coalesce saves with different conflict semantics: an
      // overwrite riding a CAS flight would be silently blocked, and
      // the reverse would drop the CAS the caller asked for.
      if (_uploadFlightFlags[copy.id] == overwriteRemoteChanges) {
        return inFlight;
      }
      await inFlight.catchError((_) => false);
      // A new flight may have started while this waiter slept — the
      // loop re-checks so two mismatched waiters never race duplicate
      // uploads of the same record.
      inFlight = _uploadFlights[copy.id];
    }
    final future = _upload(copy, overwriteRemoteChanges);
    _uploadFlights[copy.id] = future;
    _uploadFlightFlags[copy.id] = overwriteRemoteChanges;
    // whenComplete derives a second future — ignore() swallows ITS copy
    // of the error; the returned future still delivers it to callers.
    future.whenComplete(() {
      _uploadFlights.remove(copy.id);
      _uploadFlightFlags.remove(copy.id);
    }).ignore();
    return future;
  }

  Future<bool> _upload(ManagedRemoteFile copy, bool overwrite) async {
    var record = await _store.get(copy.id);
    if (record == null || _disposed) return false;
    File? snapshot;
    try {
      snapshot = await _store.createUploadSnapshot(record.localPath);
      final uploadedDigest = await streamedFileSha256(snapshot);
      final size = await snapshot.length();

      // Inline re-stat before the queue hop (06 §3.4's preflight) — and
      // the needs-reconcile repair first: a degraded snapshot adopts the
      // server stat only when size AND streamed digest still match the
      // synthesized values.
      final lease = await _connections.leaseTransferChannel(record.serverId);
      RemoteFileEntry? latest;
      try {
        latest = await _statOrNull(lease.fs, record.remotePath);
        if (record.needsReconcile) {
          record = await _repairSnapshotAgainst(lease.fs, record, latest);
        }
      } finally {
        await lease.release();
      }
      if (!overwrite &&
          (latest == null ||
              !sameRemoteSnapshot(latest, record.remoteSnapshot))) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'upload edited copy',
          path: record.remotePath,
          message:
              '"${remoteBasename(record.remotePath)}" changed or was '
              'deleted on the server after it was opened locally.',
        );
      }
      final task = _queue.enqueueManagedCheckout(
        ManagedCheckoutSpec(
          checkoutId: record.id,
          serverId: record.serverId,
          remotePath: record.remotePath,
          localPath: snapshot.path,
          displayLocalPath: _store.checkoutFile(record.localPath).path,
          direction: ManagedCheckoutDirection.upload,
          expectedSize: size,
          expectedTarget: overwrite ? null : record.remoteSnapshot,
          preserveMode: record.remoteSnapshot.mode,
        ),
      );
      await _awaitTask(task);

      // Post-commit refresh (06 §3.4 step 5): re-stat the record's
      // CURRENT remotePath — a migrateRename landing mid-upload must be
      // preserved, not overwritten by the stale target. ANY refresh
      // failure — lease acquisition included — synthesizes size+digest
      // and marks needsReconcile instead of failing a committed save.
      final current = await _store.get(record.id);
      if (current == null || _disposed) return false;
      RemoteFileEntry? freshStat;
      try {
        final refreshLease = await _connections.leaseTransferChannel(
          current.serverId,
        );
        try {
          freshStat = await _statOrNull(refreshLease.fs, current.remotePath);
        } finally {
          await refreshLease.release();
        }
      } on Object {
        // §3.4's degradation: any refresh failure — not just notFound —
        // synthesizes size+digest and leaves the needsReconcile mark; the
        // committed bytes are already remote, never the baseline.
        freshStat = null;
      }
      final newSnapshot = freshStat == null
          ? RemoteFileEntry(
              path: current.remotePath,
              name: remoteBasename(current.remotePath),
              type: RemoteFileType.file,
              size: size,
              mode: current.remoteSnapshot.mode,
              contentSha256: uploadedDigest,
            )
          : RemoteFileEntry(
              path: freshStat.path,
              name: freshStat.name,
              type: freshStat.type,
              size: freshStat.size,
              uid: freshStat.uid,
              gid: freshStat.gid,
              accessedAt: freshStat.accessedAt,
              modifiedAt: freshStat.modifiedAt,
              mode: freshStat.mode,
              contentSha256: uploadedDigest,
            );
      final currentDigest = await streamedFileSha256(
        _store.checkoutFile(current.localPath),
      );
      final updated = current.copyWith(
        remoteSnapshot: newSnapshot,
        baselineSha256: uploadedDigest,
        dirty: currentDigest != uploadedDigest,
        missing: false,
        needsReconcile: freshStat == null,
      );
      await _store.update(updated);
      _records[updated.id] = updated;
      _emitChange();
      return true;
    } finally {
      if (snapshot != null) {
        try {
          if (await snapshot.exists()) {
            await snapshot.delete();
          }
        } on Object catch (error, stack) {
          // Cleanup must never mask the save's real result — least of
          // all the conflict the caller's flow acts on.
          onError?.call(error, stack);
        }
      }
    }
  }

  /// Re-keys managed records — and in-flight checkouts — when a remote
  /// path is renamed (06 §3.5). Directory renames rewrite descendants
  /// prefix-wise. The local checkout file never moves (an editor may hold
  /// it open). A destination path claimed by an arrival displaces the
  /// standing occupant — records are re-keyed, never dropped or
  /// overwritten.
  Future<void> migrateRename({
    required String serverId,
    required String oldPath,
    required String newPath,
  }) async {
    // In-flight checkouts first: their record has not committed, so the
    // flight's mutable remotePath retargets the eventual snapshot.
    for (final key in _checkoutFlights.keys.toList()) {
      if (key.$1 != serverId) continue;
      if (key.$2 != oldPath && !key.$2.startsWith('$oldPath/')) continue;
      final flight = _checkoutFlights.remove(key)!;
      flight.remotePath = newPath + key.$2.substring(oldPath.length);
      final destination = (serverId, flight.remotePath);
      final colliding = _checkoutFlights[destination];
      if (colliding != null) {
        // A flight already targets the destination — bridge the moved
        // flight's waiters onto the survivor instead of orphaning it
        // (an orphaned flight forks a duplicate download). Its own
        // download still commits, displaced by the occupant rule.
        flight.completer.complete(colliding.completer.future);
      } else {
        _checkoutFlights[destination] = flight;
      }
    }
    final records = await _store.list(serverId: serverId);
    final affected = records.where(
      (r) => r.remotePath == oldPath || r.remotePath.startsWith('$oldPath/'),
    );
    for (final record in affected) {
      final nextPath = newPath + record.remotePath.substring(oldPath.length);
      final occupant = _records.values.where(
        (r) =>
            r.serverId == serverId &&
            !r.displaced &&
            r.remotePath == nextPath &&
            r.id != record.id,
      );
      if (occupant.isNotEmpty) {
        final displaced = occupant.first.copyWith(displaced: true);
        await _store.update(displaced);
        _records[displaced.id] = displaced;
      }
      final updated = record.copyWith(
        remotePath: nextPath,
        remoteSnapshot: copyRemoteEntry(record.remoteSnapshot, nextPath),
      );
      await _store.update(updated);
      _records[updated.id] = updated;
    }
    _emitChange();
  }

  /// Discard: plaintext first, then the record (06 §3.6's ordering —
  /// [ManagedRemoteFileStore.remove] deletes the checkout before the
  /// index entry, so a failed delete can never leave a record pointing
  /// at nothing).
  Future<void> discard(ManagedRemoteFile copy) async {
    await _stopWatching(copy.id);
    await _store.remove(copy.id);
    _records.remove(copy.id);
    _emitChange();
  }

  /// The per-copy reconcile the editor's `onSaved` hook drives
  /// (06 §2.3/§3.3): a local re-hash — dirty/missing flags, the §2.1
  /// save-temp sweep — plus the §3.4 stat-only repair when the record
  /// carries `needsReconcile`. It never touches content and never
  /// throws: `onSaved` runs inside the save's `finally`, where an
  /// escaping error would replace the original upload error, so
  /// failures are reported through [onError] instead.
  Future<void> reconcile(ManagedRemoteFile copy) async {
    try {
      final updated = await _store.reconcile(copy.id);
      if (_disposed || updated == null) return;
      _records[updated.id] = updated;
      _emitChange();
      if (updated.needsReconcile) {
        unawaited(_repairRemote(updated));
      }
    } on Object catch (error, stack) {
      onError?.call(error, stack);
    }
  }

  /// Accept the local copy's current contents as the baseline (the
  /// conflict flow's keep-local path before the next save).
  Future<void> acceptLocalCopy(ManagedRemoteFile copy) async {
    final updated = await _store.updateBaseline(copy.id);
    if (updated == null) return;
    _records[updated.id] = updated;
    _emitChange();
  }

  /// Explicitly delete a preserved recordless directory — the only verb
  /// recovered plaintext ever gets. It is never auto-uploaded.
  Future<void> forgetRecovered(RecoveredCheckout recovered) async {
    await _store.deleteRecovered(recovered.directory);
    _emitChange();
  }

  /// 06 §3.7's per-row `Discard…` for a recovered payload: removes one
  /// file inside [recovered]'s directory — external editors leave
  /// siblings beside the plaintext, so the surface drops a row's file,
  /// never the whole dir. The dir itself goes when its last file does.
  Future<void> forgetRecoveredFile(
    RecoveredCheckout recovered,
    String name,
  ) async {
    await _store.deleteRecoveredFile(recovered.directory, name);
    _emitChange();
  }

  /// Remote-side repair for a `needsReconcile` record (06 §3.4): re-stat
  /// and stream-hash the remote file; the server stat is adopted only
  /// when size AND digest still match the synthesized snapshot —
  /// anything else keeps the mark (the next save's CAS still guards).
  Future<void> _repairRemote(ManagedRemoteFile record) async {
    try {
      final lease = await _connections.leaseTransferChannel(record.serverId);
      try {
        final latest = await _statOrNull(lease.fs, record.remotePath);
        await _repairSnapshotAgainst(lease.fs, record, latest);
      } finally {
        await lease.release();
      }
      _emitChange();
    } on Object catch (error, stack) {
      onError?.call(error, stack);
    }
  }

  /// The repair body shared by resume-reconcile and the save preflight.
  /// Returns the (persisted) record — unchanged when repair cannot
  /// verify the remote.
  Future<ManagedRemoteFile> _repairSnapshotAgainst(
    RemoteFileSystem fs,
    ManagedRemoteFile record,
    RemoteFileEntry? latest,
  ) async {
    final recordedDigest = record.remoteSnapshot.contentSha256;
    if (latest == null ||
        recordedDigest == null ||
        latest.size != record.remoteSnapshot.size) {
      return record;
    }
    // The streamed remote read is the digest authority — metadata alone
    // cannot prove the remote still holds the synthesized content. An
    // engine-bridged lease hashes engine-side (D8): no byte crosses.
    final remote = await remoteContentDigest(fs, record.remotePath);
    if (remote.contentSha256 != recordedDigest) return record;
    final repaired = record.copyWith(
      remoteSnapshot: RemoteFileEntry(
        path: latest.path,
        name: latest.name,
        type: latest.type,
        size: latest.size,
        uid: latest.uid,
        gid: latest.gid,
        accessedAt: latest.accessedAt,
        modifiedAt: latest.modifiedAt,
        mode: latest.mode,
        contentSha256: remote.contentSha256,
      ),
      needsReconcile: false,
    );
    await _store.update(repaired);
    _records[repaired.id] = repaired;
    return repaired;
  }

  // ---------------------------------------------------------------------
  // Watching (06 §3.3) — parent directory, 600 ms debounce, reconcile only
  // ---------------------------------------------------------------------

  void _watch(ManagedRemoteFile record) {
    if (_disposed || _watches.containsKey(record.id)) return;
    final directory = _store.checkoutDirectory(record.localPath);
    final ownName = p.basename(record.localPath);
    try {
      late final StreamSubscription<FileSystemEvent> subscription;
      subscription = _watchDirectory(directory.path).listen(
        (event) {
          final name = p.basename(event.path);
          // The record's own basename always reconciles — even when it
          // carries a generated shape (a remote file legitimately named
          // `.poltergeist-<hex>.tmp`). Everything else is filtered to
          // exact generated pipeline temps and the lifecycle markers;
          // any other sibling event still reconciles (debounce absorbs
          // the noise — atomic-replacement saves need the net wide).
          if (name != ownName &&
              (name == ManagedRemoteFileStore.epochMarkerName ||
                  name == ManagedRemoteFileStore.abandonedMarkerName ||
                  ManagedRemoteFileStore.generatedTempName.hasMatch(name))) {
            return;
          }
          _scheduleReconcile(record.id);
        },
        onError: (_) {
          if (identical(_watches[record.id], subscription)) {
            _watches.remove(record.id);
          }
          // Watch failure falls back to reconcile-on-resume — and one
          // immediate reconcile so the missed events' window closes now.
          _scheduleReconcile(record.id);
        },
        onDone: () {
          if (identical(_watches[record.id], subscription)) {
            _watches.remove(record.id);
          }
        },
        cancelOnError: true,
      );
      _watches[record.id] = subscription;
    } on FileSystemException {
      // No watch on this platform/path — resume reconciliation is the
      // designed fallback (06 §3.3).
    }
  }

  void _scheduleReconcile(String id) {
    _debounces[id]?.cancel();
    // First pending event stamps a deadline; resets past it fire at
    // once so continuous sibling noise cannot starve reconciliation.
    final deadline = _reconcileDeadlines.putIfAbsent(
      id,
      () => DateTime.now().add(watchReconcileMaxDelay),
    );
    if (!DateTime.now().isBefore(deadline)) {
      _debounces.remove(id);
      _reconcileDeadlines.remove(id);
      unawaited(_reconcileCheckout(id));
      return;
    }
    _debounces[id] = Timer(watchDebounce, () {
      _reconcileDeadlines.remove(id);
      unawaited(_reconcileCheckout(id));
    });
  }

  Future<void> _reconcileCheckout(String id) async {
    try {
      final updated = await _store.reconcile(id);
      if (_disposed || updated == null) return;
      _records[id] = updated;
      _emitChange();
    } catch (error, stack) {
      // A debounced reconcile racing disposal — or any store read
      // failure — reports instead of surfacing as an unhandled error
      // on the watcher's unawaited future.
      onError?.call(error, stack);
    }
  }

  Future<void> _stopWatching(String id) async {
    _debounces.remove(id)?.cancel();
    _reconcileDeadlines.remove(id);
    await _watches.remove(id)?.cancel();
  }

  // ---------------------------------------------------------------------
  // Queue observation — checkout transfers terminal → caller futures
  // ---------------------------------------------------------------------

  /// Completes when the managed task terminals: the remote-side entry on
  /// success; the task's failure otherwise (conflict included — the
  /// caller maps it into the conflict flow).
  Future<RemoteFileEntry> _awaitTask(TransferTask task) {
    if (task.isTerminal) return _taskOutcome(task);
    final pending = _PendingTransfer();
    _pendingTransfers[task.id] = pending;
    // The event may already have arrived before the subscription was
    // registered — a second terminal check keeps the fast path exact.
    if (task.isTerminal) {
      _pendingTransfers.remove(task.id);
      return _taskOutcome(task);
    }
    // A dispose that raced past the pending-erroring loop would leave
    // this registration orphaned — the subscription is already gone, so
    // no terminal event will ever arrive.
    if (_disposed) {
      _pendingTransfers.remove(task.id);
      return Future.error(
        RemoteFileException(
          kind: RemoteFileErrorKind.cancelled,
          operation: 'managed checkout transfer',
          message: 'the checkout manager was disposed',
        ),
      );
    }
    return pending.completer.future;
  }

  void _onQueueEvent(TransferQueueEvent event) {
    final pending = _pendingTransfers[event.taskId];
    if (pending == null) return;
    final task = _taskById(event.taskId);
    if (task == null) {
      // The task left the queue before its terminal event reached us
      // (removeTask's clear-finished gesture only drops terminal
      // tasks) — nothing else will ever complete this waiter, so fail
      // it rather than hang.
      _pendingTransfers.remove(event.taskId);
      pending.completer.completeError(
        RemoteFileException(
          kind: RemoteFileErrorKind.other,
          operation: 'managed checkout transfer',
          message: 'the transfer task is no longer tracked by the queue',
        ),
      );
      return;
    }
    if (!task.isTerminal) return;
    _pendingTransfers.remove(event.taskId);
    _taskOutcome(task).then(
      pending.completer.complete,
      onError: pending.completer.completeError,
    );
  }

  TransferTask? _taskById(String taskId) {
    for (final task in _queue.tasks) {
      if (task.id == taskId) return task;
    }
    return null;
  }

  Future<RemoteFileEntry> _taskOutcome(TransferTask task) {
    final item = task.items.where((i) => !i.isDirectory).firstOrNull;
    switch (task.state) {
      case TransferTaskState.completed:
        final entry = item?.resultEntry;
        if (entry == null) {
          return Future.error(
            RemoteFileException(
              kind: RemoteFileErrorKind.other,
              operation: 'managed checkout transfer',
              message: 'the transfer completed without a remote entry',
            ),
          );
        }
        return Future.value(entry);
      case TransferTaskState.cancelled:
        return Future.error(
          RemoteFileException(
            kind: RemoteFileErrorKind.cancelled,
            operation: 'managed checkout transfer',
            path: task.spec.managedCheckout?.remotePath,
            message: task.error ?? 'Transfer cancelled.',
          ),
        );
      default:
        return Future.error(
          RemoteFileException(
            kind: task.failureKind ?? RemoteFileErrorKind.other,
            operation: 'managed checkout transfer',
            path: task.spec.managedCheckout?.remotePath,
            message: task.error ?? 'the managed transfer failed',
          ),
        );
    }
  }

  void _emitChange() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<RemoteFileEntry?> _statOrNull(RemoteFileSystem fs, String path) async {
    try {
      return await fs.stat(path, followLinks: false);
    } on RemoteFileException catch (error) {
      if (error.kind == RemoteFileErrorKind.notFound) return null;
      rethrow;
    }
  }

  static Stream<FileSystemEvent> _defaultWatch(String directoryPath) =>
      Directory(directoryPath).watch();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _queueSubscription?.cancel();
    for (final timer in _debounces.values) {
      timer.cancel();
    }
    _debounces.clear();
    _reconcileDeadlines.clear();
    try {
      await Future.wait(_watches.values.map((sub) => sub.cancel()));
    } on Object catch (error, stack) {
      // One failing watch cancel must not abort the rest of teardown.
      onError?.call(error, stack);
    }
    _watches.clear();
    for (final pending in _pendingTransfers.values) {
      if (pending.completer.isCompleted) continue;
      pending.completer.completeError(
        RemoteFileException(
          kind: RemoteFileErrorKind.cancelled,
          operation: 'managed checkout transfer',
          message: 'the checkout manager was disposed',
        ),
      );
    }
    _pendingTransfers.clear();
    await _changes.close();
  }
}

class _CheckoutFlight {
  _CheckoutFlight(this.remotePath);
  String remotePath;
  final completer = Completer<ManagedRemoteFile>();
}

class _PendingTransfer {
  final Completer<RemoteFileEntry> completer = Completer();
}
