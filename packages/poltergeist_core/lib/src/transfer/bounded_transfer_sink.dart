import 'dart:async';

import 'package:seance_core/seance_core.dart';

/// An async per-chunk admission check (03 §4.3's token-bucket wait).
/// [bytes] is the chunk's size; [cancellation] is the sink's gate token
/// — cancelled on abort or attempt teardown so a parked wait unwinds
/// promptly instead of holding the pipe open until the next grant.
typedef TransferChunkGate = Future<void> Function(
  int bytes,
  RemoteTransferCancellation cancellation,
);

/// A `StreamSink<List<int>>` that bridges a VFS `download` into a VFS
/// `upload` with bounded in-memory buffering (03 §4.5's "small buffer"
/// contract — the piping transport itself is a later M4 slice, but the
/// engine already pipes every file hop through a sink, so a fast local
/// source writing into a slow remote consumer must not grow memory
/// unboundedly).
///
/// Backpressure rides on `addStream` pausing its source subscription once
/// [maxBufferedBytes] are in flight; [stream] — handed to the upload —
/// debits the buffer per consumed chunk and resumes the paused producer
/// below the high-water mark. `add` (used by fakes and small writes)
/// cannot pause a producer and is accepted unconditionally.
///
/// The optional [readGate]/[writeGate] add the token-bucket wait: a
/// gated read chunk parks on its grant *and* free buffer space before it
/// counts against the buffer, and a gated write chunk parks before the
/// upload consumes it (still counted, so the bound holds). Either wait
/// releases early when [cancellation] fires or the sink aborts — that is
/// how a dead upload stops a throttled source read without an orphaned
/// producer (03 §4.5).
class BoundedTransferSink implements StreamSink<List<int>> {
  BoundedTransferSink(
    this._controller, {
    required this.maxBufferedBytes,
    this._readGate,
    this._writeGate,
    RemoteTransferCancellation? cancellation,
  }) {
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then(
          (_) => _gateToken.cancel(),
          onError: (Object _) {},
        ),
      );
    }
  }

  final StreamController<List<int>> _controller;
  final int maxBufferedBytes;
  final TransferChunkGate? _readGate;
  final TransferChunkGate? _writeGate;

  /// The token every gate wait races — cancelled by [abort] or the
  /// attempt's own cancellation. Deliberately *not* cancelled by
  /// [close]: a normal close must still let a gated write chunk drain
  /// into the upload.
  final RemoteTransferCancellation _gateToken = RemoteTransferCancellation();

  final List<StreamSubscription<List<int>>> _subscriptions = [];
  final List<Completer<void>> _pendingAddStreams = [];

  int _buffered = 0;
  Completer<void>? _drained;
  bool _closed = false;

  /// Bytes currently buffered and not yet delivered to the consumer —
  /// the bounded-buffer contract's observable face for tests.
  int get bufferedBytes => _buffered;

  /// The error the source side surfaced, if any. The consumer stream
  /// relays source errors, so without this marker an upload-side watcher
  /// cannot tell "the upload failed" from "the source's failure arrived
  /// downstream" — 03 §4.5's side attribution depends on the difference.
  Object? get sourceError => _sourceError;
  Object? _sourceError;

  /// The upload-side view: each chunk the consumer pulls frees space and
  /// completes the pending drain waiter so a paused `addStream` resumes.
  /// Cached — a fresh `.map` per access would hand callers distinct
  /// wrappers over a single-subscription stream.
  late final Stream<List<int>> stream = _buildStream();

  Stream<List<int>> _buildStream() {
    var chunks = _controller.stream;
    final gate = _writeGate;
    if (gate != null) {
      chunks = chunks.asyncExpand((chunk) => _gatedChunk(chunk, gate));
    }
    return chunks.map((chunk) {
      _buffered -= chunk.length;
      final drained = _drained;
      if (drained != null && _buffered < maxBufferedBytes) {
        _drained = null;
        drained.complete();
      }
      return chunk;
    });
  }

  /// Holds a chunk upstream of the consumer until the write bucket
  /// grants it — the chunk keeps counting against the buffer while
  /// parked so the read side's bound still applies.
  Stream<List<int>> _gatedChunk(
    List<int> chunk,
    TransferChunkGate gate,
  ) async* {
    await gate(chunk.length, _gateToken);
    yield chunk;
  }

  @override
  void add(List<int> event) {
    if (_closed) return;
    _buffered += event.length;
    _controller.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _controller.addError(error, stackTrace);
  }

  @override
  Future<void> addStream(
    Stream<List<int>> stream, {
    bool? cancelOnError,
  }) {
    final done = Completer<void>();
    if (_closed) {
      done.completeError(StateError('transfer sink already closed'));
      return done.future;
    }
    _pendingAddStreams.add(done);
    late StreamSubscription<List<int>> subscription;
    subscription = stream.listen(
      (chunk) {
        if (_closed) return;
        if (_readGate != null) {
          // Gated: park on the bucket grant and on buffer space before
          // the chunk counts against the buffer.
          subscription.pause();
          unawaited(_forwardGated(chunk, subscription, done));
          return;
        }
        _buffered += chunk.length;
        _controller.add(chunk);
        if (_buffered >= maxBufferedBytes) {
          final drained = _drained ??= Completer<void>();
          subscription.pause(drained.future);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        // A failed source read is terminal for the hop: stop relaying so
        // no chunks flow after addStream has reported the failure.
        _sourceError ??= error;
        _subscriptions.remove(subscription);
        _pendingAddStreams.remove(done);
        unawaited(
          subscription.cancel().then<void>((_) {}, onError: (_) {}),
        );
        _controller.addError(error, stackTrace);
        if (!done.isCompleted) done.completeError(error);
      },
      onDone: () {
        _subscriptions.remove(subscription);
        _pendingAddStreams.remove(done);
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: cancelOnError ?? false,
    );
    _subscriptions.add(subscription);
    return done.future;
  }

  /// The gated read path: await the bucket grant, then buffer space,
  /// then deliver. A gate rejection while the sink is live (a limiter
  /// error, not teardown) unwinds the relay exactly like a source error.
  Future<void> _forwardGated(
    List<int> chunk,
    StreamSubscription<List<int>> subscription,
    Completer<void> done,
  ) async {
    try {
      await _readGate!(chunk.length, _gateToken);
      while (!_closed && _buffered >= maxBufferedBytes) {
        await (_drained ??= Completer<void>()).future;
      }
      if (_closed) return;
      _buffered += chunk.length;
      _controller.add(chunk);
      subscription.resume();
    } catch (error) {
      if (_closed) return;
      _sourceError ??= error;
      _controller.addError(error);
      _subscriptions.remove(subscription);
      _pendingAddStreams.remove(done);
      unawaited(
        subscription.cancel().then<void>((_) {}, onError: (_) {}),
      );
      if (!done.isCompleted) done.completeError(error);
    }
  }

  /// Unwinds both ends with [error] (a plain [StateError] when omitted):
  /// pending `addStream` futures complete with the error and their source
  /// subscriptions cancel, and the consumer's stream terminates with the
  /// same error so a waiting upload aborts its partial target instead of
  /// wedging. Called when the upload died early or the attempt was
  /// cancelled — without it a paused `addStream` would never issue another
  /// `moveNext` and the drain would hang.
  void abort([Object? error]) {
    if (_closed) return;
    _closed = true;
    // An abort carrying the source's error marks that side as failed so
    // the consumer stream's relayed error stays attributable.
    if (error != null) _sourceError ??= error;
    // First: parked gate waits must release before the subscriptions
    // they paused are cancelled — the wait's error is what unwinds them.
    _gateToken.cancel();
    final failure = error ?? StateError('transfer sink aborted');
    for (final subscription in _subscriptions) {
      // A source parked mid-chunk surfaces its cancellation error through
      // the cancel future — swallow it; the pending addStream already
      // carries the abort reason.
      unawaited(
        subscription.cancel().then<void>((_) {}, onError: (_) {}),
      );
    }
    for (final pending in _pendingAddStreams) {
      if (!pending.isCompleted) pending.completeError(failure);
    }
    _pendingAddStreams.clear();
    _drained?.complete();
    _controller.addError(failure);
    // done may complete with the abort error to no listener — swallow it
    // so it cannot surface as an unhandled async error.
    unawaited(_controller.done.then<void>((_) {}, onError: (_) {}));
    unawaited(_controller.close());
  }

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    _closed = true;
    for (final subscription in _subscriptions) {
      unawaited(
        subscription.cancel().then<void>((_) {}, onError: (_) {}),
      );
    }
    for (final pending in _pendingAddStreams) {
      // Closing while a source stream is still producing is a truncated
      // relay, not a success — abort() is the path that swallows partial
      // work deliberately.
      if (!pending.isCompleted) {
        pending.completeError(
          StateError('transfer sink closed while addStream was pending'),
        );
      }
    }
    _pendingAddStreams.clear();
    _drained?.complete();
    return _controller.close();
  }

  @override
  Future<void> get done => _controller.done;
}
