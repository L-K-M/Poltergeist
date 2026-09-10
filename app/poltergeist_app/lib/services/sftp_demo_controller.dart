import 'dart:async';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'application_error_reporter.dart';
import 'prompt_coordinator.dart';
import 'uuid.dart';

/// The pane-tab id the demo browse channel registers under (03 §3.2).
const kSftpDemoPaneTabId = 'demo';

/// The transcript line bound mirrored from seance_core's
/// `SshConnectionLog` (and the status panel's display cap). Public so the
/// boundary tests derive their fixtures from the real constant.
const kSftpDemoTranscriptLineCap = 400;

/// The engine surface the demo connect flow consumes: the [EngineClient]
/// public API the slice needs (EngineClient implements it). Widget tests
/// substitute a scripted fake, so the debug surface is drivable without
/// spawning an isolate.
abstract interface class SftpDemoEngine implements PromptBridge {
  Stream<ServerStatus> watchServer(String serverId);
  Stream<ConnectionLogEvent> get connectionLog;
  Future<SftpDemoBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  });
  Future<void> disconnectServer(String serverId);

  /// Orderly engine shutdown; the spawner owns the isolate's lifetime.
  Future<void> shutdown();
}

/// One opened browse channel, mirrored UI-side: EngineClient's
/// `EngineBrowseChannel` wrapped, or a fake in tests.
abstract interface class SftpDemoBrowseChannel {
  /// `canonicalize('.')` at open — the server-side home.
  String get homePath;

  Future<List<RemoteFileEntry>> listDirectory(String path);
  Future<void> close();
}

typedef SftpDemoEngineFactory = Future<SftpDemoEngine> Function();

/// Spawns the real engine isolate and hands it out as the demo seam.
Future<SftpDemoEngine> spawnSftpDemoEngine() async =>
    _EngineClientAdapter(await EngineClient.spawn(const EngineConfig()));

/// Wraps an already-spawned [EngineClient] as the demo seam. The isolate
/// leg of the widget suite drives a scripted engine entrypoint through
/// real ports; production uses [spawnSftpDemoEngine]. Disposing the
/// returned controller shuts this client down — the wrapper is not for
/// engines shared with other consumers.
SftpDemoEngine sftpDemoEngineOf(EngineClient client) =>
    _EngineClientAdapter(client);

/// Connection facts entered on the debug form. Secrets are never typed
/// here: the engine's credential resolution prompts at connect time and
/// the coordinator's vault-first flow answers it (03 §3.2).
class SftpDemoConnectFacts {
  const SftpDemoConnectFacts({
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
  });

  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;
}

/// Drives the debug-only connect → SFTP channel → `listDirectory` flow
/// (07 §3.3's demo surface): builds an ephemeral bookmark through the
/// pinned model for the entered facts (no second server model, D2/D3),
/// connects through the engine's pool, opens the browse channel, and
/// lists the canonicalized home.
///
/// Throwaway: M3 replaces this surface with the real panes.
class SftpDemoController extends ChangeNotifier {
  SftpDemoController({
    required this.engine,
    required this.navigatorKey,
    ApplicationErrorReporter? errorReporter,
  }) : _errorReporter = errorReporter ?? ApplicationErrorReporter() {
    _prompts = PromptCoordinator(
      engine: engine,
      navigatorKey: navigatorKey,
      errorReporter: _errorReporter,
    );
  }

  final SftpDemoEngine engine;

  /// The demo page's own navigator: prompts render inside the demo route,
  /// so teardown can never pop an unrelated app page (02 §10).
  final GlobalKey<NavigatorState> navigatorKey;

  final ApplicationErrorReporter _errorReporter;
  late final PromptCoordinator _prompts;
  StreamSubscription<ServerStatus>? _states;
  StreamSubscription<ConnectionLogEvent>? _logSubscription;

