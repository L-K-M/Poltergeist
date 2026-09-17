import 'dart:async';

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
class BoundedTransferSink implements StreamSink<List<int>> {
  BoundedTransferSink(this._controller, {required this.maxBufferedBytes});

  final StreamController<List<int>> _controller;
  final int maxBufferedBytes;
  final List<StreamSubscription<List<int>>> _subscriptions = [];
  final List<Completer<void>> _pendingAddStreams = [];

  int _buffered = 0;
  Completer<void>? _drained;
  bool _closed = false;

  /// The upload-side view: each chunk the consumer pulls frees space and
  /// completes the pending drain waiter so a paused `addStream` resumes.
  /// Cached — a fresh `.map` per access would hand callers distinct
  /// wrappers over a single-subscription stream.
  late final Stream<List<int>> stream = _controller.stream.map((chunk) {
    _buffered -= chunk.length;
    final drained = _drained;
    if (drained != null && _buffered < maxBufferedBytes) {
      _drained = null;
      drained.complete();
    }
    return chunk;
  });

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
