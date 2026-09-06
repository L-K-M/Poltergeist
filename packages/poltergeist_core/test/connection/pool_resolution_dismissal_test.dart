import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _sshPort = 22;

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Matcher get _disconnected => throwsA(
      isA<RemoteFileException>().having(
        (error) => error.kind,
        'kind',
        RemoteFileErrorKind.disconnected,
      ),
    );

/// How a prompt-owning resolver models dismissal: the dialog's future
/// fails the resolution instead of waiting for an answer nobody will use.
class _PromptDismissed implements Exception {
  const _PromptDismissed();
}

/// A resolver whose every resolution parks behind a user-answerable
/// prompt, so a test can observe exactly when the pool dismisses it.
class _PromptHarness {
  final opener = FakeTransportOpener(authKind: AuthKind.storedPassword);
  final store = FakeHostKeyStore();
  late final PooledConnectionManager manager;

  /// One entry per resolution, in call order. `dismissedByPool` records
  /// every firing of the scope's dismissal, even for prompts that had
  /// already finished — the contract being pinned is "a finished
  /// resolution is never dismissed", not just "an unanswered one".
  final List<CredentialResolutionScope> scopes = [];
  final List<Completer<ResolvedCredentials>> prompts = [];
  final List<bool> dismissedByPool = [];
  final List<bool> answeredByUser = [];

  int get resolutions => scopes.length;

  _PromptHarness() {
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
      resolveCredentials: (config, scope) {
        final index = scopes.length;
        scopes.add(scope);
        final answer = Completer<ResolvedCredentials>();
        prompts.add(answer);
        dismissedByPool.add(false);
        answeredByUser.add(false);

        // A prompt owner: the dialog races its answer against dismissal.
        // The flag records the pool's trip even for an already-finished
        // prompt, so a spurious dismissal can never hide behind the
        // answer having completed first.
        scope.dismissed.then<void>((_) {
          dismissedByPool[index] = true;
          if (answer.isCompleted) return;
          answer.completeError(const _PromptDismissed());
        });
        return answer.future;
      },
      tofu: TofuVerifier(store),
      onHostKey: (_) async => true,
      openTransport: opener.opener,
    );
  }

  /// The user answers the newest prompt.
  void answer(String secret) {
    final prompt = prompts.last;
    if (prompt.isCompleted) {
      throw StateError(
        'answer() called on a prompt that already finished '
        '(dismissed or answered)',
      );
    }
    answeredByUser[answeredByUser.length - 1] = true;
    prompt.complete(ResolvedCredentials(
      credentials: SshCredentials.password(secret),
      origin: CredentialOrigin.prompted,
    ));
  }

  Future<void> close() async {
    await manager.disconnectServer('s1');
    await manager.disconnectServer('s2');
  }
}

