import 'dart:async';
import 'dart:isolate';

import 'package:seance_core/seance_core.dart';

import '../connection/connection_manager.dart';
import '../connection/credential_resolution.dart';
import '../connection/incident_store.dart';
import '../connection/pool_key.dart';
import '../connection/ssh_transport.dart';
import '../fs/local_file_system.dart';
import 'connect_log_coalescer.dart';
import 'engine_probes.dart';
import 'local_directory_watcher.dart';
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
/// [PooledConnectionManager] and the pane-facing `LocalFileSystem`
/// instances (03 §5's ownership table), executes VFS requests on its
/// channels, and bridges every user-facing prompt to an [EnginePromptEvent]/reply pair —
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
  late final EngineProbes _probes;
  StreamSubscription<ConnectLogLine>? _connectLogSubscription;

  final Map<String, ServerConfig> _servers = {};
  final Map<int, PaneChannel> _channels = {};

  /// Channel retirements still in flight: the close request removed the
  /// channel from [_channels] (routing retires immediately — no stale
  /// events or requests leak) but its teardown — the local channel's
  /// backend watch release — has not completed yet. Duplicate closes and
  /// shutdown share the pending completion instead of treating map
  /// removal as proof of teardown. Entries self-remove on completion, so
  /// the map is bounded by in-flight closes.
  final Map<int, Future<void>> _pendingCloses = {};
  final Map<String, StreamSubscription<ServerStatus>> _watches = {};
  late final LocalWatchBackend _localWatch;
  int _nextChannelId = 1;
  bool _shuttingDown = false;

  /// [openTransport], [prober], and [hostKeyStore] are test seams — the
  /// production defaults need real sockets; tests inject socket-free fakes.
  /// [localWatch] is the same for 03 §7.5's directory watchers: the default
  /// is dart:io's `Directory.watch`; tests inject deterministic backends.
  factory EngineHost({
    required EngineConfig config,
    required SendPort events,
    SshTransportOpener openTransport = openDartSshTransport,
    Prober prober = const TcpBannerProber(),
    HostKeyStore? hostKeyStore,
    LocalWatchBackend? localWatch,
  }) {
    final host = EngineHost._(events);
    host._localWatch = localWatch ?? const DartIoWatchBackend();
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
      // The app owns incident persistence: the bridge keeps the engine's
      // in-memory records in step with the app by forwarding every
      // put/remove as an [IncidentStoreEvent]. Audit finding A's coupling:
      // pins and incidents seed from the same app-owned config, so a
      // restored block always keeps both of D18's escapes.
      incidentStore: _seededIncidentStore(config, events),
      onRecoveryFailure: host._recoveryFailed,
    );
    host._probes = EngineProbes(
      emit: (statuses) {
        if (host._shuttingDown) return;
        events.send(ProbeStatusesEvent(statuses: statuses));
      },
      connectedServerIds: (targets) =>
          host._manager.liveServerIds(matchingTargets: targets),
      prober: prober,
    );
    // The manager emits one event per transcript line; only the coalesced
    // batch crosses the port (03 §5).
    host._connectLogSubscription = host._manager.connectLog.listen(
      host._logCoalescer.add,
      // Transcript fan-out is diagnostic; a future stream error must not
      // kill the engine isolate.
      onError: (Object _) {},
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

  /// Incident records from the config seed the in-memory store; every later
  /// put/remove forwards to the app-owned store as a typed event. The seed
  /// is structural, not conventional: the manager's lazy load filters these
  /// records against the pin seed (audit finding A's safety net), so a
  /// half-seeded store would silently drop a restored block — and this
  /// factory cannot await, hence the synchronous seeding constructor.
  ///
  /// The pin seed above keeps the unawaited-put convention because
  /// `InMemoryHostKeyStore` is Séance's pinned class; a missing pin fails
  /// closed (a first-use re-prompt), where a missing record would not.
  static IncidentStore _seededIncidentStore(
    EngineConfig config,
    SendPort events,
  ) => _IncidentBridge(InMemoryIncidentStore.seeded(config.incidents), events);

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
      case final OpenLocalBrowseChannelRequest request:
        _guard(request.requestId, () async {
          final fs = LocalFileSystem();
          // 03 §2.2: canonicalize never fails for a missing path, so the
          // open succeeds and an unresolvable root surfaces through the
          // typed notFound taxonomy at first listing, like any navigation.
          final homePath = await fs.canonicalize(request.rootPath);
          final channelId = _nextChannelId++;
          final watcher = LocalDirectoryWatcher(backend: _localWatch);
          final channel = _LocalPaneChannel(fs, homePath, watcher);
          // The host owns the forwarding subscription; the channel owns
          // the watcher. dispose() closes the signal stream, which ends
          // this subscription — no separate cancel bookkeeping.
          channel.signals.listen((signal) {
            if (_shuttingDown) return;
            // Broadcast streams flush signals added just before close();
            // drop ones racing a channel close/removal.
            if (_channels[channelId] != channel) return;
            _events.send(
              DirectoryWatchEvent(
                channelId: channelId,
                path: signal.path,
                signal: signal.kind,
                detail: signal.detail,
              ),
            );
          });
          _channels[channelId] = channel;
          return BrowseChannelOpened(channelId: channelId, homePath: homePath);
        });
      case final WatchLocalDirectoryRequest request:
        _guard(request.requestId, () => _watchLocalDirectory(request));
      case final UnwatchLocalDirectoryRequest request:
        _guard(request.requestId, () => _unwatchLocalDirectory(request));
      case final CloseBrowseChannelRequest request:
        _guard(request.requestId, () => _closeChannel(request));
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
      case final SetProbeTargetsRequest request:
        _guard(request.requestId, () async {
          _probes.updateTargets(request.targets);
          return const EngineAck();
        });
      case final SetProbeActivityRequest request:
        _guard(request.requestId, () async {
          _probes.setActivity(request.activity);
          return const EngineAck();
        });
      case final DisconnectServerRequest request:
        _guard(request.requestId, () async {
          await _manager.disconnectServer(request.serverId);
          return const EngineAck();
        });
      case final RemoveBookmarkRequest request:
        _guard(request.requestId, () async {
          try {
            await _manager.removeBookmark(request.serverId);
          } finally {
            // The bookmark is gone regardless of the cascade's outcome:
            // never keep serving its config or watch afterwards.
            _forgetServer(request.serverId);
          }
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

  /// Closes the channel (03 §3.2): routing retires synchronously, the
  /// acknowledgement waits out the actual teardown. A duplicate close —
  /// one racing this retirement — shares the pending completion rather
  /// than acking against a channel map entry already removed. Closing an
  /// unknown, fully retired channel stays idempotent and acks. Channel
  /// ids are never reused and duplicates await rather than create, so
  /// each tracked retirement is the only one its id will ever have. A
  /// retirement that fails surfaces its error to every close sharing it;
  /// only after settlement does closing the id become the idempotent ack.
  Future<EngineResult> _closeChannel(
    CloseBrowseChannelRequest request,
  ) async {
    final channelId = request.channelId;
    final channel = _channels.remove(channelId);
    if (channel == null) {
      // Either retired long ago (idempotent ack) or still closing: share
      // that retirement's completion so both acknowledgements mean the
      // same thing — teardown finished.
      final pending = _pendingCloses[channelId];
      if (pending != null) await pending;
      return const EngineAck();
    }

    final retirement = channel.close();
    _pendingCloses[channelId] = retirement;
    // Bounded bookkeeping: drop the entry once this retirement settles.
    // The guard swallows the outcome for cleanup only — the awaiting
    // callers still see it (the handler awaits `retirement` itself).
    unawaited(
      retirement.catchError((Object _) {}).then((_) {
        _pendingCloses.remove(channelId);
      }),
    );
    await retirement;
    return const EngineAck();
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

  Future<EngineResult> _watchLocalDirectory(
    WatchLocalDirectoryRequest request,
  ) async {
    final channel = _channels[request.channelId];
    if (channel == null) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'watch',
        message: 'The browse channel is closed.',
      );
    }
    if (channel is! _LocalPaneChannel) {
      // Explicit refusal, never a silent no-op: watching a remote directory
      // would be a polling feature this engine deliberately lacks
      // (03 §7.5).
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'watch',
        message: 'Directory watching is available on local channels only.',
      );
    }
    return channel.watch(request.path);
  }

  Future<EngineResult> _unwatchLocalDirectory(
    UnwatchLocalDirectoryRequest request,
  ) async {
    final channel = _channels[request.channelId];
    if (channel == null) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'unwatch',
        message: 'The browse channel is closed.',
      );
    }
    if (channel is! _LocalPaneChannel) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'unwatch',
        message: 'Directory watching is available on local channels only.',
      );
    }
    await channel.unwatch();
    return const EngineAck();
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

  /// Drops every host-side trace of a removed bookmark. Runs from the
  /// removal's `finally`, so it also fires when the manager's own cleanup
  /// failed partway: host state must never outlive the bookmark, and a
  /// long-lived engine must not retain config or a watch for an id that no
  /// longer exists (audit finding C's engine-side growth).
  void _forgetServer(String serverId) {
    _servers.remove(serverId);
    _unwatch(serverId);
  }

  /// The spawner owns the isolate's lifetime: it kills after the ack (see
  /// `EngineClient.shutdown`), so the host only cleans up and answers.
  Future<EngineResult> _shutdown(ShutdownRequest request) async {
    _shuttingDown = true;
    // Stop queued probes before any teardown await; active sockets may drain.
    final probesDisposed = _probes.dispose();
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
    await probesDisposed;
    _logCoalescer.dispose();
    for (final subscription in _watches.values) {
      await subscription.cancel();
    }
    _watches.clear();

    // Local channels bind no pool, so disconnectServer never saw them:
    // close them directly — which also releases each channel's directory
    // watch (03 §7.5) and its debounce timer. Pool bindings were closed by
    // disconnectServer above. Channels already removed from the map but
    // still closing (a close request in flight) are in _pendingCloses —
    // shutdown waits those too, so it can never ack over a live backend
    // watch it stopped tracking in the map. The loop awaits, so a close
    // request processed mid-loop can mutate _channels — snapshot first
    // (a channel closed by such a request is retired through its own
    // memoized close; this loop re-awaits the same future, never a
    // double teardown).
    for (final channel in List.of(_channels.values)) {
      if (channel is _LocalPaneChannel) await channel.close();
    }
    // No clear before the drain: entries self-remove on settlement, and
    // a duplicate close processed while shutdown is parked awaiting one
    // of these retirements must still find its pending entry and await
    // it — clearing here would reopen the exact early-ack window this
    // map exists to close.
    final pendingCloses = List.of(_pendingCloses.values);
    for (final retirement in pendingCloses) {
      try {
        await retirement;
      } on Object {
        // Shutdown must complete even if one retirement is broken.
      }
    }

    // disconnectServer already closed every pane binding (03 §3.5); these
    // maps are state hygiene so a post-shutdown host answers cleanly
    // instead of vending dead channels.
    _channels.clear();
    _servers.clear();
    return const EngineAck();
  }
}

