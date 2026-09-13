import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_core/src/engine/connect_log_coalescer.dart'
    show connectionLogFlushInterval;
import 'package:poltergeist_core/src/engine/local_directory_watcher.dart'
    show LocalDirectoryWatcher, LocalWatchBackend;
import 'package:test/test.dart';

import '../connection/pool_fakes.dart';

const _connectionLogPollTimeout = Duration(seconds: 1);

/// Mode-bit refusals (and symlink fixtures) need a POSIX host this process
/// cannot override as root — the fs suite's guard, applied to the local
/// channel fixtures that depend on it.
final bool _posixNonRoot =
    !Platform.isWindows &&
    int.tryParse(Process.runSync('id', ['-u']).stdout.toString().trim()) != 0;

/// A temp-dir fixture for local-pane channels: two files and a
/// subdirectory. Symlink tests create their own link. Deletion registers
/// as teardown.
Directory _localFixture(String name) {
  final root = Directory.systemTemp.createTempSync(name);
  addTearDown(() => root.deleteSync(recursive: true));
  File('${root.path}/a.txt').writeAsStringSync('alpha');
  File('${root.path}/b.txt').writeAsStringSync('beta');
  Directory('${root.path}/sub').createSync();
  return root;
}

/// The engine-side canonical form of [path], computed test-side for parity
/// (03 §2.2: realpath semantics, never an error for a missing path).
Future<String> _canonical(String path) => LocalFileSystem().canonicalize(path);

/// A scriptable watch backend for the watch seam tests: one broadcast
/// controller per watched path, cancel recording for release assertions.
class FakeWatchBackend implements LocalWatchBackend {
  final controllers = <String, StreamController<FileSystemEvent>>{};
  final cancelled = <String>[];

  @override
  Stream<FileSystemEvent> watch(String directory) {
    return (controllers[directory] ??=
            StreamController<FileSystemEvent>.broadcast(onCancel: () {
              cancelled.add(directory);
            }))
        .stream;
  }

  void emit(String directory, FileSystemEvent event) =>
      controllers[directory]?.add(event);
}

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

const _changedFingerprint = 'SHA256:changed';

/// A pin the seeded record never named — the endpoint's pin moved on.
const _otherPinnedKey = HostKey(
  host: 'example.com',
  port: 2222,
  type: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:other-pinned',
  pinnedAt: 0,
);

/// A declined changed-key record for [_config]'s endpoint, as the app's
/// persisted store would restore it (owner decision 2a).
const _incidentRecord = IncidentRecord(
  serverId: 'srv-1',
  host: 'example.com',
  port: 2222,
  username: 'user',
  presentedFingerprintSha256: _changedFingerprint,
  pinnedFingerprintSha256: 'SHA256:pinned',
);

