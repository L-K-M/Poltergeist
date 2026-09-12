import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

/// A port nothing listens on: connect attempts fail fast with ECONNREFUSED,
/// proving the full request → engine → production-opener → error → response
/// round trip without needing an sshd fixture (08 §5 owns those legs).
const _refusedPort = 1;
const _connectedServerId = 'srv-2';
const _removedServerId = 'srv-1';
const _streamClosureTimeout = Duration(seconds: 5);

/// A declined changed-key record, as the engine's incident store mirrors it
/// to the app for persistence (owner decision 2a).
const _incidentRecord = IncidentRecord(
  serverId: _removedServerId,
  host: 'example.com',
  port: 2222,
  username: 'user',
  presentedFingerprintSha256: 'SHA256:changed',
  pinnedFingerprintSha256: 'SHA256:pinned',
);

const _recoveryFailure = RecoveryFailedEvent(
  serverId: 'srv-1',
  paneTabId: 'tab-1',
  error: EngineError(
    kind: RemoteFileErrorKind.permissionDenied,
    operation: 'canonicalize',
    path: '.',
    message: 'Home access denied.',
  ),
);

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

  test('background recovery failures broadcast across real isolates', () async {
    final client = await EngineClient.spawnForTesting(
      const EngineConfig(),
      entrypoint: _diagnosticEngine,
    );
    addTearDown(client.shutdown);

    final first = <RecoveryFailedEvent>[];
    final second = <RecoveryFailedEvent>[];
    final firstSubscription = client.recoveryFailures.listen(first.add);
    final secondSubscription = client.recoveryFailures.listen(second.add);
    addTearDown(firstSubscription.cancel);
    addTearDown(secondSubscription.cancel);

    // The response follows the diagnostic on the same port, so awaiting it
    // drains forwarding without sleeps or a missing-event timeout.
    expect(await client.connectedServerIds(), {_connectedServerId});
    expect(first, hasLength(1));
    expect(second, hasLength(1));
    expect(second.single, same(first.single));

    final received = first.single;
    expect(received.serverId, _recoveryFailure.serverId);
    expect(received.paneTabId, _recoveryFailure.paneTabId);
    expect(received.error.kind, _recoveryFailure.error.kind);
    expect(received.error.operation, _recoveryFailure.error.operation);
    expect(received.error.path, _recoveryFailure.error.path);
    expect(received.error.message, _recoveryFailure.error.message);

    // Dispatching an unsolicited event must leave later requests serving.
    expect(await client.connectedServerIds(), {_connectedServerId});
    expect(first, hasLength(1));
    expect(second, hasLength(1));
  });

  test('watchServer emits the current state first', () async {
    final client = await EngineClient.spawn(const EngineConfig());
    addTearDown(client.shutdown);

    final state = await client
        .watchServer('srv-1')
        .first
        .then((status) => status.state);
    expect(state, ServerConnectionState.disconnected);
  });

  test('watchServer re-subscribes after the last listener drops', () async {
    final client = await EngineClient.spawn(const EngineConfig());
    addTearDown(client.shutdown);

    // `.first` cancels its subscription: the engine-side watch ends, and a
    // later subscription re-watches and again sees the current state.
    expect(
      await client.watchServer('srv-1').first.then((status) => status.state),
      ServerConnectionState.disconnected,
    );
    expect(
      await client.watchServer('srv-1').first.then((status) => status.state),
      ServerConnectionState.disconnected,
    );
  });

  test(
    'open fails through a real connect attempt after a prompt reply',
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
        const CredentialPromptReply(
          password: 'pw',
          origin: CredentialOrigin.prompted,
        ),
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
    },
  );

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
      const CredentialPromptReply(
        password: 'late',
        origin: CredentialOrigin.stored,
      ),
    );
    expect(await client.connectedServerIds(), isEmpty);
    await subscription.cancel();
  });

  test('shutdown terminates the client and fails later calls', () async {
    final client = await EngineClient.spawn(const EngineConfig());
    addTearDown(client.shutdown);
    expect(await client.connectedServerIds(), isEmpty);

    await client.shutdown();
    await expectLater(client.terminated, completes);

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

  test('shutdown closes the background recovery failure stream', () async {
    final client = await EngineClient.spawn(const EngineConfig());
    addTearDown(client.shutdown);

    final failures = client.recoveryFailures.toList();
    await client.shutdown();

    expect(await failures.timeout(_streamClosureTimeout), isEmpty);
  });

  test('incident changes broadcast and a removal closes its watch', () async {
    final client = await EngineClient.spawnForTesting(
      const EngineConfig(),
      entrypoint: _incidentEngine,
    );
    addTearDown(client.shutdown);

    final changes = <IncidentStoreEvent>[];
    final subscription = client.incidentChanges.listen(changes.add);
    addTearDown(subscription.cancel);
    final states = client.watchServer(_removedServerId).toList();

    // The mirror event rides the same port as the response, so awaiting the
    // response drains the forwarding without a sleep.
    expect(await client.connectedServerIds(), isEmpty);
    expect(changes, hasLength(1));
    expect(
      (changes.single as IncidentRecordStoredEvent).record,
      _incidentRecord,
    );

    await client.removeBookmark(_removedServerId);
    expect(changes, hasLength(2));
    final removed = changes.last as IncidentRecordRemovedEvent;
    expect(removed.serverId, _removedServerId);
    // A whole-bookmark delete carries no endpoint (owner decision 3a).
    expect(removed.endpoint, isNull);

    // The removed bookmark's watch completes, delivering the state the
    // engine sent before its ack.
    expect(await states.timeout(_streamClosureTimeout), [
      const ServerStatus(ServerConnectionState.disconnected),
      const ServerStatus(ServerConnectionState.disconnected),
    ]);

    // The engine keeps serving after a removal.
    expect(await client.connectedServerIds(), isEmpty);
    expect(changes, hasLength(2));
  });

  test('shutdown closes the incident change stream', () async {
    final client = await EngineClient.spawn(const EngineConfig());
    addTearDown(client.shutdown);

    final changes = client.incidentChanges.toList();
    await client.shutdown();

    expect(await changes.timeout(_streamClosureTimeout), isEmpty);
  });

  test('dead-engine surfaces: watch fails fast', () async {
    final client = await EngineClient.spawn(const EngineConfig());
    await client.shutdown();

    expect(
      () => client.watchServer('srv-1'),
      throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.disconnected,
        ),
      ),
    );
  });

  group('local browse channels', () {
    test(
      'openLocalChannel browses a local root across real isolates',
      () async {
        final client = await EngineClient.spawn(const EngineConfig());
        addTearDown(client.shutdown);

        final root = Directory.systemTemp.createTempSync('pg-engine-local');
        addTearDown(() => root.deleteSync(recursive: true));
        File('${root.path}/a.txt').writeAsStringSync('alpha');
        Directory('${root.path}/sub').createSync();

        final channel = await client.openLocalChannel(rootPath: root.path);
        expect(
          channel.homePath,
          await LocalFileSystem().canonicalize(root.path),
        );

        final entries = await channel.listDirectory(channel.homePath);
        final byName = {for (final entry in entries) entry.name: entry};
        expect(byName.keys, {'a.txt', 'sub'});
        expect(byName['a.txt']!.type, RemoteFileType.file);
        expect(byName['sub']!.type, RemoteFileType.directory);

        // A subdirectory navigation rides the same channel: no server, no
        // second open — the pane's ordinary navigation shape.
        expect(await channel.listDirectory('${channel.homePath}/sub'), isEmpty);
      },
    );

    test('local failures cross as the typed taxonomy', () async {
      final client = await EngineClient.spawn(const EngineConfig());
      addTearDown(client.shutdown);

      final missing =
          '${Directory.systemTemp.path}/pg-engine-no-such'
          '-${DateTime.now().microsecondsSinceEpoch}';
      final channel = await client.openLocalChannel(rootPath: missing);

      await expectLater(
        channel.listDirectory(channel.homePath),
        throwsA(
          isA<RemoteFileException>()
              .having(
                (error) => error.kind,
                'kind',
                RemoteFileErrorKind.notFound,
              )
              .having((error) => error.operation, 'operation', 'list')
              .having((error) => error.path, 'path', channel.homePath),
        ),
      );
    });

    test('closing a local channel is idempotent and retires it', () async {
      final client = await EngineClient.spawn(const EngineConfig());
      addTearDown(client.shutdown);

      final root = Directory.systemTemp.createTempSync('pg-engine-local-close');
      addTearDown(() => root.deleteSync(recursive: true));

      final channel = await client.openLocalChannel(rootPath: root.path);
      await channel.close();
      await channel.close();

      await expectLater(
        channel.listDirectory(channel.homePath),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.disconnected,
          ),
        ),
      );
    });
  });

  test('invalid policy kills the engine and surfaces termination', () async {
    final client = await EngineClient.spawn(
      const EngineConfig(
        policy: PoolPolicy(reconnectBackoffCap: Duration.zero),
      ),
    );
    addTearDown(client.shutdown);

    final failures = client.recoveryFailures.toList();

    // The engine died on its constructor guard; every call fails typed and
    // termination is observable (no silent zombie client).
    await expectLater(
      client.connectedServerIds(),
      throwsA(isA<RemoteFileException>()),
    );
    await expectLater(client.terminated, completes);
    expect(await failures.timeout(_streamClosureTimeout), isEmpty);

    // Shutdown on a dead engine must complete, not hang on an ack that can
    // never arrive (the ack-vs-termination race).
    await client.shutdown();
  });
}

