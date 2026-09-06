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
      final extra = harness.opener.transports.last;
      final retiring = extra.channels.single;
      final closeGate = retiring.closeGate = Completer<void>();
      final releasing = lease.release();
      time.flushMicrotasks();

      // The old channel still occupies MaxSessions while its close awaits.
      TransferChannelLease? granted;
      final waiting = harness.manager.leaseTransferChannel('s1');
      waiting.then((value) => granted = value).ignore();
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
      expect(harness.opener.transports, hasLength(_policy.maxTransports));

      completeWithoutTimers(time, granted!.release());
      completeWithoutTimers(time, harness.manager.disconnectServer('s1'));
      expect(time.pendingTimers, isEmpty);
    });
  });
}
