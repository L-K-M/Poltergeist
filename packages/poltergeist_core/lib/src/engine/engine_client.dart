import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart';

import '../connection/connection_manager.dart';
import 'engine_host.dart';
import 'protocol.dart';

/// The prompt facet of the engine protocol (03 §5): the surface the app's
/// prompt coordinator consumes. An interface so UI wiring and its tests
/// depend on the contract, not on the isolate plumbing behind it.
abstract interface class PromptBridge {
  /// Prompts the engine is waiting on the UI to answer.
  Stream<EnginePromptEvent> get prompts;

  /// The engine withdrew a prompt: its dialog closes without answering.
  Stream<PromptDismissedEvent> get promptDismissals;

  /// Answers an open prompt; un-appliable replies are ignored by contract.
  void replyPrompt(String promptId, EnginePromptKind kind, PromptReply reply);
}

/// The app controls eligibility; socket work stays behind the engine port.
/// Calls send commands in invocation order, before their futures complete.
abstract interface class ProbeBridge {
  /// Subscribe before sending targets: replacement snapshots precede the ack.
  /// Broadcast stream; closes on engine death.
  Stream<ProbeStatusesEvent> get probeStatuses;

  /// Supplies seen, permitted favorites; config ids identify bookmarks.
  /// Replacing targets does not grant permission to start probing (03 §3.4).
  Future<void> setProbeTargets(List<ServerConfig> targets);

  /// Run only while foregrounded and enabled; the engine starts paused.
  Future<void> setProbeActivity(ProbeActivity activity);
}

/// The UI-side facade over the engine isolate (03 §5): Future/Stream APIs
/// mirror the connection surface, requests correlate by requestId, and every
/// event fan-out is a broadcast stream. Controllers talk only to this class;
/// sockets, prompts, and the pool stay engine-side.
class EngineClient implements PromptBridge, ProbeBridge {
  late final Isolate _isolate;
  final _booted = Completer<SendPort>();
  final _terminated = Completer<void>();

  final _pending = <int, Completer<EngineResult>>{};
  final _serverStates = <String, StreamController<ServerStatus>>{};
  final _directoryWatches = <int, StreamController<DirectoryWatchEvent>>{};
  final _prompts = StreamController<EnginePromptEvent>.broadcast();
  final _promptDismissals = StreamController<PromptDismissedEvent>.broadcast();
  final _hostKeyPins = StreamController<HostKeyPinnedEvent>.broadcast();
  final _incidentChanges = StreamController<IncidentStoreEvent>.broadcast();
  final _progress = StreamController<TransferProgressBatchEvent>.broadcast();
  final _recoveryFailures = StreamController<RecoveryFailedEvent>.broadcast();
  final _connectLog = StreamController<ConnectionLogEvent>.broadcast();
  final _probeStatuses = StreamController<ProbeStatusesEvent>.broadcast();

  final ReceivePort _events;
  final ReceivePort _control;
  SendPort? _commands;
  int _nextRequestId = 1;
  bool _shuttingDown = false;
  bool _closed = false;

  EngineClient._() : _events = ReceivePort(), _control = ReceivePort() {
    _events.listen(_onEvent);
    _control.listen(_onControl);
  }

  /// Spawns the engine isolate and delivers [config] as its first command
  /// (03 §5). Fails with a disconnected-kind [RemoteFileException] if the
  /// isolate cannot be spawned or dies before the boot handshake completes
  /// (e.g. a construction failure such as an invalid [PoolPolicy]). Later
  /// engine death surfaces through [terminated] and failed pending calls.
  static Future<EngineClient> spawn(EngineConfig config) =>
      _spawn(config, engineMain);

  /// Exercises client dispatch over real ports with a socket-free engine.
  @visibleForTesting
  static Future<EngineClient> spawnForTesting(
    EngineConfig config, {
    required void Function(SendPort) entrypoint,
  }) => _spawn(config, entrypoint);

  static Future<EngineClient> _spawn(
    EngineConfig config,
    void Function(SendPort) entrypoint,
  ) async {
    final client = EngineClient._();
    try {
      client._isolate = await Isolate.spawn(
        entrypoint,
        client._events.sendPort,
        onError: client._control.sendPort,
        onExit: client._control.sendPort,
        errorsAreFatal: true,
      );
      // An engine that dies before booting fails the spawn instead of
      // hanging on the port handshake; the losing branch's later outcome
      // is ignored by Future.any once the race is settled.
      final commands = await Future.any<SendPort>([
        client._booted.future,
        client._terminated.future.then((_) => throw _notRunning()),
      ]);
      commands.send(config);
    } on Object {
      client._terminate();
      rethrow;
    }
    return client;
  }

  /// Completes when the engine isolate is no longer serving — it died, or
  /// [shutdown] finished. Never errors.
  Future<void> get terminated => _terminated.future;

