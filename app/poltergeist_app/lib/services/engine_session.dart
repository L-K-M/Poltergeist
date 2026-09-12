import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'application_error_reporter.dart';
import 'bookmark_store.dart';
import 'connection_state_bridge.dart';
import 'file_stores.dart';
import 'identity_audit_log.dart';
import 'identity_file_reader.dart';
import 'pane_engine_lanes.dart';
import 'prompt_coordinator.dart';

/// File names inside the app-support directory, one store per file (03 §6):
/// pin and incident storage stay app-owned; the engine seeds from them at
/// spawn and mirrors every mutation back.
const _pinStoreFileName = 'host_keys.json';
const _incidentStoreFileName = 'incidents.json';
const _identityAuditLogFileName = 'identity_reads.jsonl';

/// The pane-tab id the blocked-key review registers its browse channel
/// under (03 §3.2): a review connect is not a pane session, and the id
/// exists only for attribution.
const kHostKeyReviewPaneTabId = 'review';

/// The engine surface the app composition consumes: [EngineClient]'s
/// connection, prompt, probe, and trust lanes. Production code names the
/// concrete client nowhere but here; tests substitute a scripted fake, so
/// the composition is drivable without an isolate.
abstract interface class AppEngine implements PromptBridge, ProbeBridge, PaneEngineLanes {
  /// Host keys the engine pinned; the app persists them (one store owner).
  Stream<HostKeyPinnedEvent> get hostKeyPins;

  /// Trust-incident mutations the engine decided; the app persists them.
  Stream<IncidentStoreEvent> get incidentChanges;

  /// One server's connection status, current value first (03 §3.2).
  @override
  Stream<ServerStatus> watchServer(String serverId);

  /// Terminal recovery failures, independent of any watch (03 §3.3).
  Stream<RecoveryFailedEvent> get recoveryFailures;

  /// Live connect transcript lines (03 §5).
  Stream<ConnectionLogEvent> get connectionLog;

  @override
  Future<AppBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  });

  @override
  Future<void> disconnectServer(String serverId);

  /// Orderly engine shutdown (03 §5: orderly, then kill).
  Future<void> shutdown();
}

/// One opened browse channel, mirrored UI-side. [EngineClient]'s channel
/// implements the same shape; the review flow needs only [close].
abstract interface class AppBrowseChannel {
  String get homePath;

  Future<List<RemoteFileEntry>> listDirectory(String path);

  Future<void> close();
}

typedef AppEngineSpawner = Future<AppEngine> Function(EngineConfig config);

/// The endpoint identity a connect dials with: the bookmark's embedded
/// identity mapped through the pinned model (04 §2.1 — the vault
/// reference and the "reference, don't store" key path cross so
/// credential resolution can answer). Shared by the review connect and
/// the panes' remote bindings. The returned config's id is the bookmark
/// id, so callers must pass that same value as the engine's serverId.
/// A bookmark without an embedded identity fails fast here — never an
/// empty-host dial (both call sites list identity-backed rows only).
ServerConfig serverConfigForBookmark(Bookmark bookmark) {
  final identity = bookmark.server?.identity;
  if (identity == null) {
    throw ArgumentError.value(
      bookmark.id,
      'bookmark.id',
      'bookmark has no embedded server identity',
    );
  }
  return ServerConfig(
    id: bookmark.id,
    label: bookmark.label,
    host: identity.host,
    port: identity.port,
    username: identity.username,
    authMethod: identity.authMethod,
    secretRef: identity.secretRef,
    identityFilePath: identity.identityFilePath,
    createdAt: bookmark.createdAt.millisecondsSinceEpoch,
    updatedAt: bookmark.updatedAt.millisecondsSinceEpoch,
  );
}

/// The production spawner: the real engine isolate behind [AppEngine].
Future<AppEngine> spawnAppEngine(EngineConfig config) async =>
    _EngineClientAppEngine(await EngineClient.spawn(config));

