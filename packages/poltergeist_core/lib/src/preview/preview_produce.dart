import 'dart:async';

import 'package:seance_core/seance_core.dart';

import '../transfer/transfer_queue.dart';
import '../transfer/transfer_task.dart';

/// 03 §4.7's `TransferProducer` contract — the local-copy hook Quick
/// Look and the preview pane ride (D14). The queue implements it by
/// running the request as one queue-visible, unjournaled produce task:
/// inserted at the head of the queue, exempt from the queue-level pause
/// and the ordinary in-flight/throttle budgets, bounded by a dedicated
/// two-slot cap, and completed through the returned Future — which dies
/// with the process, so produce tasks are never journaled (03 §4.6's
/// rule for futures the caller cannot re-await).
abstract interface class TransferProducer {
  /// Produces a local copy of the remote [path] at [destinationPath]
  /// and completes when the copy commits — the returned entry carries
  /// the produced file's size and content digest so the caller can
  /// record honest cache metadata. A cancelled production completes in
  /// a `RemoteFileErrorKind.cancelled` error.
  Future<RemoteFileEntry> produceLocalCopy(
    FsLocation source,
    String path, {
    required String destinationPath,
    RemoteTransferCancellation? cancellation,
  });
}

/// The work order for one produce task — the richer seam the preview
/// session drives through `TransferQueue.enqueueProduce`. Carries the
/// bookkeeping a plain `produceLocalCopy` call cannot: the listing's
/// expected size (progress totals, over-cap pre-checks), the
/// unknown-size stream cap, and the large-download [gate].
final class PreviewProduceSpec {
  const PreviewProduceSpec({
    required this.serverId,
    required this.remotePath,
    required this.destinationPath,
    this.expectedSize,
    this.maximumBytes,
    this.gate,
    this.onProgress,
  });

  /// The pooled server binding (03 §3.5's serverId).
  final String serverId;

  /// Absolute remote path to download.
  final String remotePath;

  /// Local path the copy lands at — the preview cache's exclusive temp
  /// sibling; the cache's commit rename turns it into the keyed entry.
  final String destinationPath;

  /// The listing's reported size, when known — drives the item row's
  /// total and the task's `totalBytes`.
  final int? expectedSize;

  /// 06 §5.3's unknown-size ceiling: applied only when [expectedSize]
  /// is null — a listed size already passed the pane's cap checks.
  final int? maximumBytes;

  /// The large-download checkpoint (06 §5.2): once the produced stream
  /// crosses `gate.thresholdBytes` the sink pauses until the card's
  /// answer arrives.
  final PreviewByteGate? gate;

  /// Byte progress for the pane's progress card (§5.2). Produce tasks
  /// emit no `TransferQueueProgressEvent` (03 §4.7), so the preview
  /// surface reads its bytes here rather than through the queue mirror.
  final RemoteTransferProgress? onProgress;
}

/// 06 §5.2's mid-stream confirmation: for a remote file whose size the
/// listing did not report, production runs until the threshold, then
/// pauses the pipe and surfaces the "Cancel / Keep downloading" card.
/// [confirm] releases the stream to run to completion; [deny] aborts
/// it with a cancelled error — the partial file never lands in the
/// cache because the slot's commit only runs on success.
final class PreviewByteGate {
  PreviewByteGate({required this.thresholdBytes, this.onThresholdReached});

  /// Bytes admitted before the stream parks.
  final int thresholdBytes;

  /// Fired once when the stream first crosses the threshold — the
  /// session's cue to show the confirmation card. Runs synchronously
  /// inside the pipe; keep it to a state flip + notify.
  final void Function(int transferred)? onThresholdReached;

  int _transferred = 0;
  Completer<void>? _hold;
  bool _denied = false;
  bool _confirmed = false;
  bool _notified = false;

  /// Bytes admitted so far — the card's progress display when the
  /// listing had no size.
  int get transferred => _transferred;

  /// Whether the stream is parked waiting on an answer.
  bool get isAwaitingConfirmation => _hold != null;

  /// Whether the user declined — the gate stays thrown after [deny].
  bool get isDenied => _denied;

  /// The card's "Keep downloading": releases the parked stream; later
  /// chunks pass unchecked — the user already consented to the size.
  void confirm() {
    _confirmed = true;
    final hold = _hold;
    _hold = null;
    hold?.complete();
  }

  /// The card's "Cancel": releases the park into a cancelled throw so
  /// the pipe unwinds like a user cancel — the partial temp is aborted,
  /// never committed.
  void deny() {
    _denied = true;
    confirm();
  }

  Future<void> _admit(int bytes) async {
    _transferred += bytes;
    if (_denied) throw _cancelled();
    if (_confirmed || _transferred <= thresholdBytes) return;
    // First crossing: park and notify exactly once. A confirmed gate
    // never re-parks — the answer covers the whole remainder.
    final hold = _hold ??= Completer<void>();
    if (!_notified) {
      _notified = true;
      onThresholdReached?.call(_transferred);
    }
    await hold.future;
    if (_denied) throw _cancelled();
  }

  static RemoteFileException _cancelled() => const RemoteFileException(
    kind: RemoteFileErrorKind.cancelled,
    operation: 'preview produce',
    message: 'large download declined',
  );