/// The local half of the host's channel routing (03 §5): a `LocalFileSystem`
/// the engine owns, served through the same map and requests as pool
/// `PaneChannel`s so panes cannot tell the two apart by protocol shape.
///
/// Local failures are terminal facts, never transport loss: nothing recovers,
/// so [reportFailure] is a no-op — the host's recovery reporting keys off
/// `disconnected`-kind failures that the local funnel (03 §2.2) never
/// produces. The channel also owns its directory watch (03 §7.5), one
/// non-recursive watch per channel: [watch] starts or retargets it,
/// [unwatch] and [close] release it, and its typed signals cross the port
/// through the subscription the host installs on [signals].
final class _LocalPaneChannel implements PaneChannel {
  final LocalFileSystem _fs;
  final LocalDirectoryWatcher _watcher;
  bool _closed = false;

  /// The generation of the newest watch-control request (watch, unwatch,
  /// close). Watch validation awaits real I/O; a request that resumes with
  /// a stale generation must not install — the newest request already
  /// decided the channel's watch state, and an older validation
  /// resurrecting a watch would undo an acknowledged unwatch (or a newer
  /// watch's binding).
  int _watchGeneration = 0;

  @override
  final String homePath;

  _LocalPaneChannel(this._fs, this.homePath, this._watcher);