  // The panel mounts a frame after the connect starts, and the engine's
  // live streams keep no replay (03 §5: subscribe before connecting) —
  // the controller is the session's diagnostic owner: it subscribes at
  // [start]/connect time, buffers, and replays to late listeners the way
  // the engine's own watchServer replays current state.
  final _transcript = <ConnectionLogEvent>[];
  int _bufferedLines = 0;
  late final StreamController<ServerStatus> _statusReplay =
      StreamController<ServerStatus>.broadcast(
        onListen: () {
          final status = _status;
          if (status != null) _statusReplay.add(status);
        },
      );
  late final StreamController<ConnectionLogEvent> _logReplay =
      StreamController<ConnectionLogEvent>.broadcast(
        onListen: () {
          for (final event in _transcript) {
            _logReplay.add(event);
          }
        },
      );
  SftpDemoBrowseChannel? _channel;
  SftpDemoConnectFacts? _lastFacts;
  String? _serverId;
  ServerStatus? _status;
  List<RemoteFileEntry> _entries = const [];
  String? _failureDetail;
  bool _connecting = false;
  bool _listing = false;
  bool _disposed = false;
  int _attempt = 0;

  /// Starts consuming the engine's prompt streams (idempotent). The demo
  /// route calls this once mounted; dialogs render on [navigatorKey].
  /// The transcript subscription also starts here — before any connect —
  /// because the live log stream keeps no replay (03 §5: subscribe first).
  void start() {
    if (_disposed) return;
    _prompts.start();
    _logSubscription ??= engine.connectionLog.listen(
      _onLogLine,
      // Transcript fan-out is diagnostic; a fault must not kill the demo,
      // but it must still surface through the error reporter.
      onError: (Object error, StackTrace stackTrace) {
        if (_disposed) return;
        _errorReporter.report(error, stackTrace);
      },
    );
  }

  void _onLogLine(ConnectionLogEvent event) {
    // Dispose closes _logReplay; a racing event must not throw into the
    // zone through the closed controller.
    if (_disposed) return;
    // Mirror the source log's 400-line bound (and the panel's cap),
    // drop-oldest. The newest event always stays — an event that alone
    // exceeds the cap must not evict itself and empty the replay buffer.
    _bufferedLines += event.lines.length;
    _transcript.add(event);
    while (_bufferedLines > kSftpDemoTranscriptLineCap &&
        _transcript.length > 1) {
      _bufferedLines -= _transcript.removeAt(0).lines.length;
    }
    _logReplay.add(event);
  }

  String? get serverId => _serverId;
  ServerStatus? get status => _status;
  bool get isConnecting => _connecting;
  bool get isListing => _listing;
  List<RemoteFileEntry> get entries => _entries;

  /// The summarized failure one-liner (connect or listing); the panel
  /// renders the same failure through its state stream with the live
  /// transcript, and this keeps the one-liner on the listing surface.
  String? get failureDetail => _failureDetail;

  /// The server's status stream for the panel (current value first).
  Stream<ServerStatus> get states => _statusReplay.stream;

  /// The live transcript stream; the panel filters by serverId.
  Stream<ConnectionLogEvent> get connectLog => _logReplay.stream;

