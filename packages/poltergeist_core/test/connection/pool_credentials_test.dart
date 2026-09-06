import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _initialSecret = 'initial password';
const _replacementSecret = 'replacement password';
const _sshPort = 22;
const _growthPolicy = PoolPolicy(
  maxTransports: 2,
  maxChannelsPerTransport: 1,
  maxTransferChannelsPerTransport: 1,
);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Matcher get _disconnected => throwsA(
  isA<RemoteFileException>().having(
    (error) => error.kind,
    'kind',
    RemoteFileErrorKind.disconnected,
  ),
);

/// Observe vault access separately from transport calls and retained handles.
class _CredentialHarness {
  final opener = FakeTransportOpener(authKind: AuthKind.storedPassword);
  final store = FakeHostKeyStore();
  late final PooledConnectionManager manager;
  int resolutions = 0;
  String secret = _initialSecret;
  CredentialOrigin origin = CredentialOrigin.stored;
  Completer<void>? resolveGate;
  Object? resolveFailure;

  _CredentialHarness({PoolPolicy policy = const PoolPolicy()}) {
    manager = PooledConnectionManager(
      resolveServer: (serverId) async => ServerConfig(
        id: serverId,
        label: serverId,
        host: 'example.com',
        port: _sshPort,
        username: 'test',
        authMethod: AuthMethod.password,
        createdAt: 0,
        updatedAt: 0,
      ),
      resolveCredentials: (_, _) async {
        resolutions++;
        final resolved = ResolvedCredentials(
          credentials: SshCredentials.password(secret),
          origin: origin,
        );
        await resolveGate?.future;
        final failure = resolveFailure;
        if (failure != null) throw failure;
        return resolved;
      },
      tofu: TofuVerifier(store),
      onHostKey: (_) async => true,
      openTransport: opener.opener,
      policy: policy,
      prober: FakeReconnectProber(),
      reconnectRandom: FixedRandom(0),
    );
  }

  Future<void> close() async {
    await manager.disconnectServer('s1');
    await manager.disconnectServer('s2');
  }
}