final class _EngineClientAppEngine implements AppEngine {
  _EngineClientAppEngine(this._client);

  final EngineClient _client;

  @override
  Stream<EnginePromptEvent> get prompts => _client.prompts;

  @override
  Stream<PromptDismissedEvent> get promptDismissals =>
      _client.promptDismissals;

  @override
  void replyPrompt(String promptId, EnginePromptKind kind, PromptReply reply) =>
      _client.replyPrompt(promptId, kind, reply);

  @override
  Stream<HostKeyPinnedEvent> get hostKeyPins => _client.hostKeyPins;

  @override
  Stream<IncidentStoreEvent> get incidentChanges => _client.incidentChanges;

  @override
  Stream<ServerStatus> watchServer(String serverId) =>
      _client.watchServer(serverId);

  @override
  Stream<RecoveryFailedEvent> get recoveryFailures =>
      _client.recoveryFailures;

  @override
  Stream<ConnectionLogEvent> get connectionLog => _client.connectionLog;

  @override
  Stream<ProbeStatusesEvent> get probeStatuses => _client.probeStatuses;

  @override
  Future<void> setProbeTargets(List<ServerConfig> targets) =>
      _client.setProbeTargets(targets);

  @override
  Future<void> setProbeActivity(ProbeActivity activity) =>
      _client.setProbeActivity(activity);

  @override
  Future<AppBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  }) async => _EngineClientChannel(
    await _client.openBrowseChannel(
      serverId: serverId,
      paneTabId: paneTabId,
      config: config,
    ),
  );

  @override
  Future<AppBrowseChannel> openLocalChannel({required String rootPath})
    async => _EngineClientChannel(
      await _client.openLocalChannel(rootPath: rootPath),
    );

  @override
  Future<void> disconnectServer(String serverId) =>
      _client.disconnectServer(serverId);

  @override
  Future<void> shutdown() => _client.shutdown();
}

/// [EngineClient]'s channel behind the app composition's seam (the same
/// three members; interfaces stay nominal across the port).
final class _EngineClientChannel implements AppBrowseChannel {
  _EngineClientChannel(this._channel);

  final EngineBrowseChannel _channel;

  @override
  String get homePath => _channel.homePath;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) =>
      _channel.listDirectory(path);

  @override
  Future<void> close() => _channel.close();
}

/// The app's long-lived engine owner: spawns once at startup with the
/// app-owned persistence seeded together (03 §5's `EngineConfig` — pins
/// and incidents cross as one message, audit finding A), answers its
/// prompts through one app-level coordinator, mirrors its trust mutations
/// back into the stores, and shuts it down when the app exits.
///
/// ```
/// FileHostKeyStore ──all()───┐
/// FileIncidentStore ─load()──┤
///                            ▼
///                     EngineConfig (both seeds)
///                            ▼
///               EngineClient.spawn ──► AppEngine
///                            │
///     ┌──────────────────────┼──────────────────────┐
///     ▼                      ▼                      ▼
/// PromptCoordinator    pin/incident mirrors    ConnectionStateBridge
/// (dialogs on the     (engine decides,        (the Connections
///  root navigator)     the app stores)          surface's lanes)
/// ```
///
/// The engine decides, the app stores: the mirrors write what the engine
/// decided and never send anything back, so a mirrored event can never
/// re-seed the engine.
final class EngineSession {
  EngineSession._({
    required AppEngine engine,
    required this._pinStore,
    required this._incidentStore,
    required this._bookmarks,
    required this._errors,
    required GlobalKey<NavigatorState> navigatorKey,
    required GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey,
    required IdentityFileReader identityReader,
  }) : _engine = engine {
    // One prompt coordinator per engine (02 §10): a second subscriber
    // would render every prompt twice.
    _prompts = PromptCoordinator(
      engine: engine,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      identityReader: identityReader,
      errorReporter: _errors,
    );
    // Prompts subscribe before the session is returned: a connect that
    // raises one can only come from a caller, and no caller exists yet —
    // the mirrors join in the same step so no lane opens unwatched.
    _prompts.start();
    _pinMirror = _engine.hostKeyPins.listen(_onPinPinned);
    _incidentMirror = _engine.incidentChanges.listen(_onIncidentChange);
  }

