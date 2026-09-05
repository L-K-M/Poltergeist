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

T _complete<T>(FakeAsync time, Future<T> future) {
  late T result;
  var completed = false;
  future.then((value) {
    result = value;
    completed = true;
  });
  time.flushMicrotasks();
  expect(completed, isTrue);
  return result;
}

void main() {
  test('extra channel retirement wakes a lease queued during its close', () {
    fakeAsync((time) {
      final harness = PoolHarness(
        policy: _policy,
        opener: FakeTransportOpener(transportOpenLimit: _channelLimit),
      )..addServer('s1');
      _complete(
        time,
        harness.manager.openBrowseChannel('s1', paneTabId: 'first'),
      );
      final lease = _complete(time, harness.manager.leaseTransferChannel('s1'));
      final extra = harness.opener.transports.last;
      final retiring = extra.channels.single;
      final closeGate = retiring.closeGate = Completer<void>();
      final releasing = lease.release();
      time.flushMicrotasks();

      // The old channel still occupies MaxSessions while its close awaits.
      TransferChannelLease? granted;
      final waiting = harness.manager.leaseTransferChannel('s1');
      waiting.then((value) => granted = value);
      time.flushMicrotasks();
      expect(retiring.closed, isFalse);
      expect(granted, isNull);

      closeGate.complete();
      _complete(time, releasing);
      expect(retiring.closed, isTrue);
      expect(
        granted,
        isNotNull,
        reason: 'Completed retirement must wake demand for its freed capacity.',
      );
      expect(harness.opener.transports, hasLength(_policy.maxTransports));

      _complete(time, granted!.release());
      _complete(time, harness.manager.disconnectServer('s1'));
      expect(time.pendingTimers, isEmpty);
    });
  });
}