  /// Prompts the engine is waiting on the UI to answer (03 §5). Exactly one
  /// [replyPrompt] per promptId; the rendering layer owns the dialogs.
  @override
  Stream<EnginePromptEvent> get prompts => _prompts.stream;

  /// The engine withdrew a prompt: its dialog closes without answering.
  @override
  Stream<PromptDismissedEvent> get promptDismissals => _promptDismissals.stream;

  /// Host keys the engine pinned; the app persists them in its pin store.
  Stream<HostKeyPinnedEvent> get hostKeyPins => _hostKeyPins.stream;

  /// Incident-store mutations the engine made; the app mirrors them into its
  /// own persisted store (the engine holds the in-memory records it seeded
  /// from [EngineConfig.incidents]). Live-only; closes on engine death.
  Stream<IncidentStoreEvent> get incidentChanges => _incidentChanges.stream;

  /// Coalesced transfer progress (03 §5); consumed by the queue mirror (M4).
  Stream<TransferProgressBatchEvent> get progressBatches => _progress.stream;

  /// Terminal background failures for the local diagnostic consumer (D19).
  /// Subscribe before connecting; events are live and close on engine death.
  Stream<RecoveryFailedEvent> get recoveryFailures => _recoveryFailures.stream;

  /// Coalesced connect-attempt transcript lines (03 §5), rendered live during
  /// connect and retained on failure.
  Stream<ConnectionLogEvent> get connectionLog => _connectLog.stream;

  /// Live reachability snapshots; subscribe before configuring probes.
  /// Target changes clear removed/retargeted results. Closes on engine death.
  @override
  Stream<ProbeStatusesEvent> get probeStatuses => _probeStatuses.stream;

  /// Supplies only seen, permitted favorites; config ids identify bookmarks.
  /// This does not grant permission to start probing (03 §3.4).
  @override
  Future<void> setProbeTargets(List<ServerConfig> targets) async {
    await _call(
      (id) => SetProbeTargetsRequest(requestId: id, targets: targets),
    );
  }

  /// Run only while foregrounded and enabled; the engine starts paused.
  @override
  Future<void> setProbeActivity(ProbeActivity activity) async {
    await _call(
      (id) => SetProbeActivityRequest(requestId: id, activity: activity),
    );
  }

  /// The server's connection status — state plus the failure one-liner —
  /// current value first (03 §3.2). Watching again re-subscribes; dropping
  /// the last listener unsubscribes.
  Stream<ServerStatus> watchServer(String serverId) {
    // Match `_call`'s fail-fast: a dead engine must not hand out a stream
    // that neither emits nor closes (`.first` would hang forever).
    if (_closed) throw _notRunning();
    final controller = _serverStates.putIfAbsent(
      serverId,
      () => StreamController<ServerStatus>.broadcast(
        onListen: () => _fireAndForget(
          (id) => WatchServerRequest(requestId: id, serverId: serverId),
        ),
        onCancel: () => _fireAndForget(
          (id) => UnwatchServerRequest(requestId: id, serverId: serverId),
        ),
      ),
    );
    return controller.stream;
  }

