import 'dart:async';
import 'dart:isolate';

import 'package:seance_core/seance_core.dart';

import '../connection/connection_manager.dart';
import '../connection/credential_resolution.dart';
import '../connection/ssh_transport.dart';
import 'connect_log_coalescer.dart';
import 'protocol.dart';

/// Boots the engine isolate (the `Isolate.spawn` entrypoint).
///
/// Handshake: the caller spawns with its event port as the spawn message;
/// this sends back the command port, then treats the first command as the
/// [EngineConfig] (03 §5) and serves every later message through
/// [EngineHost.handle]. Any uncaught error kills the isolate — the client
/// observes termination and fails its pending calls.
void engineMain(SendPort events) {
  final commands = ReceivePort();
  events.send(commands.sendPort);

  EngineHost? host;
  commands.listen((message) {
    if (host != null) {
      host!.handle(message);
      return;
    }
    if (message is! EngineConfig) {
      throw StateError('Engine isolate received $message before EngineConfig.');
    }
    host = EngineHost(config: message, events: events);
  });
}

/// Serves the typed port protocol inside the engine isolate: owns the
/// [PooledConnectionManager], executes VFS requests on its channels, and
/// bridges every user-facing prompt to an [EnginePromptEvent]/reply pair —
/// the seance_core prompt callbacks cannot cross isolates (03 §5).
///
/// Constructed with the [EngineConfig]; emits every [EngineEvent] on
/// [events]. [handle] dispatches one decoded message; request bodies run
/// independently (the pool serializes what must be serialized) and their
/// failures are answered, never thrown, so one bad request cannot kill the
/// engine. Only a non-protocol message throws — a bug worth dying for.
class EngineHost {
  final SendPort _events;
  final _PromptBroker _prompts;
  late final PooledConnectionManager _manager;
  late final ConnectLogCoalescer _logCoalescer;
  StreamSubscription<ConnectLogLine>? _connectLogSubscription;

  final Map<String, ServerConfig> _servers = {};
  final Map<int, PaneChannel> _channels = {};
  final Map<String, StreamSubscription<ServerStatus>> _watches = {};
  int _nextChannelId = 1;
  bool _shuttingDown = false;

  /// [openTransport], [prober], and [hostKeyStore] are test seams — the
  /// production defaults need real sockets; tests inject socket-free fakes.
  factory EngineHost({
    required EngineConfig config,
    required SendPort events,
    SshTransportOpener openTransport = openDartSshTransport,
    Prober prober = const TcpBannerProber(),
    HostKeyStore? hostKeyStore,
  }) {
    final host = EngineHost._(events);
    host._logCoalescer = ConnectLogCoalescer(events.send);
    host._manager = PooledConnectionManager(
      resolveServer: host._resolveKnownServer,
      resolveCredentials: host._prompts.resolveCredentials,
      onHostKey: host._prompts.hostKey,
      onKeyboardInteractive: host._prompts.keyboard,
      tofu: TofuVerifier(hostKeyStore ?? _seededPinStore(config, events)),
      policy: config.policy,
      openTransport: openTransport,
      prober: prober,
      onRecoveryFailure: host._recoveryFailed,
    );
    // The manager emits one event per transcript line; only the coalesced
    // batch crosses the port (03 §5).
    host._connectLogSubscription = host._manager.connectLog.listen(
      host._logCoalescer.add,
    );
    return host;
  }

  EngineHost._(this._events) : _prompts = _PromptBroker(_events);

  void _recoveryFailed(
    String serverId,
    RemoteFileException error, {
    String? paneTabId,
  }) {
    if (_shuttingDown) return;
    // Terminal diagnostics bypass lossy progress and need no state watch.
    // Serialization drops arbitrary causes before crossing the port.
    _events.send(
      RecoveryFailedEvent(
        serverId: serverId,
        paneTabId: paneTabId,
        error: EngineError.fromException(error),
      ),
    );
  }

  /// Pins from the config seed the in-memory verifier; every later pin
  /// write surfaces to the UI for persistence (the engine owns TOFU, the
  /// app owns storage).
  static HostKeyStore _seededPinStore(EngineConfig config, SendPort events) {
    final pins = InMemoryHostKeyStore();
    for (final pin in config.hostKeyPins) {
      // In-memory puts are synchronous map writes and cannot error; the
      // explicit unawaited marks the discard intentional.
      unawaited(pins.put(pin));
    }
    return _PinningStore(pins, events);
  }

