import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

/// The diagnostics surface of 03 §3.2/§3.3: `ServerStatus.detail` — the
/// one-liner that explains a non-live state — and the connect-attempt
/// transcript fan-out that feeds the UI's live connection log.
void main() {
  test('connect transcript lines use value equality', () {
    const first = ConnectLogLine(serverId: 's1', line: 'kex complete');
    final same = ConnectLogLine(serverId: 's1', line: 'kex complete');

    expect(first, same);
    expect(first.hashCode, same.hashCode);
    expect(first, isNot(ConnectLogLine(serverId: 's2', line: first.line)));
  });

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

  test('opaque connect errors use a sanitized status detail', () {
    fakeAsync((time) {
      final opener = FakeTransportOpener()
        ..connectFailure = StateError('internal marker');
      final h = PoolHarness(opener: opener)..addServer('s1');
      final statuses = <ServerStatus>[];
      final subscription = h.manager.watchServer('s1').listen(statuses.add);
      final outcome = expectLater(
        h.manager.openBrowseChannel('s1', paneTabId: 'a'),
        throwsA(isA<StateError>()),
      );

      time.flushMicrotasks();
      completeWithoutTimers(time, outcome);

      expect(statuses.last.detail, 'Connection failed.');
      expect(statuses.last.detail, isNot(contains('internal marker')));
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

  test('terminal recovery detail reaches a queued acquisition', () {
    fakeAsync((time) {
      final h = PoolHarness(
        opener: FakeTransportOpener(growthRequiresChallenge: true),
        policy: const PoolPolicy(
          maxTransports: 1,
          maxTransferChannelsPerTransport: 1,
          maxChannelsPerTransport: 1,
        ),
      )..addServer('s1');

      browsePane(time, h, 'a');
      Object? waitingError;
      unawaited(
        h.manager
            .leaseTransferChannel('s1')
            .then<void>(
              (_) => fail('The saturated acquisition must remain queued.'),
              onError: (Object error) => waitingError = error,
            ),
      );
      time.flushMicrotasks();
      expect(waitingError, isNull);

      h.opener.transports.single.die();
      h.credentialFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: 'credentials',
        message: 'The vault is locked.',
      );
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 3));
      time.flushMicrotasks();

      expect(
        waitingError,
        isA<RemoteFileException>().having(
          (error) => error.message,
          'message',
          'The vault is locked.',
        ),
      );
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
      expect(byServer.keys, unorderedEquals(['s1', 's2']));

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

  // Synthetic credential material only — never a real secret. The records
  // below replay the one dartssh2 trace shape that interpolates a
  // credential: `SSH_Message_Userauth_InfoResponse`'s
  // `'$runtimeType(responses: $responses)'`, where the responses list *is*
  // the password for hosts doing password auth over keyboard-interactive.
  // The live fan-out must carry what upstream's `SshConnectionLog.add`
  // stored (redacted), never its raw argument — and ordinary diagnostic
  // lines must keep flowing verbatim beside them.
  test('a live connect transcript never carries raw Userauth_InfoResponse '
      'credentials', () {
    fakeAsync((time) {
      final h = PoolHarness()..addServer('s1');

      final lines = <ConnectLogLine>[];
      final subscription = h.manager.connectLog.listen(lines.add);

      h.opener.connectGate = Completer<void>();
      final opening = h.manager.openBrowseChannel('s1', paneTabId: 'a');
      time.flushMicrotasks();

      final log = h.opener.calls.single.log;
      log.add('kex: curve25519-sha256');
      // Canonical shape, plus the two whole-record shapes a bracket-bounded
      // or line-bounded match would leak past (dartssh2 does not escape
      // list elements, so `]` inside the password and a trailing newline
      // from a password manager both print verbatim).
      log.add(
        'SSH_Message_Userauth_InfoResponse(responses: '
        '[synthetic-password-4f3a])',
      );
      log.add(
        'SSH_Message_Userauth_InfoResponse(responses: '
        '[synthetic-pas]sword-9b2c])',
      );
      log.add(
        'SSH_Message_Userauth_InfoResponse(responses: '
        '[synthetic-line1\nline2-tail-7d1e])',
      );
      log.add('auth: publickey');
      time.flushMicrotasks();

      h.opener.connectGate!.complete();
      completeWithoutTimers(time, opening);

      final received = lines.map((l) => l.line).toList();
      // Absence of the fixture secrets, not equality between two copies
      // that could both be raw.
      for (final secret in [
        'synthetic-password-4f3a',
        'synthetic-pas]sword-9b2c',
        'synthetic-line1\nline2-tail-7d1e',
      ]) {
        expect(received.join('\n'), isNot(contains(secret)));
      }
      // The recognized records keep their name and position, redacted.
      expect(
        received.where((l) => l.contains('Userauth_InfoResponse')),
        everyElement(contains('(responses: [redacted])')),
      );
      expect(
        received.where((l) => l.contains('Userauth_InfoResponse')),
        hasLength(3),
      );
      // Ordinary diagnostic lines still pass through verbatim.
      expect(received.first, 'kex: curve25519-sha256');
      expect(received.last, 'auth: publickey');

      // Upstream storage must be redacted by the same add() the fan-out
      // rides on — the transcript the failure view copies is this log.
      final stored = log.lines.join('\n');
      for (final secret in [
        'synthetic-password-4f3a',
        'synthetic-pas]sword-9b2c',
        'synthetic-line1\nline2-tail-7d1e',
      ]) {
        expect(stored, isNot(contains(secret)));
      }
      expect(stored, contains('(responses: [redacted])'));

      unawaited(subscription.cancel());
    });
  });

  test('a malformed named auth record is withheld whole (upstream '
      'fail-closed shape)', () {
    fakeAsync((time) {
      final h = PoolHarness()..addServer('s1');

      final lines = <ConnectLogLine>[];
      final subscription = h.manager.connectLog.listen(lines.add);

      h.opener.connectGate = Completer<void>();
      final opening = h.manager.openBrowseChannel('s1', paneTabId: 'a');
      time.flushMicrotasks();

      final log = h.opener.calls.single.log;
      // A record that names Userauth_InfoResponse but no longer matches the
      // responses shape: upstream replaces the whole record rather than
      // risk printing a drifted credential. The live stream must carry the
      // same withheld text, not the raw argument.
      log.add(
        'SSH_Message_Userauth_InfoResponse(payload: '
        '[synthetic-drifted-secret-51aa])',
      );
      time.flushMicrotasks();

      h.opener.connectGate!.complete();
      completeWithoutTimers(time, opening);

      expect(
        lines.map((l) => l.line).join('\n'),
        isNot(contains('synthetic-drifted-secret-51aa')),
      );
      expect(
        lines.single.line,
        contains('does not recognize the shape of this message'),
      );
      expect(
        log.lines.join('\n'),
        isNot(contains('synthetic-drifted-secret-51aa')),
      );

      unawaited(subscription.cancel());
    });
  });

  test('redaction does not disturb server-id fan-out', () {
    fakeAsync((time) {
      // Two serverIds over one shared endpoint pool: the redacted record
      // must reach both referencing watchers, and only them.
      final h = PoolHarness()
        ..addServer('s1')
        ..addServer('s2');

      final byServer = <String, List<String>>{};
      final subscription = h.manager.connectLog.listen(
        (line) => byServer.putIfAbsent(line.serverId, () => []).add(line.line),
      );

      h.opener.connectGate = Completer<void>();
      final opening = h.manager.openBrowseChannel('s1', paneTabId: 'a');
      final siblingOpening = h.manager.openBrowseChannel('s2', paneTabId: 'b');
      time.flushMicrotasks();

      final log = h.opener.calls.single.log;
      log.add('connecting to example.com:22');
      log.add(
        'SSH_Message_Userauth_InfoResponse(responses: '
        '[synthetic-fanout-secret-88c2])',
      );
      time.flushMicrotasks();

      h.opener.connectGate!.complete();
      completeWithoutTimers(time, opening);
      completeWithoutTimers(time, siblingOpening);

      expect(byServer.keys, unorderedEquals(['s1', 's2']));
      for (final received in byServer.values) {
        // Exactly the two appended lines per server — a duplicate delivery
        // to one serverId must fail, not just a missing one.
        expect(received, hasLength(2));
        expect(
          received.join('\n'),
          isNot(contains('synthetic-fanout-secret-88c2')),
        );
        expect(received.first, 'connecting to example.com:22');
        expect(received[1], contains('(responses: [redacted])'));
      }

      unawaited(subscription.cancel());
    });
  });

  test('forwarding keeps the newest line when the transcript bound trims', () {
    fakeAsync((time) {
      final h = PoolHarness()..addServer('s1');

      final lines = <ConnectLogLine>[];
      final subscription = h.manager.connectLog.listen(lines.add);

      h.opener.connectGate = Completer<void>();
      final opening = h.manager.openBrowseChannel('s1', paneTabId: 'a');
      time.flushMicrotasks();

      final log = h.opener.calls.single.log;
      // One past seance_core's 400-line bound: the stored transcript drops
      // its head, but every appended line — the newest one included — must
      // still fan out exactly once, so the live view never stalls behind
      // the trim.
      for (var i = 0; i < 401; i++) {
        log.add('trace line $i');
      }
      time.flushMicrotasks();

      h.opener.connectGate!.complete();
      completeWithoutTimers(time, opening);

      expect(lines, hasLength(401));
      expect(lines.last.line, 'trace line 400');
      // Storage, unlike the stream, is bounded by the upstream constant.
      expect(log.lines, hasLength(400));
      expect(log.lines.first, 'trace line 1');

      unawaited(subscription.cancel());
    });
  });
}
