import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:seance_core/seance_core.dart';

import '../connection/connection_manager.dart';
import 'protocol.dart';

/// The engine half of the bridged transfer lease (protocol v13, the D8
/// addendum): the lease table, the generic VFS-op dispatch over leases
/// and browse channels, and the download/upload streams with their
/// credit flow control.
///
/// ```
/// UI isolate                         engine isolate
/// EngineRemoteFileSystem ──VfsOp──►  LeaseHost ──► lease.fs (SFTP)
///    download ◄──DownloadChunkEvent── _DownloadSink ◄── fs.download
///             ──StreamCredit──────►   (window: sent − credited)
///    upload   ──UploadChunk───────►  _UploadStream ──► fs.upload
///             ◄──UploadProgress─────  (credit: bytes the VFS pulled)
/// ```
///
/// Owned by [EngineHost]; every request body answers through the host's
/// single-response guard, and every fire-and-forget stream message for a
/// stream that already finished is dropped silently — late credit and
/// late chunks are the normal tail of a cancelled or failed stream, never
/// a protocol fault.
class LeaseHost {
  LeaseHost({
    required this._manager,
    required this._events,
    required this._channels,
    required this._drainTimeout,
  });

  final ConnectionManager _manager;
  final SendPort _events;

  /// The host's own channel routing map (shared, not copied): channel
  /// targets resolve against the live table, so a closed channel refuses.
  final Map<int, PaneChannel> _channels;
  final Duration _drainTimeout;

  final Map<int, _HostLease> _leases = {};
  final Map<int, _HostStream> _streams = {};
  int _nextLeaseId = 1;
  bool _closed = false;

  /// Live leases — diagnostics and tests.
  int get leaseCount => _leases.length;

  /// Live streams — diagnostics and tests.
  int get streamCount => _streams.length;

  /// Borrows a channel (blocking while the pool is at capacity). A grant
  /// that lands after [shutdown] started is returned at once and the
  /// request fails typed — nothing is minted into a closing table.
  Future<EngineResult> lease(String serverId) async {
    _rejectIfClosed('lease transfer channel');
    final lease = await _manager.leaseTransferChannel(serverId);
    if (_closed) {
      try {
        await lease.release();
      } on Object {
        // The engine is going away; the pool teardown owns the channel.
      }
      _rejectIfClosed('lease transfer channel');
    }
    final leaseId = _nextLeaseId++;
    _leases[leaseId] = _HostLease(serverId, lease);
    return TransferLeaseGranted(leaseId: leaseId);
  }

  /// Retires the lease id at once (no new operation can start on it),
  /// waits — bounded — for its in-flight operations to settle, then
  /// returns the channel. Unknown ids ack: release is idempotent.
  Future<EngineResult> release(int leaseId) async {
    final entry = _leases.remove(leaseId);
    if (entry == null) return const EngineAck();
    await entry.drained().timeout(_drainTimeout, onTimeout: () {});
    await entry.lease.release();
    return const EngineAck();
  }

  /// Dispatches one [VfsOp] on its target.
  Future<EngineResult> op(VfsOpRequest request) {
    final op = request.op;
    return _run(request.target, op.operation, (fs) => _dispatch(fs, op));
  }

