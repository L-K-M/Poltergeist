import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

// Match the server's MaxSessions ceiling so a retiring channel holds capacity.
const _channelLimit = 1;
const _policy = PoolPolicy(
  maxTransferChannelsPerTransport: _channelLimit,
  maxChannelsPerTransport: _channelLimit,
);

void main() {
  test('extra channel retirement wakes a lease queued during its close', () {
    fakeAsync((time) {
      final harness = PoolHarness(
        policy: _policy,
        opener: FakeTransportOpener(transportOpenLimit: _channelLimit),
      )..addServer('s1');
      completeWithoutTimers(
        time,
        harness.manager.openBrowseChannel('s1', paneTabId: 'first'),
      );
      final lease = completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      expect(harness.opener.transports, hasLength(2),
          reason: 'Browse + transfer lease each need their own transport.');
      final extra = harness.opener.transports.last;
      final retiring = extra.channels.single;
      final closeGate = retiring.closeGate = Completer<void>();
      final releasing = lease.release();
      time.flushMicrotasks();

      // The old channel still occupies MaxSessions while its close awaits.
      TransferChannelLease? granted;
      final waiting = harness.manager.leaseTransferChannel('s1');
      unawaited(waiting.then((value) => granted = value));
      time.flushMicrotasks();
      // The retiring close is gated: started, not settled — and until it
      // settles the freed MaxSessions slot must not be handed out, nor
      // may the pool attempt an open the server would refuse.
      expect(retiring.closeCompleted, isFalse);
      expect(extra.openCalls, 1,
          reason: 'The closing channel still occupies MaxSessions.');
      expect(granted, isNull);

      closeGate.complete();
      completeWithoutTimers(time, releasing);
      expect(retiring.closeCompleted, isTrue);
      expect(
        granted,
        isNotNull,
        reason: 'Completed retirement must wake demand for its freed capacity.',
      );
      // The woken lease must consume the retired slot on the existing extra
      // transport rather than prompting a fresh transport open.
      expect(harness.opener.transports, hasLength(2));

      completeWithoutTimers(time, granted!.release());
      completeWithoutTimers(time, harness.manager.disconnectServer('s1'));
      expect(time.pendingTimers, isEmpty);
    });
  });

  // Strictly inside the pinned cleanup bound (ssh_cleanup.dart): a settle
  // that somehow rides a timer must still complete within the probe.
  const closeCapProbe = Duration(seconds: 4);

  test('a failed waiter does not deadlock the pump on its opened channel',
      () {
    fakeAsync((time) {
      final harness = PoolHarness(
        policy: _policy,
        opener: FakeTransportOpener(transportOpenLimit: _channelLimit),
      )..addServer('s1');
      final pane = browsePane(time, harness, 'first');
      completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      final primary = harness.opener.transports.first;

      // Both transports hold their single channel and the pool is at its
      // transport cap: a fresh lease can only queue.
      final queued = harness.manager.leaseTransferChannel('s1');
      Object? queuedError;
      unawaited(queued.then<void>((_) {},
          onError: (Object error) => queuedError = error));
      time.flushMicrotasks();
      expect(queuedError, isNull);

      // Closing the pane frees primary capacity; the pump serving the
      // queued lease opens on the primary and parks on the open gate.
      final openGate = primary.openGate = Completer<void>();
      var paneClosed = false;
      unawaited(pane.close().then<void>((_) => paneClosed = true));
      time.flushMicrotasks();
      expect(primary.openCalls, 2,
          reason: 'The pump must open on the freed primary budget for the '
              'queued lease (plus the pane\'s original browse open).');

      // The disconnect fails the queued lease while its open is parked.
      var disconnected = false;
      unawaited(harness.manager
          .disconnectServer('s1')
          .then<void>((_) => disconnected = true));
      time.flushMicrotasks();
      expect(queuedError, isA<RemoteFileException>());

      // Releasing the open must settle every in-flight future: the pump's
      // cleanup of the opened-for-a-dead-waiter channel may never wait on
      // the pump itself.
      openGate.complete();
      time.flushMicrotasks();
      time.elapse(closeCapProbe);
      time.flushMicrotasks();
      expect(paneClosed, isTrue,
          reason: 'The pane close must settle once the parked open '
              'returns.');
      expect(disconnected, isTrue,
          reason: 'The disconnect must complete once the pump drains.');
      expect(time.pendingTimers, isEmpty);
    });
  });
}