const _credentials = CredentialPromptReply(
  password: 'pw',
  origin: CredentialOrigin.stored,
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
    LocalWatchBackend? localWatch,
    Duration? shutdownDrainTimeout,
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
      localWatch: localWatch,
      shutdownDrainTimeout: shutdownDrainTimeout,
    );
  }

  Future<EngineResult> call(EngineRequest Function(int id) build) {
    final request = build(_nextRequestId++);
    final completer = Completer<EngineResult>();
    _pending[request.requestId] = completer;
    try {
      host.handle(request);
    } on Object catch (error, stackTrace) {
      // Only a non-protocol message throws synchronously; surface it
      // instead of leaving the caller awaiting a completer forever.
      _pending.remove(request.requestId);
      completer.completeError(error, stackTrace);
    }
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

  /// Opens a local channel (03 §5's engine-side seam) and fails loudly on
  /// a wire error instead of returning a bare result.
  Future<BrowseChannelOpened> openLocal(String rootPath) async {
    final result = await call(
      (id) => OpenLocalBrowseChannelRequest(requestId: id, rootPath: rootPath),
    );
    if (result is BrowseChannelOpened) return result;
    fail('openLocal failed: ${(result as EngineError).message}');
  }

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
    return result is BrowseChannelOpened
        ? result
        : fail('openWithDefaults returned unexpected result: $result');
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

/// A watch backend that fails the test the moment the engine starts a
/// watch — for asserting validation happens before any backend is
/// touched.
class _NeverWatchBackend implements LocalWatchBackend {
  @override
  Stream<FileSystemEvent> watch(String directory) =>
      fail('backend must not start');
}

void main() {
  test('retargeted bookmark cannot borrow its old live pool status', () async {
    final h = HostHarness();
    addTearDown(h.dispose);
    await h.openWithDefaults();
    h.prober.status = ProbeStatus.offline;

    await h.call(
      (id) => SetProbeTargetsRequest(
        requestId: id,
        targets: [_config().copyWith(host: 'new.example.com')],
      ),
    );
    await h.call(
      (id) => SetProbeActivityRequest(
        requestId: id,
        activity: ProbeActivity.running,
      ),
    );
    await h.pumping();

    expect(h.prober.calls, 1);
    expect(h.events.whereType<ProbeStatusesEvent>().last.statuses, {
      'srv-1': ProbeStatus.offline,
    });
  });

  test(
    'probe service skips live pools and resumes probing after close',
    () async {
      final h = HostHarness();
      addTearDown(h.dispose);
      final channel = await h.openWithDefaults();
      h.prober.status = ProbeStatus.offline;

      await h.call(
        (id) => SetProbeTargetsRequest(requestId: id, targets: [_config()]),
      );
      await h.call(
        (id) => SetProbeActivityRequest(
          requestId: id,
          activity: ProbeActivity.running,
        ),
      );
      await h.pumping();

      expect(h.prober.calls, 0);
      expect(h.events.whereType<ProbeStatusesEvent>().last.statuses, {
        'srv-1': ProbeStatus.online,
      });

      await h.call(
        (id) => SetProbeActivityRequest(
          requestId: id,
          activity: ProbeActivity.paused,
        ),
      );
      await h.call(
        (id) => CloseBrowseChannelRequest(
          requestId: id,
          channelId: channel.channelId,
        ),
      );
      await h.call(
        (id) => SetProbeActivityRequest(
          requestId: id,
          activity: ProbeActivity.running,
        ),
      );
      await h.pumping();

      expect(h.prober.calls, 1);
      expect(h.events.whereType<ProbeStatusesEvent>().last.statuses, {
        'srv-1': ProbeStatus.offline,
      });
      expect(h.opener.calls, hasLength(1));
    },
  );

  test('shutdown discards pending probes and refuses later activity', () async {
    final h = HostHarness();
    addTearDown(h.dispose);
    final gate = h.prober.gate = Completer<void>();
    await h.call(
      (id) => SetProbeTargetsRequest(requestId: id, targets: [_config()]),
    );
    await h.call(
      (id) => SetProbeActivityRequest(
        requestId: id,
        activity: ProbeActivity.running,
      ),
    );
    await h.pumping();
    expect(h.prober.calls, 1);

    await h.call((id) => ShutdownRequest(requestId: id));
    final snapshots = h.events.whereType<ProbeStatusesEvent>().length;
    gate.complete();
    await h.pumping();
    expect(h.events.whereType<ProbeStatusesEvent>(), hasLength(snapshots));

    await expectError(
      h.call(
        (id) => SetProbeActivityRequest(
          requestId: id,
          activity: ProbeActivity.running,
        ),
      ),
    );
    await h.pumping();
    expect(h.prober.calls, 1);
  });

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

  test(
    'a failed connect forwards the failure detail and transcript batch',
    () async {
      final h = HostHarness();
      addTearDown(h.dispose);
      h.opener.connectFailure = SshConnectException(
        'Connection refused.',
        StateError('refused'),
        SshConnectionLog(),
      );

      h.watch('srv-1');
      await h.pumping();

      final opened = h.openBrowse();
      await h.pumping();

      // Transcript lines appended during the attempt reach the UI as a
      // coalesced batch (03 §5): the flush window is a real timer, so let
      // it fire.
      h.reply(
        h.takePrompt(),
        const CredentialPromptReply(
          password: 'pw',
          origin: CredentialOrigin.stored,
        ),
      );
      await h.pumping();
      // The opener runs after credentials resolve and parks on the
      // first-use host-key prompt — the attempt log exists by now.
      h.opener.calls.single.log.add('tcp connect example.com:2222');
      h.reply(h.takePrompt(), const HostKeyPromptReply(accepted: true));
      await h.pumping();
      final error = await expectError(opened);
      expect(error.message, 'Connection refused.');

      // The flush window is a real timer; poll instead of sleeping a fixed
      // multiple so a slow machine cannot flake the batch assertion.
      bool hasBatch() => h.events.whereType<ConnectionLogEvent>().any(
        (event) =>
            event.serverId == 'srv-1' &&
            event.lines.contains('tcp connect example.com:2222'),
      );
      final poll = Stopwatch()..start();
      while (!hasBatch() && poll.elapsed < _connectionLogPollTimeout) {
        await Future<void>.delayed(connectionLogFlushInterval ~/ 4);
      }
      expect(
        hasBatch(),
        isTrue,
        reason: 'The transcript batch did not arrive within the poll window.',
      );

      final states = h.events.whereType<ServerStateEvent>().toList();
      expect(states.last.state, ServerConnectionState.disconnected);
      expect(states.last.detail, 'Connection refused.');
      expect(states.last.serverId, 'srv-1');

      final batches = h.events
          .whereType<ConnectionLogEvent>()
          .where((e) => e.serverId == 'srv-1')
          .toList();
      expect(batches, isNotEmpty);
      expect(
        batches.expand((batch) => batch.lines),
        contains('tcp connect example.com:2222'),
      );
    },
  );

  // ── The incident bridge (03 §5): the engine owns the live records, the
  // app owns their persistence, and every mutation crosses as a typed
  // event. Pins and incidents seed from the same app-owned config, so a
  // restored block always keeps both of D18's escapes (audit finding A).

  test('a declined changed key mirrors its record to the app', () async {
    final h = HostHarness(
      config: const EngineConfig(hostKeyPins: [_pinnedKey]),
      opener: FakeTransportOpener(
        presentedFingerprints: const [_changedFingerprint],
      ),
    );
    addTearDown(h.dispose);

    final opened = h.openBrowse();
    await h.pumping();
    h.reply(h.takePrompt(), _credentials);
    await h.pumping();
    h.reply(h.takePrompt(), const HostKeyPromptReply(accepted: false));
    await expectError(opened);
    await h.pumping();

    final stored = h.events.whereType<IncidentRecordStoredEvent>().single;
    expect(stored.record, _incidentRecord);
    expect(h.events.whereType<IncidentRecordRemovedEvent>(), isEmpty);
  });

  test('seeded incidents and pins restore a liftable block', () async {
    final h = HostHarness(
      config: const EngineConfig(
        hostKeyPins: [_pinnedKey],
        incidents: [_incidentRecord],
      ),
      opener: FakeTransportOpener(
        presentedFingerprints: const ['SHA256:pinned'],
      ),
    );
    addTearDown(h.dispose);
    h.watch('srv-1');
    await h.pumping();

    final opened = h.openBrowse();
    await h.pumping();
    h.reply(h.takePrompt(), _credentials);
    expect(await opened, isA<BrowseChannelOpened>());
    await h.pumping();

    // Owner decision 1a across a restart: the pinned key needs no prompt,
    // so nothing but the credential prompt was emitted.
    expect(h.events.whereType<EnginePromptEvent>(), isEmpty);
    expect(h.events.whereType<HostKeyPinnedEvent>(), isEmpty);
    expect(
      h.events.whereType<ServerStateEvent>().map((event) => event.state),
      containsAllInOrder([
        ServerConnectionState.blocked,
        ServerConnectionState.connected,
      ]),
    );

    // The lift deletes the restored record and mirrors the delete, scoped
    // to the endpoint it blocked.
    final removed = h.events.whereType<IncidentRecordRemovedEvent>().single;
    expect(removed.serverId, 'srv-1');
    expect(removed.endpoint, _incidentRecord.poolKey);
    expect(h.events.whereType<IncidentRecordStoredEvent>(), isEmpty);
  });

  test('an approved changed key mirrors the record deletion', () async {
    final h = HostHarness(
      config: const EngineConfig(
        hostKeyPins: [_pinnedKey],
        incidents: [_incidentRecord],
      ),
      opener: FakeTransportOpener(
        presentedFingerprints: const [_changedFingerprint],
      ),
    );
    addTearDown(h.dispose);

    final opened = h.openBrowse();
    await h.pumping();
    h.reply(h.takePrompt(), _credentials);
    await h.pumping();
    final review = h.takePrompt();
    expect(review.kind, EnginePromptKind.hostKeyChanged);
    h.reply(review, const HostKeyPromptReply(accepted: true));
    expect(await opened, isA<BrowseChannelOpened>());
    await h.pumping();

    // Explicit review: the re-pin crosses as a pin event and the record it
    // supersedes crosses as an endpoint-scoped delete. The review attempt
    // re-detects the change first, so the mirror also sees the re-write that
    // the approval then deletes — one stored event, one removal.
    expect(
      h.events.whereType<HostKeyPinnedEvent>().single.key.fingerprintSha256,
      _changedFingerprint,
    );
    final stored = h.events.whereType<IncidentRecordStoredEvent>().single;
    expect(stored.record.presentedFingerprintSha256, _changedFingerprint);
    final removed = h.events.whereType<IncidentRecordRemovedEvent>().single;
    expect(removed.serverId, 'srv-1');
    expect(removed.endpoint, _incidentRecord.poolKey);
  });

  test('a seeded incident without its pin is skipped, not deleted', () async {
    final h = HostHarness(
      config: const EngineConfig(incidents: [_incidentRecord]),
      opener: FakeTransportOpener(
        presentedFingerprints: const [_changedFingerprint],
      ),
    );
    addTearDown(h.dispose);
    h.watch('srv-1');
    await h.pumping();

    final opened = h.openBrowse();
    await h.pumping();
    h.reply(h.takePrompt(), _credentials);
    await h.pumping();

    // Audit finding A: with the pin half gone the restored block could
    // never be reviewed or lifted, so the load skips the record and the
    // endpoint re-detects — here as a first use, which a blocked pool would
    // have refused to prompt for. Nothing is mirrored: "no pin" is also what
    // an app pin store that failed to load reads as, so the app keeps the
    // record and the block returns if the pin does.
    final review = h.takePrompt();
    expect(review.kind, EnginePromptKind.hostKeyFirstUse);
    h.reply(review, const HostKeyPromptReply(accepted: true));
    expect(await opened, isA<BrowseChannelOpened>());
    await h.pumping();

    expect(
      h.events.whereType<ServerStateEvent>().map((event) => event.state),
      isNot(contains(ServerConnectionState.blocked)),
    );
    expect(h.events.whereType<IncidentRecordRemovedEvent>(), isEmpty);
    expect(h.events.whereType<IncidentRecordStoredEvent>(), isEmpty);
  });

  test('a contradicted seeded incident is deleted and mirrored', () async {
    final h = HostHarness(
      config: const EngineConfig(
        hostKeyPins: [_otherPinnedKey],
        incidents: [_incidentRecord],
      ),
      opener: FakeTransportOpener(
        presentedFingerprints: const ['SHA256:other-pinned'],
      ),
    );
    addTearDown(h.dispose);

    final opened = h.openBrowse();
    await h.pumping();
    h.reply(h.takePrompt(), _credentials);
    expect(await opened, isA<BrowseChannelOpened>());
    await h.pumping();

    // The endpoint IS pinned, just to a key this record never named: the
    // store definitively answered, so the stale record is deleted and the
    // app's store converges. The trusted connect installs no new one.
    final removed = h.events.whereType<IncidentRecordRemovedEvent>().single;
    expect(removed.serverId, 'srv-1');
    expect(removed.endpoint, _incidentRecord.poolKey);
    expect(h.events.whereType<IncidentRecordStoredEvent>(), isEmpty);
    expect(h.events.whereType<HostKeyPinnedEvent>(), isEmpty);
    expect(h.events.whereType<EnginePromptEvent>(), isEmpty);
  });

  test('removeBookmark mirrors the cascade delete', () async {
    final h = HostHarness(
      config: const EngineConfig(
        hostKeyPins: [_pinnedKey],
        incidents: [_incidentRecord],
      ),
    );
    addTearDown(h.dispose);
    h.watch('srv-1');
    await h.pumping();

    // No connect: the bookmark is deleted while its restored block stands.
    expect(
      await h.call(
        (id) => RemoveBookmarkRequest(requestId: id, serverId: 'srv-1'),
      ),
      isA<EngineAck>(),
    );
    await h.pumping();

    // Owner decision 3a: every record for the bookmark goes, so the delete
    // carries no endpoint. The host also forgets the id's config and watch
    // (audit finding C); both are private state, so the ack and the mirror
    // event are what a caller can observe.
    final removed = h.events.whereType<IncidentRecordRemovedEvent>().single;
    expect(removed.serverId, 'srv-1');
    expect(removed.endpoint, isNull);
    expect(h.events.whereType<IncidentRecordStoredEvent>(), isEmpty);
    expect(h.opener.calls, isEmpty);

    // An id the engine never saw is a clean no-op ack. The bridge mirrors
    // the command, not its effect, so the app also sees a delete for an id
    // holding no records — idempotent on its store, and never scoped to an
    // endpoint it does not own.
    expect(
      await h.call(
        (id) => RemoveBookmarkRequest(requestId: id, serverId: 'srv-9'),
      ),
      isA<EngineAck>(),
    );
    await h.pumping();
    expect(
      h.events.whereType<IncidentRecordRemovedEvent>().map(
        (event) => (event.serverId, event.endpoint),
      ),
      [('srv-1', null), ('srv-9', null)],
    );
  });

  group('local browse channels', () {
    test('open canonicalizes the root and serves its listing', () async {
      final h = HostHarness();
      addTearDown(h.dispose);
      final root = _localFixture('pg-local-pane');

      final opened = await h.openLocal(root.path);
      expect(opened.homePath, await _canonical(root.path));

      final listed = await h.list(opened.channelId, opened.homePath);
      final byName = {
        for (final entry in (listed as DirectoryListed).entries)
          entry.name: entry,
      };
      expect(byName.keys, {'a.txt', 'b.txt', 'sub'});
      expect(byName['a.txt']!.type, RemoteFileType.file);
      expect(byName['a.txt']!.size, 5);
      expect(byName['b.txt']!.size, 4);
      expect(byName['sub']!.type, RemoteFileType.directory);
    });

    test('symlinks report as links without target metadata', () async {
      final h = HostHarness();
      addTearDown(h.dispose);
      final root = _localFixture('pg-local-pane-link');
      Link('${root.path}/to-a').createSync('${root.path}/a.txt');

      final opened = await h.openLocal(root.path);
      final listed = await h.list(opened.channelId, opened.homePath);
      final link = (listed as DirectoryListed).entries.singleWhere(
        (entry) => entry.name == 'to-a',
      );

      expect(link.type, RemoteFileType.symbolicLink);
      expect(link.size, isNull);
      expect(link.modifiedAt, isNull);
    }, skip: Platform.isWindows ? 'fixture needs POSIX symlinks' : false);

    test(
      'a missing root opens but its first listing answers notFound',
      () async {
        final h = HostHarness();
        addTearDown(h.dispose);
        final missing =
            '${Directory.systemTemp.path}/pg-no-such-root'
            '-${DateTime.now().microsecondsSinceEpoch}';

        // 03 §2.2: canonicalize never fails for a missing path, so the open
        // succeeds and the navigation surfaces the typed notFound taxonomy.
        final opened = await h.openLocal(missing);
        expect(opened.homePath, await _canonical(missing));

        final error = await expectError(
          h.list(opened.channelId, opened.homePath),
        );
        expect(error.kind, RemoteFileErrorKind.notFound);
        expect(error.operation, 'list');
        expect(error.path, opened.homePath);
        expect(error.message, contains('Could not list'));
      },
    );

    test(
      'an unreadable directory answers permissionDenied',
      () async {
        final h = HostHarness();
        addTearDown(h.dispose);
        final root = _localFixture('pg-local-pane-denied');
        Directory('${root.path}/vault').createSync();
        // Restore before the fixture teardown deletes the tree (teardowns
        // run LIFO, so this registered-later chmod runs first).
        addTearDown(() {
          final restore = Process.runSync('chmod', [
            '755',
            '${root.path}/vault',
          ]);
          expect(restore.exitCode, 0, reason: 'fixture chmod restore failed');
        });
        final chmod = Process.runSync('chmod', ['000', '${root.path}/vault']);
        expect(chmod.exitCode, 0, reason: 'fixture chmod failed');

        final opened = await h.openLocal(root.path);
        final error = await expectError(
          h.list(opened.channelId, '${opened.homePath}/vault'),
        );
        expect(error.kind, RemoteFileErrorKind.permissionDenied);
        expect(error.operation, 'list');
      },
      skip: _posixNonRoot
          ? false
          : 'mode-bit refusal needs a POSIX host with a non-root user',
    );

    test(
      'close is idempotent and later listings answer disconnected',
      () async {
        final h = HostHarness();
        addTearDown(h.dispose);
        final root = _localFixture('pg-local-pane-close');

        final opened = await h.openLocal(root.path);
        expect(
          await h.call(
            (id) => CloseBrowseChannelRequest(
              requestId: id,
              channelId: opened.channelId,
            ),
          ),
          isA<EngineAck>(),
        );
        // Idempotent: the second close of a retired channel still acks.
        expect(
          await h.call(
            (id) => CloseBrowseChannelRequest(
              requestId: id,
              channelId: opened.channelId,
            ),
          ),
          isA<EngineAck>(),
        );

        final error = await expectError(h.list(opened.channelId, root.path));
        expect(error.kind, RemoteFileErrorKind.disconnected);
        expect(error.message, 'The browse channel is closed.');
      },
    );

    test('local and pool channels share one id space', () async {
      final h = HostHarness();
      addTearDown(h.dispose);
      h.fs.listing = const [
        RemoteFileEntry(
          path: '/home/test/remote.txt',
          name: 'remote.txt',
          type: RemoteFileType.file,
        ),
      ];
      final root = _localFixture('pg-local-pane-mixed');

      final poolChannel = await h.openWithDefaults();
      final localChannel = await h.openLocal(root.path);
      expect(localChannel.channelId, isNot(poolChannel.channelId));

      final remoteListed = await h.list(poolChannel.channelId, '/home/test');
      expect(
        (remoteListed as DirectoryListed).entries.single.name,
        'remote.txt',
      );

      // Closing the local channel leaves the pool binding untouched.
      await h.call(
        (id) => CloseBrowseChannelRequest(
          requestId: id,
          channelId: localChannel.channelId,
        ),
      );
      final retiredError = await expectError(
        h.list(localChannel.channelId, root.path),
      );
      expect(retiredError.kind, RemoteFileErrorKind.disconnected);
      expect(
        await h.list(poolChannel.channelId, '/home/test'),
        isA<DirectoryListed>(),
      );
    });

    test('`~` expands through the engine environment', () async {
      final h = HostHarness();
      addTearDown(h.dispose);

      final opened = await h.openLocal('~');
      expect(opened.homePath, await _canonical('~'));

      // With a resolvable home the expansion is real, not a pass-through.
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home != null && home.isNotEmpty) {
        expect(opened.homePath, isNot(contains('~')));
      }
    });

    test('shutdown retires local channels', () async {
      final h = HostHarness();
      addTearDown(h.dispose);
      final root = _localFixture('pg-local-pane-shutdown');

      final opened = await h.openLocal(root.path);
      await h.call((id) => ShutdownRequest(requestId: id));

      final error = await expectError(h.list(opened.channelId, root.path));
      expect(error.kind, RemoteFileErrorKind.disconnected);
      expect(error.message, 'The browse channel is closed.');
    });

    test(
      'a root under an unreadable ancestor fails the open typed',
      () async {
        final h = HostHarness();
        addTearDown(h.dispose);
        final parent = Directory.systemTemp.createTempSync(
          'pg-local-pane-blind',
        );
        addTearDown(() {
          final restore = Process.runSync('chmod', ['755', parent.path]);
          expect(restore.exitCode, 0, reason: 'fixture chmod restore failed');
          parent.deleteSync(recursive: true);
        });
        final chmod = Process.runSync('chmod', ['000', parent.path]);
        expect(chmod.exitCode, 0, reason: 'fixture chmod failed');

        // realpath semantics: an unreadable ancestor cannot be traversed,
        // so the open itself fails — typed through the funnel, unlike a
        // missing root which opens and answers notFound at first listing.
        final error = await expectError(
          h.call(
            (id) => OpenLocalBrowseChannelRequest(
              requestId: id,
              rootPath: '${parent.path}/child',
            ),
          ),
        );
        expect(error.kind, RemoteFileErrorKind.permissionDenied);
        expect(error.operation, 'resolve');
      },
      skip: _posixNonRoot
          ? false
          : 'mode-bit refusal needs a POSIX host with a non-root user',
    );
  });

  group('local directory watches', () {
    /// Opens a local channel over [root] with a fresh injected backend and
    /// starts a watch on the canonical home, failing loudly on any wire
    /// error.
    Future<(HostHarness, FakeWatchBackend, int, String)> watchFixture(
      Directory root,
    ) async {
      final backend = FakeWatchBackend();
      final h = HostHarness(localWatch: backend);
      // Registered at construction: a failure inside this helper must not
      // leak the harness isolate for the rest of the suite. dispose() is
      // idempotent, so the per-test registrations below are safe either way.
      addTearDown(h.dispose);
      final opened = await h.openLocal(root.path);
      final result = await h.call(
        (id) => WatchLocalDirectoryRequest(
          requestId: id,
          channelId: opened.channelId,
          // A non-canonical spelling: the backend must receive the
          // canonicalized form, not the request's raw text.
          path: '${opened.homePath}/.',
        ),
      );
      if (result is! EngineAck) {
        fail('watch failed: ${(result as EngineError).message}');
      }
      return (h, backend, opened.channelId, opened.homePath);
    }

    /// Waits past the debounce window so a debounced change has crossed —
    /// derived from the production constant, not a restated millisecond
    /// value that can drift (the connectionLogFlushInterval precedent).
    Future<void> settleDebounce() => Future<void>.delayed(
          LocalDirectoryWatcher.debounceInterval * 2,
        );

    List<DirectoryWatchEvent> watchEvents(HostHarness h) =>
        h.events.whereType<DirectoryWatchEvent>().toList();

    test('watch canonicalizes the target and forwards debounced changes',
        () async {
      final root = _localFixture('pg-watch-forward');
      final (h, backend, channelId, homePath) = await watchFixture(root);
      addTearDown(h.dispose);

      // The backend receives the canonical path, not the raw request one.
      expect(backend.controllers.keys, [homePath]);
      backend.emit(homePath, FileSystemCreateEvent('$homePath/new.txt', false));

      await settleDebounce();
      final events = watchEvents(h);
      expect(events, hasLength(1));
      expect(events.single.channelId, channelId);
      expect(events.single.path, homePath);
      expect(events.single.signal, DirectoryWatchSignal.changed);
      expect(events.single.detail, isNull);
    });

    test('root loss crosses immediately, never silently', () async {
      final root = _localFixture('pg-watch-lost');
      final (h, backend, channelId, homePath) = await watchFixture(root);
      addTearDown(h.dispose);

      backend.emit(
        homePath,
        FileSystemDeleteEvent(homePath, false),
      );
      await h.pumping();

      final events = watchEvents(h);
      expect(events, hasLength(1));
      expect(events.single.channelId, channelId);
      expect(events.single.signal, DirectoryWatchSignal.lost);
      expect(events.single.path, homePath);
      expect(events.single.detail, isNotNull);
    });

    test('retarget replaces the watch; stale events never cross', () async {
      final root = _localFixture('pg-watch-retarget');
      final sub = Directory('${root.path}/sub')..createSync();

      final backend = FakeWatchBackend();
      final h = HostHarness(localWatch: backend);
      addTearDown(h.dispose);
      final opened = await h.openLocal(root.path);
      final homePath = opened.homePath;
      final subCanonical = await _canonical(sub.path);

      Future<EngineResult> watch(String path) => h.call(
            (id) => WatchLocalDirectoryRequest(
              requestId: id,
              channelId: opened.channelId,
              path: path,
            ),
          );

      expect(await watch(homePath), isA<EngineAck>());
      expect(await watch(subCanonical), isA<EngineAck>());
      expect(backend.cancelled, [homePath]);

      // The replaced watch's events are epoch-dead.
      backend.emit(homePath, FileSystemCreateEvent('$homePath/old.txt', false));
      await settleDebounce();
      expect(watchEvents(h), isEmpty);

      // The new binding signals.
      backend.emit(
        subCanonical,
        FileSystemCreateEvent('$subCanonical/new.txt', false),
      );
      await settleDebounce();
      final events = watchEvents(h);
      expect(events, hasLength(1));
      expect(events.single.path, subCanonical);
      expect(events.single.signal, DirectoryWatchSignal.changed);
    });

    test('a pool channel answers the explicit local-only refusal', () async {
      final h = HostHarness();
      addTearDown(h.dispose);
      final poolChannel = await h.openWithDefaults();

      final error = await expectError(
        h.call(
          (id) => WatchLocalDirectoryRequest(
            requestId: id,
            channelId: poolChannel.channelId,
            path: '/tmp',
          ),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.unsupported);
      expect(error.operation, 'watch');

      final unwatchError = await expectError(
        h.call(
          (id) => UnwatchLocalDirectoryRequest(
            requestId: id,
            channelId: poolChannel.channelId,
          ),
        ),
      );
      expect(unwatchError.kind, RemoteFileErrorKind.unsupported);
    });

    test('a missing root answers the typed notFound, unwatched', () async {
      final h = HostHarness(localWatch: _NeverWatchBackend());
      addTearDown(h.dispose);
      final root = _localFixture('pg-watch-missing');
      final missing = '${root.path}/no-such-dir';

      final opened = await h.openLocal(root.path);
      final error = await expectError(
        h.call(
          (id) => WatchLocalDirectoryRequest(
            requestId: id,
            channelId: opened.channelId,
            path: missing,
          ),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.notFound);
      expect(error.path, await _canonical(missing));
    });

    test('a file target answers typed, unwatched', () async {
      final h = HostHarness(localWatch: _NeverWatchBackend());
      addTearDown(h.dispose);
      final root = _localFixture('pg-watch-file');

      final opened = await h.openLocal(root.path);
      final file = await _canonical('${root.path}/a.txt');
      final error = await expectError(
        h.call(
          (id) => WatchLocalDirectoryRequest(
            requestId: id,
            channelId: opened.channelId,
            path: file,
          ),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.other);
      expect(error.message, contains('not a directory'));
    });

    test('an empty path answers typed', () async {
      final h = HostHarness(localWatch: _NeverWatchBackend());
      addTearDown(h.dispose);
      final root = _localFixture('pg-watch-empty');

      final opened = await h.openLocal(root.path);
      final error = await expectError(
        h.call(
          (id) => WatchLocalDirectoryRequest(
            requestId: id,
            channelId: opened.channelId,
            path: '',
          ),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.other);
      expect(error.operation, 'watch');
    });

    test('an unknown channel answers disconnected', () async {
      final h = HostHarness();
      addTearDown(h.dispose);

      final error = await expectError(
        h.call(
          (id) => WatchLocalDirectoryRequest(
            requestId: id,
            channelId: 999,
            path: '/tmp',
          ),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.disconnected);
      expect(error.operation, 'watch');
    });

    test('unwatch releases the backend watch and is idempotent', () async {
      final root = _localFixture('pg-watch-unwatch');
      final (h, backend, channelId, homePath) = await watchFixture(root);
      addTearDown(h.dispose);

      expect(
        await h.call(
          (id) => UnwatchLocalDirectoryRequest(
            requestId: id,
            channelId: channelId,
          ),
        ),
        isA<EngineAck>(),
      );
      expect(backend.cancelled, [homePath]);

      // Idempotent: a channel with no watch still acks.
      expect(
        await h.call(
          (id) => UnwatchLocalDirectoryRequest(
            requestId: id,
            channelId: channelId,
          ),
        ),
        isA<EngineAck>(),
      );

      // Released: events no longer cross.
      backend.emit(homePath, FileSystemCreateEvent('$homePath/x.txt', false));
      await settleDebounce();
      expect(watchEvents(h), isEmpty);
    });

    test('closing the channel releases the watch', () async {
      final root = _localFixture('pg-watch-close');
      final (h, backend, channelId, homePath) = await watchFixture(root);
      addTearDown(h.dispose);

      await h.call(
        (id) => CloseBrowseChannelRequest(
          requestId: id,
          channelId: channelId,
        ),
      );
      expect(backend.cancelled, [homePath]);

      backend.emit(homePath, FileSystemCreateEvent('$homePath/x.txt', false));
      await settleDebounce();
      expect(watchEvents(h), isEmpty);
    });

    test('shutdown releases local watches', () async {
      final root = _localFixture('pg-watch-shutdown');
      final (h, backend, _, homePath) = await watchFixture(root);

      await h.call((id) => ShutdownRequest(requestId: id));
      expect(backend.cancelled, [homePath]);
    });

    test(
      'a watch racing a channel close answers the typed channel-closed refusal',
      () async {
        final backend = FakeWatchBackend();
        final h = HostHarness(localWatch: backend);
        addTearDown(h.dispose);
        final root = _localFixture('pg-watch-close-race');

        final opened = await h.openLocal(root.path);
        // Both requests issued back to back without awaiting between: the
        // watch suspends inside its canonicalize/stat awaits, the close
        // removes the channel and disposes the watcher synchronously, and
        // the resumed watch must refuse typed instead of acking a watch
        // onto a disposed watcher.
        final watch = h.call(
          (id) => WatchLocalDirectoryRequest(
            requestId: id,
            channelId: opened.channelId,
            path: opened.homePath,
          ),
        );
        final closed = h.call(
          (id) => CloseBrowseChannelRequest(
            requestId: id,
            channelId: opened.channelId,
          ),
        );

        final error = await expectError(watch);
        // Mark the close future's outcome handled up front so a failing
        // assertion below cannot strand a throwing close as unhandled
        // async noise; the later await still observes it.
        closed.ignore();
        expect(error.kind, RemoteFileErrorKind.disconnected);
        expect(error.operation, 'watch');
        // Consume the close future deterministically — after the primary
        // expectations, so a throwing or hanging close cannot mask the
        // watch-contract assertions.
        await closed;
        // The close won: nothing was ever watched.
        expect(backend.controllers, isEmpty);
      },
    );
  });
}
