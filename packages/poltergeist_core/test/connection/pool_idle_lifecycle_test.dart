import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

// One channel per transport exposes the lifecycle of each pooled connection.
const _policy = PoolPolicy(
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 1,
);
const _beforeExpiry = Duration(seconds: 59);
const _lastSecond = Duration(seconds: 1);

T _complete<T>(FakeAsync time, Future<T> future) {
  late T result;
  var completed = false;
  future.then((value) {
    result = value;
    completed = true;
  });
  time.flushMicrotasks();
  expect(
    completed,
    isTrue,
    reason: 'The operation must finish without a timer.',
  );
  return result;
}

PoolHarness _harness({FakeTransportOpener? opener}) =>
    PoolHarness(policy: _policy, opener: opener)
      ..addServer('s1')
      ..addServer('s2');

PaneChannel _browse(
  FakeAsync time,
  PoolHarness harness,
  String tab, {
  String server = 's1',
}) =>
    _complete(time, harness.manager.openBrowseChannel(server, paneTabId: tab));

void _disconnect(FakeAsync time, PoolHarness harness) {
  _complete(time, harness.manager.disconnectServer('s1'));
  _complete(time, harness.manager.disconnectServer('s2'));
  expect(time.pendingTimers, isEmpty);
}

void main() {
  test('extra idle time starts after channel closure finishes', () {
    fakeAsync((time) {
      final harness = _harness();
      _browse(time, harness, 'first');
      final lease = _complete(time, harness.manager.leaseTransferChannel('s1'));
      final extra = harness.opener.transports.last;
      final channel = extra.channels.single;
      final gate = channel.closeGate = Completer<void>();
      final releasing = lease.release();
      time.flushMicrotasks();

      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(channel.closed, isFalse);
      expect(extra.closeCalls, 0);
      expect(time.pendingTimers, isEmpty);

      gate.complete();
      _complete(time, releasing);
      expect(channel.closed, isTrue);
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
      _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra');

      // Refresh the first tab so the extra channel is the LRU sharing victim.
      _browse(time, harness, 'first');
      final sibling = _browse(time, harness, 'shared', server: 's2');
      final extra = harness.opener.transports.last;
      expect(sibling.fs, same(extraPane.fs));

      _complete(time, extraPane.close());
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(extra.closed, isFalse);
      expect(extra.channels.single.closed, isFalse);
      expect(time.pendingTimers, isEmpty);

      _complete(time, sibling.close());
      time.elapse(_beforeExpiry);
      expect(extra.closed, isFalse);
      time.elapse(_lastSecond);
      expect(extra.closed, isTrue);
      expect(_complete(time, harness.manager.connectedServerIds()), {
        's1',
        's2',
      });
      _disconnect(time, harness);
    });
  });

  test('an extra browse pane retains the empty first transport', () {
    fakeAsync((time) {
      final harness = _harness();
      final firstPane = _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra', server: 's2');
      final first = harness.opener.transports.first;

      _complete(time, firstPane.close());
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(first.channels.single.closed, isTrue);
      expect(first.closed, isFalse);
      expect(time.pendingTimers, isEmpty);

      _complete(time, extraPane.close());
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
        _browse(time, harness, 'first');
        final extraPane = _browse(time, harness, 'extra');
        final first = harness.opener.transports.first;
        final extra = harness.opener.transports.last;
        _complete(time, extraPane.close());
        expect(time.nonPeriodicTimerCount, 1);

        final gate = first.channels.single.closeGate = Completer<void>();
        final disconnecting = harness.manager.disconnectServer('s1');
        time.flushMicrotasks();
        expect(time.pendingTimers, isEmpty);
        time.elapse(_policy.idleExtraTransportTimeout * 2);
        expect(extra.closeCalls, 0);

        gate.complete();
        _complete(time, disconnecting);
        expect(extra.closeCalls, 1);
        _disconnect(time, harness);
      });
    },
  );

  test('host-key block cancels idle timers before transport cleanup', () {
    fakeAsync((time) {
      final harness = _harness();
      _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra', server: 's2');
      final first = harness.opener.transports.first;
      final extra = harness.opener.transports.last;
      _complete(time, extraPane.close());
      expect(time.nonPeriodicTimerCount, 1);

      final firstStates = <ServerConnectionState>[];
      final siblingStates = <ServerConnectionState>[];
      final firstSubscription = harness.manager
          .watchServer('s1')
          .listen(firstStates.add);
      final siblingSubscription = harness.manager
          .watchServer('s2')
          .listen(siblingStates.add);
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

      expect(time.pendingTimers, isEmpty);
      expect(firstStates.last, ServerConnectionState.blocked);
      expect(siblingStates.last, ServerConnectionState.blocked);
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(extra.closeCalls, 0);

      gate.complete();
      expect(_complete(time, blocking), isFalse);
      expect(extra.closeCalls, 1);
      firstSubscription.cancel().ignore();
      siblingSubscription.cancel().ignore();
      _disconnect(time, harness);
    });
  });

  test('delayed failing idle close preserves a replacement transport', () {
    fakeAsync((time) {
      final harness = _harness();
      _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra');
      final extra = harness.opener.transports.last;
      final gate = extra.closeGate = Completer<void>();
      extra.closeFailure = StateError('transport cleanup');
      _complete(time, extraPane.close());

      final states = <ServerConnectionState>[];
      final subscription = harness.manager.watchServer('s1').listen(states.add);
      time.elapse(_policy.idleExtraTransportTimeout);
      expect(extra.closeCalls, 1);
      expect(extra.closed, isFalse);

      final replacement = _browse(time, harness, 'replacement', server: 's2');
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
      expect(_complete(time, harness.manager.connectedServerIds()), {
        's1',
        's2',
      });
      subscription.cancel().ignore();
      _disconnect(time, harness);
    });
  });

  test('growth whose channel open fails still expires while demand waits', () {
    fakeAsync((time) {
      final harness = _harness(
        opener: FakeTransportOpener(transportOpenLimit: 0),
      );
      final waiting = harness.manager.openBrowseChannel('s1', paneTabId: 'tab');
      waiting.ignore();
      time.flushMicrotasks();
      expect(harness.opener.transports, hasLength(2));
      expect(harness.openChannels, isEmpty);

      time.elapse(_policy.idleExtraTransportTimeout);
      expect(harness.opener.transports.last.closed, isTrue);
      expect(harness.opener.transports.first.closed, isFalse);
      _disconnect(time, harness);
    });
  });
}
