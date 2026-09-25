import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:seance_core/seance_core.dart';

import '../connection/connection_manager.dart';
import '../fs/content_digest.dart';
import 'engine_client.dart';
import 'protocol.dart';

/// Resolves a bookmark-derived serverId (03 §3.5) to the [ServerConfig]
/// a lease dials with. The engine holds no bookmark store, so every
/// connection-bearing request carries the config — and a lease can be a
/// server's first connection (a restored task, a sync run), so the
/// config cannot come from an earlier browse.
abstract interface class ServerConfigSource {
  /// The config [serverId] dials with, or null when the app holds none —
  /// a Quick Connect `adhoc:` id exists only in its tab, so the engine
  /// falls back to the config the tab's browse open supplied (and
  /// refuses typed when there was none). Throws a typed
  /// [RemoteFileException] when [serverId] names a server that can no
  /// longer be dialed (a catalog reference the synced catalog lost).
  Future<ServerConfig?> configFor(String serverId);
}

/// The UI-isolate [ConnectionManager] over the engine's pool — the
/// bridged lease (protocol v13, the D8 addendum). The transfer queue, the
/// checkout manager, the preview producer, and the sync endpoints lease
/// through it exactly as they would lease in-process; each lease's [fs]
/// is an [EngineRemoteFileSystem] whose calls run engine-side on the
/// borrowed SFTP channel.
///
/// Browse channels are not served here: panes open theirs through the
/// engine client's own browse surface, so [openBrowseChannel] refuses
/// typed rather than inventing a second browse path.
final class EngineConnectionManager implements ConnectionManager {
  EngineConnectionManager(
    this._client, {
    required this._configs,
    this.windowBytes = defaultWindowBytes,
  });

  /// Default per-stream flow-control window: at most this many bytes of
  /// one transfer sit between the engine and the consumer's sink.
  static const int defaultWindowBytes = 1024 * 1024;

  final EngineClient _client;
  final ServerConfigSource _configs;

  /// The per-stream window every lease's filesystem streams with.
  final int windowBytes;

  @override
  Future<TransferChannelLease> leaseTransferChannel(String serverId) async {
    final config = await _configs.configFor(serverId);
    final leaseId = await _client.leaseTransferChannel(
      serverId: serverId,
      config: config,
    );
    return _EngineTransferLease(
      _client,
      EngineRemoteFileSystem(
        _client,
        LeaseTarget(leaseId),
        windowBytes: windowBytes,
      ),
      leaseId,
    );
  }

  @override
  Future<PaneChannel> openBrowseChannel(
    String serverId, {
    required String paneTabId,
  }) => Future.error(
    const RemoteFileException(
      kind: RemoteFileErrorKind.unsupported,
      operation: 'open browse channel',
      message:
          'Browse channels open through the engine client, not the '
          'transfer seam.',
    ),
  );

  @override
  Stream<ServerStatus> watchServer(String serverId) =>
      _client.watchServer(serverId);

  @override
  Stream<ConnectLogLine> get connectLog => _client.connectionLog.expand(
    (batch) => [
      for (final line in batch.lines)
        ConnectLogLine(serverId: batch.serverId, line: line),
    ],
  );

  @override
  Future<Set<String>> connectedServerIds() => _client.connectedServerIds();

  @override
  Future<void> disconnectServer(String serverId) =>
      _client.disconnectServer(serverId);

  @override
  Future<void> removeBookmark(String serverId) =>
      _client.removeBookmark(serverId);
}

/// One engine-held lease, mirrored UI-side.
final class _EngineTransferLease implements TransferChannelLease {
  _EngineTransferLease(this._client, this.fs, this._leaseId);

  final EngineClient _client;
  final int _leaseId;
  bool _released = false;

  /// Stable for the lease's lifetime. After [release] its calls fail
  /// `disconnected` engine-side — the retired id is unknown there.
  @override
  final EngineRemoteFileSystem fs;

