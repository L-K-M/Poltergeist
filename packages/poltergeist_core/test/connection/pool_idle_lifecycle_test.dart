import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

// One channel per transport exposes the lifecycle of each pooled connection.
// The idle timeout is pinned so the probe windows (_beforeExpiry etc.)
// stay valid whatever the production default becomes.
const _policy = PoolPolicy(
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 1,
  idleExtraTransportTimeout: Duration(seconds: 30),
);
const _lastSecond = Duration(seconds: 1);
final _beforeExpiry = _policy.idleExtraTransportTimeout - _lastSecond;

// The pinned cleanup helper abandons any close still pending after this
// bound (ssh_cleanup.dart), so a gated close inside a test must settle
// within it — elapsing past the cap replaces the gate with abandonment.
const _closeCap = Duration(seconds: 5);
final _insideCloseCap = _closeCap - _lastSecond;

// Every in-flight close arms the pinned cleanup bound's timer, so "no
// timers at all" is never true while a close is pending — the suite's
// invariant is that no IDLE clock is pending.
bool _idleTimerPending(FakeAsync time) => time.pendingTimers
    .whereType<FakeTimer>()
    .any((timer) => timer.duration == _policy.idleExtraTransportTimeout);

PoolHarness _harness({FakeTransportOpener? opener}) =>
    PoolHarness(policy: _policy, opener: opener)
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
  test('extra idle time starts after channel closure finishes', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final lease = completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      final extra = harness.opener.transports.last;
      final channel = extra.channels.single;
      final gate = channel.closeGate = Completer<void>();
      final releasing = lease.release();
      time.flushMicrotasks();

      time.elapse(_insideCloseCap);
      // The channel close is gated, so it has started but not settled —
      // the idle window cannot begin until it finishes. Only the pinned
      // close bound's timer may be pending.
      expect(channel.closeCompleted, isFalse);
      expect(extra.closeCalls, 0);
      expect(_idleTimerPending(time), isFalse);

      gate.complete();
      completeWithoutTimers(time, releasing);
      expect(channel.closeCompleted, isTrue);
      time.elapse(_beforeExpiry);
      expect(extra.closed, isFalse);
      time.elapse(_lastSecond);
      expect(extra.closed, isTrue);
      _disconnect(time, harness);
    });
  });

  test('shared extra browse channel expires only after its last binding', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra');

      // Refresh the first tab so the extra channel is the LRU sharing victim.
      browsePane(time, harness, 'first');
      final sibling = browsePane(time, harness, 'shared', server: 's2');
      final extra = harness.opener.transports.last;
      // s1 and s2 resolve to the same endpoint in this harness (the fake's
      // default host/port), so one pool serves both and may bind this pane
      // to the extra channel even though it was opened via s2.
      expect(sibling.fs, same(extraPane.fs));

      completeWithoutTimers(time, extraPane.close());
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(extra.closed, isFalse);
      expect(extra.channels.single.closed, isFalse);
      expect(time.pendingTimers, isEmpty);

      completeWithoutTimers(time, sibling.close());
      time.elapse(_beforeExpiry);
      expect(extra.closed, isFalse);
      time.elapse(_lastSecond);
      expect(extra.closed, isTrue);
      expect(
        completeWithoutTimers(time, harness.manager.connectedServerIds()),
        {'s1', 's2'},
      );
      _disconnect(time, harness);
    });
  });

  test('an extra browse pane retains the empty first transport', () {
    fakeAsync((time) {
      final harness = _harness();
      final firstPane = browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra', server: 's2');
      final first = harness.opener.transports.first;

      completeWithoutTimers(time, firstPane.close());
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(first.channels.single.closed, isTrue);
      expect(first.closed, isFalse);
      expect(time.pendingTimers, isEmpty);

      completeWithoutTimers(time, extraPane.close());
      expect(
        harness.opener.transports.every((transport) => transport.closed),
        isTrue,
      );
      _disconnect(time, harness);
    });
  });

  test(
    'last disconnect cancels idle timers before closing browse channels',
    () {
      fakeAsync((time) {
        final harness = _harness();
        browsePane(time, harness, 'first');
        final extraPane = browsePane(time, harness, 'extra');
        final first = harness.opener.transports.first;
        final extra = harness.opener.transports.last;
        completeWithoutTimers(time, extraPane.close());
        expect(time.nonPeriodicTimerCount, 1,
            reason: 'Exactly the idle clock is armed on the emptied extra.');

        final gate = first.channels.single.closeGate = Completer<void>();
        final disconnecting = harness.manager.disconnectServer('s1');
        time.flushMicrotasks();
        // Idle clocks are canceled at disconnect; only the pinned close
        // bound may still be pending while the gated channel drains.
        expect(_idleTimerPending(time), isFalse);
        time.elapse(_insideCloseCap);
        expect(extra.closeCalls, 0);

        gate.complete();
        completeWithoutTimers(time, disconnecting);
        expect(extra.closeCalls, 1);
        expect(
          first.closeCalls,
          1,
          reason: 'Disconnect must close the drained primary transport too.',
        );
        _disconnect(time, harness);
      });
    },
  );

  test('host-key block cancels idle timers before transport cleanup', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra', server: 's2');
      final first = harness.opener.transports.first;
      final extra = harness.opener.transports.last;
      completeWithoutTimers(time, extraPane.close());
      expect(time.nonPeriodicTimerCount, 1,
          reason: 'Exactly the idle clock is armed on the emptied extra.');

      final firstStates = <ServerConnectionState>[];
      final siblingStates = <ServerConnectionState>[];
      final firstSubscription = harness.manager
          .watchServer('s1')
          .listen(firstStates.add);
      final siblingSubscription = harness.manager
          .watchServer('s2')
          .listen(siblingStates.add);
      // One shared endpoint means exactly one pin; make that assumption
      // explicit so its failure names itself.
      expect(harness.store.pins, hasLength(1));
      final gate = first.closeGate = Completer<void>();
      final decision = HostKeyDecision(
        verdict: HostKeyVerdict.changed,
        presented: HostKey(
          host: 'example.com',
          port: 22,
          type: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:changed',
          pinnedAt: 0,
        ),
        pinned: harness.store.pins.values.single,
      );
      final blocking = harness.opener.calls.last.onHostKey(decision);
      time.flushMicrotasks();

      // The block lands before cleanup settles: the idle clock is already
      // gone while the gated first transport still owes its close.
      expect(_idleTimerPending(time), isFalse);
      expect(firstStates.last, ServerConnectionState.blocked);
      expect(siblingStates.last, ServerConnectionState.blocked);
      // Transports close concurrently (pinned two-phase cleanup), so the
      // extra does not queue behind the first's gated close.
      expect(extra.closeCalls, 1);

      gate.complete();
      expect(completeWithoutTimers(time, blocking), isFalse);
      expect(extra.closeCalls, 1);
      firstSubscription.cancel().ignore();
      siblingSubscription.cancel().ignore();
      _disconnect(time, harness);
    });
  });

  test('delayed failing idle close preserves a replacement transport', () {
    fakeAsync((time) {
      final harness = _harness();
      browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra');
      final extra = harness.opener.transports.last;
      final gate = extra.closeGate = Completer<void>();
      extra.closeFailure = StateError('transport cleanup');
      completeWithoutTimers(time, extraPane.close());

      final states = <ServerConnectionState>[];
      final subscription = harness.manager.watchServer('s1').listen(states.add);
      time.elapse(_policy.idleExtraTransportTimeout);
      expect(extra.closeCalls, 1);
      // The old transport's close is gated mid-flight while its replacement
      // arrives — the exact race this test exercises.
      expect(extra.closeCompleted, isFalse);

      final replacement = browsePane(time, harness, 'replacement', server: 's2');
      final current = harness.opener.transports.last;
      expect(current, isNot(same(extra)));
      expect(harness.opener.calls, hasLength(3));
      gate.complete();
      time.flushMicrotasks();

      expect(extra.closed, isTrue);
      expect(extra.closeCalls, 1);
      expect(current.closed, isFalse);
      expect(current.channels.single.fs, same(replacement.fs));
      expect(states, [ServerConnectionState.connected]);
      expect(
        completeWithoutTimers(time, harness.manager.connectedServerIds()),
        {'s1', 's2'},
      );
      subscription.cancel().ignore();
      _disconnect(time, harness);
    });
  });

  test('idle retirement defers while a growth connect is in flight', () {
    fakeAsync((time) {
      // Growth must be possible (cap 3) and its connect parked on a gate.
      const policy = PoolPolicy(
        maxTransports: 3,
        maxTransferChannelsPerTransport: 1,
        maxChannelsPerTransport: 1,
        idleExtraTransportTimeout: Duration(seconds: 30),
      );
      final opener = FakeTransportOpener();
      final harness = PoolHarness(policy: policy, opener: opener)
        ..addServer('s1')
        ..addServer('s2');
      browsePane(time, harness, 'first');
      final lease = completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      final extra = harness.opener.transports.last;
      final first = harness.opener.transports.first;

      // Park only the NEXT growth connect (the setup lease already grew).
      opener.growthGate = Completer<void>();

      // Park the extra's channel close, then queue a lease: with the first
      // transport full and the close still occupying its budget, the pool
      // must grow — and that connect parks on the growth gate.
      final closeGate = extra.channels.single.closeGate = Completer<void>();
      final releasing = lease.release();
      time.flushMicrotasks();
      final waiting = harness.manager.leaseTransferChannel('s2');
      TransferChannelLease? grantedB;
      waiting.then<void>((value) {
        grantedB = value;
      }).ignore();
      time.flushMicrotasks();
      expect(opener.transports, hasLength(2),
          reason: 'The parked growth connect records its call but has not '
              'created a transport.');

      // The close settles into the idle window while growth is parked, and
      // the first transport dies — the extra becomes the last live one.
      closeGate.complete();
      completeWithoutTimers(time, releasing);
      first.simulateExternalDeath();

      final states = <ServerConnectionState>[];
      final subscription =
          harness.manager.watchServer('s1').listen(states.add);
      time.elapse(policy.idleExtraTransportTimeout);
      // Deferred, not retired: no transient disconnect under the growth
      // connect, and no third transport while it is parked. The single
      // state is the watcher's join snapshot.
      expect(states, [ServerConnectionState.connected]);
      expect(extra.closed, isFalse);
      expect(opener.transports, hasLength(2));

      opener.growthGate!.complete();
      time.flushMicrotasks();
      expect(grantedB, isNotNull,
          reason: 'The parked growth must satisfy the queued lease.');
      completeWithoutTimers(time, grantedB!.release());
      completeWithoutTimers(time, harness.manager.disconnectServer('s1'));
      subscription.cancel().ignore();
      completeWithoutTimers(time, harness.manager.disconnectServer('s2'));
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('a failed growth open still expires the extra while demand waits', () {
    fakeAsync((time) {
      // The first transport hosts the browse channel at its channel cap;
      // the grown extra refuses SFTP, so the lease can only wait for the
      // first transport's capacity. The useless extra must still expire —
      // and the queued demand must settle once the server goes away.
      final harness = _harness(
        opener: FakeTransportOpener(transportOpenLimits: [1, 0]),
      );
      browsePane(time, harness, 'first');
      TransferChannelLease? granted;
      Object? leaseError;
      final waiting = harness.manager.leaseTransferChannel('s1');
      // Track both outcomes so the wait's fate is asserted, not ignored.
      final tracked = waiting.then<void>(
        (value) => granted = value,
        onError: (Object error) => leaseError = error,
      );
      tracked.ignore();
      time.flushMicrotasks();
      expect(harness.opener.transports, hasLength(2));
      expect(granted, isNull);

      time.elapse(_policy.idleExtraTransportTimeout);
      expect(harness.opener.transports.last.closed, isTrue);
      expect(harness.opener.transports.first.closed, isFalse);
      expect(granted, isNull);

      _disconnect(time, harness);
      expect(leaseError, isA<RemoteFileException>());
    });
  });
}
