import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

// One channel per transport forces replacement growth after the first
// dies. The transport cap is pinned because the expected transport counts
// below encode exactly two transports.
const _policy = PoolPolicy(
  maxTransports: 2,
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 1,
);

PaneChannel _replaceDeadFirst(
  FakeAsync time,
  PoolHarness harness,
  PaneChannel firstPane,
  int expectedTransports,
) {
  final first = harness.opener.transports.first;
  completeWithoutTimers(time, firstPane.close());

  // Death during an open evicts the first slot through the public API.
  final opensBefore = first.openCalls;
  final openGate = first.openGate = Completer<void>();
  final replacement = harness.manager.openBrowseChannel(
    's1',
    paneTabId: 'replacement',
  );
  time.flushMicrotasks();
  expect(
    first.openCalls,
    opensBefore + 1,
    reason:
        'The replacement open must park on the first transport before '
        'its death, or the gate error below fires on an unwatched future.',
  );
  first.simulateExternalDeath();
  openGate.completeError(
    const RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'open SFTP',
      message: 'The first transport disconnected during channel open.',
    ),
  );
  final pane = completeWithoutTimers(time, replacement);
  expect(harness.opener.transports, hasLength(expectedTransports));
  return pane;
}

void main() {
  test('an extra keeps its release policy after the first transport dies', () {
    fakeAsync((time) {
      final harness = PoolHarness(policy: _policy)..addServer('s1');
      final firstPane = browsePane(time, harness, 'first');
      final lease = completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      final extra = harness.opener.transports.last;

      _replaceDeadFirst(time, harness, firstPane, _policy.maxTransports + 1);
      completeWithoutTimers(time, lease.release());
      expect(
        extra.channels.single.closed,
        isTrue,
        reason: 'Removing the first slot must not grant its cache to an extra.',
      );
      // The replacement pane is deliberately left open: it is the only
      // channel keeping the newest transport alive past the idle deadline.
      time.elapse(_policy.idleExtraTransportTimeout);
      expect(extra.closed, isTrue);
      expect(harness.opener.transports.last.closed, isFalse);

      completeWithoutTimers(time, harness.manager.disconnectServer('s1'));
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('an empty extra still expires after the first transport dies', () {
    fakeAsync((time) {
      final harness = PoolHarness(policy: _policy)..addServer('s1');
      final firstPane = browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra');
      final extra = harness.opener.transports.last;

      // The extra is at its channel cap, so the replacement forced a new
      // transport beyond the configured maximum.
      _replaceDeadFirst(time, harness, firstPane, _policy.maxTransports + 1);
      completeWithoutTimers(time, extraPane.close());
      expect(extra.channels.single.closed, isTrue);
      // The replacement pane is deliberately left open: it is the only
      // channel keeping the newest transport alive past the idle deadline.
      time.elapse(_policy.idleExtraTransportTimeout);
      expect(
        extra.closed,
        isTrue,
        reason: 'Removing the first slot must not exempt an extra from expiry.',
      );
      expect(harness.opener.transports.last.closed, isFalse);

      completeWithoutTimers(time, harness.manager.disconnectServer('s1'));
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('a transport grown after the first dies is born an extra', () {
    fakeAsync((time) {
      final harness = PoolHarness(policy: _policy)
        ..addServer('s1')
        ..addServer('s2');
      final firstPane = browsePane(time, harness, 'first');
      // A second bookmark on the shared endpoint keeps the pool referenced
      // after the replacement pane closes, so only the idle clock — not
      // pane-lifetime teardown — can retire the grown transport.
      final keeper = browsePane(time, harness, 'keeper', server: 's2');
      final extra = harness.opener.transports.last;

      final replacement = _replaceDeadFirst(
        time,
        harness,
        firstPane,
        _policy.maxTransports + 1,
      );
      final grown = harness.opener.transports.last;
      expect(grown, isNot(same(extra)));

      completeWithoutTimers(time, replacement.close());
      time.elapse(_policy.idleExtraTransportTimeout);
      expect(
        grown.closed,
        isTrue,
        reason:
            'The first-transport role is assigned at creation only; a '
            'later transport stays idle-expiring (03 §3.3).',
      );
      expect(extra.closed, isFalse);

      completeWithoutTimers(time, keeper.close());
      completeWithoutTimers(time, harness.manager.disconnectServer('s1'));
      completeWithoutTimers(time, harness.manager.disconnectServer('s2'));
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('recovered browse demand keeps the last live extra connected', () {
    fakeAsync((time) {
      const policy = PoolPolicy(
        maxTransports: 2,
        maxTransferChannelsPerTransport: 1,
        maxChannelsPerTransport: 2,
      );
      final harness = PoolHarness(policy: policy)..addServer('s1');
      final recovered = browsePane(time, harness, 'recovering-primary-binding');
      final firstPane = browsePane(time, harness, 'first');
      final extraPane = browsePane(time, harness, 'extra');
      final extra = harness.opener.transports.last;

      // Recovery spends the extra's spare channel on the surviving pane;
      // the concurrent replacement acquisition then grows another extra.
      final replacement = _replaceDeadFirst(
        time,
        harness,
        firstPane,
        policy.maxTransports + 1,
      );

      completeWithoutTimers(time, extraPane.close());
      completeWithoutTimers(time, replacement.close());
      final states = <ServerConnectionState>[];
      final subscription = harness.manager
          .watchServer('s1')
          .listen((status) => states.add(status.state));
      time.flushMicrotasks();
      expect(states, [ServerConnectionState.connected]);

      time.elapse(policy.idleExtraTransportTimeout);
      expect(extra.closed, isFalse);
      expect(
        completeWithoutTimers(time, harness.manager.connectedServerIds()),
        {'s1'},
      );
      expect(states.last, ServerConnectionState.connected);
      completeWithoutTimers(time, recovered.close());
      final snapshots = <ServerConnectionState>[];
      final snapshotSubscription = harness.manager
          .watchServer('s1')
          .listen((status) => snapshots.add(status.state));
      time.flushMicrotasks();
      expect(
        states.last,
        ServerConnectionState.disconnected,
        reason: 'Closing the recovered pane removes the last live demand.',
      );
      expect(snapshots.single, ServerConnectionState.disconnected);

      subscription.cancel().ignore();
      snapshotSubscription.cancel().ignore();
      completeWithoutTimers(time, harness.manager.disconnectServer('s1'));
      expect(time.pendingTimers, isEmpty);
    });
  });
}