  /// The watch's typed signals (03 §7.5); closes when [close] disposes the
  /// watcher. A getter — not a callback field — so the engine sources carry
  /// no function-typed fields (08 §3.3's guard).
  Stream<LocalWatchSignal> get signals => _watcher.signals;

  @override
  RemoteFileSystem get fs => _fs;

  /// Starts (or retargets) this channel's watch on [path] (03 §7.5).
  /// Validation fails loud and typed before any backend is touched: an
  /// empty path is a caller bug, a missing root answers the local funnel's
  /// `notFound` (operation `inspect`, like the open seam's `resolve`), and
  /// a non-directory target is refused (deliberately leaving any installed
  /// watch untouched — note a failing request still supersedes older
  /// in-flight watches, since every request claims the generation at
  /// entry). Last request wins: every watch-control request on
  /// this channel bumps the generation, and a validation that resumes
  /// superseded answers typed `cancelled` instead of installing — an
  /// acknowledged unwatch can never be undone by an older, slower watch.
  /// A close processed mid-validation still answers the typed
  /// channel-closed refusal (checked before and after the awaits).
  /// The race after validation — the root vanishing before the backend
  /// arms — degrades to an immediate `lost` signal, never a silent stop.
  Future<EngineAck> watch(String path) async {
    final generation = ++_watchGeneration;
    // Fails fast before the validation I/O; the post-await recheck below
    // covers a close racing the awaits.
    if (_closed) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'watch',
        message: 'The browse channel is closed.',
      );
    }
    if (path.isEmpty) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: 'watch',
        message: 'The watch path must not be empty.',
      );
    }
    final canonical = await _fs.canonicalize(path);
    final entry = await _fs.stat(canonical);
    if (_closed) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'watch',
        message: 'The browse channel is closed.',
      );
    }
    if (_watchGeneration != generation) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: 'watch',
        message: 'The watch request was superseded by a later watch or '
            'unwatch on this channel.',
      );
    }
    if (entry.type != RemoteFileType.directory) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: 'watch',
        path: canonical,
        message: 'The watch target "$canonical" is not a directory.',
      );
    }
    await _watcher.retarget(canonical);
    return const EngineAck();
  }

  /// Releases the watch without a signal; idempotent, and the newest
  /// word on the channel's watch state — an in-flight older watch
  /// validation is superseded by the generation bump here.
  Future<void> unwatch() {
    _watchGeneration++;
    return _watcher.stop();
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void>? _closeFuture;

  Future<void> _close() async {
    _closed = true;
    _watchGeneration++;
    await _watcher.dispose();
  }

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
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

/// An incident store that forwards every mutation to the UI (03 §5's
/// incident bridge). Reads stay engine-local: the app seeds the engine with
/// its records through [EngineConfig.incidents], then persists the engine's
/// mutations from the mirror events.
final class _IncidentBridge implements IncidentStore {
  final IncidentStore _store;
  final SendPort _events;

  _IncidentBridge(this._store, this._events);

  @override
  Future<List<IncidentRecord>> load() => _store.load();

  @override
  Future<void> put(IncidentRecord record) async {
    await _store.put(record);
    _events.send(IncidentRecordStoredEvent(record: record));
  }

  @override
  Future<void> removeFor(String serverId, PoolKey endpoint) async {
    await _store.removeFor(serverId, endpoint);
    _events.send(
      IncidentRecordRemovedEvent(serverId: serverId, endpoint: endpoint),
    );
  }

  @override
  Future<void> removeAllFor(String serverId) async {
    await _store.removeAllFor(serverId);
    // No endpoint means bulk erase: the mirror must read a null endpoint as
    // "delete every record for this serverId", never as an unmatched lookup.
    _events.send(IncidentRecordRemovedEvent(serverId: serverId));
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
