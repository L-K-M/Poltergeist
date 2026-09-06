import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

// Match the pinned session's cleanup bound; no wall-clock waits in this suite.
const _closeBudget = Duration(seconds: 5);
const _smallPool = PoolPolicy(
  maxChannelsPerTransport: 2,
  maxTransferChannelsPerTransport: 2,
);

void main() {
  test('disconnect bounds all channels and still closes the transport', () {
    fakeAsync((clock) {
      final harness = PoolHarness()..addServer('s1');
      for (final tab in ['a', 'b', 'c']) {
        _settle(clock, harness.manager.openBrowseChannel('s1', paneTabId: tab));
      }
      for (var index = 0; index < 2; index++) {
        _settle(clock, harness.manager.leaseTransferChannel('s1'));
      }
      final transport = harness.opener.transports.single;
      final gates = [
        for (final channel in harness.channels)
          channel.closeGate = Completer<void>(),
        transport.closeGate = Completer<void>(),
      ];

      final disconnect = _Outcome(harness.manager.disconnectServer('s1'));
      clock.flushMicrotasks();
      expect(harness.channels.every((channel) => channel.closed), isTrue);
      expect(disconnect._done, isFalse);

      clock.elapse(_closeBudget);
      expect(transport.closed, isTrue);
      clock.elapse(_closeBudget);
      disconnect._expectSuccess();
      expect(_settle(clock, harness.manager.connectedServerIds()), isEmpty);

      // Timed-out futures remain observed when the socket eventually fails.
      for (final gate in gates) {
        gate.completeError(StateError('late cleanup failure'));
      }
      clock.flushMicrotasks();
    });
  });

  test('partial disconnect bounds cleanup and preserves the sibling', () {
    fakeAsync((clock) {
      final harness = PoolHarness()
        ..addServer('s1')
        ..addServer('s2');
      final sibling = _settle(
        clock,
        harness.manager.openBrowseChannel('s2', paneTabId: 'keep'),
      );
      for (final tab in ['a', 'b']) {
        _settle(clock, harness.manager.openBrowseChannel('s1', paneTabId: tab));
      }
      _settle(clock, harness.manager.leaseTransferChannel('s1'));
      for (final channel in harness.channels.skip(1)) {
        channel.closeGate = Completer<void>();
      }

      final disconnect = _Outcome(harness.manager.disconnectServer('s1'));
      clock.flushMicrotasks();
      clock.elapse(_closeBudget);
      disconnect._expectSuccess();
      expect(harness.openChannels.single.fs, same(sibling.fs));
      expect(harness.opener.transports.single.closed, isFalse);
      expect(_settle(clock, harness.manager.connectedServerIds()), {'s2'});
    });
  });

  test('last pane close bounds channel and transport teardown', () {
    fakeAsync((clock) {
      final harness = PoolHarness()..addServer('s1');
      final pane = _settle(
        clock,
        harness.manager.openBrowseChannel('s1', paneTabId: 'tab'),
      );
      harness.channels.single.closeGate = Completer<void>();
      final transport = harness.opener.transports.single
        ..closeGate = Completer<void>();

      final close = _Outcome(pane.close());
      clock.flushMicrotasks();
      clock.elapse(_closeBudget);
      expect(transport.closed, isTrue);
      clock.elapse(_closeBudget);
      close._expectSuccess();
      expect(_settle(clock, harness.manager.connectedServerIds()), isEmpty);
    });
  });

  test('changed-key cleanup cannot stall the hard block', () {
    fakeAsync((clock) {
      final harness =
          PoolHarness(
              policy: _smallPool,
              opener: FakeTransportOpener(
                presentedFingerprints: ['SHA256:old', 'SHA256:changed'],
              ),
            )
            ..addServer('s1')
            ..addServer('s2');
      _settle(clock, harness.manager.openBrowseChannel('s1', paneTabId: 'tab'));
      _settle(clock, harness.manager.leaseTransferChannel('s2'));
      final states = <ServerConnectionState>[];
      harness.manager.watchServer('s2').listen(states.add);
      for (final channel in harness.channels) {
        channel.closeGate = Completer<void>();
      }
      final transport = harness.opener.transports.single
        ..closeGate = Completer<void>();

      final growth = _Outcome(harness.manager.leaseTransferChannel('s1'));
      clock.flushMicrotasks();
      expect(states.last, ServerConnectionState.blocked);
      expect(harness.channels.every((channel) => channel.closed), isTrue);
      expect(_settle(clock, harness.manager.connectedServerIds()), isEmpty);

      clock.elapse(_closeBudget);
      expect(transport.closed, isTrue);
      clock.elapse(_closeBudget);
      growth._expectFailure(RemoteFileErrorKind.other);
      expect(states.last, ServerConnectionState.blocked);
    });
  });

  test('stale first connect reports disconnect despite stalled teardown', () {
    fakeAsync((clock) {
      final harness = PoolHarness()..addServer('s1');
      final gate = harness.opener.connectGate = Completer<void>();
      final opening = _Outcome(
        harness.manager.openBrowseChannel('s1', paneTabId: 'tab'),
      );
      clock.flushMicrotasks();
      final transport = harness.opener.transports.single
        ..closeGate = Completer<void>();
      _settle(clock, harness.manager.disconnectServer('s1'));

      gate.complete();
      clock.flushMicrotasks();
      expect(transport.closed, isTrue);
      clock.elapse(_closeBudget);
      opening._expectFailure(RemoteFileErrorKind.disconnected);
    });
  });

  test('stale growth reports disconnect despite stalled teardown', () {
    fakeAsync((clock) {
      final harness = PoolHarness(policy: _smallPool)..addServer('s1');
      _settle(clock, harness.manager.openBrowseChannel('s1', paneTabId: 'tab'));
      _settle(clock, harness.manager.leaseTransferChannel('s1'));
      final gate = harness.opener.connectGate = Completer<void>();
      final growth = _Outcome(harness.manager.leaseTransferChannel('s1'));
      clock.flushMicrotasks();
      final transport = harness.opener.transports.last
        ..closeGate = Completer<void>();
      _settle(clock, harness.manager.disconnectServer('s1'));

      gate.complete();
      clock.flushMicrotasks();
      expect(transport.closed, isTrue);
      clock.elapse(_closeBudget);
      growth._expectFailure(RemoteFileErrorKind.disconnected);
    });
  });

  test('a late channel cannot stall an abandoned acquisition', () {
    fakeAsync((clock) {
      final harness = PoolHarness()..addServer('s1');
      _settle(clock, harness.manager.openBrowseChannel('s1', paneTabId: 'tab'));
      final transport = harness.opener.transports.single;
      final gate = transport.openGate = Completer<void>();
      final opening = _Outcome(harness.manager.leaseTransferChannel('s1'));
      clock.flushMicrotasks();
      final lateChannel = transport.channels.last
        ..closeGate = Completer<void>();
      transport.closeGate = Completer<void>();
      final disconnect = _Outcome(harness.manager.disconnectServer('s1'));
      clock.flushMicrotasks();
      clock.elapse(_closeBudget);
      disconnect._expectSuccess();

      gate.complete();
      clock.flushMicrotasks();
      expect(lateChannel.closed, isTrue);
      clock.elapse(_closeBudget);
      opening._expectFailure(RemoteFileErrorKind.disconnected);
    });
  });
}

// Observe errors immediately so fake time can distinguish failure from a hang.
class _Outcome<T> {
  bool _done = false;
  T? _value;
  Object? _error;

  _Outcome(Future<T> future) {
    future.then<void>(
      (value) {
        _value = value;
        _done = true;
      },
      onError: (Object error) {
        _error = error;
        _done = true;
      },
    );
  }

  void _expectSuccess() {
    expect(_done, isTrue, reason: 'cleanup must finish within its budget');
    expect(_error, isNull);
  }

  void _expectFailure(RemoteFileErrorKind kind) {
    expect(_done, isTrue, reason: 'cleanup must not strand the original error');
    expect(
      _error,
      isA<RemoteFileException>().having((error) => error.kind, 'kind', kind),
    );
  }
}

T _settle<T>(FakeAsync clock, Future<T> future) {
  final outcome = _Outcome(future);
  clock.flushMicrotasks();
  outcome._expectSuccess();
  return outcome._value as T;
}
