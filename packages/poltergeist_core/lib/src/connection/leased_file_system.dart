import 'dart:async';

import 'package:seance_core/seance_core.dart';

import '../fs/content_digest.dart';
import 'connection_manager.dart';

/// A [RemoteFileSystem] over one server that leases a transfer channel on
/// demand (03 §3.2) — the shape sync's scanner and executor need (05
/// §11): they take a plain VFS, not a lease, and issue many calls
/// (pipelined listings, the case probe, per-item copies) across one scan
/// or run.
///
/// - The first call leases; concurrent calls share that one lease.
/// - [release] returns the lease; the next call leases again. The owner
///   releases when a scan or run ends, and an idle backstop
///   ([idleRelease]) returns a lease nobody used for a while, so a
///   forgotten owner cannot pin a pool channel for the app's lifetime.
/// - A `disconnected` failure drops the lease it came from, so the retry
///   the caller makes re-leases through the pool's reconnect instead of
///   reusing a dead channel — the queue's per-attempt lease rule.
final class LeasedRemoteFileSystem
    implements RemoteFileSystem, ContentDigestSource {
  LeasedRemoteFileSystem(
    this._connections,
    this.serverId, {
    this.idleRelease = const Duration(seconds: 30),
  });

  final ConnectionManager _connections;

  /// The bookmark-derived serverId (03 §3.5) every lease names.
  final String serverId;

  /// How long an unused lease is kept before it returns on its own; null
  /// keeps it until [release].
  final Duration? idleRelease;

  Future<TransferChannelLease>? _lease;
  int _active = 0;
  Timer? _idleTimer;

  /// Whether a lease is currently held (or being acquired).
  bool get holdsLease => _lease != null;

  /// Returns the held lease, if any. Calls in flight keep the lease they
  /// started on; the engine host drains them before the channel goes
  /// back to the pool. Idempotent; never throws.
  Future<void> release() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final pending = _lease;
    _lease = null;
    if (pending == null) return;
    try {
      await (await pending).release();
    } on Object {
      // A lease that never landed or a release into a dead engine leaves
      // nothing to return.
    }
  }

  Future<T> _run<T>(Future<T> Function(RemoteFileSystem fs) body) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final pending = _lease ??= _connections.leaseTransferChannel(serverId);
    _active++;
    try {
      final TransferChannelLease lease;
      try {
        lease = await pending;
      } on Object {
        if (identical(_lease, pending)) _lease = null;
        rethrow;
      }
      try {
        return await body(lease.fs);
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.disconnected &&
            identical(_lease, pending)) {
          _lease = null;
          unawaited(lease.release().catchError((Object _) {}));
        }
        rethrow;
      }
    } finally {
      _active--;
      _armIdle();
    }
  }

  void _armIdle() {
    final idle = idleRelease;
    if (idle == null || _active != 0 || _lease == null) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idle, () {
      _idleTimer = null;
      if (_active == 0) unawaited(release());
    });
  }

  @override
  Future<String> canonicalize(String path) =>
      _run((fs) => fs.canonicalize(path));

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) =>
      _run((fs) => fs.listDirectory(path));

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) =>
      _run((fs) => fs.stat(path, followLinks: followLinks));

  @override
  Future<void> setMode(String path, int permissions) =>
      _run((fs) => fs.setMode(path, permissions));

  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) => _run(
    (fs) => fs.setTimes(path, accessedAt: accessedAt, modifiedAt: modifiedAt),
  );

  @override
  Future<void> setOwner(String path, {int? uid, int? gid}) =>
      _run((fs) => fs.setOwner(path, uid: uid, gid: gid));

  @override
  Future<String> readSymbolicLink(String path) =>
      _run((fs) => fs.readSymbolicLink(path));

  @override
  Future<void> createSymbolicLink(String linkPath, String targetPath) =>
      _run((fs) => fs.createSymbolicLink(linkPath, targetPath));

  @override
  Future<void> createDirectory(String path) =>
      _run((fs) => fs.createDirectory(path));

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) => _run((fs) => fs.rename(oldPath, newPath, overwrite: overwrite));

  @override
  Future<void> delete(RemoteFileEntry entry) => _run((fs) => fs.delete(entry));

  @override
  Future<RemoteFileEntry> contentDigest(String path) =>
      _run((fs) => remoteContentDigest(fs, path));

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) => _run(
    (fs) => fs.download(
      path,
      destination,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    ),
  );

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) => _run(
    (fs) => fs.upload(
      path,
      content,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    ),
  );
}