  /// Connects with [facts] and lists the home directory. Re-entrancy
  /// guarded: one attempt at a time; a stale attempt's completions drop
  /// themselves on the attempt generation (09 §3.1/§3.2). A previous
  /// session's channel and server reference close first, so reconnects
  /// cannot orphan engine-side sessions.
  Future<void> connect(SftpDemoConnectFacts facts) async {
    if (_disposed || _connecting) return;

    // The previous session (a completed connect, or a failed one that
    // minted a serverId) must not linger: every connect mints a fresh
    // bookmark id (03 §3.5), so the old reference is closed, never
    // reused. Awaited so the retry's open cannot interleave with the
    // old channel's close.
    final staleChannel = _channel;
    final staleServerId = _serverId;
    _channel = null;
    if (staleChannel != null || staleServerId != null) {
      await _closeChannelAndServer(staleChannel, staleServerId);
      // The await above is the first suspension: dispose may have run
      // during it, and a resumed connect must not notify a disposed
      // notifier (09 §3.1).
      if (_disposed) return;
    }

    final attempt = ++_attempt;
    _lastFacts = facts;
    final now = DateTime.now().toUtc();
    final bookmark = _ephemeralBookmark(facts, now);
    _serverId = bookmark.id;
    _status = null;
    _entries = const [];
    _failureDetail = null;
    _listing = false;
    _connecting = true;
    notifyListeners();

    unawaited(_states?.cancel());

    final config = ServerConfig(
      id: bookmark.id,
      label: bookmark.label,
      host: facts.host,
      port: facts.port,
      username: facts.username,
      authMethod: facts.authMethod,
      createdAt: now.millisecondsSinceEpoch,
      updatedAt: now.millisecondsSinceEpoch,
    );

    try {
      // Prompt answering and transcript buffering must be live before any
      // open; the route normally ran start() already, and it is
      // idempotent. Inside the guarded block so a seam fault here reaches
      // the catch below instead of escaping connect() unhandled.
      start();

      // The subscription lives inside the guarded block: a synchronous
      // throw from watchServer/listen (e.g. a dead engine seam) must
      // reach the catch below, not wedge _connecting.
      _states = engine
          .watchServer(bookmark.id)
          .listen(
            (status) {
              if (_disposed || attempt != _attempt) return;
              _status = status;
              _statusReplay.add(status);
              notifyListeners();
            },
            // The log subscription guards the same way: a status-stream
            // fault must not become an unhandled async error.
            onError: (Object error, StackTrace stackTrace) {
              if (_disposed || attempt != _attempt) return;
              _errorReporter.report(error, stackTrace);
            },
          );
      final channel = await engine.openBrowseChannel(
        serverId: bookmark.id,
        paneTabId: kSftpDemoPaneTabId,
        config: config,
      );
      if (_disposed || attempt != _attempt) {
        // Cleanup failures must not escape as unhandled async errors.
        // The server reference follows unless dispose already tore it
        // down: a disconnect-during-connect left the late-opened session
        // for this id behind, and nothing else tracks it. NOTE: disconnect
        // may already have issued disconnectServer for this id — the
        // engine treats unknown ids as a no-op, never an error.
        unawaited(
          _closeChannelAndServer(channel, _disposed ? null : bookmark.id),
        );
        return;
      }
      _channel = channel;
      _connecting = false;
      await _listDirectory(channel, attempt);
    } on RemoteFileException catch (error) {
      if (_disposed || attempt != _attempt) return;
      _connecting = false;
      _failureDetail = error.message;
      notifyListeners();
    } on Object catch (error, stackTrace) {
      // The protocol wraps engine failures as RemoteFileExceptions, but a
      // non-VFS fault (a broken seam, an isolate death mid-call) must not
      // wedge the re-entrancy guard with _connecting stuck true — unwedge
      // before anything that could throw.
      if (_disposed || attempt != _attempt) return;
      _connecting = false;
      _failureDetail = error.toString();
      _errorReporter.report(error, stackTrace);
      notifyListeners();
    }
  }

  /// Re-runs the last connect (the panel's retry affordance).
  Future<void> retry() async {
    final facts = _lastFacts;
    if (facts == null) return;
    await connect(facts);
  }

  /// Disconnects the demo session and returns to the idle form: the
  /// serverId, entries, failure one-liner, and recorded status clear (the
  /// transcript stays with the session's log owner until the next
  /// connect). A connect in flight drops itself.
  Future<void> disconnect() async {
    if (_disposed) return;
    final serverId = _serverId;

    // Invalidate the in-flight attempt so its completions drop themselves
    // (09 §3.1); the engine-side connect keeps running until teardown.
    _attempt++;
    unawaited(_states?.cancel());
    _states = null;
    _status = null;
    _connecting = false;
    _listing = false;
    _entries = const [];
    _failureDetail = null;

    final channel = _channel;
    _channel = null;
    // The teardown below uses the captured id; clearing the getter stops
    // a later connect/dispose from double-disconnecting the same session.
    _serverId = null;

    // Notify only once the session refs are cleared: listeners observe
    // the fully idle state, never a torn one.
    notifyListeners();

    if (channel == null && serverId == null) return;
    await _closeChannelAndServer(channel, serverId);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _attempt++;
    unawaited(_states?.cancel());
    unawaited(_logSubscription?.cancel());
    unawaited(_statusReplay.close());
    unawaited(_logReplay.close());
    _prompts.dispose();
    unawaited(_teardown());
    super.dispose();
  }