  Future<EngineResult> _dispatch(RemoteFileSystem fs, VfsOp op) async {
    switch (op) {
      case VfsCanonicalize(:final path):
        return VfsStringResult(value: await fs.canonicalize(path));
      case VfsListDirectory(:final path):
        return DirectoryListed(entries: await fs.listDirectory(path));
      case VfsStat(:final path, :final followLinks):
        return VfsEntryResult(
          entry: await fs.stat(path, followLinks: followLinks),
        );
      case VfsSetMode(:final path, :final permissions):
        // The host is the trust boundary for cross-port arguments.
        if (permissions < 0 || permissions > 0xFFF) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.unsupported,
            operation: op.operation,
            path: path,
            message: 'The mode must be a twelve-bit value (0x000-0xFFF).',
          );
        }
        await fs.setMode(path, permissions);
        return const EngineAck();
      case VfsSetTimes(:final path, :final accessedAt, :final modifiedAt):
        if (accessedAt == null && modifiedAt == null) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.unsupported,
            operation: op.operation,
            path: path,
            message:
                'At least one of the access and modification times '
                'must be given.',
          );
        }
        await fs.setTimes(path, accessedAt: accessedAt, modifiedAt: modifiedAt);
        return const EngineAck();
      case VfsSetOwner(:final path, :final uid, :final gid):
        if (uid == null && gid == null) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.unsupported,
            operation: op.operation,
            path: path,
            message: 'At least one of the owner and group ids must be given.',
          );
        }
        await fs.setOwner(path, uid: uid, gid: gid);
        return const EngineAck();
      case VfsReadSymbolicLink(:final path):
        return VfsStringResult(value: await fs.readSymbolicLink(path));
      case VfsCreateSymbolicLink(:final linkPath, :final targetPath):
        await fs.createSymbolicLink(linkPath, targetPath);
        return const EngineAck();
      case VfsCreateDirectory(:final path):
        await fs.createDirectory(path);
        return const EngineAck();
      case VfsRename(:final oldPath, :final newPath, :final overwrite):
        await fs.rename(oldPath, newPath, overwrite: overwrite);
        return const EngineAck();
      case VfsDelete(:final entry):
        await fs.delete(entry);
        return const EngineAck();
      case VfsCreateEmptyFile(:final path):
        // The VFS's own upload: temporary sibling, exclusive create, and
        // rename-into-place — an existing target is a typed conflict.
        return VfsEntryResult(
          entry: await fs.upload(
            path,
            const Stream<List<int>>.empty(),
            length: 0,
            computeHash: false,
          ),
        );
      case VfsContentDigest(:final path):
        return VfsEntryResult(
          entry: await fs.download(path, _DiscardSink(), computeHash: true),
        );
    }
  }

  /// Streams a download into [DownloadChunkEvent]s under the window.
  Future<EngineResult> download(DownloadStreamRequest request) {
    final streamId = request.requestId;
    return _run(LeaseTarget(request.leaseId), 'download', (fs) async {
      final sink = _DownloadSink(
        leaseId: request.leaseId,
        streamId: streamId,
        path: request.path,
        windowBytes: request.windowBytes,
        events: _events,
      );
      _streams[streamId] = sink;
      try {
        final entry = await fs.download(
          request.path,
          sink,
          onProgress: sink.onProgress,
          cancellation: sink.token,
          computeHash: request.computeHash,
        );
        // A VFS that finished without tripping on a cancel still honors
        // it: the consumer asked for nothing more.
        sink.throwIfCancelled();
        await sink.flush();
        return VfsEntryResult(entry: entry);
      } finally {
        _streams.remove(streamId);
        sink.dispose();
      }
    });
  }

  /// Feeds an upload from [UploadChunkRequest]s.
  Future<EngineResult> upload(UploadStreamRequest request) {
    final streamId = request.requestId;
    return _run(LeaseTarget(request.leaseId), 'upload', (fs) async {
      final stream = _UploadStream(
        leaseId: request.leaseId,
        streamId: streamId,
        windowBytes: request.windowBytes,
        events: _events,
      );
      _streams[streamId] = stream;
      try {
        final entry = await fs.upload(
          request.path,
          stream.content,
          length: request.length,
          overwrite: request.overwrite,
          preserveMode: request.preserveMode,
          expectedTarget: request.expectedTarget,
          onProgress: stream.onProgress,
          cancellation: stream.token,
          computeHash: request.computeHash,
        );
        return VfsEntryResult(entry: entry);
      } finally {
        _streams.remove(streamId);
        stream.dispose();
      }
    });
  }

  void credit(StreamCreditRequest request) {
    final stream = _streams[request.streamId];
    if (stream is _DownloadSink) stream.credit(request.bytes);
  }

  void chunk(UploadChunkRequest request) {
    final stream = _streams[request.streamId];
    if (stream is _UploadStream) {
      stream.chunk(request.bytes);
    } else {
      // Late chunk for a finished stream: still materialize so the
      // transferred buffer is released now rather than at collection.
      request.bytes.materialize();
    }
  }

  void end(UploadEndRequest request) {
    final stream = _streams[request.streamId];
    if (stream is _UploadStream) stream.end();
  }

  void abort(UploadAbortRequest request) {
    final stream = _streams[request.streamId];
    if (stream is _UploadStream) stream.abort(request.error.toException());
  }

  void cancel(CancelVfsStreamRequest request) {
    _streams[request.streamId]?.cancel();
  }

  /// The pool force-released [serverId]'s leases (disconnect or bookmark
  /// removal): their ids retire and their streams cancel, so the proxy's
  /// next operation fails `disconnected` and the queue re-leases —
  /// exactly the in-process lease's post-force-release behavior.
  void dropServer(String serverId) {
    final dropped = [
      for (final entry in _leases.entries)
        if (entry.value.serverId == serverId) entry.key,
    ];
    if (dropped.isEmpty) return;
    for (final leaseId in dropped) {
      _leases.remove(leaseId);
    }
    for (final stream in List.of(_streams.values)) {
      if (dropped.contains(stream.leaseId)) stream.cancel();
    }
  }

  /// Engine shutdown: refuse new leases, cancel every stream, and return
  /// every lease (bounded per lease by the drain timeout).
  Future<void> shutdown() async {
    _closed = true;
    for (final stream in List.of(_streams.values)) {
      stream.cancel();
    }
    final leases = List.of(_leases.values);
    _leases.clear();
    await Future.wait([
      for (final entry in leases)
        entry
            .drained()
            .timeout(_drainTimeout, onTimeout: () {})
            .then((_) => entry.lease.release())
            .catchError((Object _) {}),
    ]);
  }

  void _rejectIfClosed(String operation) {
    if (!_closed) return;
    throw RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: operation,
      message: 'The engine is shutting down.',
    );
  }

  /// Resolves [target], captures its VFS once, and runs [body] counted
  /// against the lease's in-flight set. A `disconnected` failure is
  /// reported to the binding before the answer crosses the port — the
  /// pool's identity check ignores reports from a VFS it already replaced.
  Future<EngineResult> _run(
    VfsTarget target,
    String operation,
    Future<EngineResult> Function(RemoteFileSystem fs) body,
  ) async {
    final binding = _bindingFor(target, operation);
    final fs = binding.fs;
    final token = binding.enter();
    try {
      return await body(fs);
    } on RemoteFileException catch (error) {
      binding.reportFailure(fs, error);
      rethrow;
    } finally {
      binding.exit(token);
    }
  }

  _Binding _bindingFor(VfsTarget target, String operation) {
    switch (target) {
      case LeaseTarget(:final leaseId):
        final entry = _leases[leaseId];
        if (entry == null) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.disconnected,
            operation: operation,
            message: 'The transfer lease was released.',
          );
        }
        return _LeaseBinding(entry);
      case ChannelTarget(:final channelId):
        final channel = _channels[channelId];
        if (channel == null) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.disconnected,
            operation: operation,
            message: 'The browse channel is closed.',
          );
        }
        return _ChannelBinding(channel);
    }
  }
}

