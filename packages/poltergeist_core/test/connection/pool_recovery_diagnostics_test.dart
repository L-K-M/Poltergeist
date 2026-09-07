import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _firstDelay = Duration(seconds: 1);
const _denied = RemoteFileException(
  kind: RemoteFileErrorKind.permissionDenied,
  operation: 'canonicalize',
  path: '.',
  message: 'Home access denied.',
);

void main() {
  test('terminal background failure reaches every current pool reference', () {
    fakeAsync((time) {
      final h = PoolHarness()
        ..addServer('s1')
        ..addServer('s2');
      browsePane(time, h, 'a');
      browsePane(time, h, 'b', server: 's2');
      h.opener.connectFailure = _denied;
      h.opener.transports.single.die();
      time.flushMicrotasks();
      time.elapse(_firstDelay);

      expect(h.recoveryFailures.map((f) => f.serverId), ['s1', 's2']);
      for (final failure in h.recoveryFailures) {
        expect(failure.paneTabId, isNull);
        expect(failure.error, same(_denied));
      }
      expect(time.pendingTimers, isEmpty);
    });
  });

  test(
    'resolver failures report once and preserve the folded caller error',
    () {
      fakeAsync((time) {
        final h = PoolHarness(
          opener: FakeTransportOpener(growthRequiresChallenge: true),
        )..addServer('s1');
        browsePane(time, h, 'a');
        final original = h.credentialFailure = _OpaqueFailure();
        h.opener.transports.single.die();
        time.flushMicrotasks();
        final waiting = h.manager.openBrowseChannel('s1', paneTabId: 'b');
        final failed = expectLater(waiting, throwsA(same(original)));
        time.elapse(const Duration(seconds: 3));
        completeWithoutTimers(time, failed);

        final failure = h.recoveryFailures.single;
        expect(failure.error.kind, RemoteFileErrorKind.other);
        expect(failure.error.operation, 'reconnect');
        expect(failure.error.message, 'Connection recovery failed.');
        expect(failure.error.cause, isNull);
        expect(time.pendingTimers, isEmpty);
      });
    },
  );

  test('diagnostic observer cannot replace failure or prevent teardown', () {
    fakeAsync((time) {
      var calls = 0;
      final h =
          PoolHarness(
              onRecoveryFailure: (_, _, {paneTabId}) {
                calls++;
                throw StateError('observer failed');
              },
            )
            ..addServer('s1')
            ..addServer('s2');
      browsePane(time, h, 'a');
      browsePane(time, h, 'b', server: 's2');
      h.opener.connectFailure = _denied;
      h.opener.transports.single.die();
      time.flushMicrotasks();
      final failed = expectLater(
        h.manager.openBrowseChannel('s1', paneTabId: 'c'),
        throwsA(same(_denied)),
      );
      time.elapse(_firstDelay);
      completeWithoutTimers(time, failed);
      expect(calls, 2);
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('offline retries and successful recovery emit no failure', () {
    fakeAsync((time) {
      final prober = FakeReconnectProber()..status = ProbeStatus.offline;
      final h = PoolHarness(prober: prober)..addServer('s1');
      final pane = browsePane(time, h, 'a');
      h.opener.transports.single.die();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 3));
      expect(h.recoveryFailures, isEmpty);
      prober.status = ProbeStatus.online;
      time.elapse(const Duration(seconds: 4));
      expect(pane.fs, isA<RemoteFileSystem>());
      expect(h.recoveryFailures, isEmpty);
      completeWithoutTimers(time, pane.close());
    });
  });

  test(
    'disconnect and late resolver failure cannot diagnose a replacement',
    () {
      fakeAsync((time) {
        final h = PoolHarness(
          opener: FakeTransportOpener(growthRequiresChallenge: true),
        )..addServer('s1');
        browsePane(time, h, 'a');
        final gate = h.credentialGate = Completer<void>();
        h.opener.transports.single.die();
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 3));
        completeWithoutTimers(time, h.manager.disconnectServer('s1'));
        h.credentialGate = null;
        final replacement = browsePane(time, h, 'a');
        gate.completeError(_denied);
        time.flushMicrotasks();
        expect(h.recoveryFailures, isEmpty);
        expect(replacement.fs, isA<RemoteFileSystem>());
        completeWithoutTimers(time, replacement.close());
      });
    },
  );

  test(
    'terminal home failure names only its pane while a sibling recovers',
    () {
      fakeAsync((time) {
        final h = PoolHarness()..addServer('s1');
        final a = browsePane(time, h, 'a');
        final b = browsePane(time, h, 'b');
        final connect = h.opener.connectGate = Completer<void>();
        h.opener.transports.single.die();
        time.flushMicrotasks();
        time.elapse(_firstDelay);
        final replacement = h.opener.transports.last;
        final home = replacement.canonicalizeGate = Completer<void>();
        connect.complete();
        time.flushMicrotasks();
        replacement.canonicalizeGate = null;
        home.completeError(_denied);
        time.flushMicrotasks();

        expect(h.recoveryFailures.single.serverId, 's1');
        expect(h.recoveryFailures.single.paneTabId, 'a');
        expect(h.recoveryFailures.single.error, same(_denied));
        expect(() => a.fs, throwsA(same(_denied)));
        expect(b.fs, isA<RemoteFileSystem>());
        completeWithoutTimers(time, b.close());
      });
    },
  );

  test(
    'SFTP refusal reports before channel acquisition tears down recovery',
    () {
      fakeAsync((time) {
        final h = PoolHarness()..addServer('s1');
        browsePane(time, h, 'a');
        h.opener.transportOpenLimit = 0;
        h.opener.transports.single.die();
        time.flushMicrotasks();
        time.elapse(_firstDelay);

        expect(h.recoveryFailures.single.serverId, 's1');
        expect(h.recoveryFailures.single.paneTabId, isNull);
        expect(h.recoveryFailures.single.error.operation, 'open SFTP');
        expect(time.pendingTimers, isEmpty);
      });
    },
  );
}

/// Arbitrary resolver errors may contain secrets or even break formatting.
class _OpaqueFailure implements Exception {
  @override
  String toString() => throw StateError('Do not format resolver internals.');
}