  /// Wraps [inner] so admission through `addStream` pays the gate —
  /// the download path only ever streams, so backpressure on the parked
  /// future stalls the remote read without buffering. `add` cannot
  /// await; it still counts and forwards so a hypothetical direct-add
  /// caller never silently loses bytes.
  StreamSink<List<int>> wrap(StreamSink<List<int>> inner) =>
      _GatedByteSink(this, inner);
}

final class _GatedByteSink implements StreamSink<List<int>> {
  _GatedByteSink(this._gate, this._inner);

  final PreviewByteGate _gate;
  final StreamSink<List<int>> _inner;

  /// Serialized chain for `add` calls so ordering survives the async
  /// admit check (produce streams via `addStream`; `add` exists only to
  /// keep the sink contract honest).
  Future<void> _addTail = Future.value();
  Object? _addError;

  @override
  void add(List<int> event) {
    if (_addError != null) return;
    _addTail = _addTail
        .then((_) => _gate._admit(event.length))
        .then((_) => _inner.add(event))
        .catchError((Object error) {
          _addError = error;
          _inner.addError(error);
        });
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(
    stream.asyncMap((event) async {
      await _gate._admit(event.length);
      return event;
    }),
  );

  @override
  Future<void> close() async {
    await _addTail;
    await _inner.close();
  }

  @override
  Future<void> get done async {
    await _addTail;
    if (_addError != null) throw _addError!;
    return _inner.done;
  }
}

/// The session-facing producer seam (06 §5.2/§5.3): starts one produce
/// task per request, hands back a ticket whose [result] completes with
/// the committed entry — or a cancelled error when the queue row's
/// Cancel, an Esc cancel, or a denied gate unwinds it. Dedupe and cache
/// lookups live in the caller; the seam starts work verbatim.
abstract interface class PreviewProducer {
  /// Enqueues [spec]'s produce task and returns its ticket.
  PreviewProduceTicket start(PreviewProduceSpec spec);

  /// Trips the task's queue-level cancel — the row's Cancel verb and
  /// the session's Esc path share it.
  void cancel(String taskId);
}

/// One in-flight production: [taskId] keys the queue row (progress
/// events, per-row Cancel) and [result] is the awaited outcome.
final class PreviewProduceTicket {
  const PreviewProduceTicket({required this.taskId, required this.result});

  final String taskId;
  final Future<RemoteFileEntry> result;
}

/// [PreviewProducer] over a concrete [TransferQueue] — the composition
/// the app wires once (the session and tests see only the seam).
/// Completion is the task's terminal state observed on the queue's
/// event stream, mirroring `CheckoutManager._awaitTask` so a task
/// drained between enqueue and subscription still resolves.
final class QueuePreviewProducer implements PreviewProducer {
  QueuePreviewProducer(this._queue) {
    _subscription = _queue.events.listen(_onQueueEvent);
  }

  final TransferQueue _queue;
  late final StreamSubscription<TransferQueueEvent> _subscription;
  final Map<String, Completer<RemoteFileEntry>> _pending = {};

  @override
  PreviewProduceTicket start(PreviewProduceSpec spec) {
    final task = _queue.enqueueProduce(spec);
    final completer = Completer<RemoteFileEntry>();
    if (!task.isTerminal) {
      _pending[task.id] = completer;
      // The terminal event may already have fired before registration —
      // re-check like the checkout awaiter does.
      if (task.isTerminal) {
        _pending.remove(task.id);
        _settle(completer, task);
      }
    } else {
      _settle(completer, task);
    }
    return PreviewProduceTicket(taskId: task.id, result: completer.future);
  }

  @override
  void cancel(String taskId) => _queue.cancelTask(taskId);

  void _onQueueEvent(TransferQueueEvent event) {
    final completer = _pending[event.taskId];
    if (completer == null) return;
    TransferTask? task;
    for (final candidate in _queue.tasks) {
      if (candidate.id == event.taskId) {
        task = candidate;
        break;
      }
    }
    // A removed row resolves its waiter as cancelled — nothing else
    // will ever complete it.
    if (task == null || !task.isTerminal) return;
    _pending.remove(event.taskId);
    _settle(completer, task);
  }

  void _settle(Completer<RemoteFileEntry> completer, TransferTask task) {
    if (completer.isCompleted) return;
    final item = task.items.where((i) => !i.isDirectory).firstOrNull;
    if (task.state == TransferTaskState.completed &&
        item?.resultEntry != null) {
      completer.complete(item!.resultEntry!);
      return;
    }
    if (task.state == TransferTaskState.cancelled ||
        task.cancellation.isCancelled) {
      completer.completeError(
        const RemoteFileException(
          kind: RemoteFileErrorKind.cancelled,
          operation: 'preview produce',
          message: 'preview production cancelled',
        ),
      );
      return;
    }
    completer.completeError(
      RemoteFileException(
        kind: task.failureKind ?? RemoteFileErrorKind.other,
        operation: 'preview produce',
        path: task.spec.produce?.remotePath,
        message: task.error ?? 'preview production failed',
      ),
    );
  }

  /// Releases the queue-event subscription; pending tickets stay
  /// incomplete — the session owning this producer is gone.
  Future<void> dispose() async {
    await _subscription.cancel();
    _pending.clear();
  }
}