  void handle(Object? message) {
    switch (message) {
      case final OpenBrowseChannelRequest request:
        _guard(request.requestId, () async {
          _servers[request.serverId] = request.config;
          final channel = await _manager.openBrowseChannel(
            request.serverId,
            paneTabId: request.paneTabId,
          );
          final channelId = _nextChannelId++;
          _channels[channelId] = channel;
          return BrowseChannelOpened(
            channelId: channelId,
            homePath: channel.homePath,
          );
        });
      case final CloseBrowseChannelRequest request:
        _guard(request.requestId, () async {
          final channel = _channels.remove(request.channelId);
          // Idempotent: closing a closed channel succeeds.
          await channel?.close();
          return const EngineAck();
        });
      case final ListDirectoryRequest request:
        _guard(request.requestId, () => _listDirectory(request));
      case final WatchServerRequest request:
        _watch(request.serverId);
      case final UnwatchServerRequest request:
        _unwatch(request.serverId);
      case final ConnectedServerIdsRequest request:
        _guard(request.requestId, () async {
          final ids = await _manager.connectedServerIds();
          return ServerIdsListed(ids: ids.toList()..sort());
        });
      case final DisconnectServerRequest request:
        _guard(request.requestId, () async {
          await _manager.disconnectServer(request.serverId);
          return const EngineAck();
        });
      case final PromptReplyRequest request:
        _prompts.reply(request);
      case final ShutdownRequest request:
        _guard(request.requestId, () => _shutdown(request));
      default:
        throw StateError(
          'Engine isolate received an unknown message: $message',
        );
    }
  }

  /// Runs one request body, answering exactly one [ResponseEvent]: the typed
  /// result, a serialized [RemoteFileException], or a wrapped engine fault.
  /// Non-VFS exceptions (a connect failure's `SshConnectException`, a bug)
  /// keep their message but lose their unsendable cause.
  void _guard(int requestId, Future<EngineResult> Function() run) {
    unawaited(
      run().then(
        (result) => _respond(requestId, result),
        onError: (Object error) {
          final failure = switch (error) {
            final RemoteFileException exception => EngineError.fromException(
              exception,
            ),
            _ => EngineError(
              kind: RemoteFileErrorKind.other,
              operation: 'engine request',
              message: error.toString(),
            ),
          };
          _respond(requestId, failure);
        },
      ),
    );
  }

  void _respond(int requestId, EngineResult result) {
    _events.send(ResponseEvent(requestId: requestId, result: result));
  }

  Future<ServerConfig> _resolveKnownServer(String serverId) async {
    final config = _servers[serverId];
    if (config != null) return config;
    throw RemoteFileException(
      kind: RemoteFileErrorKind.other,
      operation: 'resolve server',
      message:
          'No connection request has supplied a config for '
          '"$serverId" yet.',
    );
  }