final class _HostLease {
  _HostLease(this.serverId, this.lease);

  final String serverId;
  final TransferChannelLease lease;
  int _inFlight = 0;
  Completer<void>? _idle;

  Future<void> drained() {
    if (_inFlight == 0) return Future<void>.value();
    return (_idle ??= Completer<void>()).future;
  }

  void enter() => _inFlight++;

  void exit() {
    _inFlight--;
    if (_inFlight == 0) {
      final idle = _idle;
      _idle = null;
      idle?.complete();
    }
  }
}

sealed class _Binding {
  RemoteFileSystem get fs;
  Object? enter();
  void exit(Object? token);
  void reportFailure(RemoteFileSystem fs, RemoteFileException error);
}

final class _LeaseBinding extends _Binding {
  _LeaseBinding(this._entry);

  final _HostLease _entry;

  @override
  RemoteFileSystem get fs => _entry.lease.fs;

  @override
  Object? enter() {
    _entry.enter();
    return null;
  }

  @override
  void exit(Object? token) => _entry.exit();

  @override
  void reportFailure(RemoteFileSystem fs, RemoteFileException error) =>
      _entry.lease.reportFailure(fs, error);
}

final class _ChannelBinding extends _Binding {
  _ChannelBinding(this._channel);

  final PaneChannel _channel;