/// Emits a diagnostic only after the client attaches its listeners, then
/// serves ordinary requests to prove the event did not terminate dispatch.
void _diagnosticEngine(SendPort events) {
  final requests = ReceivePort();
  events.send(requests.sendPort);
  RecoveryFailedEvent? pendingFailure = _recoveryFailure;
  requests.listen((message) {
    switch (message) {
      case EngineConfig():
        return;
      case final ConnectedServerIdsRequest request:
        if (pendingFailure != null) {
          events.send(pendingFailure);
          pendingFailure = null;
        }
        events.send(
          ResponseEvent(
            requestId: request.requestId,
            result: const ServerIdsListed(ids: [_connectedServerId]),
          ),
        );
      case final ShutdownRequest request:
        events.send(
          ResponseEvent(
            requestId: request.requestId,
            result: const EngineAck(),
          ),
        );
        requests.close();
      default:
        throw StateError('Unexpected diagnostic fixture request.');
    }
  });
}

/// Mirrors one stored record on the first query, then answers a removal
/// with the cascade's mirror event and the removed bookmark's last state —
/// the engine's ordering, so the client delivers both before it closes.
void _incidentEngine(SendPort events) {
  final requests = ReceivePort();
  events.send(requests.sendPort);
  var storedPending = true;
  requests.listen((message) {
    switch (message) {
      case EngineConfig():
        return;
      case final WatchServerRequest request:
        events.send(
          ServerStateEvent(
            serverId: request.serverId,
            state: ServerConnectionState.disconnected,
          ),
        );
      case UnwatchServerRequest():
        return;
      case final ConnectedServerIdsRequest request:
        if (storedPending) {
          storedPending = false;
          events.send(const IncidentRecordStoredEvent(record: _incidentRecord));
        }
        events.send(
          ResponseEvent(
            requestId: request.requestId,
            result: const ServerIdsListed(ids: []),
          ),
        );
      case final RemoveBookmarkRequest request:
        events.send(
          ServerStateEvent(
            serverId: request.serverId,
            state: ServerConnectionState.disconnected,
          ),
        );
        events.send(IncidentRecordRemovedEvent(serverId: request.serverId));
        events.send(
          ResponseEvent(
            requestId: request.requestId,
            result: const EngineAck(),
          ),
        );
      case final ShutdownRequest request:
        events.send(
          ResponseEvent(
            requestId: request.requestId,
            result: const EngineAck(),
          ),
        );
        requests.close();
      default:
        throw StateError('Unexpected incident fixture request.');
    }
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