  Future<void> _listDirectory(
    SftpDemoBrowseChannel channel,
    int attempt,
  ) async {
    _listing = true;
    notifyListeners();

    try {
      final entries = await channel.listDirectory(channel.homePath);
      if (_disposed || attempt != _attempt) return;
      _entries = List.unmodifiable(entries);
      _failureDetail = null;
    } on RemoteFileException catch (error) {
      if (_disposed || attempt != _attempt) return;
      _failureDetail = error.message;
    } finally {
      if (!_disposed && attempt == _attempt) {
        _listing = false;
        notifyListeners();
      }
    }
  }

  /// Closes a browse channel and drops its server reference; cleanup
  /// failures are reported, never thrown, so teardown always completes.
  Future<void> _closeChannelAndServer(
    SftpDemoBrowseChannel? channel,
    String? serverId,
  ) async {
    if (channel != null) {
      try {
        await channel.close();
      } on Object catch (error, stackTrace) {
        _errorReporter.report(error, stackTrace);
      }
    }
    if (serverId == null) return;
    try {
      await engine.disconnectServer(serverId);
    } on Object catch (error, stackTrace) {
      _errorReporter.report(error, stackTrace);
    }
  }

  /// Closes the browse channel and shuts the engine down; dispose cannot
  /// block, so teardown is fire-and-forget (idempotent both sides).
  Future<void> _teardown() async {
    final channel = _channel;
    final serverId = _serverId;
    _channel = null;
    await _closeChannelAndServer(channel, serverId);
    try {
      await engine.shutdown();
    } on Object catch (error, stackTrace) {
      _errorReporter.report(error, stackTrace);
    }
  }

  /// Builds an ephemeral remotePath bookmark through the pinned model:
  /// the serverId is the bookmark's id (03 §3.5) and the connection
  /// facts live in its `EmbeddedHostIdentity` (04 §2.1). Never persisted.
  Bookmark _ephemeralBookmark(SftpDemoConnectFacts facts, DateTime now) {
    return Bookmark(
      id: uuidV4(),
      kind: BookmarkKind.remotePath,
      label: '${facts.username}@${facts.host}',
      server: BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: facts.host,
          port: facts.port,
          username: facts.username,
          authMethod: facts.authMethod,
        ),
      ),
      // Connect canonicalizes home (04 §2.1); '/' is the demo's root.
      remotePath: '/',
      sortKey: uuidV4(),
      createdAt: now,
      updatedAt: now,
    );
  }
}

/// The production seam: the real engine isolate behind [SftpDemoEngine].
class _EngineClientAdapter implements SftpDemoEngine {
  _EngineClientAdapter(this._client);

  final EngineClient _client;

  @override
  Stream<EnginePromptEvent> get prompts => _client.prompts;

  @override
  Stream<PromptDismissedEvent> get promptDismissals => _client.promptDismissals;

  @override
  void replyPrompt(String promptId, EnginePromptKind kind, PromptReply reply) =>
      _client.replyPrompt(promptId, kind, reply);

  @override
  Stream<ServerStatus> watchServer(String serverId) =>
      _client.watchServer(serverId);

  @override
  Stream<ConnectionLogEvent> get connectionLog => _client.connectionLog;

  @override
  Future<SftpDemoBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  }) async {
    final channel = await _client.openBrowseChannel(
      serverId: serverId,
      paneTabId: paneTabId,
      config: config,
    );
    return _EngineChannelAdapter(channel);
  }

  @override
  Future<void> disconnectServer(String serverId) =>
      _client.disconnectServer(serverId);

  @override
  Future<void> shutdown() => _client.shutdown();
}

/// Wraps the mirrored UI-side channel for the demo seam.
class _EngineChannelAdapter implements SftpDemoBrowseChannel {
  _EngineChannelAdapter(this._channel);

  final EngineBrowseChannel _channel;

  @override
  String get homePath => _channel.homePath;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) =>
      _channel.listDirectory(path);

  @override
  Future<void> close() => _channel.close();
}
