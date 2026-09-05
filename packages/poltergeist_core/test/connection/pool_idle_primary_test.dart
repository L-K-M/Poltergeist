import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

// One channel per transport forces replacement growth after the first dies.
const _policy = PoolPolicy(
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 1,
);

PaneChannel _browse(FakeAsync time, PoolHarness harness, String tab) =>
    completeWithoutTimers(
      time,
      harness.manager.openBrowseChannel('s1', paneTabId: tab),
    );

void _replaceDeadFirst(
  FakeAsync time,
  PoolHarness harness,
  PaneChannel firstPane,
) {
  final first = harness.opener.transports.first;
  completeWithoutTimers(time, firstPane.close());

  // Death during an open evicts the first slot through the public API.
  final openGate = first.openGate = Completer<void>();
  final replacement =
      harness.manager.openBrowseChannel('s1', paneTabId: 'replacement');
  time.flushMicrotasks();
  first.closed = true;
  openGate.completeError(const RemoteFileException(
    kind: RemoteFileErrorKind.disconnected,
    operation: 'open SFTP',
    message: 'The first transport disconnected during channel open.',
  ));
  completeWithoutTimers(time, replacement);
  expect(harness.opener.transports, hasLength(_policy.maxTransports + 1));
}

void main() {
  test('an extra keeps its release policy after the first transport dies', () {
    fakeAsync((time) {
      final harness = PoolHarness(policy: _policy)..addServer('s1');
      final firstPane = _browse(time, harness, 'first');
      final lease = completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      final extra = harness.opener.transports.last;

      _replaceDeadFirst(time, harness, firstPane);
      completeWithoutTimers(time, lease.release());
      expect(
        extra.channels.single.closed,
        isTrue,
        reason: 'Removing the first slot must not grant its cache to an extra.',
      );
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
      final firstPane = _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra');
      final extra = harness.opener.transports.last;

      _replaceDeadFirst(time, harness, firstPane);
      completeWithoutTimers(time, extraPane.close());
      expect(extra.channels.single.closed, isTrue);
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

  test('retiring the last live extra reports the pool disconnected', () {
    fakeAsync((time) {
      const policy = PoolPolicy(
        maxTransferChannelsPerTransport: 1,
        maxChannelsPerTransport: 2,
      );
      final harness = PoolHarness(policy: policy)..addServer('s1');
      _browse(time, harness, 'stale-primary-binding');
      final firstPane = _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra');
      final first = harness.opener.transports.first;
      final extra = harness.opener.transports.last;
      completeWithoutTimers(time, firstPane.close());

      // Evict the primary while another pane still has its old binding.
      final openGate = first.openGate = Completer<void>();
      final opening =
          harness.manager.openBrowseChannel('s1', paneTabId: 'replacement');
      time.flushMicrotasks();
      first.closed = true;
      openGate.completeError(const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'open SFTP',
        message: 'The first transport disconnected during channel open.',
      ));
      final replacement = completeWithoutTimers(time, opening);
      expect(harness.opener.transports, hasLength(policy.maxTransports));

      completeWithoutTimers(time, extraPane.close());
      completeWithoutTimers(time, replacement.close());
      final states = <ServerConnectionState>[];
      final subscription =
          harness.manager.watchServer('s1').listen(states.add);
      time.flushMicrotasks();
      expect(states, [ServerConnectionState.connected]);

      time.elapse(policy.idleExtraTransportTimeout);
      expect(extra.closed, isTrue);
      expect(
        completeWithoutTimers(time, harness.manager.connectedServerIds()),
        isEmpty,
      );
      final snapshots = <ServerConnectionState>[];
      final snapshotSubscription =
          harness.manager.watchServer('s1').listen(snapshots.add);
      time.flushMicrotasks();
      expect(
        {'event': states.last, 'snapshot': snapshots.single},
        {
          'event': ServerConnectionState.disconnected,
          'snapshot': ServerConnectionState.disconnected,
        },
        reason: 'Retirement removed the last live transport from the pool.',
      );

      subscription.cancel().ignore();
      snapshotSubscription.cancel().ignore();
      completeWithoutTimers(time, harness.manager.disconnectServer('s1'));
      expect(time.pendingTimers, isEmpty);
    });
  });
}