  @override
  RemoteFileSystem get fs => _channel.fs;

  @override
  Object? enter() => null;

  @override
  void exit(Object? token) {}

  @override
  void reportFailure(RemoteFileSystem fs, RemoteFileException error) =>
      _channel.reportFailure(fs, error);
}

sealed class _HostStream {
  _HostStream(this.leaseId);

  /// The lease the stream runs on — a force-released lease cancels it.
  final int leaseId;
  final RemoteTransferCancellation token = RemoteTransferCancellation();

  void cancel();
}

/// The download half: a [StreamSink] the VFS writes into. Chunks batch up
/// to [_batchBytes] before crossing; each batch waits while the window is
/// full (the wait pauses the VFS's `addStream` loop, which pauses the
/// SFTP read — backpressure all the way to the server).
final class _DownloadSink extends _HostStream implements StreamSink<List<int>> {
  _DownloadSink({
    required int leaseId,
    required this.streamId,
    required this.path,
    required int windowBytes,
    required this._events,
  }) : _window = windowBytes < 1 ? 1 : windowBytes,
       _batchBytes = _batchFor(windowBytes),
       super(leaseId);

  /// A quarter window per batch — a consumer that credits as it drains
  /// always has the next batch in flight — capped so one message stays
  /// small, and never below one byte.
  static int _batchFor(int windowBytes) {
    final quarter = windowBytes ~/ 4;
    if (quarter < 1) return 1;
    return quarter > _maxBatchBytes ? _maxBatchBytes : quarter;
  }

  static const int _maxBatchBytes = 256 * 1024;

  final int streamId;
  final String path;
  final int _window;
  final SendPort _events;
  final int _batchBytes;

  final List<Uint8List> _pending = [];
  int _pendingBytes = 0;
  int _inFlight = 0;
  int _transferred = 0;
  int? _total;
  Completer<void>? _creditWaiter;
  final Completer<void> _done = Completer<void>();
  bool _disposed = false;

  void onProgress(int transferred, int? total) {
    if (total != null) _total = total;
  }

  void credit(int bytes) {
    _inFlight -= bytes;
    if (_inFlight < 0) _inFlight = 0;
    _wake();
  }

  @override
  void cancel() {
    token.cancel();
    _wake();
  }

  void throwIfCancelled() {
    if (!token.isCancelled) return;
    throw RemoteFileException(
      kind: RemoteFileErrorKind.cancelled,
      operation: 'download',
      path: path,
      message: 'Transfer cancelled.',
    );
  }

