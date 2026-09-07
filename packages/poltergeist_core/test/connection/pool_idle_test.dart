import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

// One channel per transport makes growth and ownership explicit in each
// test. The transport cap is pinned because the queueing premises of the
// lease tests depend on exactly two transports.
const _policy = PoolPolicy(
  maxTransports: 2,
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 1,
);
const _lastSecond = Duration(seconds: 1);
final _beforeExpiry = _policy.idleExtraTransportTimeout - _lastSecond;

PoolHarness _harness() => PoolHarness(policy: _policy)
  ..addServer('s1')
  ..addServer('s2');

void _disconnect(FakeAsync time, PoolHarness harness) {
  // Safe by contract: disconnectServer is a no-op for an unknown or
  // already-disconnected id, so re-disconnects and never-added ids are fine.
  completeWithoutTimers(time, harness.manager.disconnectServer('s1'));
  completeWithoutTimers(time, harness.manager.disconnectServer('s2'));
  expect(time.pendingTimers, isEmpty);
}

void main() {
  // Fail fast at the constant if a policy tune would make the 1 s probe
  // negative — fakeAsync's elapse would otherwise throw far from the cause.
  assert(
    _beforeExpiry > Duration.zero,
    'The 1s idle probe must stay shorter than idleExtraTransportTimeout.',
  );

  test('empty extra transport closes at the idle deadline', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra');
      final extra = harness.opener.transports.last;
      completeWithoutTimers(time, extraPane.close());

      time.elapse(_beforeExpiry);
      expect(extra.closed, isFalse);
      time.elapse(_lastSecond);
      expect(extra.closed, isTrue);
      expect(harness.opener.transports.first.closed, isFalse);
      expect(
        completeWithoutTimers(time, harness.manager.connectedServerIds()),
        {'s1'},
      );
      _disconnect(time, harness);
    });
  });

  test('browse channels on shared bookmarks prevent idle expiry', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      browsePane(time, harness, 'extra', server: 's2');
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(harness.opener.transports.every((t) => !t.closed), isTrue);
      // Both transports are alive, so only the pool's single periodic
      // keepalive clock (D3) may be pending.
      expectOnlyKeepAliveClock(time, _policy.keepAliveInterval);
      _disconnect(time, harness);
    });
  });

  test(
    'returned extra transfer channel closes before its idle timer starts',
    () {
      fakeAsync((time) {
        final harness = _harness();
        browsePane(time, harness, 'first');
        final lease = completeWithoutTimers(
          time,
          harness.manager.leaseTransferChannel('s1'),
        );
        final extra = harness.opener.transports.last;

        time.elapse(_policy.idleExtraTransportTimeout * 2);
        expect(extra.closed, isFalse);
        completeWithoutTimers(time, lease.release());
        expect(extra.channels.single.closed, isTrue);
        time.elapse(_beforeExpiry);
        expect(extra.closed, isFalse);
        time.elapse(_lastSecond);
        expect(extra.closed, isTrue);
        _disconnect(time, harness);
      });
    },
  );

  test('queued lease receives the returned channel before idle cleanup', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final lease = completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      final waiting = harness.manager.leaseTransferChannel('s2');
      TransferChannelLease? granted;
      waiting.then((value) => granted = value).ignore();
      time.flushMicrotasks();
      expect(
        granted,
        isNull,
        reason: 'The lease must queue while the extra channel is checked out.',
      );
      completeWithoutTimers(time, lease.release());
      final next = completeWithoutTimers(time, waiting);
      // s1 and s2 share one endpoint (one pool), so handing the released
      // channel to the s2 waiter is same-connection reuse — and no new
      // transport may be opened to serve it.
      expect(harness.opener.calls, hasLength(2));
      expect(next.fs, same(lease.fs));
      expect(harness.opener.transports.last.channels.single.closed, isFalse);
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(harness.opener.transports.last.closed, isFalse);

      completeWithoutTimers(time, next.release());
      time.elapse(_policy.idleExtraTransportTimeout);
      expect(harness.opener.transports.last.closed, isTrue);
      _disconnect(time, harness);
    });
  });

  test('new channel use cancels expiry and restarts the full idle timeout', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra');
      final extra = harness.opener.transports.last;
      completeWithoutTimers(time, extraPane.close());
      time.elapse(_beforeExpiry);

      final replacement = browsePane(time, harness, 'replacement');
      time.elapse(_lastSecond);
      expect(extra.closed, isFalse);
      completeWithoutTimers(time, replacement.close());
      time.elapse(_beforeExpiry);
      expect(extra.closed, isFalse);
      time.elapse(_lastSecond);
      expect(extra.closed, isTrue);
      _disconnect(time, harness);
    });
  });

  test('lease demand reuses an empty extra inside its idle window', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra');
      final extra = harness.opener.transports.last;
      completeWithoutTimers(time, extraPane.close());
      time.elapse(_beforeExpiry);

      // The pool is at its transport cap; the lease must cancel the idle
      // clock and open on the empty extra instead of churning transports.
      final callsBefore = harness.opener.calls.length;
      final lease = completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      expect(harness.opener.calls.length, callsBefore);
      expect(extra.channels.where((c) => !c.closed), isNotEmpty);

      completeWithoutTimers(time, lease.release());
      // The lease's channel closed eagerly (no waiter) and the idle clock
      // restarted with the close: the emptied extra expires one window
      // after release, not never.
      time.elapse(_beforeExpiry);
      expect(extra.closed, isFalse);
      time.elapse(_lastSecond);
      expect(extra.closed, isTrue);
      _disconnect(time, harness);
    });
  });

  test('pending channel open prevents expiry before a handle exists', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra');
      final extra = harness.opener.transports.last;
      completeWithoutTimers(time, extraPane.close());
      time.elapse(_beforeExpiry);

      final gate = extra.openGate = Completer<void>();
      final opening = harness.manager.openBrowseChannel('s1', paneTabId: 'new');
      time.flushMicrotasks();
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(extra.closed, isFalse);
      gate.complete();
      final pane = completeWithoutTimers(time, opening);
      completeWithoutTimers(time, pane.close());
      time.elapse(_policy.idleExtraTransportTimeout);
      expect(extra.closed, isTrue);
      _disconnect(time, harness);
    });
  });

  test('home resolution holds the extra transport through the deadline', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra');
      final extra = harness.opener.transports.last;
      completeWithoutTimers(time, extraPane.close());

      final gate = extra.canonicalizeGate = Completer<void>();
      final opening =
          harness.manager.openBrowseChannel('s1', paneTabId: 'new');
      opening.ignore();
      time.flushMicrotasks();
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(extra.closed, isFalse);
      gate.complete();
      final pane = completeWithoutTimers(time, opening);
      // The hold must be released with the resolution: the emptied extra
      // expires normally afterwards.
      completeWithoutTimers(time, pane.close());
      time.elapse(_policy.idleExtraTransportTimeout);
      expect(extra.closed, isTrue);
      _disconnect(time, harness);
    });
  });

  test('expiry frees capacity for later prompting-disabled growth', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra');
      final expired = harness.opener.transports.last;
      completeWithoutTimers(time, extraPane.close());
      time.elapse(_policy.idleExtraTransportTimeout);

      browsePane(time, harness, 'new');
      expect(expired.closed, isTrue);
      expect(harness.opener.calls, hasLength(3));
      expect(harness.opener.calls.last.prompting, ConnectPrompting.disabled);
      _disconnect(time, harness);
    });
  });

  test('the first transport stays alive while its last channel is leased', () {
    fakeAsync((time) {
      // Pin the default policy explicitly so the idle window the test
      // elapses can never drift from the policy the harness runs.
      final defaultPolicy = PoolPolicy();
      final harness = PoolHarness(policy: defaultPolicy)..addServer('s1');
      final pane = browsePane(time, harness, 'first');
      final lease = completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      completeWithoutTimers(time, pane.close());
      time.elapse(defaultPolicy.idleExtraTransportTimeout * 2);
      expect(harness.opener.transports.single.closed, isFalse);
      // Alive under a lease, so only the pool's single periodic keepalive
      // clock (D3) may be pending.
      expectOnlyKeepAliveClock(time, defaultPolicy.keepAliveInterval);
      completeWithoutTimers(time, lease.release());
      // A server whose last channel has closed disconnects immediately
      // (pane-lifetime teardown); only surplus extra transports get the
      // idle grace window.
      expect(harness.opener.transports.single.closed, isTrue);
      _disconnect(time, harness);
    });
  });

  test('disconnect cancels old idle timers before the server reconnects', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra');
      completeWithoutTimers(time, extraPane.close());
      expect(time.nonPeriodicTimerCount, 1);
      _disconnect(time, harness);

      browsePane(time, harness, 'replacement');
      time.elapse(_policy.idleExtraTransportTimeout);
      expect(harness.opener.transports.last.closed, isFalse);
      _disconnect(time, harness);
    });
  });
}