void main() {
  late _PromptHarness harness;

  setUp(() => harness = _PromptHarness());
  tearDown(() => harness.close());

  test('abandoning the pool dismisses an in-flight resolution prompt', () async {
    final connect = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    final outcome = expectLater(connect, _disconnected);
    await _flush();
    expect(harness.resolutions, 1);

    await harness.manager.disconnectServer('s1');

    // The scope's contract: dismissal completes, the prompt dies without a
    // user answer, and the caller fails without that answer ever arriving.
    await harness.scopes.single.dismissed;
    expect(harness.dismissedByPool, [true]);
    expect(harness.answeredByUser, [false]);
    await outcome;
  });

  test('folded callers fail without waiting for the abandoned prompt', () async {
    final first = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    final second = harness.manager.openBrowseChannel('s1', paneTabId: 'b');
    final outcomes = Future.wait([
      expectLater(first, _disconnected),
      expectLater(second, _disconnected),
    ]);
    await _flush();
    expect(harness.resolutions, 1);

    await harness.manager.disconnectServer('s1');
    await outcomes;

    // One resolution, dismissed once — never a second prompt for callers
    // whose pool already ended.
    expect(harness.resolutions, 1);
    expect(harness.dismissedByPool, [true]);
    expect(harness.answeredByUser, [false]);
  });

  test('a sibling reference keeps the resolution prompt alive', () async {
    final stale = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    final staleOutcome = expectLater(stale, _disconnected);
    final live = harness.manager.openBrowseChannel('s2', paneTabId: 'b');
    await _flush();
    expect(harness.resolutions, 1);

    await harness.manager.disconnectServer('s1');
    await _flush();
    expect(harness.dismissedByPool, [false]);

    // The surviving sibling's session still wants the answer.
    harness.answer('secret');
    await live;
    await staleOutcome;

    // The resolution completed normally; even the final teardown (s2's
    // last disconnect, via close()) never trips its scope.
    await harness.manager.disconnectServer('s2');
    await _flush();
    expect(harness.dismissedByPool, [false]);
    expect(harness.answeredByUser, [true]);
  });

  test('a replacement session resolves afresh after dismissal', () async {
    final abandoned = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    final abandonedOutcome = expectLater(abandoned, _disconnected);
    await _flush();
    await harness.manager.disconnectServer('s1');
    await abandonedOutcome;
    expect(harness.resolutions, 1);

    // The replacement session runs its own resolution and does not wait
    // on the abandoned resolver future.
    final fresh = harness.manager.openBrowseChannel('s1', paneTabId: 'new');
    await _flush();
    expect(harness.resolutions, 2);
    harness.answer('fresh secret');
    await fresh;

    expect(harness.scopes.first, isNot(same(harness.scopes.last)));
    await harness.scopes.first.dismissed;
    expect(harness.dismissedByPool, [true, false]);
    expect(
      harness.opener.calls.single.credentials.password,
      'fresh secret',
    );
  });

  test('a failed resolution hands its retry a fresh scope', () async {
    final failed = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    final vaultFailure = StateError('vault locked');
    final failedOutcome = expectLater(failed, throwsA(same(vaultFailure)));
    await _flush();
    harness.prompts.single.completeError(vaultFailure);
    await failedOutcome;

    final retry = harness.manager.openBrowseChannel('s1', paneTabId: 'b');
    await _flush();
    expect(harness.resolutions, 2);
    harness.answer('retry secret');
    await retry;

    // References stayed alive through the failure, so nothing was
    // dismissed, and the retry's scope is a distinct, un-dismissed one.
    expect(harness.scopes.first, isNot(same(harness.scopes.last)));
    expect(harness.dismissedByPool, [false, false]);
    expect(harness.opener.calls.single.credentials.password, 'retry secret');
  });

  test('a completed resolution is never dismissed', () async {
    final connect = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
    await _flush();
    harness.answer('secret');
    await connect;

    await harness.manager.disconnectServer('s1');
    await _flush();

    expect(harness.dismissedByPool, [false]);
    expect(harness.answeredByUser, [true]);
  });

  test(
    'a resolution that finished is not dismissed mid-handshake',
    () async {
      final connectGate = harness.opener.connectGate = Completer<void>();
      final connect = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
      final outcome = expectLater(connect, _disconnected);
      await _flush();
      harness.answer('secret');
      await _flush();

      // The transport handshake is parked; the resolution completed before
      // it. Abandoning the pool here must not fire the finished scope.
      await harness.manager.disconnectServer('s1');
      connectGate.complete();
      await outcome;

      expect(harness.dismissedByPool, [false]);
      expect(harness.answeredByUser, [true]);
    },
  );

  test(
    'a dismissal racing the answer in the same turn is tolerated',
    () async {
      final connect = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
      final outcome = expectLater(connect, _disconnected);
      await _flush();

      // One synchronous turn: the answer completes the resolver future and
      // the disconnect's prefix runs before the pool's continuation
      // observes the answer — the documented window where dismissal may
      // still fire for a future that already completed. The guard (an
      // already-completed answer ignores the firing) must hold, and the
      // late result stays discarded.
      harness.answer('secret');
      await harness.manager.disconnectServer('s1');
      await outcome;

      expect(harness.answeredByUser, [true]);
      expect(harness.dismissedByPool, [true]);
    },
  );
}
