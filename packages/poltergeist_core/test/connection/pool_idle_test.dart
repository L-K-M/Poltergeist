import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

// One channel per transport makes growth and ownership explicit in each test.
const _policy = PoolPolicy(
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 1,
);
const _lastSecond = Duration(seconds: 1);
final _beforeExpiry = _policy.idleExtraTransportTimeout - _lastSecond;

PoolHarness _harness() => PoolHarness(policy: _policy)
  ..addServer('s1')
  ..addServer('s2');

PaneChannel _browse(
  FakeAsync time,
  PoolHarness harness,
  String tab, {
  String server = 's1',
}) => completeWithoutTimers(
  time,
  harness.manager.openBrowseChannel(server, paneTabId: tab),
);

void _disconnect(FakeAsync time, PoolHarness harness) {
  completeWithoutTimers(time, harness.manager.disconnectServer('s1'));
  completeWithoutTimers(time, harness.manager.disconnectServer('s2'));
  expect(time.pendingTimers, isEmpty);
}

void main() {
  test('empty extra transport closes at the idle deadline', () {
    fakeAsync((time) {
      final harness = _harness();
      _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra');
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
      _browse(time, harness, 'first');
      _browse(time, harness, 'extra', server: 's2');
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(harness.opener.transports.every((t) => !t.closed), isTrue);
      expect(time.pendingTimers, isEmpty);
      _disconnect(time, harness);
    });
  });

  test(
    'returned extra transfer channel closes before its idle timer starts',
    () {
      fakeAsync((time) {
        final harness = _harness();
        _browse(time, harness, 'first');
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
      _browse(time, harness, 'first');
      final lease = completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      final waiting = harness.manager.leaseTransferChannel('s2');
      time.flushMicrotasks();
      completeWithoutTimers(time, lease.release());
      final next = completeWithoutTimers(time, waiting);
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
      _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra');
      final extra = harness.opener.transports.last;
      completeWithoutTimers(time, extraPane.close());
      time.elapse(_beforeExpiry);

      final replacement = _browse(time, harness, 'replacement');
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

  test('pending channel open prevents expiry before a handle exists', () {
    fakeAsync((time) {
      final harness = _harness();
      _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra');
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
      _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra');
      final extra = harness.opener.transports.last;
      completeWithoutTimers(time, extraPane.close());

      final gate = extra.canonicalizeGate = Completer<void>();
      final opening = harness.manager.openBrowseChannel('s1', paneTabId: 'new');
      time.flushMicrotasks();
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(extra.closed, isFalse);
      gate.complete();
      completeWithoutTimers(time, opening);
      _disconnect(time, harness);
    });
  });

  test('expiry frees capacity for later prompting-disabled growth', () {
    fakeAsync((time) {
      final harness = _harness();
      _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra');
      final expired = harness.opener.transports.last;
      completeWithoutTimers(time, extraPane.close());
      time.elapse(_policy.idleExtraTransportTimeout);

      _browse(time, harness, 'new');
      expect(expired.closed, isTrue);
      expect(harness.opener.calls, hasLength(3));
      expect(harness.opener.calls.last.prompting, ConnectPrompting.disabled);
      _disconnect(time, harness);
    });
  });

  test('the first transport stays alive while its last channel is leased', () {
    fakeAsync((time) {
      final harness = PoolHarness()..addServer('s1');
      final pane = _browse(time, harness, 'first');
      final lease = completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      completeWithoutTimers(time, pane.close());
      time.elapse(_policy.idleExtraTransportTimeout * 2);
      expect(harness.opener.transports.single.closed, isFalse);
      expect(time.pendingTimers, isEmpty);
      completeWithoutTimers(time, lease.release());
      expect(harness.opener.transports.single.closed, isTrue);
      _disconnect(time, harness);
    });
  });

  test('disconnect cancels old idle timers before the server reconnects', () {
    fakeAsync((time) {
      final harness = _harness();
      _browse(time, harness, 'first');
      final extraPane = _browse(time, harness, 'extra');
      completeWithoutTimers(time, extraPane.close());
      expect(time.nonPeriodicTimerCount, 1);
      _disconnect(time, harness);

      _browse(time, harness, 'replacement');
      time.elapse(_policy.idleExtraTransportTimeout);
      expect(harness.opener.transports.last.closed, isFalse);
      _disconnect(time, harness);
    });
  });
}