  @override
  Future<void> release() async {
    // Release belongs to this borrower: once, never again.
    if (_released) return;
    _released = true;
    try {
      await _client.releaseTransferLease(_leaseId);
    } on RemoteFileException catch (error) {
      // A dead engine released every lease by definition.
      if (error.kind != RemoteFileErrorKind.disconnected) rethrow;
    }
  }

  /// The engine host reports `disconnected` failures of lease operations
  /// to its pool itself, before the answer crosses — a UI-side report
  /// would name a filesystem the pool has never seen.
  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
}

/// A [RemoteFileSystem] whose calls run engine-side on a lease or a
/// browse channel (protocol v13). Failures arrive as the typed
/// [RemoteFileException]s the engine's VFS raised (kind, operation, path,
/// message — the unsendable `cause` stays engine-side).
///
/// The two byte-carrying calls are credit-flow-controlled streams, only
/// available on a lease:
/// - [download] hands chunks to the destination sink through its
///   `addStream`, so the sink's own backpressure (a paused subscription)
///   withholds credit and stalls the remote read engine-side. A failure
///   raised by the sink itself is wrapped exactly as the VFS adapter
///   wraps it (`Could not download "p": …`, the sink error as `cause`),
///   so message-keyed callers (the editor-limit suffix) see what they
///   saw in-process.
/// - [upload] subscribes to its content only once the engine-side VFS
///   subscribed to its own — an upload refused before reading (an
///   existing target) never pulls a byte, like the in-process adapter —
///   and keeps at most one window unconsumed.
///
/// Neither completes before the engine's final answer: a cancelled
/// transfer has really unwound engine-side before its lease can return.
final class EngineRemoteFileSystem
    implements RemoteFileSystem, ContentDigestSource {
  EngineRemoteFileSystem(
    this._client,
    this._target, {
    this.windowBytes = EngineConnectionManager.defaultWindowBytes,
  });

  final EngineClient _client;
  final VfsTarget _target;

  /// The per-stream flow-control window.
  final int windowBytes;

  Future<EngineResult> _op(VfsOp op) => _client.runVfsOp(_target, op);

  @override
  Future<String> canonicalize(String path) async =>
      (await _op(VfsCanonicalize(path)) as VfsStringResult).value;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async =>
      (await _op(VfsListDirectory(path)) as DirectoryListed).entries;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async =>
      (await _op(VfsStat(path, followLinks: followLinks)) as VfsEntryResult)
          .entry;

  @override
  Future<void> setMode(String path, int permissions) async {
    await _op(VfsSetMode(path, permissions));
  }

  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) async {
    await _op(
      VfsSetTimes(path, accessedAt: accessedAt, modifiedAt: modifiedAt),
    );
  }

  @override
  Future<void> setOwner(String path, {int? uid, int? gid}) async {
    await _op(VfsSetOwner(path, uid: uid, gid: gid));
  }

  @override
  Future<String> readSymbolicLink(String path) async =>
      (await _op(VfsReadSymbolicLink(path)) as VfsStringResult).value;

  @override
  Future<void> createSymbolicLink(String linkPath, String targetPath) async {
    await _op(VfsCreateSymbolicLink(linkPath, targetPath));
  }

  @override
  Future<void> createDirectory(String path) async {
    await _op(VfsCreateDirectory(path));
  }

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) async {
    await _op(VfsRename(oldPath, newPath, overwrite: overwrite));
  }

  @override
  Future<void> delete(RemoteFileEntry entry) async {
    await _op(VfsDelete(entry));
  }

  /// Creates an empty regular file — a typed conflict when [path] exists.
  Future<RemoteFileEntry> createEmptyFile(String path) async =>
      (await _op(VfsCreateEmptyFile(path)) as VfsEntryResult).entry;

  @override
  Future<RemoteFileEntry> contentDigest(String path) async =>
      (await _op(VfsContentDigest(path)) as VfsEntryResult).entry;

  int _leaseFor(String operation, String path) => switch (_target) {
    LeaseTarget(:final leaseId) => leaseId,
    ChannelTarget() => throw RemoteFileException(
      kind: RemoteFileErrorKind.unsupported,
      operation: operation,
      path: path,
      message: 'Byte streams run on transfer leases, not browse channels.',
    ),
  };

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    final leaseId = _leaseFor('download', path);
    if (cancellation?.isCancelled ?? false) {
      throw _cancelled('download', path);
    }
    final stream = _client.openDownloadStream(
      leaseId: leaseId,
      path: path,
      computeHash: computeHash,
      windowBytes: windowBytes,
    );
    final creditEvery = windowBytes ~/ 4 < 1 ? 1 : windowBytes ~/ 4;
    final queue = ListQueue<Uint8List>();
    var delivered = 0;
    var uncredited = 0;
    int? total;
    var engineDone = false;
    Object? engineFailure;
    var localClosed = false;
    var cancelledForSink = false;
    late final StreamController<List<int>> local;

    void flushCredit() {
      if (uncredited == 0) return;
      stream.credit(uncredited);
      uncredited = 0;
    }

    void pump() {
      if (localClosed) return;
      while (queue.isNotEmpty && local.hasListener && !local.isPaused) {
        final chunk = queue.removeFirst();
        local.add(chunk);
        delivered += chunk.length;
        uncredited += chunk.length;
        onProgress?.call(delivered, total);
        if (uncredited >= creditEvery) flushCredit();
      }
      // A consumer that keeps up returns everything it took: the engine
      // never waits on credit the consumer is merely sitting on.
      if (queue.isEmpty) flushCredit();
      if (queue.isEmpty && engineDone) {
        localClosed = true;
        final failure = engineFailure;
        // The source's failure travels into the sink the way the VFS
        // adapter's own read stream would fail inside `addStream` — pipe
        // sinks record it as the source-side error (03 §4.5).
        if (failure != null) local.addError(failure);
        unawaited(local.close());
      }
    }

    void cancelEngine() {
      if (engineDone) return;
      stream.cancel();
    }

    local = StreamController<List<int>>(
      onListen: pump,
      onResume: pump,
      onCancel: () {
        // The sink stopped reading before the end: nothing more is
        // wanted from the server.
        if (!localClosed) {
          cancelledForSink = true;
          cancelEngine();
        }
      },
    );

    Object? sinkError;
    final sinkDone = destination
        .addStream(local.stream)
        .then<void>(
          (_) {},
          onError: (Object error) {
            sinkError = error;
            cancelledForSink = true;
            cancelEngine();
          },
        );
    unawaited(
      cancellation?.whenCancelled.then<void>(
        (_) => cancelEngine(),
        onError: (Object _) => cancelEngine(),
      ),
    );

    final eventsDone = Completer<void>();
    stream.events.listen((event) {
      if (event is! DownloadChunkEvent) return;
      final bytes = event.bytes.materialize().asUint8List();
      if (event.total != null) total = event.total;
      if (localClosed) return;
      queue.add(bytes);
      pump();
    }, onDone: eventsDone.complete);

    RemoteFileEntry? entry;
    try {
      entry = (await stream.result as VfsEntryResult).entry;
    } on Object catch (error) {
      engineFailure = error;
    }
    // Every chunk precedes the answer on the port; the route closes after
    // them, so waiting for its end means the queue holds the whole tail.
    await eventsDone.future;
    engineDone = true;
    pump();
    await sinkDone;

    if (cancellation?.isCancelled ?? false) throw _cancelled('download', path);
    final sinkFailure = sinkError;
    final failure = engineFailure;
    if (sinkFailure != null &&
        !identical(sinkFailure, failure) &&
        (failure == null || cancelledForSink)) {
      throw _asVfsError('download', path, sinkFailure);
    }
    if (failure != null) throw failure;
    return entry!;
  }

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
  }) async {
    final leaseId = _leaseFor('upload', path);
    if (cancellation?.isCancelled ?? false) throw _cancelled('upload', path);
    final stream = _client.openUploadStream(
      leaseId: leaseId,
      path: path,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      computeHash: computeHash,
      windowBytes: windowBytes,
    );
    StreamSubscription<List<int>>? subscription;
    var sent = 0;
    var consumed = 0;
    var paused = false;
    var contentFinished = false;
    var finished = false;
    Object? contentError;

    void updateFlow() {
      final current = subscription;
      if (current == null || contentFinished) return;
      final full = sent - consumed >= windowBytes;
      if (full && !paused) {
        paused = true;
        current.pause();
      } else if (!full && paused) {
        paused = false;
        current.resume();
      }
    }

    void startContent() {
      if (subscription != null || finished) return;
      subscription = content.listen(
        (chunk) {
          if (chunk.isEmpty) return;
          final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
          stream.sendChunk(bytes);
          sent += bytes.length;
          updateFlow();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (contentFinished) return;
          contentFinished = true;
          contentError = error;
          stream.abort(
            EngineError.fromException(_asVfsError('upload', path, error)),
          );
          unawaited(subscription?.cancel());
        },
        onDone: () {
          if (contentFinished) return;
          contentFinished = true;
          stream.end();
        },
        cancelOnError: true,
      );
    }

    unawaited(
      cancellation?.whenCancelled.then<void>(
        (_) {
          if (!finished) stream.cancel();
        },
        onError: (Object _) {
          if (!finished) stream.cancel();
        },
      ),
    );

    final eventsDone = Completer<void>();
    stream.events.listen((event) {
      switch (event) {
        case UploadReadyEvent():
          startContent();
        case final UploadProgressEvent progress:
          consumed = progress.consumed;
          final committed = progress.committed;
          if (committed != null) onProgress?.call(committed, length);
          updateFlow();
        case _:
          break;
      }
    }, onDone: eventsDone.complete);

    RemoteFileEntry? entry;
    Object? engineFailure;
    try {
      entry = (await stream.result as VfsEntryResult).entry;
    } on Object catch (error) {
      engineFailure = error;
    }
    finished = true;
    await eventsDone.future;
    // The engine stopped consuming (committed, refused, or failed): a
    // content subscription still open is released like the adapter's
    // own `await for` exit releases it.
    final open = subscription;
    if (open != null && !contentFinished) {
      contentFinished = true;
      unawaited(open.cancel().then<void>((_) {}, onError: (Object _) {}));
    }

    if (cancellation?.isCancelled ?? false) throw _cancelled('upload', path);
    // A content failure is the root cause of whatever the engine then
    // reported — the adapter's `await for` rethrows it as-is (wrapped).
    final localFailure = contentError;
    if (localFailure != null) throw _asVfsError('upload', path, localFailure);
    if (engineFailure != null) throw engineFailure;
    final committedEntry = entry!;
    onProgress?.call(sent, length);
    return committedEntry;
  }
}

RemoteFileException _cancelled(String operation, String path) =>
    RemoteFileException(
      kind: RemoteFileErrorKind.cancelled,
      operation: operation,
      path: path,
      message: 'Transfer cancelled.',
    );

/// The VFS adapter's own error funnel for failures raised outside the
/// SFTP layer (a sink or content-stream error): typed errors pass
/// through, a timeout is transport silence, anything else is `other`
/// with the adapter's message shape and the original as `cause`.
RemoteFileException _asVfsError(String operation, String path, Object error) {
  if (error is RemoteFileException) return error;
  if (error is TimeoutException) {
    return RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: operation,
      path: path,
      message: 'Could not $operation "$path": the server did not respond',
      cause: error,
    );
  }
  return RemoteFileException(
    kind: RemoteFileErrorKind.other,
    operation: operation,
    path: path,
    message: 'Could not $operation "$path": $error',
    cause: error,
  );
}