  /// Opens (or rejoins) this pane-tab's browse channel (03 §3.2). Carries
  /// the server's [ServerConfig] — the engine holds no bookmark store.
  Future<EngineBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  }) async {
    final result = await _call(
      (id) => OpenBrowseChannelRequest(
        requestId: id,
        serverId: serverId,
        paneTabId: paneTabId,
        config: config,
      ),
    );
    final opened = result as BrowseChannelOpened;
    return EngineBrowseChannel._(this, opened.channelId, opened.homePath);
  }

  /// Opens a local browse channel (03 §5's engine-side seam): the engine
  /// owns the backing `LocalFileSystem` — D8 keeps dart:io off the UI
  /// isolate — and canonicalizes [rootPath] into [EngineBrowseChannel.homePath].
  /// The same [EngineBrowseChannel] surface as [openBrowseChannel]: panes
  /// list and close identically, and failures arrive as typed
  /// [RemoteFileException]s from the local funnel (03 §2.2). [rootPath] is
  /// the initial home, not a sandbox — like pool channels, listings may
  /// navigate anywhere the user's OS permissions allow (confinement is
  /// 03 §7.2's app-side `ScopedPathAccess` seam, pass-through on v1
  /// desktop). [rootPath] should be absolute (or `~`-anchored) — a
  /// relative root resolves against the engine's working directory.
  /// Only a missing root is guaranteed to open (`notFound` surfaces at
  /// first listing); a root under an unreadable ancestor fails the open
  /// typed. No server state exists to watch, so there is no stream to
  /// subscribe first.
  Future<EngineBrowseChannel> openLocalChannel({
    required String rootPath,
  }) async {
    final result = await _call(
      (id) => OpenLocalBrowseChannelRequest(requestId: id, rootPath: rootPath),
    );
    final opened = result as BrowseChannelOpened;
    return EngineBrowseChannel._(this, opened.channelId, opened.homePath);
  }

  /// ServerIds with live transports — feeds the probe loop's sync reads.
  Future<Set<String>> connectedServerIds() async {
    final result = await _call(
      (id) => ConnectedServerIdsRequest(requestId: id),
    );
    return (result as ServerIdsListed).ids.toSet();
  }

  /// Drops this serverId's pool reference (03 §3.5). A credential prompt it
  /// owns is dismissed engine-side.
  Future<void> disconnectServer(String serverId) async {
    await _call(
      (id) => DisconnectServerRequest(requestId: id, serverId: serverId),
    );
  }

  /// Deletes the bookmark's connection state and trust-incident records
  /// (owner decision 3a). The engine's incident store emits the mirroring
  /// [IncidentStoreEvent]s for the app to persist.
  ///
  /// The id's [watchServer] stream closes — here and engine-side — because
  /// the bookmark no longer exists. Both sides forget it even when the
  /// request fails, mirroring the host's own cascade `finally`.
  Future<void> removeBookmark(String serverId) async {
    try {
      await _call(
        (id) => RemoveBookmarkRequest(requestId: id, serverId: serverId),
      );
    } finally {
      unawaited(_serverStates.remove(serverId)?.close());
    }
  }

  /// Answers an open prompt. Fire-and-forget by contract (03 §5): replies
  /// the engine cannot apply are ignored — there is deliberately no
  /// feedback channel.
  @override
  void replyPrompt(String promptId, EnginePromptKind kind, PromptReply reply) {
    _fireAndForget(
      (id) => PromptReplyRequest(
        requestId: id,
        promptId: promptId,
        kind: kind,
        reply: reply,
      ),
    );
  }

  /// Orderly shutdown: open prompts dismissed, servers disconnected, the
  /// isolate killed. Idempotent. The ack races engine death: an engine that
  /// exits without acking (or with an internal error) still ends shutdown —
  /// the kill is a no-op on an already-dead isolate.
  Future<void> shutdown() async {
    if (_shuttingDown) return _terminated.future;
    if (_closed) return;
    _shuttingDown = true;

    try {
      await Future.any([
        _call((id) => ShutdownRequest(requestId: id)),
        _terminated.future,
      ]);
    } on Object {
      // Engine death, a protocol fault, or a failed ack — cleanup below is
      // the same for all three.
    }
    _terminate();
    _isolate.kill(priority: Isolate.immediate);
  }

  // ── Wiring ─────────────────────────────────────────────────────────────

  void _onEvent(Object? message) {
    // Bootstrap: the engine's command port is the one pre-config message.
    if (message is SendPort) {
      _commands = message;
      if (!_booted.isCompleted) _booted.complete(message);
      return;
    }

    switch (message) {
      case final ResponseEvent event:
        _complete(event);
      case final ServerStateEvent event:
        _serverStates[event.serverId]?.add(
          ServerStatus(event.state, detail: event.detail),
        );
      case final DirectoryWatchEvent event:
        _directoryWatches[event.channelId]?.add(event);
      case final ConnectionLogEvent event:
        _connectLog.add(event);
      case final ProbeStatusesEvent event:
        _probeStatuses.add(event);
      case final EnginePromptEvent event:
        _prompts.add(event);
      case final PromptDismissedEvent event:
        _promptDismissals.add(event);
      case final HostKeyPinnedEvent event:
        _hostKeyPins.add(event);
      case final IncidentStoreEvent event:
        _incidentChanges.add(event);
      case final TransferProgressBatchEvent event:
        _progress.add(event);
      case final RecoveryFailedEvent event:
        _recoveryFailures.add(event);
      default:
        // Same-package protocol drift: no client can produce this message.
        // Fail closed rather than wedge every pending call.
        _failPending(StateError('Unknown engine event: $message'));
        _terminate();
    }
  }

  void _onControl(Object? message) {
    // onError delivers [error, stack]; onExit delivers [exitCode]. Either
    // way the engine is no longer serving, and _terminate is idempotent —
    // shutdown() races its ack against [terminated], so even the expected
    // post-shutdown exit runs cleanup instead of being ignored (an engine
    // that exits without acking must never wedge shutdown).
    _terminate();
  }

  void _complete(ResponseEvent event) {
    final completer = _pending.remove(event.requestId);
    if (completer == null || completer.isCompleted) return;

    final result = event.result;
    if (result is EngineError) {
      completer.completeError(result.toException());
    } else {
      completer.complete(result);
    }
  }

  /// Sends a request and returns its reply future; fails immediately when
  /// the engine is gone.
  Future<EngineResult> _call(EngineRequest Function(int requestId) build) {
    final request = _fireAndForget(build);
    if (request == null) throw _notRunning();

    final completer = Completer<EngineResult>();
    _pending[request.requestId] = completer;
    return completer.future;
  }

  /// Sends a request without waiting for a reply; null when closed.
  EngineRequest? _fireAndForget(EngineRequest Function(int requestId) build) {
    final commands = _commands;
    if (_closed || commands == null) return null;

    final request = build(_nextRequestId++);
    commands.send(request);
    return request;
  }

  /// Invalidation signals for watched local directories, one broadcast
  /// controller per open channel (03 §7.5). Closed with its channel and
  /// all at once on engine death.
  StreamController<DirectoryWatchEvent> _directoryWatchController(
    int channelId,
  ) => _directoryWatches.putIfAbsent(
    channelId,
    () => StreamController<DirectoryWatchEvent>.broadcast(),
  );

  void _closeDirectoryWatch(int channelId) {
    unawaited(_directoryWatches.remove(channelId)?.close());
  }

  static RemoteFileException _notRunning() => const RemoteFileException(
    kind: RemoteFileErrorKind.disconnected,
    operation: 'engine',
    message: 'The engine is not running.',
  );

  void _failPending(Object error) {
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  void _terminate() {
    if (_closed) return;
    _closed = true;

    _failPending(_notRunning());
    for (final controller in _serverStates.values) {
      controller.close();
    }
    _serverStates.clear();
    for (final controller in _directoryWatches.values) {
      unawaited(controller.close());
    }
    _directoryWatches.clear();
    _prompts.close();
    _promptDismissals.close();
    _hostKeyPins.close();
    _incidentChanges.close();
    _progress.close();
    _recoveryFailures.close();
    _connectLog.close();
    _probeStatuses.close();
    _events.close();
    _control.close();
    if (!_terminated.isCompleted) _terminated.complete();
  }
}