  void _wake() {
    final waiter = _creditWaiter;
    _creditWaiter = null;
    waiter?.complete();
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      throwIfCancelled();
      _buffer(chunk);
      if (_pendingBytes >= _batchBytes) await _emit();
    }
    await _emit();
  }

  /// `add` cannot pause a producer (fakes and small writes use it): the
  /// batch is sent without waiting for credit, the same unconditional
  /// acceptance `BoundedTransferSink.add` documents.
  @override
  void add(List<int> event) {
    if (_disposed) return;
    _buffer(event);
    if (_pendingBytes >= _batchBytes) _sendPending();
  }

  void _buffer(List<int> chunk) {
    if (chunk.isEmpty) return;
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    _pending.add(bytes);
    _pendingBytes += bytes.length;
  }

  /// Sends whatever is buffered once the window has room (a lone batch
  /// larger than the window still goes when nothing is in flight — the
  /// window can never deadlock a big chunk).
  Future<void> _emit() async {
    while (_pendingBytes > 0 &&
        _inFlight > 0 &&
        _inFlight + _pendingBytes > _window) {
      throwIfCancelled();
      await (_creditWaiter ??= Completer<void>()).future;
    }
    throwIfCancelled();
    _sendPending();
  }

  void _sendPending() {
    if (_pendingBytes == 0 || _disposed) return;
    final size = _pendingBytes;
    _transferred += size;
    _inFlight += size;
    _events.send(
      DownloadChunkEvent(
        streamId: streamId,
        bytes: TransferableTypedData.fromList(_pending),
        length: size,
        transferred: _transferred,
        total: _total,
      ),
    );
    _pending.clear();
    _pendingBytes = 0;
  }

  /// The tail after the VFS returned (anything `add` buffered).
  Future<void> flush() => _emit();

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    // The VFS surfaces its own failures by throwing, not through the
    // sink; nothing to relay.
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  void dispose() {
    _disposed = true;
    _pending.clear();
    _pendingBytes = 0;
    _wake();
    if (!_done.isCompleted) _done.complete();
  }
}

/// The upload half: the content stream the VFS consumes. Chunks arrive
/// from the port; the stream counts what the VFS pulls and returns it as
/// credit in [UploadProgressEvent]s at least every quarter window, so the
/// client never has more than one window unconsumed.
final class _UploadStream extends _HostStream {
  _UploadStream({
    required int leaseId,
    required this.streamId,
    required int windowBytes,
    required this._events,
  }) : _reportEvery = (windowBytes ~/ 4) < 1 ? 1 : windowBytes ~/ 4,
       super(leaseId) {
    _controller = StreamController<List<int>>(
      onListen: () {
        if (!_disposed) _events.send(UploadReadyEvent(streamId: streamId));
      },
    );
    content = _controller.stream.map((chunk) {
      _consumed += chunk.length;
      if (_consumed - _reported >= _reportEvery) _report();
      return chunk;
    });
  }

  final int streamId;
  final SendPort _events;
  final int _reportEvery;
  late final StreamController<List<int>> _controller;
  late final Stream<List<int>> content;
  int _consumed = 0;
  int _reported = 0;
  int? _committed;
  int? _total;
  bool _ended = false;
  bool _disposed = false;

  void onProgress(int transferred, int? total) {
    _committed = transferred;
    if (total != null) _total = total;
  }

  void _report() {
    if (_disposed) return;
    _reported = _consumed;
    _events.send(
      UploadProgressEvent(
        streamId: streamId,
        consumed: _consumed,
        committed: _committed,
        total: _total,
      ),
    );
  }

  void chunk(TransferableTypedData bytes) {
    final data = bytes.materialize().asUint8List();
    if (_ended || _disposed) return;
    _controller.add(data);
  }

  void end() {
    if (_ended || _disposed) return;
    _ended = true;
    unawaited(_controller.close());
  }

  void abort(Object error) {
    if (_ended || _disposed) return;
    _ended = true;
    _controller.addError(error);
    unawaited(_controller.close());
  }

  @override
  void cancel() {
    token.cancel();
    // A VFS parked on the next chunk unwinds through its cancellation
    // race; closing the content as well means one that ignores the
    // token still stops.
    if (!_ended && !_disposed) {
      _ended = true;
      _controller.addError(
        const RemoteFileException(
          kind: RemoteFileErrorKind.cancelled,
          operation: 'upload',
          message: 'Transfer cancelled.',
        ),
      );
      unawaited(_controller.close());
    }
  }

  void dispose() {
    _disposed = true;
    if (!_ended) {
      _ended = true;
      unawaited(_controller.close());
    }
  }
}

/// Swallows a digest download's bytes — the hash rides the VFS stream.
final class _DiscardSink implements StreamSink<List<int>> {
  final Completer<void> _done = Completer<void>();

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
