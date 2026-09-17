import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:seance_core/seance_core.dart';

/// The largest chunk any `BandwidthLimiter.acquire` caller passes —
/// today the VFS adapters' stream read size (dart:io `openRead` emits
/// ≤64 KiB; dartssh2's SFTP reads are 16 KiB). It only feeds the bucket
/// capacity floor, so an underestimate costs wait granularity, never a
/// hang (03 §4.3's capacity-sized-grant rule).
const maxTransferChunkBytes = 64 * 1024;

/// 03 §4.3's token bucket: one per direction, global to the engine
/// isolate. `acquire` returns a future — waits ride `Timer`s on the
/// queue's clock, so `fake_async` drives every test deterministically
/// and no busy loop or `sleep` ever touches the event loop.
///
/// Bucket semantics (03 §4.3): capacity is `max(rate, maxChunkBytes)`;
/// a freshly configured bucket starts full (one bounded initial burst,
/// never a dynamic-rate one); a request larger than capacity drains in
/// capacity-sized grants; parked acquires grant in request order and
/// observe `bytesPerSecond` changes immediately.
///
/// `bytesPerSecond <= 0` normalizes to unlimited — the settings layer
/// logs the hand-edited zero/negative; the bucket never stores one.
class BandwidthLimiter {
  BandwidthLimiter({
    this.maxChunkBytes = maxTransferChunkBytes,
    int? bytesPerSecond,
  }) : _capacity = maxChunkBytes {
    final rate = bytesPerSecond;
    if (rate != null && rate > 0) {
      _bytesPerSecond = rate;
      _capacity = max(rate, maxChunkBytes);
      _tokens = _capacity.toDouble();
    }
  }

  /// The largest single acquire — the bucket's capacity floor.
  final int maxChunkBytes;

  int? _bytesPerSecond;
  int _capacity;
  double _tokens = 0;
  // clock.now, not DateTime.now: fake_async's virtual zone clock drives
  // the deterministic tests.
  DateTime _lastRefill = clock.now();
  final ListQueue<_AcquireWaiter> _waiters = ListQueue();
  Timer? _wakeTimer;

  /// The configured rate in bytes/second; `null` is unlimited. The
  /// future throttle UI (02 §6) mutates this directly — the setter is
  /// the dynamic rate-change API. Changes take effect for parked
  /// acquires immediately; a new rate never tops the bucket back up, so
  /// lowering the limit can only ever clamp, not burst.
  int? get bytesPerSecond => _bytesPerSecond;

  set bytesPerSecond(int? value) {
    final normalized = value == null || value <= 0 ? null : value;
    if (normalized == _bytesPerSecond) return;
    _refill();
    _bytesPerSecond = normalized;
    _capacity =
        normalized == null ? maxChunkBytes : max(normalized, maxChunkBytes);
    if (normalized == null) {
      // "Off" banks nothing — a later enable must not release a stale
      // burst banked under the previous rate.
      _tokens = 0;
    } else if (_tokens > _capacity) {
      // Clamp, never top up: a rate landing on an empty bucket starts
      // empty and a decrease can only shrink the bank.
      _tokens = _capacity.toDouble();
    }
    _pumpWaiters();
  }

  /// The bucket's capacity — `max(rate, maxChunkBytes)` while limited
  /// (03 §4.3). Exposed for tests and debug surfaces.
  int get capacity => _capacity;

  /// Waits until [chunkBytes] may leave through this bucket. Chunks
  /// larger than the bucket drain in capacity-sized grants — they wait
  /// rather than deadlock (03 §4.3).
  ///
  /// [cancellation] evicts a parked wait with a `cancelled` error so a
  /// paused or cancelled attempt unwinds promptly instead of holding the
  /// pipe open until the next grant tick.
  Future<void> acquire(
    int chunkBytes, {
    RemoteTransferCancellation? cancellation,
  }) {
    if (chunkBytes <= 0 || _bytesPerSecond == null) {
      return Future<void>.value();
    }
    if (cancellation != null && cancellation.isCancelled) {
      return Future<void>.error(_cancelledError());
    }
    var remaining = chunkBytes;
    if (_waiters.isEmpty) {
      _refill();
      final grant = min(remaining, _capacity);
      if (_tokens >= grant) {
        _tokens -= grant;
        remaining -= grant;
      }
    }
    if (remaining == 0) return Future<void>.value();
    final waiter = _AcquireWaiter(remaining);
    _waiters.addLast(waiter);
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then((_) {
          if (_waiters.remove(waiter) && !waiter.completer.isCompleted) {
            waiter.completer.completeError(_cancelledError());
          }
          // A removed head may have been blocking grantable waiters
          // behind it — release what now fits.
          _pumpWaiters();
        }),
      );
    }
    _armWakeTimer();
    return waiter.completer.future;
  }

  void _refill() {
    final now = clock.now();
    final rate = _bytesPerSecond;
    if (rate != null) {
      final elapsed = now.difference(_lastRefill).inMicroseconds;
      if (elapsed > 0) {
        _tokens = min(
          _capacity.toDouble(),
          _tokens + elapsed * rate / Duration.microsecondsPerSecond,
        );
      }
    }
    _lastRefill = now;
  }

  /// Grants each head waiter its full quantum while tokens allow —
  /// quantum = min(remaining, capacity), so a parked acquire can never
  /// receive more than one capacity-sized grant per tick.
  void _pumpWaiters() {
    if (_bytesPerSecond == null) {
      // "Off" releases everything parked — a rate set to null must not
      // leave work hanging on a dead bucket.
      _wakeTimer?.cancel();
      _wakeTimer = null;
      while (_waiters.isNotEmpty) {
        _waiters.removeFirst().completer.complete();
      }
      return;
    }
    _refill();
    while (_waiters.isNotEmpty) {
      final head = _waiters.first;
      final grant = min(head.remaining, _capacity);
      if (_tokens < grant) break;
      _tokens -= grant;
      head.remaining -= grant;
      if (head.remaining == 0) {
        _waiters.removeFirst();
        if (!head.completer.isCompleted) head.completer.complete();
      } else {
        break;
      }
    }
    _armWakeTimer();
  }

  void _armWakeTimer() {
    _wakeTimer?.cancel();
    _wakeTimer = null;
    final rate = _bytesPerSecond;
    if (rate == null || _waiters.isEmpty) return;
    final head = _waiters.first;
    final deficit = min(head.remaining, _capacity) - _tokens;
    if (deficit <= 0) {
      // Tokens already cover the next grant (float dust on the quantum
      // boundary) — pump without spending a timer.
      scheduleMicrotask(_pumpWaiters);
      return;
    }
    _wakeTimer = Timer(
      Duration(
        microseconds:
            (deficit / rate * Duration.microsecondsPerSecond).ceil(),
      ),
      _pumpWaiters,
    );
  }

  RemoteFileException _cancelledError() => const RemoteFileException(
    kind: RemoteFileErrorKind.cancelled,
    operation: 'throttle',
    message: 'throttle wait cancelled',
  );
}

class _AcquireWaiter {
  _AcquireWaiter(this.remaining);

  int remaining;
  final Completer<void> completer = Completer<void>();
}
