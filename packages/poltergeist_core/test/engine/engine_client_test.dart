import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

/// A port nothing listens on: connect attempts fail fast with ECONNREFUSED,
/// proving the full request → engine → production-opener → error → response
/// round trip without needing an sshd fixture (08 §5 owns those legs).
const _refusedPort = 1;

ServerConfig _config({int port = _refusedPort}) => ServerConfig(
  id: 'srv-1',
  label: 'Refused',
  host: '127.0.0.1',
  port: port,
  username: 'user',
  authMethod: AuthMethod.password,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  test('spawn answers connection queries over real isolates', () async {
    final client = await EngineClient.spawn(const EngineConfig());
    addTearDown(client.shutdown);

    expect(await client.connectedServerIds(), isEmpty);
  });

  test('watchServer emits the current state first', () async {
    final client = await EngineClient.spawn(const EngineConfig());
    addTearDown(client.shutdown);

    final states = await client.watchServer('srv-1').first;
    expect(states, ServerConnectionState.disconnected);
  });

  test('watchServer re-subscribes after the last listener drops', () async {
    final client = await EngineClient.spawn(const EngineConfig());
    addTearDown(client.shutdown);

    // `.first` cancels its subscription: the engine-side watch ends, and a
    // later subscription re-watches and again sees the current state.
    expect(await client.watchServer('srv-1').first,
        ServerConnectionState.disconnected);
    expect(await client.watchServer('srv-1').first,
        ServerConnectionState.disconnected);
  });

  test('open fails through a real connect attempt after a prompt reply',
      () async {
    final client = await EngineClient.spawn(const EngineConfig());
    addTearDown(client.shutdown);

    final prompts = <EnginePromptEvent>[];
    final subscription = client.prompts.listen(prompts.add);

    final opened = client.openBrowseChannel(
      serverId: 'srv-1',
      paneTabId: 'tab-1',
      config: _config(),
    );

    final prompt = await _nextPrompt(client);
    expect(prompt.kind, EnginePromptKind.credentialNeeded);
    final data = prompt.data as CredentialPromptData;
    expect(data.host, '127.0.0.1');
    expect(data.port, _refusedPort);
    expect(data.username, 'user');

    client.replyPrompt(
      prompt.promptId,
      prompt.kind,
      const CredentialPromptReply(password: 'pw', origin: CredentialOrigin.prompted),
    );

    // The refused connect surfaces as a typed error with a real summary.
    await expectLater(
      opened,
      throwsA(
        isA<RemoteFileException>().having(
          (error) => error.message,
          'message',
          isNotEmpty,
        ),
      ),
    );
    await subscription.cancel();
    expect(prompts, isNotEmpty);
  });

  test('disconnect dismisses an open prompt across real isolates', () async {
    final client = await EngineClient.spawn(const EngineConfig());
    addTearDown(client.shutdown);

    final dismissals = <PromptDismissedEvent>[];
    final subscription = client.promptDismissals.listen(dismissals.add);

    final opened = client.openBrowseChannel(
      serverId: 'srv-1',
      paneTabId: 'tab-1',
      config: _config(),
    );
    final prompt = await _nextPrompt(client);

    // Attach the expectation before the disconnect: the failing response
    // can arrive while the disconnect ack is still being awaited.
    final openFails = expectLater(
      opened,
      throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.disconnected,
        ),
      ),
    );

    // Dropping the last reference trips the engine-side resolution scope,
    // which withdraws the prompt and fails the abandoned open.
    await client.disconnectServer('srv-1');
    await openFails;

    await pumpEventQueue();
    expect(dismissals, hasLength(1));
    expect(dismissals.single.promptId, prompt.promptId);
    expect(dismissals.single.kind, EnginePromptKind.credentialNeeded);

    // A late answer is ignored: the engine keeps serving.
    client.replyPrompt(
      prompt.promptId,
      prompt.kind,
      const CredentialPromptReply(password: 'late'),
    );
    expect(await client.connectedServerIds(), isEmpty);
    await subscription.cancel();
  });

  test('shutdown terminates the client and fails later calls', () async {
    final client = await EngineClient.spawn(const EngineConfig());
    expect(await client.connectedServerIds(), isEmpty);

    await client.shutdown();
    expect(client.terminated, completes);

    await expectLater(
      client.connectedServerIds(),
      throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.disconnected,
        ),
      ),
    );
  });

  test('invalid policy kills the engine and surfaces termination', () async {
    final client = await EngineClient.spawn(
      const EngineConfig(
        policy: PoolPolicy(reconnectBackoffCap: Duration.zero),
      ),
    );

    // The engine died on its constructor guard; every call fails typed and
    // termination is observable (no silent zombie client).
    await expectLater(
      client.connectedServerIds(),
      throwsA(isA<RemoteFileException>()),
    );
    await expectLater(client.terminated, completes);
  });
}

/// Awaits the next prompt event on a fresh broadcast subscription.
Future<EnginePromptEvent> _nextPrompt(EngineClient client) {
  final completer = Completer<EnginePromptEvent>();
  late final StreamSubscription<EnginePromptEvent> subscription;
  subscription = client.prompts.listen((event) {
    if (!completer.isCompleted) completer.complete(event);
    subscription.cancel();
  });
  return completer.future;
}
