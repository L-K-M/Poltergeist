import 'dart:async';
import 'dart:collection';

const progressFlushesPerSecond = 30;
const progressItemsPerFlushCap = 64;

const _progressFlushInterval = Duration(
  microseconds:
      (Duration.microsecondsPerSecond + progressFlushesPerSecond - 1) ~/
      progressFlushesPerSecond,
);

class ProgressSample {
  final String taskId;
  final String itemId;
  final int transferred;
  final int? total;

  const ProgressSample({
    required this.taskId,
    required this.itemId,
    required this.transferred,
    required this.total,
  });
}

typedef ProgressFlush =
    void Function(String taskId, List<ProgressSample> samples);

/// Keeps only the latest item state and bounds each cross-isolate message.
class ProgressCoalescer {
  final ProgressFlush _emit;
  final Map<String, LinkedHashMap<String, ProgressSample>> _pending = {};
  final Map<String, Timer> _timers = {};

  ProgressCoalescer(this._emit);

  void add(ProgressSample sample) {
    final items = _pending.putIfAbsent(sample.taskId, LinkedHashMap.new);
    final refreshed = items.remove(sample.itemId) != null;
    if (!refreshed && items.length == progressItemsPerFlushCap) {
      items.remove(items.keys.first);
    }
    items[sample.itemId] = sample;

    _timers.putIfAbsent(
      sample.taskId,
      () => Timer(_progressFlushInterval, () => _flush(sample.taskId)),
    );
  }

  Future<void> drain() async {
    while (_timers.isNotEmpty) {
      await Future<void>.delayed(_progressFlushInterval);
    }
  }

  void _flush(String taskId) {
    _timers.remove(taskId);
    final items = _pending.remove(taskId);
    if (items == null || items.isEmpty) return;

    _emit(taskId, List<ProgressSample>.unmodifiable(items.values));
  }
}
