import 'dart:async';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import '../connection/pool_fakes.dart';

/// Filesystem for the engine suite's channels: home resolution plus a
/// scripted listing. Anything else fails loudly.
class ScriptedFs implements RemoteFileSystem {
  List<RemoteFileEntry> listing = const [];
  Object? listFailure;
  int listCalls = 0;

  @override
  Future<String> canonicalize(String path) async => '/home/test';

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    listCalls++;
    final failure = listFailure;
    if (failure != null) throw failure;
    return listing;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'ScriptedFs only implements canonicalize and listDirectory, got '
    '${invocation.memberName}.',
  );
}

ServerConfig _config() => const ServerConfig(
  id: 'srv-1',
  label: 'Test',
  host: 'example.com',
  port: 2222,
  username: 'user',
  authMethod: AuthMethod.password,
  secretRef: 'secret-7',
  createdAt: 0,
  updatedAt: 0,
);

const _pinnedKey = HostKey(
  host: 'example.com',
  port: 2222,
  type: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:pinned',
  pinnedAt: 0,
);

/// An in-process [EngineHost] over the socket-free pool fakes: requests go
/// in through `handle`, responses and events come out of a real port.
class HostHarness {
  final FakeTransportOpener opener;
  final ScriptedFs fs = ScriptedFs();
  final prober = FakeReconnectProber();
  final _port = ReceivePort();
  final _pending = <int, Completer<EngineResult>>{};
  final events = <EngineEvent>[];
  late final EngineHost host;
  int _nextRequestId = 1;

  HostHarness({
    EngineConfig config = const EngineConfig(),
    FakeTransportOpener? opener,
  }) : opener = opener ?? FakeTransportOpener() {
    this.opener.transportFsBuilder = (_) => fs;
    _port.listen((message) {
      switch (message as EngineEvent) {
        case final ResponseEvent response:
          _pending.remove(response.requestId)?.complete(response.result);
        case _:
          events.add(message);
      }
    });
    host = EngineHost(
      config: config,
      events: _port.sendPort,
      openTransport: this.opener.opener,
      prober: prober,
    );
  }

  Future<EngineResult> call(EngineRequest Function(int id) build) {
    final request = build(_nextRequestId++);
    final completer = Completer<EngineResult>();
    _pending[request.requestId] = completer;
    host.handle(request);
    return completer.future;
  }

  Future<EngineResult> openBrowse() => call(
    (id) => OpenBrowseChannelRequest(
      requestId: id,
      serverId: 'srv-1',
      paneTabId: 'tab-1',
      config: _config(),
    ),
  );

  Future<EngineResult> list(int channelId, String path) => call(
    (id) =>
        ListDirectoryRequest(requestId: id, channelId: channelId, path: path),
  );

  void watch(String serverId) =>
      call((id) => WatchServerRequest(requestId: id, serverId: serverId));

  Future<EngineResult> disconnect(String serverId) =>
      call((id) => DisconnectServerRequest(requestId: id, serverId: serverId));

  void reply(EnginePromptEvent prompt, PromptReply answer) => call(
    (id) => PromptReplyRequest(
      requestId: id,
      promptId: prompt.promptId,
      kind: prompt.kind,
      reply: answer,
    ),
  );

  /// The common first-connect flow: resolve credentials from a reply, then
  /// approve the first-use host key. Fails with the engine's own error
  /// instead of a bare cast when the open resolves to a failure.
  Future<BrowseChannelOpened> openWithDefaults() async {
    final opened = openBrowse();
    await pumping();
    reply(
      takePrompt(),
      const CredentialPromptReply(
        password: 'pw',
        origin: CredentialOrigin.stored,
      ),
    );
    await pumping();
    reply(takePrompt(), const HostKeyPromptReply(accepted: true));
    final result = await opened;
    if (result is EngineError) {
      fail('openWithDefaults failed: ${result.message}');
    }
    return result as BrowseChannelOpened;
  }

  /// Pops the oldest unconsumed prompt event.
  EnginePromptEvent takePrompt() {
    final prompt = events.whereType<EnginePromptEvent>().firstOrNull;
    expect(prompt, isNotNull, reason: 'no prompt event was emitted');
    events.remove(prompt!);
    return prompt;
  }

  Future<void> pumping() => pumpEventQueue();

