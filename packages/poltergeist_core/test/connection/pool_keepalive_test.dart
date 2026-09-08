import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

// Keepalive cadence for these tests. Cadence assertions land on interval
// multiples; the unanswered-ping test instead uses its own longer interval
// so the ping timeout lands strictly between ticks — never sharing an
// instant with one, which would make the suite depend on fake-clock
// tie-breaking instead of the documented skip-on-outstanding rule.
const _interval = Duration(seconds: 30);
const _policy = PoolPolicy(keepAliveInterval: _interval);

// Strictly above SshTransport.pingOperationTimeout (30 s): the unanswered
// ping's timeout then lands between two ticks.
const _timeoutTestInterval = Duration(seconds: 45);

// A one-channel total cap per transport forces the first transfer lease
// onto a grown second transport (the browse channel holds the first's
// budget), without queueing a second lease behind it.
const _growthPolicy = PoolPolicy(
  keepAliveInterval: _interval,
  maxTransports: 2,
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 1,
);

PoolHarness _harness() => PoolHarness(policy: _policy)..addServer('s1');

void main() {
  test('timeout-test constants keep the ping timeout off the ticks', () {
    // The unanswered-ping test needs SshTransport.pingOperationTimeout to
    // expire strictly between two _timeoutTestInterval ticks. Guard the
    // invariant so a change to either constant fails loudly here rather
    // than silently reintroducing fake-clock tie-breaking.
    expect(SshTransport.pingOperationTimeout < _timeoutTestInterval, isTrue);
    expect(
      SshTransport.pingOperationTimeout.inMilliseconds %
          _timeoutTestInterval.inMilliseconds,
      isNot(0),
    );
  });

  test('a nonpositive keepalive interval is rejected at construction', () {
    // A zero interval would spin the event loop; same contract as the
    // reconnect backoff cap.
    expect(
      () => PoolHarness(
        policy: const PoolPolicy(keepAliveInterval: Duration.zero),
      ),
      throwsArgumentError,
    );
    expect(
      () => PoolHarness(
        policy: const PoolPolicy(keepAliveInterval: Duration(seconds: -1)),
      ),
      throwsArgumentError,
    );
  });

  test('idle transports are pinged once per interval, never immediately', () {
    fakeAsync((time) {
      final h = _harness();
      final pane = browsePane(time, h, 'a');
      final transport = h.opener.transports.single;
      expect(
        transport.pingCalls,
        0,
        reason: 'the first ping waits an interval',
      );

      time.elapse(_interval);
      expect(transport.pingCalls, 1);
      time.elapse(_interval);
      expect(transport.pingCalls, 2);

      completeWithoutTimers(time, pane.close());
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('a transport with an in-flight operation skips its ping', () {
    fakeAsync((time) {
      final h = _harness();
      final pane = browsePane(time, h, 'a');
      final transport = h.opener.transports.single;

      transport.activeOperations = true;
      time.elapse(_interval);
      expect(transport.pingCalls, 0);

      // The skip is per tick, not sticky: cadence resumes with the next
      // idle tick.
      transport.activeOperations = false;
      time.elapse(_interval);
      expect(transport.pingCalls, 1);

      completeWithoutTimers(time, pane.close());
    });
  });

  test('a pending channel open holds the ping', () {
    fakeAsync((time) {
      final h = _harness();
      final pane = browsePane(time, h, 'a');
      final transport = h.opener.transports.single;
      transport.openGate = Completer<void>();

      final lease = h.manager.leaseTransferChannel('s1');
      time.flushMicrotasks();
      time.elapse(_interval);
      expect(
        transport.pingCalls,
        0,
        reason: 'an open in flight counts as an operation (03 §3.3)',
      );

      transport.openGate!.complete();
      final acquired = completeWithoutTimers(time, lease);
      completeWithoutTimers(time, acquired.release());
      time.elapse(_interval);
      expect(transport.pingCalls, 1);

      completeWithoutTimers(time, pane.close());
    });
  });

  test('every live transport is pinged on the same tick', () {
    fakeAsync((time) {
      final h = PoolHarness(policy: _growthPolicy)..addServer('s1');
      final pane = browsePane(time, h, 'a');
      // A held lease is not an in-flight operation: idle means operations.
      final lease = completeWithoutTimers(
        time,
        h.manager.leaseTransferChannel('s1'),
      );
      expect(h.opener.transports, hasLength(2));

      time.elapse(_interval);
      expect(h.opener.transports[0].pingCalls, 1);
      expect(h.opener.transports[1].pingCalls, 1);

      completeWithoutTimers(time, lease.release());
      completeWithoutTimers(time, pane.close());
      completeWithoutTimers(time, h.manager.disconnectServer('s1'));
      expect(time.pendingTimers, isEmpty);
    });
  });

  test(
    'an unanswered ping times out, closes the transport, and reconnects',
    () {
      fakeAsync((time) {
        final h = PoolHarness(
          policy: const PoolPolicy(keepAliveInterval: _timeoutTestInterval),
        )..addServer('s1');
        final states = <ServerConnectionState>[];
        final subscription = h.manager
            .watchServer('s1')
            .listen((status) => states.add(status.state));
        final pane = browsePane(time, h, 'a');
        final dead = h.opener.transports.single;
        dead.pingGate = Completer<void>();
        final oldFs = pane.fs;

        time.elapse(_timeoutTestInterval);
        expect(dead.pingCalls, 1);
        expect(states.last, ServerConnectionState.connected);

        // One outstanding ping per transport: a tick inside the timeout
        // window must not stack a second ping. The timeout itself lands at
        // 45 s + 30 s — strictly between the 45 s ticks, so the assertions
        // below never share an instant with a tick.
        time.elapse(
          SshTransport.pingOperationTimeout - const Duration(seconds: 1),
        );
        expect(dead.pingCalls, 1);
        expect(dead.closed, isFalse);

        time.elapse(const Duration(seconds: 1));
        time.flushMicrotasks();
        expect(
          dead.closed,
          isTrue,
          reason: 'silence past the operation timeout is death',
        );
        expect(states.last, ServerConnectionState.reconnecting);

        time.elapse(const Duration(seconds: 1));
        time.flushMicrotasks();
        expect(states.last, ServerConnectionState.connected);
        expect(h.opener.calls, hasLength(2));
        final replacement = h.opener.transports.last;
        expect(replacement, isNot(same(dead)));
        expect(pane.fs, isNot(same(oldFs)));
        expect(pane.homePath, '/home/test');
        expect(
          dead.pingCalls,
          1,
          reason: 'the dead transport is never pinged again',
        );

        // The replacement is kept alive on the ordinary cadence.
        time.elapse(_timeoutTestInterval);
        expect(replacement.pingCalls, 1);

        completeWithoutTimers(time, pane.close());
        unawaited(subscription.cancel());
        expect(time.pendingTimers, isEmpty);
      });
    },
  );

  test(
    'a ping-timeout verdict is never stacked onto while its close wedges',
    () {
      fakeAsync((time) {
        final h = PoolHarness(
          policy: const PoolPolicy(keepAliveInterval: _timeoutTestInterval),
        )..addServer('s1');
        final pane = browsePane(time, h, 'a');
        final dead = h.opener.transports.single;
        // Unanswered pings, a wedged close, and a closed flag that lags the
        // close call (dartssh2 reports closure with the socket teardown) —
        // the exact window where a later tick must not re-ping the dying
        // transport.
        dead.pingGate = Completer<void>();
        dead.closeGate = Completer<void>();
        dead.isClosedOnlyWhenSettled = true;

        time.elapse(_timeoutTestInterval);
        expect(dead.pingCalls, 1);

        time.elapse(SshTransport.pingOperationTimeout);
        time.flushMicrotasks();
        expect(dead.closeCalls, 1);
        expect(dead.pingCalls, 1);

        // Ticks while the wedged close keeps the slot attached and (per the
        // knob) looking open: no second ping onto the sentenced transport.
        time.elapse(_timeoutTestInterval * 3);
        expect(dead.pingCalls, 1);

        dead.closeGate!.complete();
        time.flushMicrotasks();
        completeWithoutTimers(time, pane.close());
        completeWithoutTimers(time, h.manager.disconnectServer('s1'));
      });
    },
  );

  test(
    'a ping error that is not a timeout leaves closure to the done watcher',
    () {
      fakeAsync((time) {
        final h = _harness();
        final pane = browsePane(time, h, 'a');
        final transport = h.opener.transports.single;
        transport.pingFailure = StateError('ping refused');

        time.elapse(_interval);
        expect(transport.pingCalls, 1);
        expect(transport.closed, isFalse);
        expect(
          pane.fs,
          isA<RemoteFileSystem>(),
          reason: 'the pool stays usable',
        );

        // Cadence continues: only a timeout is a pool-initiated death
        // verdict; every other failure flows through the transport's own
        // closure (03 §3.3).
        time.elapse(_interval);
        expect(transport.pingCalls, 2);

        completeWithoutTimers(time, pane.close());
      });
    },
  );

  test('teardown cancels the keepalive clock', () {
    fakeAsync((time) {
      final h = _harness();
      final pane = browsePane(time, h, 'a');
      final transport = h.opener.transports.single;
      time.elapse(_interval);
      expect(transport.pingCalls, 1);

      completeWithoutTimers(time, pane.close());
      completeWithoutTimers(time, h.manager.disconnectServer('s1'));
      expect(time.pendingTimers, isEmpty);

      time.elapse(_interval * 3);
      expect(transport.pingCalls, 1, reason: 'no ping after teardown');
    });
  });

  test('disconnecting one endpoint leaves the other endpoint on the clock', () {
    fakeAsync((time) {
      // Distinct hosts keep the two servers on distinct pools — the
      // granularity under test: one pool's teardown must never touch
      // another pool's clock.
      final h = PoolHarness(policy: _policy)
        ..addServer('s1')
        ..addServer('s2', host: 'other.example.com');
      final p1 = browsePane(time, h, 'a');
      final p2 = browsePane(time, h, 'b', server: 's2');
      final gone = h.opener.transports[0];
      final survivor = h.opener.transports[1];

      completeWithoutTimers(time, p1.close());
      completeWithoutTimers(time, h.manager.disconnectServer('s1'));
      expect(gone.pingCalls, 0);

      time.elapse(_interval * 2);
      expect(survivor.pingCalls, 2);
      expect(gone.pingCalls, 0, reason: 'a torn-down pool is never pinged');

      completeWithoutTimers(time, p2.close());
      completeWithoutTimers(time, h.manager.disconnectServer('s2'));
      expect(time.pendingTimers, isEmpty);
    });
  });
}
