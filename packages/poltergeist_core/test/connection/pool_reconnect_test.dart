import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _disconnected = RemoteFileException(
  kind: RemoteFileErrorKind.disconnected,
  operation: 'list',
  message: 'Connection lost.',
);
const _firstDelay = Duration(seconds: 1);

enum _StopRecovery { paneClose, disconnect }

void main() {
  test(
    'rejects nonpositive reconnect caps instead of spinning on an outage',
    () {
      for (final cap in [Duration.zero, const Duration(seconds: -1)]) {
        expect(
          () => PoolHarness(policy: PoolPolicy(reconnectBackoffCap: cap)),
          throwsArgumentError,
        );
      }
    },
  );

  for (final deathError in [null, StateError('socket died')]) {
    test('closure ($deathError) rebinds the same pane and resolves home', () {
      fakeAsync((time) {
        final h = PoolHarness()..addServer('s1');
        final states = <ServerConnectionState>[];
        final subscription = h.manager.watchServer('s1').listen(states.add);
        final pane = browsePane(time, h, 'a');
        final oldFs = pane.fs;
        h.opener.transports.single.die(deathError);
        time.flushMicrotasks();
        expect(states.last, ServerConnectionState.reconnecting);
        expect(() => pane.fs, throwsA(isA<RemoteFileException>()));
        expect(h.opener.calls, hasLength(1));

        time.elapse(_firstDelay);
        time.flushMicrotasks();
        expect(states.last, ServerConnectionState.connected);
        expect(pane.fs, isNot(same(oldFs)));
        expect(pane.homePath, '/home/test');
        expect((pane.fs as StubRemoteFileSystem).canonicalizeCalls, 1);
        expect(browsePane(time, h, 'a'), same(pane));
        completeWithoutTimers(time, pane.close());
        expect(h.opener.transports.last.closed, isTrue);
        unawaited(subscription.cancel());
        expect(time.pendingTimers, isEmpty);
      });
    });
  }

  test('backoff is clamped first and jittered downward at every retry', () {
    for (final jitter in [0.0, 0.5, 1.0]) {
      fakeAsync((time) {
        final prober = FakeReconnectProber()..status = ProbeStatus.offline;
        final h = PoolHarness(prober: prober, random: FixedRandom(jitter))
          ..addServer('s1');
        final pane = browsePane(time, h, 'a');
        h.opener.transports.single.die();
        time.flushMicrotasks();
        var probes = 0;
        for (final base in [1, 2, 4, 8, 16, 30, 30, 30]) {
          final delay = Duration(
            microseconds:
                (base * Duration.microsecondsPerSecond * (1 - 0.3 * jitter))
                    .round(),
          );
          time.elapse(delay - const Duration(microseconds: 1));
          expect(prober.calls, probes);
          time.elapse(const Duration(microseconds: 1));
          time.flushMicrotasks();
          expect(prober.calls, ++probes);
          expect(h.opener.calls, hasLength(1));
        }
        completeWithoutTimers(time, pane.close());
        expect(time.pendingTimers, isEmpty);
      });
    }
  });

  test('shared references and new acquisitions fold into one recovery', () {
    fakeAsync((time) {
      final h = PoolHarness()
        ..addServer('s1')
        ..addServer('s2');
      final a = browsePane(time, h, 'a');
      final b = browsePane(time, h, 'b', server: 's2');
      h.opener.transports.single.die();
      time.flushMicrotasks();
      final pending = h.manager.openBrowseChannel('s1', paneTabId: 'c');
      time.elapse(_firstDelay);
      final c = completeWithoutTimers(time, pending);
      expect(h.opener.calls, hasLength(2));
      expect(a.fs, isNot(same(b.fs)));
      expect(c.fs, isNot(same(a.fs)));
      completeWithoutTimers(time, h.manager.disconnectServer('s1'));
      expect(b.fs, isA<RemoteFileSystem>());
      completeWithoutTimers(time, b.close());
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('closing a pane during a delayed recovery open never revives it', () {
    fakeAsync((time) {
      final h = PoolHarness()
        ..addServer('s1')
        ..addServer('s2');
      final a = browsePane(time, h, 'a');
      final b = browsePane(time, h, 'b', server: 's2');
      h.opener.transports.single.die();
      time.flushMicrotasks();
      final gate = Completer<void>();
      h.opener.connectGate = gate;
      time.elapse(_firstDelay);
      time.flushMicrotasks();
      completeWithoutTimers(time, a.close());
      gate.complete();
      time.flushMicrotasks();
      expect(h.openChannels, hasLength(1));
      expect(b.fs, isA<RemoteFileSystem>());
      completeWithoutTimers(time, b.close());
      expect(h.opener.transports.last.closed, isTrue);
    });
  });

  test(
    'last disconnect cancels backoff and folded acquisition immediately',
    () {
      fakeAsync((time) {
        final prober = FakeReconnectProber()..status = ProbeStatus.unknown;
        final h = PoolHarness(prober: prober)..addServer('s1');
        browsePane(time, h, 'a');
        h.opener.transports.single.die();
        time.flushMicrotasks();
        final pending = h.manager.openBrowseChannel('s1', paneTabId: 'b');
        final failed = expectLater(
          pending,
          throwsA(isA<RemoteFileException>()),
        );
        time.flushMicrotasks();
        completeWithoutTimers(time, h.manager.disconnectServer('s1'));
        completeWithoutTimers(time, failed);
        expect(time.pendingTimers, isEmpty);
        time.elapse(const Duration(minutes: 2));
        expect(prober.calls, 0);
      });
    },
  );

  test(
    'late probe and handshake results cannot resurrect an abandoned pool',
    () {
      for (final phase in ['probe', 'handshake']) {
        fakeAsync((time) {
          final prober = FakeReconnectProber();
          final h = PoolHarness(prober: prober)..addServer('s1');
          final pane = browsePane(time, h, 'a');
          final gate = Completer<void>();
          if (phase == 'probe') prober.gate = gate;
          if (phase == 'handshake') h.opener.connectGate = gate;
          h.opener.transports.single.die();
          time.flushMicrotasks();
          time.elapse(_firstDelay);
          time.flushMicrotasks();
          completeWithoutTimers(time, pane.close());
          prober.gate = null;
          h.opener.connectGate = null;
          final replacement = browsePane(time, h, 'a');
          final currentFs = replacement.fs;
          gate.complete();
          time.flushMicrotasks();
          expect(replacement.fs, same(currentFs));
          expect(h.opener.transports.where((t) => !t.closed), hasLength(1));
          completeWithoutTimers(time, replacement.close());
          expect(time.pendingTimers, isEmpty);
        });
      }
    },
  );

  test('only disconnected VFS failures kill their current transport', () {
    fakeAsync((time) {
      final h = PoolHarness()..addServer('s1');
      final pane = browsePane(time, h, 'a');
      final lease = completeWithoutTimers(
        time,
        h.manager.leaseTransferChannel('s1'),
      );
      final oldPaneFs = pane.fs;
      final oldLeaseFs = lease.fs;
      pane.reportFailure(
        oldPaneFs,
        const RemoteFileException(
          kind: RemoteFileErrorKind.permissionDenied,
          operation: 'list',
          message: 'Denied.',
        ),
      );
      time.flushMicrotasks();
      expect(h.opener.transports.single.closed, isFalse);
      lease.reportFailure(oldLeaseFs, _disconnected);
      time.flushMicrotasks();
      time.elapse(_firstDelay);
      time.flushMicrotasks();
      final replacement = h.opener.transports.last;
      lease.reportFailure(oldLeaseFs, _disconnected);
      pane.reportFailure(oldPaneFs, _disconnected);
      time.flushMicrotasks();
      expect(replacement.closed, isFalse);
      expect(() => lease.fs, throwsA(isA<RemoteFileException>()));
      completeWithoutTimers(time, lease.release());
      completeWithoutTimers(time, pane.close());
    });
  });

  test('a healthy sibling supplies recovery without another TCP connect', () {
    fakeAsync((time) {
      final h = PoolHarness(
        policy: const PoolPolicy(
          maxChannelsPerTransport: 2,
          maxTransferChannelsPerTransport: 1,
        ),
      )..addServer('s1');
      final a = browsePane(time, h, 'a');
      final lease = completeWithoutTimers(
        time,
        h.manager.leaseTransferChannel('s1'),
      );
      final b = browsePane(time, h, 'b');
      final oldFs = a.fs;
      h.opener.transports.first.die();
      time.flushMicrotasks();
      expect(a.fs, isNot(same(oldFs)));
      expect(a.fs, isNot(same(b.fs)));
      expect(h.opener.calls, hasLength(2));
      completeWithoutTimers(time, lease.release());
      completeWithoutTimers(time, a.close());
      completeWithoutTimers(time, b.close());
    });
  });

  test(
    'changed-key reconnect blocks all siblings without prompting or retry',
    () {
      fakeAsync((time) {
        final opener = FakeTransportOpener(
          presentedFingerprints: ['SHA256:a', 'SHA256:b'],
        );
        final h = PoolHarness(opener: opener)
          ..addServer('s1')
          ..addServer('s2');
        var prompts = 0;
        h.onHostKey = (_) async {
          prompts++;
          return true;
        };
        browsePane(time, h, 'a');
        browsePane(time, h, 'b', server: 's2');
        opener.transports.single.die();
        time.flushMicrotasks();
        time.elapse(_firstDelay);
        time.flushMicrotasks();
        for (final id in ['s1', 's2']) {
          final states = <ServerConnectionState>[];
          final subscription = h.manager.watchServer(id).listen(states.add);
          time.flushMicrotasks();
          expect(states, [ServerConnectionState.blocked]);
          unawaited(subscription.cancel());
        }
        expect(prompts, 1);
        expect(h.store.pins.values.single.fingerprintSha256, 'SHA256:a');
        expect(time.pendingTimers, isEmpty);
        completeWithoutTimers(time, h.manager.disconnectServer('s1'));
        completeWithoutTimers(time, h.manager.disconnectServer('s2'));
      });
    },
  );

  test('a failed recovery channel retries rather than waiting on itself', () {
    fakeAsync((time) {
      final h = PoolHarness()..addServer('s1');
      final pane = browsePane(time, h, 'a');
      h.opener.transports.single.die();
      time.flushMicrotasks();
      final handshake = h.opener.connectGate = Completer<void>();
      time.elapse(_firstDelay);
      time.flushMicrotasks();
      final failedTransport = h.opener.transports.last;
      failedTransport.openFailure = _disconnected;
      h.opener.connectGate = null;
      handshake.complete();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      expect(h.opener.calls, hasLength(3));
      expect(failedTransport.closed, isTrue);
      expect(pane.fs, isA<RemoteFileSystem>());
      completeWithoutTimers(time, pane.close());
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('disconnect during home resolution cannot kill a surviving sibling', () {
    fakeAsync((time) {
      final h = PoolHarness()
        ..addServer('s1')
        ..addServer('s2');
      browsePane(time, h, 'a');
      final b = browsePane(time, h, 'b', server: 's2');
      h.opener.transports.single.die();
      time.flushMicrotasks();
      final handshake = h.opener.connectGate = Completer<void>();
      time.elapse(_firstDelay);
      time.flushMicrotasks();
      final replacement = h.opener.transports.last;
      final home = replacement.canonicalizeGate = Completer<void>();
      h.opener.connectGate = null;
      handshake.complete();
      time.flushMicrotasks();
      completeWithoutTimers(time, h.manager.disconnectServer('s1'));
      home.complete();
      time.flushMicrotasks();
      expect(replacement.closed, isFalse);
      expect(b.fs, isA<RemoteFileSystem>());
      completeWithoutTimers(time, b.close());
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('backoff resets after a successful recovery', () {
    fakeAsync((time) {
      final prober = FakeReconnectProber()..status = ProbeStatus.offline;
      final h = PoolHarness(prober: prober)..addServer('s1');
      final pane = browsePane(time, h, 'a');
      h.opener.transports.single.die();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 3));
      time.flushMicrotasks();
      expect(prober.calls, 2);
      prober.status = ProbeStatus.online;
      time.elapse(const Duration(seconds: 4));
      time.flushMicrotasks();
      h.opener.transports.last.die();
      time.flushMicrotasks();
      time.elapse(_firstDelay);
      time.flushMicrotasks();
      expect(prober.calls, 4);
      expect(h.opener.transports, hasLength(3));
      completeWithoutTimers(time, pane.close());
    });
  });

  for (final stop in _StopRecovery.values) {
    test('$stop dismisses an in-flight recovery credential prompt', () {
      fakeAsync((time) {
        final h = PoolHarness(
          opener: FakeTransportOpener(growthRequiresChallenge: true),
        )..addServer('s1');
        final pane = browsePane(time, h, 'a');
        h.opener.transports.single.die();
        time.flushMicrotasks();
        final gate = h.credentialGate = Completer<void>();
        time.elapse(const Duration(seconds: 3));
        time.flushMicrotasks();
        expect(h.credentialResolveCalls, 2);
        var dismissed = false;
        unawaited(
          h.resolutionScopes.last.dismissed.then((_) => dismissed = true),
        );
        completeWithoutTimers(time, switch (stop) {
          _StopRecovery.paneClose => pane.close(),
          _StopRecovery.disconnect => h.manager.disconnectServer('s1'),
        });
        expect(dismissed, isTrue);
        expect(time.pendingTimers, isEmpty);
        gate.complete();
        time.flushMicrotasks();
        expect(h.opener.calls, hasLength(2));
        expect(
          h.opener.transports.every((transport) => transport.closed),
          isTrue,
        );
      });
    });
  }

  test('a cancelled credential prompt stops automatic retries', () {
    fakeAsync((time) {
      final h = PoolHarness(
        opener: FakeTransportOpener(growthRequiresChallenge: true),
      )..addServer('s1');
      browsePane(time, h, 'a');
      h.credentialFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: 'credentials',
        message: 'Prompt cancelled.',
      );
      h.opener.transports.single.die();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 3));
      time.flushMicrotasks();
      expect(h.credentialResolveCalls, 2);
      expect(time.pendingTimers, isEmpty);
      completeWithoutTimers(time, h.manager.disconnectServer('s1'));
    });
  });

  test(
    'auth challenge re-resolves credentials and retains interactive cap',
    () {
      fakeAsync((time) {
        final opener = FakeTransportOpener(growthRequiresChallenge: true);
        final h = PoolHarness(opener: opener)..addServer('s1');
        final pane = browsePane(time, h, 'a');
        opener.transports.single.die();
        time.flushMicrotasks();
        time.elapse(_firstDelay);
        time.flushMicrotasks();
        expect(h.credentialResolveCalls, 1);
        opener.authKind = AuthKind.keyboardInteractive;
        time.elapse(const Duration(seconds: 2));
        time.flushMicrotasks();
        expect(h.credentialResolveCalls, 2);
        expect(opener.calls.last.prompting, ConnectPrompting.enabled);
        expect(opener.calls.last.onKeyboardInteractive, isNotNull);
        expect(pane.fs, isA<RemoteFileSystem>());
        final leases = [
          for (var i = 0; i < 4; i++)
            completeWithoutTimers(time, h.manager.leaseTransferChannel('s1')),
        ];
        final waiting = h.manager.leaseTransferChannel('s1');
        time.flushMicrotasks();
        expect(opener.calls, hasLength(3));
        completeWithoutTimers(time, leases.first.release());
        final last = completeWithoutTimers(time, waiting);
        for (final lease in [...leases.skip(1), last]) {
          completeWithoutTimers(time, lease.release());
        }
        completeWithoutTimers(time, pane.close());
      });
    },
  );
}