void main() {
  late _CredentialHarness harness;

  setUp(() => harness = _CredentialHarness());
  tearDown(() => harness.close());

  test('concurrent bookmarks resolve credentials once per pool', () async {
    await Future.wait([
      harness.manager.openBrowseChannel('s1', paneTabId: 'a'),
      harness.manager.openBrowseChannel('s2', paneTabId: 'b'),
    ]);

    expect(harness.opener.calls, hasLength(1));
    expect(harness.resolutions, 1);
  });

  test('joining a connected pool does not resolve credentials again', () async {
    await harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    await harness.manager.openBrowseChannel('s2', paneTabId: 'b');

    expect(harness.resolutions, 1);
  });

  test('pane teardown makes the next connect resolve a fresh secret', () async {
    final pane = await harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    await pane.close();
    harness.secret = _replacementSecret;

    await harness.manager.openBrowseChannel('s1', paneTabId: 'b');

    expect(harness.resolutions, 2);
    expect(harness.opener.calls.last.credentials.password, _replacementSecret);
  });

  test('failed authentication makes a retry resolve a fresh secret', () async {
    final failure = StateError('authentication failed');
    harness.opener.connectFailure = failure;
    await expectLater(
      harness.manager.openBrowseChannel('s1', paneTabId: 'a'),
      throwsA(same(failure)),
    );
    harness.opener.connectFailure = null;
    harness.secret = _replacementSecret;

    await harness.manager.openBrowseChannel('s1', paneTabId: 'a');

    expect(harness.resolutions, 2);
    expect(harness.opener.calls.last.credentials.password, _replacementSecret);
  });

  test(
    'resolver-prompted passwords cap growth despite storedPassword auth',
    () async {
      harness = _CredentialHarness(policy: _growthPolicy)
        ..origin = CredentialOrigin.prompted;
      final first = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'a',
      );
      final second = await harness.manager.openBrowseChannel(
        's2',
        paneTabId: 'b',
      );

      expect(harness.opener.calls, hasLength(1));
      expect(second.fs, same(first.fs));
      expect(harness.resolutions, 1);
    },
  );

  test(
    'stored credentials survive sibling disconnect and serve growth',
    () async {
      harness = _CredentialHarness(
        policy: const PoolPolicy(
          maxTransports: 2,
          maxChannelsPerTransport: 2,
          maxTransferChannelsPerTransport: 1,
        ),
      );
      final first = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'a',
      );
      await harness.manager.openBrowseChannel('s2', paneTabId: 'b');
      await first.close();
      await harness.manager.disconnectServer('s1');
      harness.secret = _replacementSecret;
      await harness.manager.openBrowseChannel('s2', paneTabId: 'c');
      expect(harness.opener.calls, hasLength(1));
      await harness.manager.openBrowseChannel('s2', paneTabId: 'd');

      expect(harness.resolutions, 1);
      expect(harness.opener.calls, hasLength(2));
      expect(harness.opener.calls.last.prompting, ConnectPrompting.disabled);
      expect(
        harness.opener.calls.last.credentials,
        same(harness.opener.calls.first.credentials),
      );
    },
  );

  test('last transfer release makes the next connect resolve afresh', () async {
    final lease = await harness.manager.leaseTransferChannel('s1');
    await lease.release();
    harness.secret = _replacementSecret;
    await harness.manager.leaseTransferChannel('s1');

    expect(harness.resolutions, 2);
    expect(harness.opener.calls.last.credentials.password, _replacementSecret);
  });

  test(
    'fresh resolution prevents growth with an evicted transport secret',
    () {
      fakeAsync((time) {
        // Construct inside the fake zone so recovery owns no real timers.
        final h = _CredentialHarness();
        completeWithoutTimers(time,
            h.manager.openBrowseChannel('s1', paneTabId: 'keep'));
        final original = h.opener.transports.single;
        final firstGate = original.openGate = Completer<void>();
        final first = h.manager.openBrowseChannel('s1', paneTabId: 'a');
        first.ignore();
        time.flushMicrotasks();
        final secondGate = original.openGate = Completer<void>();
        final second = h.manager.openBrowseChannel('s1', paneTabId: 'b');
        second.ignore();
        time.flushMicrotasks();

        const disconnected = RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'open SFTP',
          message: 'Transport died during channel open.',
        );
        original.die();
        h.opener.connectFailure = const AuthChallengeRequiredError('Auth expired');
        firstGate.completeError(disconnected);
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 1));
        time.flushMicrotasks();
        final callsBeforeResolution = h.opener.calls.length;
        expect(callsBeforeResolution, 2);

        final resolveGate = h.resolveGate = Completer<void>();
        h.secret = _replacementSecret;
        h.opener.connectFailure = null;
        final fresh = h.manager.openBrowseChannel('s2', paneTabId: 'fresh');
        time.elapse(const Duration(seconds: 2));
        time.flushMicrotasks();
        expect(h.resolutions, 2);

        // A stale acquisition cannot borrow the rejected credential while
        // the recovery loop awaits its replacement from the vault.
        secondGate.completeError(disconnected);
        time.flushMicrotasks();
        final callsDuringResolution = h.opener.calls.length;
        resolveGate.complete();
        completeWithoutTimers(time, Future.wait([first, second, fresh]));
        expect(callsDuringResolution, callsBeforeResolution);
        expect(h.opener.calls.last.credentials.password, _replacementSecret);
        completeWithoutTimers(time, h.close());
      });
    },
  );

  test('failed credential resolution leaves the pool retryable', () async {
    final failure = StateError('vault locked');
    harness.resolveFailure = failure;
    final gate = harness.resolveGate = Completer<void>();
    final first = expectLater(
      harness.manager.openBrowseChannel('s1', paneTabId: 'a'),
      throwsA(same(failure)),
    );
    final second = expectLater(
      harness.manager.openBrowseChannel('s2', paneTabId: 'b'),
      throwsA(same(failure)),
    );
    await _flush();
    expect(harness.resolutions, 1);
    gate.complete();
    await Future.wait([first, second]);
    expect(harness.opener.calls, isEmpty);
    harness.resolveFailure = null;
    await harness.manager.openBrowseChannel('s1', paneTabId: 'a');

    expect(harness.resolutions, 2);
    expect(harness.opener.calls, hasLength(1));
  });

  test(
    'late credentials cannot open or replace a disconnected session',
    () async {
      final gate = harness.resolveGate = Completer<void>();
      final stale = harness.manager.openBrowseChannel('s1', paneTabId: 'old');
      final outcome = expectLater(stale, _disconnected);
      await _flush();
      expect(harness.resolutions, 1);
      await harness.manager.disconnectServer('s1');

      harness.resolveGate = null;
      harness.secret = _replacementSecret;
      final current = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'new',
      );
      gate.complete();
      await outcome;

      expect(harness.resolutions, 2);
      expect(harness.opener.calls, hasLength(1));
      expect(
        harness.opener.calls.single.credentials.password,
        _replacementSecret,
      );
      expect(
        harness.opener.transports.single.channels.single.fs,
        same(current.fs),
      );
      expect(await harness.manager.connectedServerIds(), {'s1'});
    },
  );

  test(
    'disconnecting the resolver owner preserves a waiting sibling',
    () async {
      final gate = harness.resolveGate = Completer<void>();
      final first = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
      final firstOutcome = expectLater(first, _disconnected);
      final second = harness.manager.openBrowseChannel('s2', paneTabId: 'b');
      await _flush();
      expect(harness.resolutions, 1);
      expect(harness.opener.calls, isEmpty);
      await harness.manager.disconnectServer('s1');
      gate.complete();
      await firstOutcome;
      await second;

      expect(harness.resolutions, 1);
      expect(harness.opener.calls, hasLength(1));
      expect(await harness.manager.connectedServerIds(), {'s2'});
    },
  );

  test('a prompted retry caps growth after authentication failed', () async {
    harness = _CredentialHarness(policy: _growthPolicy);
    final failure = StateError('password changed');
    harness.opener.connectFailure = failure;
    await expectLater(
      harness.manager.openBrowseChannel('s1', paneTabId: 'a'),
      throwsA(same(failure)),
    );
    harness.opener.connectFailure = null;
    harness.origin = CredentialOrigin.prompted;
    harness.secret = _replacementSecret;
    await harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    await harness.manager.openBrowseChannel('s2', paneTabId: 'b');

    expect(harness.resolutions, 2);
    expect(harness.opener.calls, hasLength(2));
    expect(harness.opener.calls.last.credentials.password, _replacementSecret);
  });

  test(
    'a fresh stored secret permits growth after prompted pool teardown',
    () async {
      harness = _CredentialHarness(policy: _growthPolicy)
        ..origin = CredentialOrigin.prompted;
      final first = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'a',
      );
      await first.close();
      harness.origin = CredentialOrigin.stored;
      harness.secret = _replacementSecret;
      await harness.manager.openBrowseChannel('s1', paneTabId: 'a');
      await harness.manager.openBrowseChannel('s2', paneTabId: 'b');

      expect(harness.resolutions, 2);
      expect(harness.opener.calls, hasLength(3));
      expect(harness.opener.calls.last.prompting, ConnectPrompting.disabled);
      expect(
        harness.opener.calls.last.credentials.password,
        _replacementSecret,
      );
    },
  );
}