  final AppEngine _engine;
  final HostKeyStore _pinStore;
  final IncidentStore _incidentStore;
  final BookmarkRepository _bookmarks;
  final ApplicationErrorReporter _errors;
  late final PromptCoordinator _prompts;

  StreamSubscription<HostKeyPinnedEvent>? _pinMirror;
  StreamSubscription<IncidentStoreEvent>? _incidentMirror;

  /// Pin-store writes serialize through this tail: the ported
  /// [FileHostKeyStore] does not serialize internally, and stream events
  /// do not await their handlers — two pins landing in one flush window
  /// must not lose one to a read-modify-write race.
  Future<void> _pinTail = Future<void>.value();

  /// Incident-mirror writes join a tail of their own: store events do
  /// not await their handlers, and mirror mutations — like the engine's
  /// own unawaited writes — must observe issue order against the
  /// store's serialized chain (a removal issued after a newer store must
  /// never overtake it).
  Future<void> _incidentTail = Future<void>.value();

  bool _reviewInFlight = false;
  Future<void>? _shutdownFuture;

  /// The one prompt coordinator for this engine (02 §10: dialogs never
  /// stack, one coordinator per engine — a second subscriber would render
  /// every prompt twice). Started at construction.
  PromptCoordinator get prompts => _prompts;

  /// The Connections surface's state lanes: a stable instance across
  /// rebuilds, because the shell keys its controller lifecycle on seam
  /// identity.
  late final ConnectionStateBridge connectionLanes = _AppConnectionLanes(
    _engine,
  );

  /// The browsing panes' engine lanes (03 §6's PaneController seam): the
  /// two channel opens, the per-server state lane, and the disconnect
  /// the pane banner cancels recovery through. Stable across rebuilds
  /// for the same reason as [connectionLanes].
  late final PaneEngineLanes paneLanes = _engine;

  void _onPinPinned(HostKeyPinnedEvent event) {
    _pinTail = _pinTail
        .then((_) => _pinStore.put(event.key))
        .then<void>((_) {}, onError: (Object error, StackTrace stackTrace) {
          // A failed write is reported, never thrown into the stream, and
          // must not break the chain for later pins.
          _errors.report(error, stackTrace);
        });
  }

  void _onIncidentChange(IncidentStoreEvent event) {
    // Removals apply idempotently (both shipped stores treat an absent
    // record as a no-op), including for a record the app just seeded that
    // the engine dropped because its pin was gone.
    _incidentTail = _incidentTail.then((_) {
      final Future<void> operation = switch (event) {
        IncidentRecordStoredEvent(:final record) => _incidentStore.put(record),
        IncidentRecordRemovedEvent(:final serverId, :final endpoint) =>
          endpoint == null
              ? _incidentStore.removeAllFor(serverId)
              : _incidentStore.removeFor(serverId, endpoint),
      };
      return operation;
    }).then<void>((_) {}, onError: (Object error, StackTrace stackTrace) {
      // A failed write is reported, never thrown into the stream, and
      // must not break the chain for later mutations.
      _errors.report(error, stackTrace);
    });
  }

  /// Forwards the app lifecycle. Only [AppLifecycleState.detached] — the
  /// app is exiting — matters here: the session owns no probe activity
  /// (the demo session owns the only probe wiring, 03 §3.4), so hidden
  /// states have nothing to pause.
  void forwardLifecycle(AppLifecycleState? state) {
    if (state == AppLifecycleState.detached) {
      unawaited(shutdown());
    }
  }

