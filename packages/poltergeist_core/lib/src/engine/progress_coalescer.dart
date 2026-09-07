import 'dart:async';

import 'protocol.dart';

const progressFlushesPerSecond = 30;
const progressItemsPerFlushCap = 64;

// Round up to whole milliseconds: VM timers truncate finer durations.
const progressFlushInterval = Duration(
  milliseconds:
      (Duration.millisecondsPerSecond + progressFlushesPerSecond - 1) ~/
      progressFlushesPerSecond,
);

/// Bounds pending memory and aggregate port traffic under rotating item floods.
/// Terminal/state events bypass this buffer; they must never be dropped.
final class ProgressCoalescer {
  final void Function(TransferProgressBatchEvent) _emit;
  final _pending = <(String, String), TransferProgressEvent>{};
  Timer? _timer;
  bool _disposed = false;

  ProgressCoalescer(this._emit);

  void add(TransferProgressEvent event) {
    if (_disposed) return;

    // Refresh recency as well as value. Tuple keys cannot alias arbitrary IDs.
    final key = (event.taskId, event.itemId);
    _pending.remove(key);
    _pending[key] = event;
    if (_pending.length > progressItemsPerFlushCap) {
      _pending.remove(_pending.keys.first);
    }

    _timer ??= Timer(progressFlushInterval, _flush);
  }

  /// Drop buffered counters before publishing a task's terminal state.
  /// The task owner must also detach its producer to reject later callbacks.
  void discardTask(String taskId) {
    _pending.removeWhere((key, _) => key.$1 == taskId);
    _cancelEmptyTimer();
  }

  /// An item's terminal event must not be followed by its buffered counters.
  /// Detach that item's producer first, as with [discardTask].
  void discardItem(String taskId, String itemId) {
    _pending.remove((taskId, itemId));
    _cancelEmptyTimer();
  }

  /// Engine shutdown abandons progress; late producer callbacks are harmless.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }

  void _flush() {
    _timer = null;
    if (_disposed || _pending.isEmpty) return;

    // Clear before delivery so a reentrant producer starts the next window.
    final batch = TransferProgressBatchEvent(_pending.values);
    _pending.clear();
    _emit(batch);
  }

  void _cancelEmptyTimer() {
    if (_pending.isNotEmpty) return;

    _timer?.cancel();
    _timer = null;
  }
}