  Future<EngineResult> _listDirectory(ListDirectoryRequest request) async {
    final channel = _channels[request.channelId];
    if (channel == null) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'list directory',
        message: 'The browse channel is closed.',
      );
    }

    // Capture the binding's fs once: the getter itself throws typed errors
    // when the pool blocked or the handle died mid-request, and re-reading
    // it in the catch could replace the original failure.
    final fs = channel.fs;
    try {
      return DirectoryListed(entries: await fs.listDirectory(request.path));
    } on RemoteFileException catch (error) {
      // Report before answering: recovery keys off disconnected failures
      // from the binding's current transport (03 §3.2 PaneChannel).
      channel.reportFailure(fs, error);
      rethrow;
    }
  }

  void _watch(String serverId) {
    // Last request wins: a fresh watch replaces any existing forwarding so
    // the first forwarded event is again the current state.
    _watches.remove(serverId)?.cancel();
    late final StreamSubscription<ServerStatus> subscription;
    subscription = _manager
        .watchServer(serverId)
        .listen(
          (status) => _events.send(
            ServerStateEvent(
              serverId: serverId,
              state: status.state,
              detail: status.detail,
            ),
          ),
          // The manager's streams neither error nor complete today; a
          // future change on either side must not kill the engine over a
          // state fan-out.
          onError: (Object _) {},
          onDone: () {
            if (identical(_watches[serverId], subscription)) {
              _watches.remove(serverId);
            }
          },
        );
    _watches[serverId] = subscription;
  }

  void _unwatch(String serverId) {
    _watches.remove(serverId)?.cancel();
  }

  /// The spawner owns the isolate's lifetime: it kills after the ack (see
  /// `EngineClient.shutdown`), so the host only cleans up and answers.
  Future<EngineResult> _shutdown(ShutdownRequest request) async {
    _shuttingDown = true;
    // Still-open prompts are implicit cancels (03 §5): dismiss them so no
    // dialog outlives the engine.
    _prompts.dismissAll();
    for (final serverId in _servers.keys.toList()) {
      try {
        await _manager.disconnectServer(serverId);
      } on Object {
        // Shutdown must complete even if one server's cleanup is broken.
      }
    }
    // Disconnect first, then stop forwarding: teardown closes no transports
    // through the opener, so no transcript line can follow — but an early
    // await here would let prompt dismissals win the disconnect race and
    // change the abandoned opens' documented failure kind.
    await _connectLogSubscription?.cancel();
    _logCoalescer.dispose();
    for (final subscription in _watches.values) {
      await subscription.cancel();
    }
    _watches.clear();

    // disconnectServer already closed every pane binding (03 §3.5); these
    // maps are state hygiene so a post-shutdown host answers cleanly
    // instead of vending dead channels.
    _channels.clear();
    _servers.clear();
    return const EngineAck();
  }
}

/// A pin store that forwards every write to the UI (03 §5's pin bridge).
final class _PinningStore implements HostKeyStore {
  final HostKeyStore _pins;
  final SendPort _events;

  _PinningStore(this._pins, this._events);

  @override
  Future<HostKey?> get(String host, int port) => _pins.get(host, port);

  @override
  Future<List<HostKey>> all() => _pins.all();

  @override
  Future<void> put(HostKey key) async {
    await _pins.put(key);
    _events.send(HostKeyPinnedEvent(key: key));
  }
}

/// Signals that the engine withdrew a prompt before an answer arrived.
final class _PromptDismissed implements Exception {
  const _PromptDismissed();
}

final class _OpenPrompt {
  final EnginePromptKind kind;
  final Completer<PromptReply> completer = Completer<PromptReply>();

  _OpenPrompt(this.kind);
}

/// Bridges the engine's prompt callbacks onto the port (03 §5): mints a
/// promptId, emits the event, and awaits exactly one reply. Everything else
/// — unknown ids, kind mismatches, second replies, replies racing a
/// dismissal — is ignored at debug level, promptId and kind only, never the
/// payload, since credential replies carry secrets.
final class _PromptBroker {
  final SendPort _events;
  final Map<String, _OpenPrompt> _open = {};
  int _nextPromptId = 1;

  _PromptBroker(this._events);

  Future<bool> hostKey(HostKeyDecision decision) async {
    final kind = decision.verdict == HostKeyVerdict.changed
        ? EnginePromptKind.hostKeyChanged
        : EnginePromptKind.hostKeyFirstUse;
    final presented = decision.presented;
    final promptId = _mint(
      kind,
      HostKeyPromptData(
        host: presented.host,
        port: presented.port,
        keyType: presented.type,
        fingerprintSha256: presented.fingerprintSha256,
        pinnedFingerprintSha256: decision.pinned?.fingerprintSha256,
      ),
    );

    try {
      final reply = await _awaitReply(promptId) as HostKeyPromptReply;
      return reply.accepted;
    } on _PromptDismissed {
      // Shutdown-time dismissal declines; the failing connect is moot anyway.
      return false;
    } finally {
      _retire(promptId);
    }
  }

  Future<List<String>> keyboard(
    List<String> prompts,
    String name,
    String instruction,
  ) async {
    final promptId = _mint(
      EnginePromptKind.keyboardInteractive,
      KeyboardInteractivePromptData(
        name: name,
        instruction: instruction,
        prompts: prompts,
      ),
    );

    try {
      final reply =
          await _awaitReply(promptId) as KeyboardInteractivePromptReply;
      return reply.answers;
    } on _PromptDismissed {
      // Empty answers cannot authenticate: the connect fails its auth step.
      return const [];
    } finally {
      _retire(promptId);
    }
  }

