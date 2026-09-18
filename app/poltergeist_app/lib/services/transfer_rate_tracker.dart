import 'dart:collection';

/// 02 §5.3's smoothed per-task transfer rate: a sliding window of
/// (timestamp, cumulative bytes) samples. The rate surfaces as soon as
/// two samples span a window; the ETA waits until the window holds at
/// least three seconds of data and its reported value is recomputed at
/// most once per second — the spec's "never jumps more than once per
/// second" rule, enforced here rather than left to the build cadence.
class TransferRateTracker {
  TransferRateTracker({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// The smoothing window (02 §5.3).
  static const window = Duration(seconds: 5);

  /// Minimum data before an ETA is honest enough to show (02 §5.3).
  static const etaMinWindow = Duration(seconds: 3);

  /// The ETA refresh cadence — a derived value, not the spec's rule:
  /// the rule is that displayed ETAs update no faster than this.
  static const etaRefresh = Duration(seconds: 1);

  final DateTime Function() _clock;
  final _samples = <String, ListQueue<({DateTime at, int bytes})>>{};
  final _etas = <String, ({Duration value, DateTime at})>{};

  /// Feeds one cumulative-bytes observation for [taskId]. Samples older
  /// than the window are dropped; a non-monotonic byte count (a retry
  /// debit) resets the task's window so a stale rate cannot misreport.
  void record(String taskId, int cumulativeBytes) {
    final now = _clock();
    final queue =
        _samples.putIfAbsent(taskId, () => ListQueue())..addLast((
          at: now,
          bytes: cumulativeBytes,
        ));
    while (queue.length > 1 &&
        now.difference(queue.first.at) > window) {
      queue.removeFirst();
    }
    if (queue.length > 1 && queue.last.bytes < queue.first.bytes) {
      queue
        ..clear()
        ..addLast((at: now, bytes: cumulativeBytes));
      _etas.remove(taskId);
    }
  }

  /// Smoothed bytes/second over the window, or null before two distinct
  /// samples exist (a single sample spans zero time — no rate is
  /// derivable, and §5.3 shows nothing rather than a fake) and once
  /// the newest sample ages out of the window — a stopped task's last
  /// rate is stale, not a measurement.
  double? bytesPerSecond(String taskId) {
    final queue = _samples[taskId];
    if (queue == null || queue.length < 2) return null;
    // Expiry is write-side only (record drops old samples), so a task
    // that stopped recording — stalled, paused, finished — would quote
    // its last rate forever. Read-side: once the newest sample ages
    // out of the window there is no live rate to report.
    if (_clock().difference(queue.last.at) > window) return null;
    final span = queue.last.at.difference(queue.first.at);
    if (span.inMilliseconds <= 0) return null;
    return (queue.last.bytes - queue.first.bytes) * 1000.0 /
        span.inMilliseconds;
  }

  /// Seconds of data inside the window — the ETA honesty gate.
  Duration dataSpan(String taskId) {
    final queue = _samples[taskId];
    if (queue == null || queue.length < 2) return Duration.zero;
    return queue.last.at.difference(queue.first.at);
  }

  /// Estimated time left for [remainingBytes] at the smoothed rate.
  /// Null while the data span is under [etaMinWindow] or the rate is
  /// not derivable; the returned value refreshes at most once per
  /// [etaRefresh] so a flickering estimate cannot jump twice in a
  /// second (02 §5.3).
  Duration? eta(String taskId, int remainingBytes) {
    if (remainingBytes <= 0) return Duration.zero;
    if (dataSpan(taskId) < etaMinWindow) return null;
    final rate = bytesPerSecond(taskId);
    if (rate == null || rate <= 0) return null;
    final now = _clock();
    final last = _etas[taskId];
    if (last != null && now.difference(last.at) < etaRefresh) {
      return last.value;
    }
    final value = Duration(milliseconds: (remainingBytes / rate * 1000).round());
    _etas[taskId] = (value: value, at: now);
    return value;
  }

  /// Drops tasks the queue no longer lists so a long session cannot
  /// grow the maps without bound.
  void prune(Set<String> liveTaskIds) {
    _samples.removeWhere((id, _) => !liveTaskIds.contains(id));
    _etas.removeWhere((id, _) => !liveTaskIds.contains(id));
  }

  /// Forgets one task — e.g. a completed row that left the listing.
  void remove(String taskId) {
    _samples.remove(taskId);
    _etas.remove(taskId);
  }
}
