import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _freshCredentials = SshCredentials.privateKey('ROTATED TEST KEY');
const _oneChannelPerTransport = PoolPolicy(
  maxChannelsPerTransport: 1,
  maxTransferChannelsPerTransport: 1,
);

Matcher get _disconnected => throwsA(
  isA<RemoteFileException>().having(
    (error) => error.kind,
    'kind',
    RemoteFileErrorKind.disconnected,
  ),
);

void _rotateCredentials(PoolHarness harness, String serverId) {
  harness.credentials[serverId] = const ResolvedSshCredentials(
    origin: CredentialOrigin.stored,
    credentials: _freshCredentials,
  );
}

void main() {
  late PoolHarness harness;

  setUp(() {
    harness = PoolHarness()
      ..addServer('s1')
      ..addServer('s2');
  });
  tearDown(() async {
    await harness.manager.disconnectServer('s1');
    await harness.manager.disconnectServer('s2');
  });

  test(
    'pane teardown resolves fresh credentials on the next connect',
    () async {
      final pane = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'tab',
      );
      await pane.close();
      _rotateCredentials(harness, 's1');

      await harness.manager.openBrowseChannel('s1', paneTabId: 'next');

      expect(harness.opener.calls.last.credentials, same(_freshCredentials));
      expect(harness.credentialResolveCalls, 2);
    },
  );

  test('shared references cannot retain secrets past the last pane', () async {
    final first = await harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    final sibling = await harness.manager.openBrowseChannel(
      's2',
      paneTabId: 'b',
    );
    await first.close();
    await sibling.close();
    _rotateCredentials(harness, 's2');

    await harness.manager.openBrowseChannel('s2', paneTabId: 'next');

    expect(harness.opener.calls.last.credentials, same(_freshCredentials));
    expect(harness.credentialResolveCalls, 2);
  });

  test('failed authentication does not cache credentials for retry', () async {
    final failure = StateError('authentication rejected');
    harness.opener.connectFailure = failure;
    await expectLater(
      harness.manager.openBrowseChannel('s1', paneTabId: 'tab'),
      throwsA(same(failure)),
    );
    _rotateCredentials(harness, 's1');
    harness.opener.connectFailure = null;

    await harness.manager.openBrowseChannel('s1', paneTabId: 'tab');

    expect(harness.opener.calls.last.credentials, same(_freshCredentials));
    expect(harness.credentialResolveCalls, 2);
  });

  test('joining a live endpoint does not resolve another secret', () async {
    await harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    await harness.manager.openBrowseChannel('s2', paneTabId: 'b');

    expect(harness.credentialResolveCalls, 1);
    expect(harness.opener.calls, hasLength(1));
  });

  test('concurrent endpoint joins share credential resolution', () async {
    final gate = Completer<bool>();
    harness.onHostKey = (_) => gate.future;
    final first = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    final sibling = harness.manager.openBrowseChannel('s2', paneTabId: 'b');
    await Future<void>.delayed(Duration.zero);
    final resolutions = harness.credentialResolveCalls;
    gate.complete(true);
    await Future.wait([first, sibling]);

    expect(resolutions, 1);
    expect(harness.opener.calls, hasLength(1));
  });

  test('a prompted vault password caps a stored-password transport', () async {
    harness = PoolHarness(
      opener: FakeTransportOpener(authKind: AuthKind.storedPassword),
      policy: _oneChannelPerTransport,
    )..addServer('s1');
    harness.credentials['s1'] = const ResolvedSshCredentials(
      credentials: SshCredentials.password('PROMPTED TEST PASSWORD'),
      origin: CredentialOrigin.prompted,
    );

    final first = await harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    final next = await harness.manager.openBrowseChannel('s1', paneTabId: 'b');

    expect(harness.opener.calls, hasLength(1));
    expect(harness.credentialResolveCalls, 1);
    expect(next.fs, same(first.fs));
  });

  test(
    'a sibling can finish resolution after the initiating id disconnects',
    () async {
      final gate = Completer<ResolvedSshCredentials>();
      harness.onResolveCredentials = (_) => gate.future;
      final first = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
      final firstOutcome = expectLater(first, _disconnected);
      final sibling = harness.manager.openBrowseChannel('s2', paneTabId: 'b');
      await Future<void>.delayed(Duration.zero);
      await harness.manager.disconnectServer('s1');

      expect(harness.credentialResolveCalls, 1);
      expect(harness.opener.calls, isEmpty);
      gate.complete(harness.credentials['s1']);
      await firstOutcome;
      await sibling;

      expect(harness.opener.calls, hasLength(1));
      expect(await harness.manager.connectedServerIds(), {'s2'});
      expect(harness.openChannels, hasLength(1));
    },
  );

  test(
    'late credentials cannot open a transport after final disconnect',
    () async {
      final gate = Completer<ResolvedSshCredentials>();
      harness.onResolveCredentials = (_) => gate.future;
      final opening = harness.manager.openBrowseChannel('s1', paneTabId: 'tab');
      final outcome = expectLater(opening, _disconnected);
      await Future<void>.delayed(Duration.zero);
      await harness.manager.disconnectServer('s1');
      gate.complete(harness.credentials['s1']);
      await outcome;

      expect(harness.opener.calls, isEmpty);
      expect(await harness.manager.connectedServerIds(), isEmpty);
    },
  );

  test(
    'late credentials cannot replace a new session at the same endpoint',
    () async {
      final gate = Completer<ResolvedSshCredentials>();
      final staleCredentials = harness.credentials['s1']!;
      harness.onResolveCredentials = (_) => gate.future;
      final stale = harness.manager.openBrowseChannel('s1', paneTabId: 'old');
      final outcome = expectLater(stale, _disconnected);
      await Future<void>.delayed(Duration.zero);
      await harness.manager.disconnectServer('s1');

      harness.onResolveCredentials = null;
      _rotateCredentials(harness, 's1');
      final current = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'new',
      );
      gate.complete(staleCredentials);
      await outcome;

      expect(harness.credentialResolveCalls, 2);
      expect(harness.opener.calls.single.credentials, same(_freshCredentials));
      expect(harness.openChannels.single.fs, same(current.fs));
    },
  );

  test(
    'a failed vault resolution is shared and a later connect retries',
    () async {
      final gate = Completer<ResolvedSshCredentials>();
      final failure = StateError('vault unavailable');
      harness.onResolveCredentials = (_) => gate.future;
      final first = expectLater(
        harness.manager.openBrowseChannel('s1', paneTabId: 'a'),
        throwsA(same(failure)),
      );
      final sibling = expectLater(
        harness.manager.openBrowseChannel('s2', paneTabId: 'b'),
        throwsA(same(failure)),
      );
      await Future<void>.delayed(Duration.zero);
      gate.completeError(failure);
      await Future.wait([first, sibling]);
      expect(harness.credentialResolveCalls, 1);
      expect(harness.opener.calls, isEmpty);

      harness.onResolveCredentials = null;
      _rotateCredentials(harness, 's2');
      await harness.manager.openBrowseChannel('s2', paneTabId: 'retry');
      expect(harness.credentialResolveCalls, 2);
      expect(harness.opener.calls.single.credentials, same(_freshCredentials));
    },
  );

  test(
    'sibling growth reuses the first secret after its bookmark disconnects',
    () async {
      harness =
          PoolHarness(
              policy: const PoolPolicy(
                maxChannelsPerTransport: 2,
                maxTransferChannelsPerTransport: 1,
              ),
            )
            ..addServer('s1')
            ..addServer('s2');
      await harness.manager.openBrowseChannel('s1', paneTabId: 'a');
      await harness.manager.openBrowseChannel('s2', paneTabId: 'b');
      final original = harness.opener.calls.first.credentials;
      await harness.manager.disconnectServer('s1');
      _rotateCredentials(harness, 's2');
      final lease = await harness.manager.leaseTransferChannel('s2');
      await harness.manager.openBrowseChannel('s2', paneTabId: 'c');

      expect(harness.credentialResolveCalls, 1);
      expect(harness.opener.calls, hasLength(2));
      expect(harness.opener.calls.last.credentials, same(original));
      expect(harness.opener.calls.last.prompting, ConnectPrompting.disabled);
      await lease.release();
    },
  );
}