  /// Leads a blocked server to the changed-key review (D18): the review is
  /// the pool's own prompt, raised by a connect attempt through this
  /// engine with prompting enabled — never a re-pin, never a silent lift.
  ///
  /// On approval the pin and incident mirrors have already persisted the
  /// outcomes; on decline the row's state lane carries the block (the
  /// user's answer, not a fault). Either way the reference is dropped —
  /// a review is not a session.
  Future<void> reviewBlockedHostKey(String serverId) async {
    if (_shutdownFuture != null || _reviewInFlight) return;
    _reviewInFlight = true;
    try {
      final bookmarks = await _bookmarks.load();
      // Recheck after the await: shutdown may have started while the
      // store read was in flight (09 §3.1).
      if (_shutdownFuture != null) return;

      Bookmark? bookmark;
      for (final candidate in bookmarks) {
        if (candidate.id == serverId) {
          bookmark = candidate;
          break;
        }
      }
      final identity = bookmark?.server?.identity;
      if (bookmark == null || identity == null) return;

      try {
        final reviewConfig = serverConfigForBookmark(bookmark);
        final channel = await _engine.openBrowseChannel(
          serverId: reviewConfig.id,
          paneTabId: kHostKeyReviewPaneTabId,
          config: reviewConfig,
        );
        // Approved or the pinned key returned: close the channel and let
        // the finally below drop the reference.
        try {
          await channel.close();
        } on Object catch (error, stackTrace) {
          _errors.report(error, stackTrace);
        }
      } on RemoteFileException {
        // The review failed the connect (a decline keeps the block; a
        // network failure carries its own state-lane detail): the row is
        // the user-facing channel, so this is not reported as a fault.
      } on Object catch (error, stackTrace) {
        // Non-VFS faults (a dying engine, a broken seam) are reported.
        _errors.report(error, stackTrace);
      } finally {
        try {
          await _engine.disconnectServer(serverId);
        } on Object catch (error, stackTrace) {
          _errors.report(error, stackTrace);
        }
      }
    } on Object catch (error, stackTrace) {
      // A fault before the review connect (the bookmark store read) is
      // reported like every other unexpected fault — never rethrown to a
      // fire-and-forget caller.
      _errors.report(error, stackTrace);
    } finally {
      _reviewInFlight = false;
    }
  }

  /// Awaits the pending mirror writes (pin and incident tails). Called
  /// by the app's exit hook — the one framework-awaited path — so the
  /// last trust decision is durable before the process exits. Kept
  /// separate from [shutdown]: awaiting the tails inside the shutdown
  /// closure deadlocks flutter_test's teardown zone (see its doc), while
  /// this plain await of the tails completes everywhere.
  Future<void> flushWrites() => Future.wait([_pinTail, _incidentTail]);

  /// Orderly engine shutdown, idempotent: prompts close, mirrors cancel,
  /// the engine stops (03 §5: orderly, then kill). The mirror
  /// cancellations are fire-and-forget — they only stop store writes, so
  /// nothing downstream depends on their completion.
  ///
  /// The write tails ([_pinTail], [_incidentTail]) are deliberately NOT
  /// awaited here: an awaited instance-field future as this closure's
  /// first suspension deadlocks flutter_test's teardown zone (reproduced
  /// in isolation — the identical test passes without the await and
  /// hangs with it, even with an already-completed `Future.value` tail),
  /// and no production exit path awaits this future anyway (the
  /// lifecycle forward is unawaited; `onExitRequested` returns without
  /// gating on it). Queued mirror writes are app-side file operations
  /// that complete independently of the engine isolate and drain while
  /// the process lives — the same durability window every persisted
  /// store here has.
  Future<void> shutdown() {
    final pending = _shutdownFuture;
    if (pending != null) return pending;
    return _shutdownFuture = () async {
      try {
        _prompts.dispose();
      } on Object catch (error, stackTrace) {
        // A throwing coordinator teardown must not skip the engine's
        // own shutdown.
        _errors.report(error, stackTrace);
      }
      unawaited(_pinMirror?.cancel());
      unawaited(_incidentMirror?.cancel());
      _pinMirror = null;
      _incidentMirror = null;
      try {
        await _engine.shutdown();
      } on Object {
        // EngineClient.shutdown is already fail-safe; even a throwing
        // seam must complete the session's own teardown.
      }
    }();
  }
}