  Future<ResolvedCredentials> resolveCredentials(
    ServerConfig config,
    CredentialResolutionScope scope,
  ) async {
    final promptId = _mint(
      EnginePromptKind.credentialNeeded,
      CredentialPromptData(
        host: config.host,
        port: config.port,
        username: config.username,
        authMethod: config.authMethod,
        secretRef: config.secretRef,
        identityFilePath: config.identityFilePath,
      ),
    );

    // The dismissal crossing (03 §3.2): when the pool's lifetime ends
    // mid-resolution, withdraw the prompt so the UI-side dialog closes —
    // one mechanism, both sides. A completed answer tolerates the firing
    // (the scope's documented microtask window): dismiss no-ops then.
    unawaited(scope.dismissed.then((_) => dismiss(promptId)));

    final CredentialPromptReply reply;
    try {
      reply = await _awaitReply(promptId) as CredentialPromptReply;
    } on _PromptDismissed {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: 'resolve credentials',
        message: 'The credential prompt was dismissed before an answer.',
      );
    } finally {
      _retire(promptId);
    }

    if (reply.cancelled) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: 'resolve credentials',
        message: 'Authentication was cancelled.',
      );
    }

    return ResolvedCredentials(
      credentials: _credentialsOf(reply),
      origin: reply.origin,
    );
  }

  /// Which secret field is set picks the constructor, mirroring
  /// [SshCredentials]: key pem → key auth, password → password auth,
  /// neither → agent.
  static SshCredentials _credentialsOf(CredentialPromptReply reply) {
    final pem = reply.privateKeyPem;
    if (pem != null) {
      return SshCredentials.privateKey(pem, keyPassphrase: reply.keyPassphrase);
    }
    final password = reply.password;
    if (password != null) return SshCredentials.password(password);
    return const SshCredentials.agent();
  }

  void reply(PromptReplyRequest request) {
    final prompt = _open[request.promptId];

    // Unknown promptId, closed prompt, kind mismatch, a reply of the wrong
    // runtime type, or a second reply: ignored (03 §5). Never an error —
    // an answer racing a dismissal must not break the engine.
    final expectedType = _replyTypeFor(request.kind);
    if (prompt == null ||
        prompt.kind != request.kind ||
        prompt.completer.isCompleted ||
        expectedType == null ||
        request.reply.runtimeType != expectedType) {
      return;
    }
    prompt.completer.complete(request.reply);
  }

  void dismiss(String promptId) {
    final prompt = _open.remove(promptId);

    // An already-answered prompt ignores the firing (scope contract).
    if (prompt == null || prompt.completer.isCompleted) return;

    _events.send(PromptDismissedEvent(promptId: promptId, kind: prompt.kind));
    prompt.completer.completeError(const _PromptDismissed());
  }

  /// Engine shutdown's implicit cancel for every still-open prompt.
  void dismissAll() {
    for (final promptId in _open.keys.toList()) {
      dismiss(promptId);
    }
  }

  /// The reply runtime type each kind accepts; the `conflict` kind has no
  /// reply subtype until the transfer queue (M4) lands, so its replies are
  /// ignored — no producer exists to consume one.
  static Type? _replyTypeFor(EnginePromptKind kind) => switch (kind) {
    EnginePromptKind.hostKeyFirstUse ||
    EnginePromptKind.hostKeyChanged => HostKeyPromptReply,
    EnginePromptKind.keyboardInteractive => KeyboardInteractivePromptReply,
    EnginePromptKind.credentialNeeded => CredentialPromptReply,
    EnginePromptKind.conflict => null,
  };

  String _mint(EnginePromptKind kind, EnginePromptData data) {
    final promptId = 'p${_nextPromptId++}';
    _open[promptId] = _OpenPrompt(kind);
    _events.send(EnginePromptEvent(promptId: promptId, kind: kind, data: data));
    return promptId;
  }

  Future<PromptReply> _awaitReply(String promptId) =>
      _open[promptId]!.completer.future;

  void _retire(String promptId) {
    final prompt = _open[promptId];
    if (prompt != null && prompt.completer.isCompleted) _open.remove(promptId);
  }
}