  /// Deterministic teardown: request shutdown (bounded engine-side), then
  /// close the port. Tests that leave recovery mid-flight stop reconnect
  /// work here instead of running past the test's end.
  void dispose() {
    try {
      host.handle(ShutdownRequest(requestId: _nextRequestId++));
    } on Object {
      // Only the non-protocol-message host throws; nothing to shut down.
    }
    _port.close();
  }
}

/// Awaits a result future and returns the wire error — the host answers
/// failures, it never raises them across the port.
Future<EngineError> expectError(Future<EngineResult> future) async {
  final result = await future;
  expect(result, isA<EngineError>(), reason: 'expected a failure result');
  return result as EngineError;
}

void main() {
  test('open browse channel round-trips credentials and host key', () async {
    final h = HostHarness();
    addTearDown(h.dispose);

    final opened = h.openBrowse();
    await h.pumping();

    // The vault-less engine always asks the UI for credentials first.
    final credential = h.takePrompt();
    expect(credential.kind, EnginePromptKind.credentialNeeded);
    final data = credential.data as CredentialPromptData;
    expect(data.host, 'example.com');
    expect(data.username, 'user');
    expect(data.secretRef, 'secret-7');

    h.reply(
      credential,
      const CredentialPromptReply(
        password: 'pw',
        origin: CredentialOrigin.stored,
      ),
    );
    await h.pumping();

    final hostKey = h.takePrompt();
    expect(hostKey.kind, EnginePromptKind.hostKeyFirstUse);
    h.reply(hostKey, const HostKeyPromptReply(accepted: true));
    await h.pumping();

    final channel = (await opened) as BrowseChannelOpened;
    expect(channel.homePath, '/home/test');
    expect(channel.channelId, 1);

    // The reply's secret reached the opener; the approval reached the pins.
    expect(h.opener.calls.single.credentials.password, 'pw');
    expect(
      h.events.whereType<HostKeyPinnedEvent>().single.key.fingerprintSha256,
      'SHA256:presented',
    );
  });

  test('declined first-use host key fails the open without pinning', () async {
    final h = HostHarness();
    addTearDown(h.dispose);

    final opened = h.openBrowse();
    await h.pumping();
    h.reply(
      h.takePrompt(),
      const CredentialPromptReply(
        password: 'pw',
        origin: CredentialOrigin.stored,
      ),
    );
    await h.pumping();
    h.reply(h.takePrompt(), const HostKeyPromptReply(accepted: false));
    await h.pumping();

    final error = await expectError(opened);
    expect(error.kind, RemoteFileErrorKind.other);
    expect(error.message, contains('not accepted'));
    expect(h.events.whereType<HostKeyPinnedEvent>(), isEmpty);
  });

  test('changed key prompts for review, blocks on decline', () async {
    final h = HostHarness(
      config: const EngineConfig(hostKeyPins: [_pinnedKey]),
      opener: FakeTransportOpener(
        presentedFingerprints: const ['SHA256:changed'],
      ),
    );
    addTearDown(h.dispose);
    h.watch('srv-1');
    await h.pumping();

    final opened = h.openBrowse();
    await h.pumping();
    h.reply(
      h.takePrompt(),
      const CredentialPromptReply(
        password: 'pw',
        origin: CredentialOrigin.stored,
      ),
    );
    await h.pumping();

    final review = h.takePrompt();
    expect(review.kind, EnginePromptKind.hostKeyChanged);
    final data = review.data as HostKeyPromptData;
    expect(data.fingerprintSha256, 'SHA256:changed');
    expect(data.pinnedFingerprintSha256, 'SHA256:pinned');
    h.reply(review, const HostKeyPromptReply(accepted: false));
    await h.pumping();

    final error = await expectError(opened);
    expect(error.message, contains('has changed'));
    expect(
      h.events.whereType<ServerStateEvent>().map((e) => e.state),
      containsAll([
        ServerConnectionState.disconnected,
        ServerConnectionState.connecting,
        ServerConnectionState.blocked,
      ]),
    );
    expect(h.events.whereType<HostKeyPinnedEvent>(), isEmpty);
  });

  test('changed key accepted on review re-pins and connects', () async {
    final h = HostHarness(
      config: const EngineConfig(hostKeyPins: [_pinnedKey]),
      opener: FakeTransportOpener(
        presentedFingerprints: const ['SHA256:changed'],
      ),
    );
    addTearDown(h.dispose);

    final opened = h.openBrowse();
    await h.pumping();
    h.reply(
      h.takePrompt(),
      const CredentialPromptReply(
        password: 'pw',
        origin: CredentialOrigin.stored,
      ),
    );
    await h.pumping();
    h.reply(h.takePrompt(), const HostKeyPromptReply(accepted: true));
    await h.pumping();

    expect(await opened, isA<BrowseChannelOpened>());
    expect(
      h.events.whereType<HostKeyPinnedEvent>().single.key.fingerprintSha256,
      'SHA256:changed',
    );
  });

  test('keyboard-interactive answers round-trip through the prompt', () async {
    final h = HostHarness();
    addTearDown(h.dispose);
    h.opener.connectGate = Completer<void>();

    final opened = h.openBrowse();
    await h.pumping();
    h.reply(
      h.takePrompt(),
      const CredentialPromptReply(
        password: 'pw',
        origin: CredentialOrigin.stored,
      ),
    );
    await h.pumping();
    h.reply(h.takePrompt(), const HostKeyPromptReply(accepted: true));
    await h.pumping();

    // The connect is parked; the server issues a 2FA challenge.
    final responder = h.opener.calls.single.onKeyboardInteractive!;
    final answers = responder(['Enter code'], '2FA', 'verify me');
    await h.pumping();

    final challenge = h.takePrompt();
    expect(challenge.kind, EnginePromptKind.keyboardInteractive);
    final data = challenge.data as KeyboardInteractivePromptData;
    expect(data.prompts, ['Enter code']);
    expect(data.instruction, 'verify me');

    h.reply(
      challenge,
      const KeyboardInteractivePromptReply(answers: ['123456']),
    );
    expect(await answers, ['123456']);

    h.opener.connectGate!.complete();
    expect(await opened, isA<BrowseChannelOpened>());
  });

  test('listDirectory returns the channel listing', () async {
    final h = HostHarness();
    addTearDown(h.dispose);
    h.fs.listing = const [
      RemoteFileEntry(path: '/tmp/a', name: 'a', type: RemoteFileType.file),
      RemoteFileEntry(
        path: '/tmp/b',
        name: 'b',
        type: RemoteFileType.directory,
      ),
    ];

    final channel = await h.openWithDefaults();

    final listed = await h.list(channel.channelId, '/tmp');
    final entries = (listed as DirectoryListed).entries;
    expect(entries.map((e) => e.name), ['a', 'b']);
    expect(h.fs.listCalls, 1);
  });

  test('listDirectory on an unknown channel fails disconnected', () async {
    final h = HostHarness();
    addTearDown(h.dispose);

    final error = await expectError(h.list(42, '/tmp'));
    expect(error.kind, RemoteFileErrorKind.disconnected);
    expect(h.fs.listCalls, 0);
  });

  test(
    'VFS failures serialize their kind and are reported for recovery',
    () async {
      final h = HostHarness();
      addTearDown(h.dispose);
      h.fs.listFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'list directory',
        message: 'The connection was lost.',
      );
      h.watch('srv-1');
      await h.pumping();

      final channel = await h.openWithDefaults();

      final error = await expectError(h.list(channel.channelId, '/tmp'));
      expect(error.kind, RemoteFileErrorKind.disconnected);
      expect(error.message, 'The connection was lost.');

      // The report reached the binding: recovery starts (03 §3.3). The
      // state fans out through the manager's async controllers — pump before
      // asserting on the port's delivery.
      await h.pumping();
      expect(
        h.events.whereType<ServerStateEvent>().map((e) => e.state),
        contains(ServerConnectionState.reconnecting),
      );
    },
  );

  test(
    'disconnect dismisses an open credential prompt across the boundary',
    () async {
      final h = HostHarness();
      addTearDown(h.dispose);

      final opened = h.openBrowse();
      await h.pumping();
      final prompt = h.takePrompt();
      expect(prompt.kind, EnginePromptKind.credentialNeeded);

      await h.disconnect('srv-1');
      await h.pumping();
      // The prompt was withdrawn: the UI dialog closes on this event.
      final dismissal = h.events.whereType<PromptDismissedEvent>().single;
      expect(dismissal.promptId, prompt.promptId);
      expect(dismissal.kind, EnginePromptKind.credentialNeeded);

      // The abandoned open fails; a late reply is ignored without effect.
      final error = await expectError(opened);
      expect(error.kind, RemoteFileErrorKind.disconnected);
      h.reply(
        prompt,
        const CredentialPromptReply(
          password: 'late',
          origin: CredentialOrigin.stored,
        ),
      );
      await h.pumping();
      expect(h.opener.calls, isEmpty);
    },
  );

  test('cancelled credential reply fails with kind cancelled', () async {
    final h = HostHarness();
    addTearDown(h.dispose);

    final opened = h.openBrowse();
    await h.pumping();
    h.reply(
      h.takePrompt(),
      const CredentialPromptReply(
        cancelled: true,
        origin: CredentialOrigin.stored,
      ),
    );
    await h.pumping();

    final error = await expectError(opened);
    expect(error.kind, RemoteFileErrorKind.cancelled);
    expect(h.opener.calls, isEmpty);
  });

  test('replies that cannot apply are ignored at debug level', () async {
    final h = HostHarness();
    addTearDown(h.dispose);

    final opened = h.openBrowse();
    await h.pumping();
    final prompt = h.takePrompt();

    // A kind-mismatched reply and one for an unknown promptId: neither may
    // take effect or kill the engine (03 §5) — the open stays parked.
    h.reply(prompt, const HostKeyPromptReply(accepted: true));
    await h.pumping();
    h.host.handle(
      const PromptReplyRequest(
        requestId: 999,
        promptId: 'nope',
        kind: EnginePromptKind.credentialNeeded,
        reply: CredentialPromptReply(
          password: 'x',
          origin: CredentialOrigin.stored,
        ),
      ),
    );
    await h.pumping();

    // Neither took effect: no connect started, the resolution is parked.
    expect(h.opener.calls, isEmpty);

    h.reply(
      prompt,
      const CredentialPromptReply(
        password: 'real',
        origin: CredentialOrigin.stored,
      ),
    );
    await h.pumping();
    // The ignored replies left the first-use host-key prompt pending.
    h.reply(h.takePrompt(), const HostKeyPromptReply(accepted: true));
    // A duplicate after the answer: dropped the same way.
    h.reply(
      prompt,
      const CredentialPromptReply(
        password: 'dupe',
        origin: CredentialOrigin.stored,
      ),
    );
    await h.pumping();

    final channel = await opened;
    expect(channel, isA<BrowseChannelOpened>());
    expect(h.opener.calls.single.credentials.password, 'real');
  });

  test('connectedServerIds lists live servers', () async {
    final h = HostHarness();
    addTearDown(h.dispose);

    Future<EngineResult> ids() =>
        h.call((id) => ConnectedServerIdsRequest(requestId: id));

    expect((await ids() as ServerIdsListed).ids, isEmpty);

    await h.openWithDefaults();
    expect((await ids() as ServerIdsListed).ids, ['srv-1']);
  });

  test('watch emits the current state first and follows transitions', () async {
    final h = HostHarness();
    addTearDown(h.dispose);

    h.watch('srv-1');
    await h.pumping();
    expect(
      h.events.whereType<ServerStateEvent>().single.state,
      ServerConnectionState.disconnected,
    );

    h.events.clear();
    await h.openWithDefaults();

    final states = h.events
        .whereType<ServerStateEvent>()
        .map((e) => e.state)
        .toList();
    expect(states.first, ServerConnectionState.connecting);
    expect(states.last, ServerConnectionState.connected);
  });

  test('shutdown dismisses open prompts and acks', () async {
    final h = HostHarness();
    addTearDown(h.dispose);

    final opened = h.openBrowse();
    await h.pumping();
    final prompt = h.takePrompt();

    final ack = h.call((id) => ShutdownRequest(requestId: id));
    await h.pumping();

    expect(await ack, isA<EngineAck>());
    expect(
      h.events.whereType<PromptDismissedEvent>().single.promptId,
      prompt.promptId,
    );
    final error = await expectError(opened);
    expect(error.kind, RemoteFileErrorKind.disconnected);
  });

  test('a non-protocol message kills the host loudly', () {
    final h = HostHarness();
    addTearDown(h.dispose);

    expect(() => h.host.handle('nonsense'), throwsStateError);
  });

  test('non-VFS failures keep their message across the wire', () async {
    final h = HostHarness();
    addTearDown(h.dispose);
    h.opener.connectFailure = StateError('socket exploded');

    final opened = h.openBrowse();
    await h.pumping();
    h.reply(
      h.takePrompt(),
      const CredentialPromptReply(
        password: 'pw',
        origin: CredentialOrigin.stored,
      ),
    );
    await h.pumping();
    h.reply(h.takePrompt(), const HostKeyPromptReply(accepted: true));
    await h.pumping();

    final error = await expectError(opened);
    expect(error.kind, RemoteFileErrorKind.other);
    expect(error.message, contains('socket exploded'));
  });
}