/// Builds the production engine session over the app-support directory
/// (main.dart's wiring; tests substitute the spawner and a temp
/// directory). Returns null — after reporting — when the isolate cannot
/// spawn: the app still runs, with every surface reading "no engine"
/// instead of failing to boot.
///
/// [pinStore] and [incidentStore] default to the app-support file stores;
/// widget tests inject the in-memory pair, whose reads complete without
/// real IO inside the test zone's fake async.
Future<EngineSession?> startEngineSession({
  required String supportDirectoryPath,
  required BookmarkRepository bookmarks,
  required GlobalKey<NavigatorState> navigatorKey,
  GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey,
  AppEngineSpawner spawn = spawnAppEngine,
  HostKeyStore? pinStore,
  IncidentStore? incidentStore,
  void Function(Object error, StackTrace)? onError,
}) async {
  final errors = onError == null
      ? ApplicationErrorReporter()
      : ApplicationErrorReporter(sink: onError);
  final separator = Platform.pathSeparator;
  final pinsStore =
      pinStore ??
      FileHostKeyStore(File('$supportDirectoryPath$separator$_pinStoreFileName'));
  final incidentsStore =
      incidentStore ??
      FileIncidentStore(
        File('$supportDirectoryPath$separator$_incidentStoreFileName'),
        // Load failures are local diagnostics, never telemetry (D19).
        onLoadError: (error) => errors.report(error, StackTrace.current),
      );

  // Both seeds are read before the spawn so they cross as one message:
  // an incident never reaches the engine without the pin list it names
  // (audit finding A). Each store read is fail-safe by its own contract —
  // unreadable storage seeds empty, never blocks startup — and any
  // contract violation (an unexpected fault type out of a store read, a
  // failing spawn) reports and returns null: the app boots engine-less
  // rather than dying before its first frame.
  final List<HostKey> pins;
  final List<IncidentRecord> incidents;
  try {
    pins = await pinsStore.all();
    incidents = await incidentsStore.load();
  } on Object catch (error, stackTrace) {
    errors.report(error, stackTrace);
    return null;
  }

  final AppEngine engine;
  try {
    engine = await spawn(
      EngineConfig(hostKeyPins: pins, incidents: incidents),
    );
  } on Object catch (error, stackTrace) {
    errors.report(error, stackTrace);
    return null;
  }

  // The session object itself is guarded too: a throwing coordinator
  // construction must not leak the freshly spawned isolate behind an
  // escaped exception — the caller sees null, the engine dies.
  try {
    return EngineSession._(
      engine: engine,
      pinStore: pinsStore,
      incidentStore: incidentsStore,
      bookmarks: bookmarks,
      errors: errors,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      identityReader: IdentityFileReader(
        IdentityAuditLog(
          File('$supportDirectoryPath$separator$_identityAuditLogFileName'),
        ),
      ),
    );
  } on Object catch (error, stackTrace) {
    errors.report(error, stackTrace);
    try {
      await engine.shutdown();
    } on Object {
      // Best effort: the isolate dies with the process regardless.
    }
    return null;
  }
}

/// The Connections surface's two state lanes over [AppEngine].
final class _AppConnectionLanes implements ConnectionStateBridge {
  _AppConnectionLanes(this._engine);

  final AppEngine _engine;

  @override
  Stream<ServerStatus> watchServer(String serverId) =>
      _engine.watchServer(serverId);

  @override
  Stream<RecoveryFailedEvent> get recoveryFailures =>
      _engine.recoveryFailures;
}
