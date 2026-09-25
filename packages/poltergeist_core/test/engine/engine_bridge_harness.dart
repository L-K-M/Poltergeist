import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';

import '../connection/pool_fakes.dart';
import '../transfer/transfer_fakes.dart';

/// The fingerprint every scripted transport presents — pinned up front so
/// no first-use prompt interrupts the bridge suites.
const bridgeFingerprint = 'SHA256:presented';

/// The deterministic config a bridged serverId dials with.
ServerConfig bridgeConfig(String serverId) => ServerConfig(
  id: serverId,
  label: serverId,
  host: '$serverId.test',
  username: 'user',
  authMethod: AuthMethod.privateKey,
  createdAt: 0,
  updatedAt: 0,
);

/// A real [EngineHost] behind the in-process client seam, over
/// socket-free pools whose SFTP channels are [FakeTreeFileSystem]s — one
/// per serverId — so the bridge's production client, proxy, and host
/// code run end to end while the fake trees stay inspectable here.
class BridgeHarness {
  BridgeHarness(
    this.servers, {
    int windowBytes = EngineConnectionManager.defaultWindowBytes,
    LocalTrashService? localTrash,
    Duration? drainTimeout,
    bool withConfigs = true,
  }) {
    for (final serverId in servers.keys) {
      openers[serverId] = FakeTransportOpener()
        ..transportFsBuilder = (_) => servers[serverId]!;
    }
    client = EngineClient.inProcessForTesting(
      host: (events) => host = EngineHost(
        config: EngineConfig(
          hostKeyPins: [
            for (final serverId in servers.keys)
              HostKey(
                host: '$serverId.test',
                port: 22,
                type: 'ssh-ed25519',
                fingerprintSha256: bridgeFingerprint,
                pinnedAt: 0,
              ),
          ],
        ),
        events: events,
        openTransport: _open,
        prober: FakeReconnectProber(),
        localTrash: localTrash,
        shutdownDrainTimeout: drainTimeout,
      ),
    );
    // Credentials come "from the vault" on every first connect.
    _prompts = client.prompts.listen((prompt) {
      final reply = switch (prompt.kind) {
        EnginePromptKind.credentialNeeded => const CredentialPromptReply(
          privateKeyPem: 'TEST KEY',
          origin: CredentialOrigin.stored,
        ),
        EnginePromptKind.hostKeyFirstUse || EnginePromptKind.hostKeyChanged =>
          const HostKeyPromptReply(accepted: true),
        _ => null,
      };
      if (reply != null) {
        client.replyPrompt(prompt.promptId, prompt.kind, reply);
      }
    });
    connections = EngineConnectionManager(
      client,
      configs: _BridgeConfigs(resolveCalls, withConfigs: withConfigs),
      windowBytes: windowBytes,
    );
  }

  final Map<String, FakeTreeFileSystem> servers;
  final Map<String, FakeTransportOpener> openers = {};
  final List<String> resolveCalls = [];
  late final EngineClient client;

  /// The in-process host — for engine-side assertions.
  late final EngineHost host;
  late final EngineConnectionManager connections;
  late final StreamSubscription<EnginePromptEvent> _prompts;

  SshTransportOpener get _open =>
      ({
        required config,
        required credentials,
        required tofu,
        required onHostKey,
        onKeyboardInteractive,
        required prompting,
        timeout = const Duration(seconds: 15),
        log,
      }) {
        final serverId = config.host.substring(
          0,
          config.host.length - '.test'.length,
        );
        return openers[serverId]!.opener(
          config: config,
          credentials: credentials,
          tofu: tofu,
          onHostKey: onHostKey,
          onKeyboardInteractive: onKeyboardInteractive,
          prompting: prompting,
          timeout: timeout,
          log: log,
        );
      };

  Future<void> dispose() async {
    await _prompts.cancel();
    await client.shutdown();
  }
}

/// A sink whose `addStream` consumes nothing until [open] completes —
/// the stalled-consumer shape the credit window must bound.
class GatedSink implements StreamSink<List<int>> {
  final Completer<void> open = Completer<void>();
  final List<int> received = [];
  final Completer<void> _done = Completer<void>();
  Object? failWith;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await open.future;
    await for (final chunk in stream) {
      received.addAll(chunk);
      final failure = failWith;
      if (failure != null) throw failure;
    }
  }

  @override
  void add(List<int> data) => received.addAll(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}

/// Collects a download's bytes.
class CollectingSink implements StreamSink<List<int>> {
  final List<int> received = [];
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      received.addAll(chunk);
    }
  }

  @override
  void add(List<int> data) => received.addAll(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}

class _BridgeConfigs implements ServerConfigSource {
  _BridgeConfigs(this.calls, {required this.withConfigs});

  final List<String> calls;

  /// False models an app that holds no config (a Quick Connect id).
  final bool withConfigs;

  @override
  Future<ServerConfig?> configFor(String serverId) async {
    calls.add(serverId);
    return withConfigs ? bridgeConfig(serverId) : null;
  }
}