/// One pane-tab's browse channel, mirrored UI-side (03 §3.2): VFS calls
/// become engine requests on this channel; errors arrive as
/// [RemoteFileException]s like any local VFS call.
class EngineBrowseChannel {
  final EngineClient _client;
  final int channelId;

  /// `canonicalize('.')` at open — the server-side home.
  final String homePath;

  /// Cached at construction: after [close] removes the map entry, later
  /// `directoryChanges` accesses must keep returning the same (closed)
  /// stream — a putIfAbsent per access would mint a fresh dead controller
  /// that never emits and never completes.
  late final StreamController<DirectoryWatchEvent> _watchEvents;

  EngineBrowseChannel._(this._client, this.channelId, this.homePath) {
    _watchEvents = _client._directoryWatchController(channelId);
  }

  /// Invalidation signals for this channel's watched directory (03 §7.5):
  /// [DirectoryWatchSignal.changed] after the engine-side 300 ms debounce,
  /// [DirectoryWatchSignal.lost] immediately when the watch dies. The
  /// stream is broadcast, per channel, live across retargets, and closes
  /// on channel close and engine death. Local channels only —
  /// [watchDirectory] on a pool channel fails with the typed local-only
  /// refusal.
  Stream<DirectoryWatchEvent> get directoryChanges => _watchEvents.stream;

  /// Starts (or retargets) this channel's single non-recursive watch on
  /// [path] (03 §7.5); the engine canonicalizes it. One watch per channel:
  /// a second call replaces the first, and stale signals from the replaced
  /// watch never name the new binding. Fails typed for an empty path, a
  /// missing root, or a non-directory target.
  Future<void> watchDirectory(String path) async {
    await _client._call(
      (id) => WatchLocalDirectoryRequest(
        requestId: id,
        channelId: channelId,
        path: path,
      ),
    );
  }

  /// Releases this channel's watch; idempotent. Closing the channel or
  /// the engine releases it too.
  Future<void> unwatchDirectory() async {
    await _client._call(
      (id) => UnwatchLocalDirectoryRequest(requestId: id, channelId: channelId),
    );
  }

  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final result = await _client._call(
      (id) =>
          ListDirectoryRequest(requestId: id, channelId: channelId, path: path),
    );
    return (result as DirectoryListed).entries;
  }

  /// Closes the channel; idempotent. A dead engine has closed every
  /// channel by definition — disconnected errors complete normally so
  /// disposal code can close defensively during teardown races.
  Future<void> close() async {
    try {
      await _client._call(
        (id) => CloseBrowseChannelRequest(requestId: id, channelId: channelId),
      );
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.disconnected) rethrow;
    } finally {
      // The engine released its watch with the channel; the mirrored
      // stream completes for every listener regardless of how the close
      // resolved.
      _client._closeDirectoryWatch(channelId);
    }
  }
}
