import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

/// The diagnostics surface of 03 §3.2/§3.3: `ServerStatus.detail` — the
/// one-liner that explains a non-live state — and the connect-attempt
/// transcript fan-out that feeds the UI's live connection log.
void main() {
  test('a failed first connect reports the summarized failure as detail', () {
    fakeAsync((time) {
      final opener = FakeTransportOpener()
        ..connectFailure = SshConnectException(
          'Host key not accepted for example.com:22.',
          StateError('host key rejected'),
          SshConnectionLog(),
        );
      final h = PoolHarness(opener: opener)..addServer('s1');

      final statuses = <ServerStatus>[];
      final subscription = h.manager
          .watchServer('s1')
          .listen((status) => statuses.add(status));
      final outcome = expectLater(
        h.manager.openBrowseChannel('s1', paneTabId: 'a'),
        throwsA(isA<SshConnectException>()),
      );
      time.flushMicrotasks();
      completeWithoutTimers(time, outcome);

      expect(statuses.map((s) => s.state).toList(), [
        ServerConnectionState.disconnected,
        ServerConnectionState.connecting,
        ServerConnectionState.disconnected,
      ]);
      expect(statuses.last.detail, 'Host key not accepted for example.com:22.');

      // The summary survives for a watcher that joins after the failure —
      // the transcript view of a failed pane needs it on rewatch too.
      ServerStatus? rewatched;
      final rewatchSubscription = h.manager
          .watchServer('s1')
          .listen((status) => rewatched = status);
      time.flushMicrotasks();
      expect(rewatched?.detail, 'Host key not accepted for example.com:22.');

      unawaited(rewatchSubscription.cancel());
      unawaited(subscription.cancel());
    });
  });

  test('terminal background recovery delivers its error when no acquisition '
      'awaits it', () {
    fakeAsync((time) {
      final h = PoolHarness(
        opener: FakeTransportOpener(growthRequiresChallenge: true),
      )..addServer('s1');

      final statuses = <ServerStatus>[];
      final subscription = h.manager
          .watchServer('s1')
          .listen((status) => statuses.add(status));

      // Connect, then lose the transport with a pane still bound: the
      // recovery loop runs in the background with no caller awaiting it.
      browsePane(time, h, 'a');
      h.opener.transports.single.die();

      // The cached-credential retry hits the auth challenge, recovery
      // flips to prompting, re-resolves — and the resolver fails hard.
      h.credentialFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: 'credentials',
        message: 'The vault is locked.',
      );
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 3));
      time.flushMicrotasks();

      expect(h.credentialResolveCalls, 2);
      expect(time.pendingTimers, isEmpty);
      expect(statuses.last.state, ServerConnectionState.disconnected);
      // The whole point of the diagnostics path: the terminal error is
      // delivered to watchers, not swallowed with the ignored cycle
      // future (docs/STATUS.md open item 5).
      expect(statuses.last.detail, 'The vault is locked.');

      unawaited(subscription.cancel());
    });
  });

  test('terminal recovery cancellation reports no detail', () {
    fakeAsync((time) {
      final h = PoolHarness(
        opener: FakeTransportOpener(growthRequiresChallenge: true),
      )..addServer('s1');

      final statuses = <ServerStatus>[];
      final subscription = h.manager
          .watchServer('s1')
          .listen((status) => statuses.add(status));

      browsePane(time, h, 'a');
      h.opener.transports.single.die();

      // A cancelled credential resolution is the user ending the attempt —
      // there is nothing to diagnose, so no detail is published.
      h.credentialFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: 'credentials',
        message: 'Prompt cancelled.',
      );
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 3));
      time.flushMicrotasks();

      expect(statuses.last.state, ServerConnectionState.disconnected);
      expect(statuses.last.detail, isNull);

      unawaited(subscription.cancel());
    });
  });

  test('a declined changed key reports the block reason as detail', () {
    fakeAsync((time) {
      // First connect pins `original`; the next connect presents `changed`.
      final opener = FakeTransportOpener(
        presentedFingerprints: const ['SHA256:original', 'SHA256:changed'],
      );
      final h = PoolHarness(opener: opener)..addServer('s1');

      final statuses = <ServerStatus>[];
      final subscription = h.manager
          .watchServer('s1')
          .listen((status) => statuses.add(status));

      final first = completeWithoutTimers(
        time,
        h.manager.openBrowseChannel('s1', paneTabId: 'a'),
      );
      expect(statuses.map((s) => s.state), [
        ServerConnectionState.disconnected,
        ServerConnectionState.connecting,
        ServerConnectionState.connected,
      ]);
      completeWithoutTimers(time, first.close());
      completeWithoutTimers(time, h.manager.disconnectServer('s1'));

      // The changed-key review is declined (D18: hard block, no auto-repin).
      h.onHostKey = (_) async => false;
      final outcome = expectLater(
        h.manager.openBrowseChannel('s1', paneTabId: 'b'),
        throwsA(isA<RemoteFileException>()),
      );
      time.flushMicrotasks();
      completeWithoutTimers(time, outcome);

      expect(statuses.last.state, ServerConnectionState.blocked);
      expect(statuses.last.detail, contains('has changed'));

      unawaited(subscription.cancel());
    });
  });

  test('transcript lines fan out to every referencing serverId', () {
    fakeAsync((time) {
      // Two serverIds over one shared endpoint pool (03 §3.5).
      final h = PoolHarness()
        ..addServer('s1')
        ..addServer('s2');

      final byServer = <String, List<String>>{};
      final subscription = h.manager.connectLog.listen(
        (line) => byServer.putIfAbsent(line.serverId, () => []).add(line.line),
      );

      h.opener.connectGate = Completer<void>();
      final opening = h.manager.openBrowseChannel('s1', paneTabId: 'a');
      final siblingOpening = expectLater(
        h.manager.openBrowseChannel('s2', paneTabId: 'b'),
        throwsA(isA<RemoteFileException>()),
      );
      time.flushMicrotasks();

      // The attempt runs while both serverIds reference the pool: both see
      // every line, in append order.
      final log = h.opener.calls.single.log;
      log.add('connecting to example.com:22');
      log.add('kex: curve25519-sha256');
      time.flushMicrotasks();

      // One reference gone mid-attempt: the next line reaches only the
      // survivor — fan-out is computed at append time.
      completeWithoutTimers(time, h.manager.disconnectServer('s2'));
      log.add('auth: publickey');
      time.flushMicrotasks();

      h.opener.connectGate!.complete();
      completeWithoutTimers(time, opening);
      completeWithoutTimers(time, siblingOpening);

      expect(byServer['s1'], [
        'connecting to example.com:22',
        'kex: curve25519-sha256',
        'auth: publickey',
      ]);
      expect(byServer['s2'], [
        'connecting to example.com:22',
        'kex: curve25519-sha256',
      ]);

      unawaited(subscription.cancel());
    });
  });

  test('a frozen attempt forwards nothing further', () {
    fakeAsync((time) {
      final h = PoolHarness()..addServer('s1');

      final lines = <ConnectLogLine>[];
      final subscription = h.manager.connectLog.listen(lines.add);

      h.opener.connectGate = Completer<void>();
      final opening = h.manager.openBrowseChannel('s1', paneTabId: 'a');
      time.flushMicrotasks();

      final log = h.opener.calls.single.log;
      log.add('before freeze');
      // A successful connect freezes the log (seance_core contract); late
      // writers must not reach the UI.
      log.freeze();
      log.add('after freeze');
      time.flushMicrotasks();

      h.opener.connectGate!.complete();
      completeWithoutTimers(time, opening);

      expect(lines.map((l) => l.line), ['before freeze']);

      unawaited(subscription.cancel());
    });
  });
}
