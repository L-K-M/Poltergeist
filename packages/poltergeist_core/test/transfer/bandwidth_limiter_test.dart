// Deterministic contract tests for 03 §4.3's BandwidthLimiter — the
// engine-global token bucket, one per direction.
//
// Every test runs under fake_async: the limiter's waits ride Timers and
// DateTime.now, so elapsing the fake clock drives the refill policy with
// no wall-clock dependence. Most tests end by asserting no pending
// timers remain — a parked-acquire leak would wedge the queue later.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

/// Observes an acquire future's outcome without awaiting it inside the
/// fake zone.
class _Outcome {
  bool done = false;
  Object? error;

  void watch(Future<void> future) {
    unawaited(
      future.then(
        (_) => done = true,
        onError: (Object e) => error = e,
      ),
    );
  }
}

void main() {
  group('rate normalization', () {
    test('null rate is unlimited — any acquire returns immediately', () {
      fakeAsync((time) {
        final limiter = BandwidthLimiter(maxChunkBytes: 64);
        final outcome = _Outcome()..watch(limiter.acquire(1 << 30));
        time.flushMicrotasks();
        expect(outcome.done, isTrue);
        expect(limiter.bytesPerSecond, isNull);
        expect(time.pendingTimers, isEmpty);
      });
    });

    test('zero and negative rates normalize to unlimited (03 §4.3)', () {
      fakeAsync((time) {
        // The settings layer rejects zero before it reaches the bucket;
        // the limiter still normalizes as defense in depth so no rate-0
        // bucket is ever built.
        for (final rate in [0, -1, -1024]) {
          final limiter = BandwidthLimiter(
            maxChunkBytes: 64,
            bytesPerSecond: rate,
          );
          expect(limiter.bytesPerSecond, isNull);
          final outcome = _Outcome()..watch(limiter.acquire(4096));
          time.flushMicrotasks();
          expect(outcome.done, isTrue);
        }
        // The dynamic setter normalizes the same way.
        final limiter = BandwidthLimiter(
          maxChunkBytes: 64,
          bytesPerSecond: 100,
        );
        limiter.bytesPerSecond = 0;
        expect(limiter.bytesPerSecond, isNull);
        limiter.bytesPerSecond = -50;
        expect(limiter.bytesPerSecond, isNull);
        expect(time.pendingTimers, isEmpty);
      });
    });
  });

  group('burst then sustain', () {
    test('a fresh bucket grants one second of tokens, then paces', () {
      fakeAsync((time) {
        final limiter = BandwidthLimiter(
          maxChunkBytes: 64,
          bytesPerSecond: 1000,
        );
        // N = 3000 at L = 1000: the full initial bucket covers 1000, the
        // remaining 2000 drain at rate — total wait must be ≥ (N − L)/L =
        // 2 s, and a correct implementation hits exactly that.
        final outcome = _Outcome()..watch(limiter.acquire(3000));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        time.elapse(const Duration(milliseconds: 1999));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        time.elapse(const Duration(milliseconds: 1));
        time.flushMicrotasks();
        expect(outcome.done, isTrue);
        expect(time.pendingTimers, isEmpty);
      });
    });

    test('no burst ever grants more than one second of tokens', () {
      fakeAsync((time) {
        final limiter = BandwidthLimiter(
          maxChunkBytes: 64,
          bytesPerSecond: 100,
        );
        // Idling for an hour must not bank more than capacity (100
        // bytes): an immediate acquire of 100 lands, 101 parks.
        time.elapse(const Duration(hours: 1));
        final first = _Outcome()..watch(limiter.acquire(100));
        final second = _Outcome()..watch(limiter.acquire(1));
        time.flushMicrotasks();
        expect(first.done, isTrue);
        expect(second.done, isFalse);
        time.elapse(const Duration(milliseconds: 10));
        time.flushMicrotasks();
        expect(second.done, isTrue);
        expect(time.pendingTimers, isEmpty);
      });
    });

    test('throughput in a W-second window averages ≤ L·(1 + 1/W)', () {
      fakeAsync((time) {
        const rate = 100;
        final limiter = BandwidthLimiter(
          maxChunkBytes: 10,
          bytesPerSecond: rate,
        );
        var granted = 0;
        // Steady demand: more queued work than any window can grant.
        for (var i = 0; i < 200; i++) {
          unawaited(
            limiter.acquire(10).then((_) => granted += 10),
          );
        }
        time.flushMicrotasks();
        // W = 2 s: at most L·(1 + 2) bytes may be granted.
        time.elapse(const Duration(seconds: 2));
        time.flushMicrotasks();
        expect(granted, lessThanOrEqualTo(rate * 3));
        // W = 10 s: the bound tightens to L·(1 + 10) as the burst term
        // amortizes — and a correct pacer grants exactly the allowance.
        time.elapse(const Duration(seconds: 8));
        time.flushMicrotasks();
        expect(granted, rate * 11);
        expect(time.pendingTimers, isNotEmpty);
      });
    });
  });

  group('capacity splitting', () {
    test('an acquire larger than capacity drains in capacity-sized grants',
        () {
      fakeAsync((time) {
        // capacity = max(10, 4) = 10; a 40-byte request must drain
        // 10/10/10/10 across four grant ticks without deadlocking.
        final limiter = BandwidthLimiter(
          maxChunkBytes: 4,
          bytesPerSecond: 10,
        );
        final outcome = _Outcome()..watch(limiter.acquire(40));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        time.elapse(const Duration(milliseconds: 2999));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        time.elapse(const Duration(milliseconds: 1));
        time.flushMicrotasks();
        expect(outcome.done, isTrue);
        expect(time.pendingTimers, isEmpty);
      });
    });

    test('capacity floors at maxChunkBytes below tiny rates', () {
      fakeAsync((time) {
        // rate 1 B/s with 64-byte chunks: capacity = 64 — a 128-byte
        // request drains its second grant after 64 s rather than
        // awaiting tokens the bucket could never hold.
        final limiter = BandwidthLimiter(
          maxChunkBytes: 64,
          bytesPerSecond: 1,
        );
        final outcome = _Outcome()..watch(limiter.acquire(128));
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 63));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        time.elapse(const Duration(seconds: 1));
        time.flushMicrotasks();
        expect(outcome.done, isTrue);
        expect(time.pendingTimers, isEmpty);
      });
    });
  });

  group('waiter ordering and release', () {
    test('parked acquires grant in request order', () {
      fakeAsync((time) {
        final limiter = BandwidthLimiter(
          maxChunkBytes: 100,
          bytesPerSecond: 100,
        );
        // Drain the initial bucket so both park.
        unawaited(limiter.acquire(100));
        final first = _Outcome()..watch(limiter.acquire(60));
        final second = _Outcome()..watch(limiter.acquire(30));
        time.flushMicrotasks();
        expect(first.done, isFalse);
        expect(second.done, isFalse);
        // 0.6 s refills exactly the first waiter's 60.
        time.elapse(const Duration(milliseconds: 600));
        time.flushMicrotasks();
        expect(first.done, isTrue);
        expect(second.done, isFalse);
        time.elapse(const Duration(milliseconds: 300));
        time.flushMicrotasks();
        expect(second.done, isTrue);
        expect(time.pendingTimers, isEmpty);
      });
    });

    test('setting the rate to unlimited releases every parked acquire', () {
      fakeAsync((time) {
        final limiter = BandwidthLimiter(
          maxChunkBytes: 64,
          bytesPerSecond: 10,
        );
        unawaited(limiter.acquire(10));
        final first = _Outcome()..watch(limiter.acquire(100));
        final second = _Outcome()..watch(limiter.acquire(50));
        time.flushMicrotasks();
        expect(first.done, isFalse);
        expect(second.done, isFalse);
        limiter.bytesPerSecond = null;
        time.flushMicrotasks();
        expect(first.done, isTrue);
        expect(second.done, isTrue);
        expect(time.pendingTimers, isEmpty);
      });
    });

    test('a parked acquire cancels cleanly through the attempt token', () {
      fakeAsync((time) {
        final limiter = BandwidthLimiter(
          maxChunkBytes: 64,
          bytesPerSecond: 10,
        );
        unawaited(limiter.acquire(10));
        final token = RemoteTransferCancellation();
        final outcome = _Outcome()
          ..watch(limiter.acquire(100, cancellation: token));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        token.cancel();
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        expect(outcome.error, isA<RemoteFileException>());
        expect(
          (outcome.error! as RemoteFileException).kind,
          RemoteFileErrorKind.cancelled,
        );
        // The freed slot is observable: a fresh small acquire must not
        // wait behind the cancelled one.
        final next = _Outcome()..watch(limiter.acquire(10));
        time.elapse(const Duration(seconds: 1));
        time.flushMicrotasks();
        expect(next.done, isTrue);
        expect(time.pendingTimers, isEmpty);
      });
    });
  });

  group('dynamic rate changes', () {
    test('a rate decrease clamps the bucket — no fresh burst', () {
      fakeAsync((time) {
        final limiter = BandwidthLimiter(
          maxChunkBytes: 64,
          bytesPerSecond: 1000,
        );
        // Let the bucket fill to capacity 1000.
        time.elapse(const Duration(seconds: 5));
        limiter.bytesPerSecond = 100;
        // Capacity is now 100; the 1000 banked tokens must have clamped —
        // a 500-byte request gets only the 100-token residue, not the
        // stale 1000.
        final outcome = _Outcome()..watch(limiter.acquire(500));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        // (500 − 100)/100 = 4 s at the new rate.
        time.elapse(const Duration(milliseconds: 3999));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        time.elapse(const Duration(milliseconds: 1));
        time.flushMicrotasks();
        expect(outcome.done, isTrue);
        expect(time.pendingTimers, isEmpty);
      });
    });

    test('a rate increase is observed by pending acquires', () {
      fakeAsync((time) {
        final limiter = BandwidthLimiter(
          maxChunkBytes: 64,
          bytesPerSecond: 100,
        );
        unawaited(limiter.acquire(100));
        final outcome = _Outcome()..watch(limiter.acquire(100));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        // At the old rate this parks 1 s; raising to 1000 must complete
        // it after ~0.1 s.
        limiter.bytesPerSecond = 1000;
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        time.elapse(const Duration(milliseconds: 100));
        time.flushMicrotasks();
        expect(outcome.done, isTrue);
        expect(time.pendingTimers, isEmpty);
      });
    });

    test('enabling a limit mid-transfer starts with no banked burst', () {
      fakeAsync((time) {
        final limiter = BandwidthLimiter(maxChunkBytes: 100);
        // Unlimited for a while, then a rate lands.
        time.elapse(const Duration(seconds: 30));
        limiter.bytesPerSecond = 100;
        final outcome = _Outcome()..watch(limiter.acquire(300));
        time.flushMicrotasks();
        // No free second of tokens: the grant waits the full 3 s.
        expect(outcome.done, isFalse);
        time.elapse(const Duration(milliseconds: 2999));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        time.elapse(const Duration(milliseconds: 1));
        time.flushMicrotasks();
        expect(outcome.done, isTrue);
        expect(time.pendingTimers, isEmpty);
      });
    });

    test('disabling then re-enabling carries no stale banked tokens', () {
      fakeAsync((time) {
        final limiter = BandwidthLimiter(
          maxChunkBytes: 100,
          bytesPerSecond: 100,
        );
        // Bank a full bucket, switch the limit off, switch it back on.
        time.elapse(const Duration(seconds: 5));
        limiter.bytesPerSecond = null;
        limiter.bytesPerSecond = 100;
        // The 100 banked under the first rate must not survive the
        // off/on cycle — 300 bytes waits the full 3 s, not 2.
        final outcome = _Outcome()..watch(limiter.acquire(300));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        time.elapse(const Duration(milliseconds: 2999));
        time.flushMicrotasks();
        expect(outcome.done, isFalse);
        time.elapse(const Duration(milliseconds: 1));
        time.flushMicrotasks();
        expect(outcome.done, isTrue);
        expect(time.pendingTimers, isEmpty);
      });
    });
  });
}
