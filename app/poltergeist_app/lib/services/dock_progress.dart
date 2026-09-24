import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'app_transfer_queue.dart';

/// The platform surface the reporter drives — window_manager's Dock /
/// taskbar progress and badge in production, a recorder in tests.
abstract interface class DockProgressSurface {
  /// [fraction] in 0…1, or null to clear the indicator.
  Future<void> setProgress(double? fraction);

  /// A short badge label (the live task count), or null to clear it.
  Future<void> setBadge(String? label);
}

/// D32 §11: while transfers run, the Dock icon (macOS) and the taskbar
/// button (Windows) show the queue's aggregate byte progress and the
/// live task count — the Finder/Transmit habit of checking a long copy
/// without bringing the window forward. Idle clears both. Updates are
/// coalesced to one per [interval]: queue events arrive per chunk.
final class DockProgressReporter {
  DockProgressReporter({
    required AppTransferQueue queue,
    required DockProgressSurface surface,
    Duration interval = const Duration(milliseconds: 500),
  }) : _queue = queue,
       // Keep the seams private; named parameters cannot be private.
       // ignore: prefer_initializing_formals
       _surface = surface,
       // ignore: prefer_initializing_formals
       _interval = interval {
    _subscription = queue.events.listen((_) => _schedule());
    _schedule();
  }

  final AppTransferQueue _queue;
  final DockProgressSurface _surface;
  final Duration _interval;
  late final StreamSubscription<TransferQueueEvent> _subscription;
  Timer? _pending;
  double? _lastFraction = -1;
  String? _lastBadge = '';

  void _schedule() {
    _pending ??= Timer(_interval, () {
      _pending = null;
      unawaited(_publish());
    });
  }

  Future<void> _publish() async {
    var done = 0;
    var total = 0;
    var live = 0;
    for (final task in _queue.tasks) {
      if (task.isTerminal) continue;
      live++;
      done += task.transferredBytes;
      total += task.totalBytes ?? 0;
    }
    final fraction = live == 0
        ? null
        : total > 0
        ? (done / total).clamp(0.0, 1.0)
        : 0.0;
    final badge = live == 0 ? null : '$live';
    try {
      if (fraction != _lastFraction) {
        _lastFraction = fraction;
        await _surface.setProgress(fraction);
      }
      if (badge != _lastBadge) {
        _lastBadge = badge;
        await _surface.setBadge(badge);
      }
    } on Object catch (error, stack) {
      // A platform without the capability (Linux has no Dock progress
      // API in window_manager) must never break the queue's listeners.
      debugPrint('Dock progress unavailable: $error\n$stack');
    }
  }

  Future<void> dispose() async {
    _pending?.cancel();
    await _subscription.cancel();
  }
}

/// The production surface: window_manager's Dock tile progress bar on
/// macOS and taskbar progress on Windows (a negative value hides it).
/// The badge is deliberately a no-op: macOS only paints Dock badges for
/// apps granted notification authorization, which Poltergeist does not
/// request — the progress bar alone is the signal.
final class WindowManagerDockSurface implements DockProgressSurface {
  const WindowManagerDockSurface();

  @override
  Future<void> setProgress(double? fraction) =>
      windowManager.setProgressBar(fraction ?? -1);

  @override
  Future<void> setBadge(String? label) async {}
}
