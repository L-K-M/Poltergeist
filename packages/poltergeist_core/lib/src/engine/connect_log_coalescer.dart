import 'dart:async';

import '../connection/connection_manager.dart' show ConnectLogLine;
import 'protocol.dart';

/// Per-server transcript flushes per second — the progress surface's port
/// budget (03 §5), applied to the transcript so a dartssh2 trace burst
/// cannot flood the port either.
const connectionLogFlushesPerSecond = 30;

// Round up to whole milliseconds: VM timers truncate finer durations.
const connectionLogFlushInterval = Duration(
  milliseconds:
      (Duration.millisecondsPerSecond + connectionLogFlushesPerSecond - 1) ~/
      connectionLogFlushesPerSecond,
);

/// Mirrors seance_core's per-attempt `SshConnectionLog` bound (400 lines,
/// drop-oldest): a pending batch can never exceed what one attempt's own
/// log retains.
const connectionLogMaxLines = 400;

/// Bounds transcript port traffic: lines accumulate per server in append
/// order, and one shared timer fires at most [connectionLogFlushesPerSecond]
/// times per second. Each fire emits one batch per pending server; each
/// server's pending lines are capped at [connectionLogMaxLines] with
/// drop-oldest. Unlike progress (latest-wins
/// per item), transcript order is the content — nothing is reordered or
/// merged, only the oldest lines drop under a flood.
final class ConnectLogCoalescer {
  final void Function(ConnectionLogEvent) _emit;
  Map<String, List<String>> _pending = {};
  Timer? _timer;
  bool _disposed = false;

  /// [emit] synchronously sends a batch; its failures propagate as wiring
  /// errors.
  ConnectLogCoalescer(this._emit);

  void add(ConnectLogLine line) {
    if (_disposed) return;

    final lines = _pending.putIfAbsent(line.serverId, () => <String>[]);
    lines.add(line.line);
    if (lines.length > connectionLogMaxLines) {
      lines.removeRange(0, lines.length - connectionLogMaxLines);
    }

    _timer ??= Timer(connectionLogFlushInterval, _flush);
  }

  /// Engine shutdown abandons buffered lines; late transcript appends are
  /// harmless.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }

  void _flush() {
    _timer = null;
    if (_disposed || _pending.isEmpty) return;

    // Steal the map before delivery so a reentrant producer starts the
    // next window rather than mutating the batch being sent.
    final batches = _pending;
    _pending = {};
    for (final entry in batches.entries) {
      _emit(ConnectionLogEvent(serverId: entry.key, lines: entry.value));
    }
  }
}
