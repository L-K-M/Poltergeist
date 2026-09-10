import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/application_error_reporter.dart';
import 'package:poltergeist_app/services/probe_controller.dart';
import 'package:poltergeist_app/services/probe_settings_store.dart';
import 'package:poltergeist_app/services/sftp_demo_controller.dart';
import 'package:poltergeist_app/ui/demo/sftp_demo_view.dart';
import 'package:poltergeist_app/ui/probe_status_dot.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

const _commandButtonKey = ValueKey('command.$kSftpDemoCommandId');

const _scriptedEntries = [
  RemoteFileEntry(
    path: '/home/deploy/docs',
    name: 'docs',
    type: RemoteFileType.directory,
  ),
  RemoteFileEntry(
    path: '/home/deploy/notes.txt',
    name: 'notes.txt',
    type: RemoteFileType.file,
    size: 12,
  ),
];

/// A scripted browse channel: fixed entries, an optional listing failure.
class FakeDemoBrowseChannel implements SftpDemoBrowseChannel {
  FakeDemoBrowseChannel({
    required this.homePath,
    List<RemoteFileEntry>? entries,
  }) : entries = entries ?? const [];

  @override
  final String homePath;

  List<RemoteFileEntry> entries;
  Object? listFailure;
  int listCalls = 0;
  int closeCalls = 0;
  final requestedPaths = <String>[];

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    requestedPaths.add(path);
    listCalls++;
    final failure = listFailure;
    if (failure != null) throw failure;
    return entries;
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

/// The engine protocol simulated socket-free: emits scripted prompts and
/// answers them through the real coordinator, records replies and calls.
class FakeSftpDemoEngine implements SftpDemoEngine {
  final promptsController = StreamController<EnginePromptEvent>.broadcast();
  final dismissalsController =
      StreamController<PromptDismissedEvent>.broadcast();
  final statesController = StreamController<ServerStatus>.broadcast();
  final logController = StreamController<ConnectionLogEvent>.broadcast();
  final probeStatusesController =
      StreamController<ProbeStatusesEvent>.broadcast(sync: true);
  final _pendingReplies = <String, Completer<PromptReply>>{};

  final replies = <(String, EnginePromptKind, PromptReply)>[];
  final openCalls =
      <({String serverId, String paneTabId, ServerConfig config})>[];

  /// Probe commands in invocation order.
  final probeCalls = <String>[];
  List<ServerConfig> probeTargets = const [];

  /// The status emitted for every target after [setProbeTargets]; null
  /// leaves snapshots unscripted so targets stay unknown.
  ProbeStatus? autoProbeStatus = ProbeStatus.online;

  /// True if every probe command ran while a snapshot listener was live
  /// (the #55 ordering rule: subscribe before sending).
  bool probeCommandsSawListener = true;

  /// Emitted (and awaited) in order inside [openBrowseChannel].
  List<EnginePromptEvent> promptScript = const [];

  /// Blocks every open until completed (the re-entrancy guard test).
  Completer<void>? openGate;

  /// Transcript lines every open emits — the "during connect" material.
  List<String> openLogLines = const ['Connecting to example.com:22'];

  Object? openFailure;
  FakeDemoBrowseChannel? channel;
  int disconnectCalls = 0;
  final disconnectIds = <String>[];
  int shutdownCalls = 0;

  /// Blocks every disconnectServer until completed (the stale-cleanup
  /// ordering tests).
  Completer<void>? disconnectGate;

  @override
  Stream<EnginePromptEvent> get prompts => promptsController.stream;

  @override
  Stream<PromptDismissedEvent> get promptDismissals =>
      dismissalsController.stream;

  @override
  void replyPrompt(String promptId, EnginePromptKind kind, PromptReply reply) {
    replies.add((promptId, kind, reply));
    final completer = _pendingReplies.remove(promptId);
    if (completer != null && !completer.isCompleted) completer.complete(reply);
  }

  @override
  Stream<ServerStatus> watchServer(String serverId) => statesController.stream;

  @override
  Stream<ConnectionLogEvent> get connectionLog => logController.stream;

  @override
  Stream<ProbeStatusesEvent> get probeStatuses =>
      probeStatusesController.stream;

  @override
  Future<void> setProbeTargets(List<ServerConfig> targets) {
    _recordProbe('targets:${targets.map((target) => target.id).join(',')}');
    probeTargets = targets;
    final snapshot = autoProbeStatus;
    if (snapshot != null) {
      // Like the real port, the replacement snapshot precedes the ack
      // without reentering a synchronous stream.
      scheduleMicrotask(() {
        if (!probeStatusesController.isClosed) {
          probeStatusesController.add(
            ProbeStatusesEvent(
              statuses: {for (final target in targets) target.id: snapshot},
            ),
          );
        }
      });
    }
    return Future.value();
  }

  @override
  Future<void> setProbeActivity(ProbeActivity activity) {
    _recordProbe(activity.name);
    return Future.value();
  }

  void _recordProbe(String call) {
    probeCalls.add(call);
    probeCommandsSawListener =
        probeCommandsSawListener && probeStatusesController.hasListener;
  }

  @override
  Future<SftpDemoBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  }) async {
    openCalls.add((serverId: serverId, paneTabId: paneTabId, config: config));
    final repliesAtOpenStart = replies.length;
    statesController.add(const ServerStatus(ServerConnectionState.connecting));
    logController.add(
      ConnectionLogEvent(serverId: serverId, lines: openLogLines),
    );
    final gate = openGate;
    if (gate != null) await gate.future;
    for (final prompt in promptScript) {
      promptsController.add(prompt);
      await _waitForReply(prompt.promptId);
    }
    final failure = openFailure;
    if (failure != null) {
      // The engine's teardown fan-out: a declined changed key ends
      // blocked; every other failure ends disconnected with the detail.
      final declinedChangedKey = promptScript.any(
        (prompt) =>
            prompt.kind == EnginePromptKind.hostKeyChanged &&
            replies
                .skip(repliesAtOpenStart)
                .any(
                  (reply) =>
                      reply.$1 == prompt.promptId &&
                      reply.$3 is HostKeyPromptReply &&
                      !(reply.$3 as HostKeyPromptReply).accepted,
                ),
      );
      statesController.add(
        ServerStatus(
          declinedChangedKey
              ? ServerConnectionState.blocked
              : ServerConnectionState.disconnected,
          detail: failure is RemoteFileException ? failure.message : null,
        ),
      );
      throw failure;
    }
    final channel = this.channel;
    if (channel == null) throw StateError('no browse channel scripted');
    statesController.add(const ServerStatus(ServerConnectionState.connected));
    return channel;
  }

  Future<PromptReply> _waitForReply(String promptId) {
    assert(
      !_pendingReplies.containsKey(promptId),
      'promptScript reuses promptId "$promptId"; the earlier reply is dropped',
    );
    final completer = Completer<PromptReply>();
    _pendingReplies[promptId] = completer;
    return completer.future;
  }

  @override
  Future<void> disconnectServer(String serverId) async {
    disconnectCalls++;
    disconnectIds.add(serverId);
    final gate = disconnectGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
  }

  Future<void> close() async {
    // A test that fails while a scripted prompt is unanswered must not
    // leave the pending open suspended through teardown. The gate also
    // completes first — the resumed open's stream adds must never hit
    // the just-closed controllers below.
    final pending = _pendingReplies.values.toList();
    _pendingReplies.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        // A suspended open awaits this future; an abandoned one must not
        // leak an unhandled error either way.
        completer.future.ignore();
        completer.completeError(
          StateError('engine closed while awaiting a scripted reply'),
        );
      }
    }
    final gate = openGate;
    if (gate != null && !gate.isCompleted) {
      // No open may actually be awaiting the gate (a test that gated
      // without submitting); the error must not leak unhandled.
      gate.future.ignore();
      gate.completeError(StateError('engine closed while the open was gated'));
    }
    final disconnectGate = this.disconnectGate;
    if (disconnectGate != null && !disconnectGate.isCompleted) {
      disconnectGate.complete();
    }
    await promptsController.close();
    await dismissalsController.close();
    await statesController.close();
    await logController.close();
    await probeStatusesController.close();
  }
}

/// In-memory probe settings for widget tests: the demo session's
/// persistence seam without file I/O.
final class _FakeProbeSettings implements ProbeSettings {
  _FakeProbeSettings({this.global = ProbePreference.enabled});

  ProbePreference global;
  final calls = <String>[];
  final servers = <String, ({String host, int port, bool connected})>{};

  @override
  Future<ProbePreference> loadGlobalPreference() async => global;

  @override
  Future<ProbeServerFacts> loadServerFacts({
    required String serverId,
    required String host,
    required int port,
  }) async {
    final facts = servers[serverId];
    // Mirrors the real store: case-insensitive host binding, exact port.
    if (facts == null ||
        facts.host.toLowerCase() != host.toLowerCase() ||
        facts.port != port) {
      return ProbeServerFacts.unseen;
    }
    return ProbeServerFacts(
      exposure: FavoriteExposure.seen,
      connected: facts.connected
          ? FavoriteConnection.connected
          : FavoriteConnection.neverConnected,
    );
  }

  @override
  Future<void> markSeen({
    required String serverId,
    required String host,
    required int port,
  }) async {
    calls.add('markSeen:$serverId');
    servers[serverId] = (
      host: host,
      port: port,
      connected: servers[serverId]?.connected ?? false,
    );
  }

  @override
  Future<void> markConnected({
    required String serverId,
    required String host,
    required int port,
  }) async {
    calls.add('markConnected:$serverId');
    servers[serverId] = (host: host, port: port, connected: true);
  }

  @override
  Future<void> removeServer(String serverId) async {
    calls.add('removeServer:$serverId');
    servers.remove(serverId);
  }
}

/// A fake whose transcript seam is dead: start() must fail through the
/// connect guard, not escape it.
class _BrokenLogEngine extends FakeSftpDemoEngine {
  @override
  Stream<ConnectionLogEvent> get connectionLog =>
      throw StateError('dead log seam');
}

EnginePromptEvent _hostKeyFirstUse(String promptId) => EnginePromptEvent(
  promptId: promptId,
  kind: EnginePromptKind.hostKeyFirstUse,
  data: const HostKeyPromptData(
    host: 'example.com',
    port: 22,
    keyType: 'ssh-ed25519',
    fingerprintSha256: 'SHA256:presented',
  ),
);

EnginePromptEvent _hostKeyChanged(String promptId) => EnginePromptEvent(
  promptId: promptId,
  kind: EnginePromptKind.hostKeyChanged,
  data: const HostKeyPromptData(
    host: 'example.com',
    port: 22,
    keyType: 'ssh-ed25519',
    fingerprintSha256: 'SHA256:changed',
    pinnedFingerprintSha256: 'SHA256:original',
  ),
);

/// Pumps the demo route inside a localized MaterialApp over a fake engine.
Future<void> pumpDemoView(
  WidgetTester tester,
  FakeSftpDemoEngine engine, {
  ProbeSettings? probeSettings,
}) async {
  // Desktop-sized viewport: the panel below the form must stay on screen
  // for its transcript to be tappable.
  tester.view.physicalSize = const Size(1180, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  addTearDown(engine.close);
  final controller = SftpDemoController(
    engine: engine,
    navigatorKey: GlobalKey<NavigatorState>(),
    probeSettings: probeSettings ?? _FakeProbeSettings(),
  );
  addTearDown(controller.dispose);
  controller.start();

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SftpDemoView(controller),
    ),
  );
  await tester.pump();
}

/// Builds a fake engine with the common successful-connect script.
FakeSftpDemoEngine successfulEngine({FakeDemoBrowseChannel? channel}) {
  return FakeSftpDemoEngine()
    ..channel = channel ?? FakeDemoBrowseChannel(homePath: '/home/deploy');
}

Future<FakeSftpDemoEngine> pumpApp(
  WidgetTester tester, {
  required bool debugDemoEnabled,
  ProbeSettings? probeSettings,
}) async {
  assert(
    debugDemoEnabled || probeSettings == null,
    'probeSettings must not be provided when the demo is gated off',
  );
  final engine = FakeSftpDemoEngine();
  addTearDown(engine.close);
  await tester.pumpWidget(
    PoltergeistApp(
      debugDemoEnabled: debugDemoEnabled,
      // A gated-off app must not receive a factory (the app asserts it).
      sftpDemoEngineFactory: debugDemoEnabled ? () async => engine : null,
      probeSettings: debugDemoEnabled
          ? probeSettings ?? _FakeProbeSettings()
          : null,
    ),
  );
  await tester.pump();
  return engine;
}

/// Fills the demo form and taps Connect.
Future<void> submitDemoForm(
  WidgetTester tester, {
  String host = 'example.com',
  String port = '22',
  String username = 'deploy',
  AuthMethod authMethod = AuthMethod.agent,
}) async {
  await tester.enterText(find.byKey(const ValueKey('sftp-demo-host')), host);
  await tester.enterText(find.byKey(const ValueKey('sftp-demo-port')), port);
  await tester.enterText(
    find.byKey(const ValueKey('sftp-demo-username')),
    username,
  );
  if (authMethod != AuthMethod.agent) {
    assert(
      authMethod == AuthMethod.password,
      'submitDemoForm only knows how to select Agent and Password',
    );
    await tester.tap(find.byKey(const ValueKey('sftp-demo-auth')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Password').last);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('sftp-demo-connect')));
  await tester.pump();
}

/// Pumps in bounded steps until [finder] matches — the pending view's
/// spinner keeps pumpAndSettle from settling, so fixed-step pumping is
/// the only way to wait on prompts and transcript lines without racing
/// machine speed.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration step = const Duration(milliseconds: 50),
  int maxSteps = 40,
}) async {
  for (var i = 0; i < maxSteps; i++) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('pumpUntilFound timed out waiting for: $finder');
}

/// Opens the panel's collapsed transcript (children build lazily —
/// Séance's `_ConnectionLogView` starts collapsed too) and waits for the
/// given line to render.
Future<void> expandTranscript(WidgetTester tester, String expectedLine) async {
  await tester.tap(find.text('Connection log'));
  await pumpUntilFound(tester, find.textContaining(expectedLine));
}

/// A socket-free engine entrypoint running in a real spawned isolate:
/// answers the browse open with a fixed channel and a fixed listing,
/// emitting transcript/state events along the way.
void scriptedDemoEngineMain(SendPort events) {
  final commands = ReceivePort();
  events.send(commands.sendPort);

  commands.listen((message) {
    switch (message) {
      case EngineConfig():
        break;
      case final OpenBrowseChannelRequest request:
        events.send(
          ServerStateEvent(
            serverId: request.serverId,
            state: ServerConnectionState.connecting,
          ),
        );
        events.send(
          ConnectionLogEvent(
            serverId: request.serverId,
            lines: ['Connecting to demo.example.com'],
          ),
        );
        events.send(
          ServerStateEvent(
            serverId: request.serverId,
            state: ServerConnectionState.connected,
          ),
        );
        events.send(
          ResponseEvent(
            requestId: request.requestId,
            result: const BrowseChannelOpened(
              channelId: 1,
              homePath: '/home/deploy',
            ),
          ),
        );
      case final ListDirectoryRequest request:
        events.send(
          ResponseEvent(
            requestId: request.requestId,
            result: const DirectoryListed(entries: _scriptedEntries),
          ),
        );
      case final CloseBrowseChannelRequest request:
        events.send(
          ResponseEvent(requestId: request.requestId, result: EngineAck()),
        );
      case final DisconnectServerRequest request:
        events.send(
          ResponseEvent(requestId: request.requestId, result: EngineAck()),
        );
      // The demo session's probe wiring drives these; the script acks
      // without emitting snapshots, leaving probe truth unknown.
      case final SetProbeTargetsRequest request:
        events.send(
          ResponseEvent(requestId: request.requestId, result: EngineAck()),
        );
      case final SetProbeActivityRequest request:
        events.send(
          ResponseEvent(requestId: request.requestId, result: EngineAck()),
        );
      case final ShutdownRequest request:
        events.send(
          ResponseEvent(requestId: request.requestId, result: EngineAck()),
        );
      // Watch/unwatch are fire-and-forget in the protocol; the scripted
      // engine emits the state events above and needs no forwarding.
      case WatchServerRequest():
        break;
      case UnwatchServerRequest():
        break;
      default:
        // A new protocol message reaching this script means the demo
        // seam grew a dependency the script does not model — fail the
        // isolate loudly instead of hanging the waiting call.
        throw StateError(
          'scriptedDemoEngineMain received an unhandled message: $message',
        );
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('debug gating and command registration', () {
    testWidgets('the demo entry renders only when gated', (tester) async {
      tester.view.physicalSize = const Size(1180, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpApp(tester, debugDemoEnabled: false);
      expect(find.byKey(_commandButtonKey), findsNothing);

      await pumpApp(tester, debugDemoEnabled: true);
      expect(find.byKey(_commandButtonKey), findsOneWidget);
      expect(find.text('Demo: SFTP listing'), findsOneWidget);
    });

    testWidgets('the registered command opens the demo and tears down', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1180, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final engine = await pumpApp(tester, debugDemoEnabled: true);
      final channel = FakeDemoBrowseChannel(homePath: '/home/deploy');
      engine.channel = channel;
      await tester.tap(find.byKey(_commandButtonKey));
      await tester.pumpAndSettle();
      await submitDemoForm(tester);
      await tester.pumpAndSettle();

      expect(find.text('SFTP listing demo'), findsOneWidget);
      expect(find.byKey(const ValueKey('sftp-demo-host')), findsOneWidget);
      expect(engine.shutdownCalls, 0);

      // Closing the demo route ends the session: prompts close, the
      // browse channel closes, and the spawned engine shuts down.
      await tester.tap(find.byKey(const ValueKey('sftp-demo-close')));
      await tester.pumpAndSettle();

      expect(find.text('SFTP listing demo'), findsNothing);
      expect(engine.shutdownCalls, 1);
      expect(channel.closeCalls, 1);
    });

    testWidgets(
      'system back dismisses an open prompt before closing the demo',
      (tester) async {
        tester.view.physicalSize = const Size(1180, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final engine =
            successfulEngine(
                channel: FakeDemoBrowseChannel(
                  homePath: '/home/deploy',
                  entries: _scriptedEntries,
                ),
              )
              ..promptScript = [_hostKeyFirstUse('b1')]
              ..openGate = Completer<void>();
        addTearDown(
          () =>
              engine.openGate!.isCompleted ? null : engine.openGate!.complete(),
        );
        addTearDown(engine.close);
        await tester.pumpWidget(
          PoltergeistApp(
            debugDemoEnabled: true,
            sftpDemoEngineFactory: () async => engine,
            probeSettings: _FakeProbeSettings(),
          ),
        );
        await tester.pump();

        await tester.tap(find.byKey(_commandButtonKey));
        await tester.pumpAndSettle();
        await submitDemoForm(tester);
        engine.openGate!.complete();
        await pumpUntilFound(tester, find.text('Unknown host key'));
        expect(find.text('Unknown host key'), findsOneWidget);

        // Back first dismisses the prompt on the demo's nested navigator;
        // the demo route stays mounted.
        final root = tester.state<NavigatorState>(find.byType(Navigator).first);
        await root.maybePop();
        await tester.pumpAndSettle();

        expect(find.text('Unknown host key'), findsNothing);
        expect(find.text('SFTP listing demo'), findsOneWidget);
        expect(engine.replies, hasLength(1));

        // A second back (nothing left to dismiss) closes the demo route
        // and ends the session.
        await root.maybePop();
        await tester.pumpAndSettle();

        expect(find.text('SFTP listing demo'), findsNothing);
        expect(engine.shutdownCalls, 1);
      },
    );

    testWidgets('the toolbar tolerates a narrow window', (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        PoltergeistApp(
          debugDemoEnabled: true,
          sftpDemoEngineFactory: () async {
            final engine = FakeSftpDemoEngine();
            addTearDown(engine.close);
            return engine;
          },
          probeSettings: _FakeProbeSettings(),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(_commandButtonKey), findsOneWidget);
      await tester.tap(find.byKey(_commandButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('SFTP listing demo'), findsOneWidget);
    });

    testWidgets('a double tap cannot start two demo sessions', (tester) async {
      tester.view.physicalSize = const Size(1180, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      var spawns = 0;
      final engine = FakeSftpDemoEngine();
      addTearDown(engine.close);
      await tester.pumpWidget(
        PoltergeistApp(
          debugDemoEnabled: true,
          sftpDemoEngineFactory: () async {
            spawns++;
            return engine;
          },
          probeSettings: _FakeProbeSettings(),
        ),
      );
      await tester.pump();

      // Two taps in the same frame: the rebuild that disables the button
      // has not happened yet, so only the in-flight guard can stop the
      // second session from spawning.
      await tester.tap(find.byKey(_commandButtonKey));
      await tester.tap(find.byKey(_commandButtonKey));
      await tester.pumpAndSettle();

      expect(spawns, 1);
      expect(find.text('SFTP listing demo'), findsOneWidget);
    });

    testWidgets('a failed engine spawn reports and never opens the demo', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1180, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        PoltergeistApp(
          debugDemoEnabled: true,
          sftpDemoEngineFactory: () async =>
              throw StateError('isolate boot failure'),
          probeSettings: _FakeProbeSettings(),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(_commandButtonKey));
      await tester.pumpAndSettle();

      expect(
        find.text('The connection engine could not start.'),
        findsOneWidget,
      );
      expect(find.text('SFTP listing demo'), findsNothing);

      // The spawn failure is also reported as an app error (the app's
      // default sink); the widget test consumes it here.
      expect(tester.takeException(), isA<StateError>());
    });
  });

  group('the connect flow drives prompts through the coordinator', () {
    testWidgets('host-key first use: transcript live, trust, then listing', (
      tester,
    ) async {
      final channel = FakeDemoBrowseChannel(
        homePath: '/home/deploy',
        entries: _scriptedEntries,
      );
      final engine = successfulEngine(channel: channel)
        ..promptScript = [_hostKeyFirstUse('p1')]
        ..openGate = Completer<void>();
      addTearDown(
        () => engine.openGate!.isCompleted ? null : engine.openGate!.complete(),
      );
      await pumpDemoView(tester, engine);

      await submitDemoForm(tester);

      // The transcript renders while the connect is still pending (the
      // gate holds the open before the prompt appears, so the panel is
      // tappable).
      await expandTranscript(tester, 'Connecting to example.com:22');
      expect(
        find.textContaining('Connecting to example.com:22'),
        findsOneWidget,
      );

      engine.openGate!.complete();
      await pumpUntilFound(tester, find.text('Unknown host key'));
      expect(find.text('Unknown host key'), findsOneWidget);

      await tester.tap(find.text('Trust and connect'));
      await tester.pumpAndSettle();

      final (promptId, kind, reply) = engine.replies.single;
      expect(promptId, 'p1');
      expect(kind, EnginePromptKind.hostKeyFirstUse);
      expect(reply, isA<HostKeyPromptReply>());
      expect((reply as HostKeyPromptReply).accepted, isTrue);
      expect(find.text('2 entries'), findsOneWidget);
      expect(find.text('docs'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);

      // The listing targets the channel's canonicalized home path.
      expect(channel.requestedPaths, ['/home/deploy']);

      // The connection facts ride the pinned bookmark model: the config's
      // id is the ephemeral bookmark id the pool keyed on (03 §3.5).
      final open = engine.openCalls.single;
      expect(open.paneTabId, kSftpDemoPaneTabId);
      expect(open.config.host, 'example.com');
      expect(open.config.port, 22);
      expect(open.config.username, 'deploy');
      expect(open.config.authMethod, AuthMethod.agent);
      expect(open.serverId, open.config.id);
    });

    testWidgets('credential prompt collects the password', (tester) async {
      final engine =
          successfulEngine(
              channel: FakeDemoBrowseChannel(
                homePath: '/home/deploy',
                entries: _scriptedEntries,
              ),
            )
            ..promptScript = [
              const EnginePromptEvent(
                promptId: 'c1',
                kind: EnginePromptKind.credentialNeeded,
                data: CredentialPromptData(
                  host: 'example.com',
                  port: 22,
                  username: 'deploy',
                  authMethod: AuthMethod.password,
                ),
              ),
            ];
      await pumpDemoView(tester, engine);

      await submitDemoForm(tester, authMethod: AuthMethod.password);
      expect(find.text('Authentication required'), findsOneWidget);

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextField, 'Password'),
        ),
        'hunter2',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Connect'),
        ),
      );
      await tester.pumpAndSettle();

      final reply = engine.replies.single.$3 as CredentialPromptReply;
      expect(reply.password, 'hunter2');
      expect(reply.origin, CredentialOrigin.prompted);
      expect(reply.cancelled, isFalse);
      expect(find.text('2 entries'), findsOneWidget);
    });

    testWidgets('keyboard-interactive answers travel back', (tester) async {
      final engine =
          successfulEngine(
              channel: FakeDemoBrowseChannel(
                homePath: '/home/deploy',
                entries: _scriptedEntries,
              ),
            )
            ..promptScript = [
              const EnginePromptEvent(
                promptId: 'k1',
                kind: EnginePromptKind.keyboardInteractive,
                data: KeyboardInteractivePromptData(
                  name: 'Duo',
                  instruction: '',
                  prompts: ['Passcode'],
                ),
              ),
            ];
      await pumpDemoView(tester, engine);

      await submitDemoForm(tester);
      expect(find.text('Authentication'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Passcode'), '42');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();

      expect(engine.replies.single.$3, isA<KeyboardInteractivePromptReply>());
      expect(
        (engine.replies.single.$3 as KeyboardInteractivePromptReply).answers,
        ['42'],
      );
      expect(find.text('docs'), findsOneWidget);
    });

    testWidgets(
      'declining a changed key blocks: one-liner and transcript persist',
      (tester) async {
        final engine =
            successfulEngine(
                channel: FakeDemoBrowseChannel(
                  homePath: '/home/deploy',
                  entries: _scriptedEntries,
                ),
              )
              ..promptScript = [_hostKeyChanged('c2')]
              ..openLogLines = ['Offering the server key']
              ..openGate = Completer<void>()
              ..openFailure = const RemoteFileException(
                kind: RemoteFileErrorKind.other,
                operation: 'connect',
                message: 'The host key changed for example.com:22.',
              );
        addTearDown(
          () =>
              engine.openGate!.isCompleted ? null : engine.openGate!.complete(),
        );
        await pumpDemoView(tester, engine);

        await submitDemoForm(tester);

        // The transcript renders during connect, before the prompt shows.
        await expandTranscript(tester, 'Offering the server key');
        expect(find.textContaining('Offering the server key'), findsOneWidget);

        engine.openGate!.complete();
        await pumpUntilFound(tester, find.text('HOST KEY CHANGED'));
        expect(find.text('HOST KEY CHANGED'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await pumpUntilFound(tester, find.text('Connection blocked'));
        await tester.pump();

        expect(
          (engine.replies.single.$3 as HostKeyPromptReply).accepted,
          isFalse,
        );
        expect(find.text('Connection blocked'), findsOneWidget);
        expect(
          find.text('The host key changed for example.com:22.'),
          findsNWidgets(2), // panel detail + listing one-liner
        );
        expect(find.text('docs'), findsNothing);

        // The transcript rendered during connect stays visible on failure.
        expect(find.textContaining('Offering the server key'), findsOneWidget);
      },
    );

    testWidgets('a failed listing keeps the one-liner', (tester) async {
      final engine =
          successfulEngine(
              channel: FakeDemoBrowseChannel(homePath: '/home/deploy')
                ..listFailure = const RemoteFileException(
                  kind: RemoteFileErrorKind.permissionDenied,
                  operation: 'list directory',
                  message: 'Permission denied.',
                ),
            )
            ..openLogLines = ['Authentication succeeded']
            ..openGate = Completer<void>();
      addTearDown(
        () => engine.openGate!.isCompleted ? null : engine.openGate!.complete(),
      );
      await pumpDemoView(tester, engine);

      await submitDemoForm(tester);

      // The transcript renders while the connect is still pending.
      await expandTranscript(tester, 'Authentication succeeded');
      expect(find.textContaining('Authentication succeeded'), findsOneWidget);

      engine.openGate!.complete();
      await tester.pumpAndSettle();

      expect(find.text('Permission denied.'), findsOneWidget);
      expect(find.text('docs'), findsNothing);

      // The connection is healthy, so the panel hides the transcript by
      // its own connected-state contract; the session buffer keeps it
      // (covered by the replay-buffer test). Connection failures keep it
      // visible — the changed-key test above pins that.
    });
  });

  group('listing and session lifecycle', () {
    testWidgets('disconnect clears the listing and disconnects the server', (
      tester,
    ) async {
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(
          homePath: '/home/deploy',
          entries: _scriptedEntries,
        ),
      );
      await pumpDemoView(tester, engine);

      await submitDemoForm(tester);
      await tester.pumpAndSettle();
      expect(find.text('docs'), findsOneWidget);

      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();

      expect(engine.disconnectCalls, 1);
      expect(find.text('docs'), findsNothing);

      // Disconnect returns the demo to its idle form: no server, so the
      // status panel and the listing surface are gone.
      expect(find.text('Connection log'), findsNothing);
      expect(find.text('The directory is empty.'), findsNothing);
    });

    testWidgets('the form validates entry points before connecting', (
      tester,
    ) async {
      final engine = successfulEngine();
      await pumpDemoView(tester, engine);

      await tester.tap(find.byKey(const ValueKey('sftp-demo-connect')));
      await tester.pump();
      expect(find.text('Enter a host.'), findsOneWidget);
      expect(find.text('Enter a username.'), findsOneWidget);

      await submitDemoForm(tester, port: '70000');
      expect(find.text('Enter a port between 1 and 65535.'), findsOneWidget);

      expect(engine.openCalls, isEmpty);
    });

    test('a second connect during a pending attempt is ignored', () async {
      final engine = successfulEngine()..openGate = Completer<void>();
      final controller = SftpDemoController(
        engine: engine,
        navigatorKey: GlobalKey<NavigatorState>(),
        probeSettings: _FakeProbeSettings(),
      );
      addTearDown(engine.close);
      addTearDown(controller.dispose);

      const facts = SftpDemoConnectFacts(
        host: 'example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      );
      final first = controller.connect(facts);
      final second = controller.connect(facts);
      engine.openGate!.complete();
      await Future.wait([first, second]);
      await controller.disconnect();

      expect(engine.openCalls, hasLength(1));
    });

    test('a new connect closes the previous channel and server', () async {
      final firstChannel = FakeDemoBrowseChannel(homePath: '/home/deploy');
      final engine = successfulEngine(channel: firstChannel);
      final controller = SftpDemoController(
        engine: engine,
        navigatorKey: GlobalKey<NavigatorState>(),
        probeSettings: _FakeProbeSettings(),
      );
      addTearDown(engine.close);
      addTearDown(controller.dispose);

      const facts = SftpDemoConnectFacts(
        host: 'example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      );
      await controller.connect(facts);
      expect(engine.openCalls, hasLength(1));

      // Every connect mints a fresh bookmark id (03 §3.5); the previous
      // session's channel and server reference must not linger.
      engine.channel = FakeDemoBrowseChannel(homePath: '/home/deploy');
      await controller.connect(facts);
      await Future<void>.delayed(Duration.zero);

      expect(engine.openCalls, hasLength(2));
      expect(firstChannel.closeCalls, 1);
      expect(engine.disconnectCalls, 1);
    });

    test('an unexpected connect failure cannot wedge the guard', () async {
      final reported = <Object>[];
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(
          homePath: '/home/deploy',
          entries: _scriptedEntries,
        ),
      )..openFailure = StateError('engine hiccup');
      final controller = SftpDemoController(
        engine: engine,
        navigatorKey: GlobalKey<NavigatorState>(),
        probeSettings: _FakeProbeSettings(),
        errorReporter: ApplicationErrorReporter(
          sink: (error, _) => reported.add(error),
        ),
      );
      addTearDown(engine.close);
      addTearDown(controller.dispose);

      const facts = SftpDemoConnectFacts(
        host: 'example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      );
      await controller.connect(facts);

      expect(reported, contains(isA<StateError>()));
      expect(controller.isConnecting, isFalse);
      expect(controller.failureDetail, contains('engine hiccup'));

      // The next attempt is not blocked by the stale guard.
      engine.openFailure = null;
      await controller.connect(facts);
      expect(engine.openCalls, hasLength(2));
      expect(controller.entries, hasLength(2));
    });

    test(
      'an invalid-facts throw during connect cannot wedge the guard',
      () async {
        final reported = <Object>[];
        final engine = successfulEngine(
          channel: FakeDemoBrowseChannel(
            homePath: '/home/deploy',
            entries: _scriptedEntries,
          ),
        );
        final controller = SftpDemoController(
          engine: engine,
          navigatorKey: GlobalKey<NavigatorState>(),
          probeSettings: _FakeProbeSettings(),
          errorReporter: ApplicationErrorReporter(
            sink: (error, _) => reported.add(error),
          ),
        );
        addTearDown(engine.close);
        addTearDown(controller.dispose);

        // The pinned model asserts port bounds (EmbeddedHostIdentity), so a
        // debug-build throw lands in connect()'s synchronous construction
        // span. It must reach the unwedging catch instead of escaping with
        // _connecting stuck.
        const invalidFacts = SftpDemoConnectFacts(
          host: 'example.com',
          port: 0,
          username: 'deploy',
          authMethod: AuthMethod.agent,
        );
        await controller.connect(invalidFacts);

        expect(reported, contains(isA<AssertionError>()));
        expect(controller.isConnecting, isFalse);
        expect(controller.failureDetail, isNotNull);

        // The guard is unwedged: a valid connect proceeds.
        await controller.connect(
          const SftpDemoConnectFacts(
            host: 'example.com',
            port: 22,
            username: 'deploy',
            authMethod: AuthMethod.agent,
          ),
        );
        expect(engine.openCalls, hasLength(1));
        expect(controller.entries, hasLength(2));
      },
    );

    test('an unexpected listing failure keeps the one-liner', () async {
      final reported = <Object>[];
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(homePath: '/home/deploy')
          ..listFailure = StateError('listing hiccup'),
      );
      final controller = SftpDemoController(
        engine: engine,
        navigatorKey: GlobalKey<NavigatorState>(),
        probeSettings: _FakeProbeSettings(),
        errorReporter: ApplicationErrorReporter(
          sink: (error, _) => reported.add(error),
        ),
      );
      addTearDown(engine.close);
      addTearDown(controller.dispose);

      await controller.connect(
        const SftpDemoConnectFacts(
          host: 'example.com',
          port: 22,
          username: 'deploy',
          authMethod: AuthMethod.agent,
        ),
      );

      expect(reported, contains(isA<StateError>()));
      expect(controller.isConnecting, isFalse);
      expect(controller.isListing, isFalse);
      expect(controller.failureDetail, contains('listing hiccup'));
      expect(controller.entries, isEmpty);
    });

    test('a status-stream fault is reported, not unhandled', () async {
      final reported = <Object>[];
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(
          homePath: '/home/deploy',
          entries: _scriptedEntries,
        ),
      )..openGate = Completer<void>();
      final controller = SftpDemoController(
        engine: engine,
        navigatorKey: GlobalKey<NavigatorState>(),
        probeSettings: _FakeProbeSettings(),
        errorReporter: ApplicationErrorReporter(
          sink: (error, _) => reported.add(error),
        ),
      );
      addTearDown(engine.close);
      addTearDown(controller.dispose);

      const facts = SftpDemoConnectFacts(
        host: 'example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      );
      final connect = controller.connect(facts);
      // Let connect() reach its first suspension point so the status
      // subscription is guaranteed live before the fault is injected.
      await Future<void>.delayed(Duration.zero);
      engine.statesController.addError(StateError('status fault'));
      engine.openGate!.complete();
      await connect;

      expect(reported, contains(isA<StateError>()));
      expect(controller.entries, hasLength(2));
    });

    test(
      'a disconnect during a pending connect drops the late session',
      () async {
        final engine = successfulEngine()..openGate = Completer<void>();
        final controller = SftpDemoController(
          engine: engine,
          navigatorKey: GlobalKey<NavigatorState>(),
          probeSettings: _FakeProbeSettings(),
        );
        addTearDown(engine.close);
        addTearDown(controller.dispose);

        const facts = SftpDemoConnectFacts(
          host: 'example.com',
          port: 22,
          username: 'deploy',
          authMethod: AuthMethod.agent,
        );
        final connect = controller.connect(facts);
        await Future<void>.delayed(Duration.zero);
        await controller.disconnect();

        // The open completes after the disconnect: the stale attempt must
        // drop the just-established session for its serverId, or nothing
        // else ever tracks it.
        engine.openGate!.complete();
        await connect;
        await Future<void>.delayed(Duration.zero);

        expect(engine.disconnectCalls, 2);
        expect(engine.disconnectIds.toSet(), hasLength(1));
      },
    );

    test(
      'dispose during the stale-cleanup await cannot resume connect',
      () async {
        final engine = successfulEngine(
          channel: FakeDemoBrowseChannel(
            homePath: '/home/deploy',
            entries: _scriptedEntries,
          ),
        )..disconnectGate = Completer<void>();
        final controller = SftpDemoController(
          engine: engine,
          navigatorKey: GlobalKey<NavigatorState>(),
          probeSettings: _FakeProbeSettings(),
        );
        addTearDown(engine.close);
        addTearDown(controller.dispose);

        const facts = SftpDemoConnectFacts(
          host: 'example.com',
          port: 22,
          username: 'deploy',
          authMethod: AuthMethod.agent,
        );
        await controller.connect(facts);

        // The second connect's stale cleanup blocks on the fake's
        // disconnectServer; dispose lands while it is suspended.
        final second = controller.connect(facts);
        await Future<void>.delayed(Duration.zero);
        controller.dispose();
        engine.disconnectGate!.complete();

        // Completes silently: the post-await disposed guard drops the
        // resumed connect instead of notifying a disposed notifier.
        await second;

        // One disconnect from the blocked stale cleanup, one already
        // counted from the dispose teardown racing the same gate (its
        // completion lands later, after teardown resumes).
        expect(engine.disconnectCalls, 2);
      },
    );

    test(
      'a disconnect during the stale-cleanup await cannot resurrect',
      () async {
        final engine = successfulEngine(
          channel: FakeDemoBrowseChannel(
            homePath: '/home/deploy',
            entries: _scriptedEntries,
          ),
        )..disconnectGate = Completer<void>();
        final controller = SftpDemoController(
          engine: engine,
          navigatorKey: GlobalKey<NavigatorState>(),
          probeSettings: _FakeProbeSettings(),
        );
        addTearDown(engine.close);
        addTearDown(controller.dispose);

        const facts = SftpDemoConnectFacts(
          host: 'example.com',
          port: 22,
          username: 'deploy',
          authMethod: AuthMethod.agent,
        );
        await controller.connect(facts);

        // The second connect suspends on the gated stale cleanup; the
        // disconnect supersedes it. The resumed connect must drop itself
        // instead of resurrecting the cleared session (a zombie connect
        // would re-set the serverId, leave the guard stuck, and waste an
        // engine open).
        final second = controller.connect(facts);
        await Future<void>.delayed(Duration.zero);

        // disconnect() also suspends on the gated disconnectServer, so
        // the gate must complete before either future is awaited.
        final disconnect = controller.disconnect();
        await Future<void>.delayed(Duration.zero);
        engine.disconnectGate!.complete();
        await Future.wait([second, disconnect]);

        expect(controller.serverId, isNull);
        expect(controller.isConnecting, isFalse);
        expect(engine.openCalls, hasLength(1));
      },
    );

    test('the connect guard holds during the stale-cleanup await', () async {
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(
          homePath: '/home/deploy',
          entries: _scriptedEntries,
        ),
      )..disconnectGate = Completer<void>();
      final controller = SftpDemoController(
        engine: engine,
        navigatorKey: GlobalKey<NavigatorState>(),
        probeSettings: _FakeProbeSettings(),
      );
      addTearDown(engine.close);
      addTearDown(controller.dispose);

      const facts = SftpDemoConnectFacts(
        host: 'example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      );
      await controller.connect(facts);

      // The second connect suspends on the gated stale cleanup. The
      // guard is established before that suspension, so a third call in
      // the same window is refused instead of double-opening.
      final second = controller.connect(facts);
      await Future<void>.delayed(Duration.zero);
      final third = controller.connect(facts);
      engine.disconnectGate!.complete();
      await Future.wait([second, third]);

      expect(engine.openCalls, hasLength(2));
    });

    test('disconnect clears the recorded status and replays none', () async {
      final engine = successfulEngine();
      final controller = SftpDemoController(
        engine: engine,
        navigatorKey: GlobalKey<NavigatorState>(),
        probeSettings: _FakeProbeSettings(),
      );
      addTearDown(engine.close);
      addTearDown(controller.dispose);

      await controller.connect(
        const SftpDemoConnectFacts(
          host: 'example.com',
          port: 22,
          username: 'deploy',
          authMethod: AuthMethod.agent,
        ),
      );
      expect(controller.status?.state, ServerConnectionState.connected);

      await controller.disconnect();

      expect(controller.status, isNull);
      expect(controller.serverId, isNull);
      final replayed = <ServerStatus>[];
      final subscription = controller.states.listen(replayed.add);
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      expect(replayed, isEmpty);

      // disconnect() after dispose() must no-op, not notify a disposed
      // ChangeNotifier; teardown must not double-disconnect the id.
      controller.dispose();
      await controller.disconnect();
      expect(engine.disconnectCalls, 1);
    });

    test('a broken transcript seam unwedges instead of escaping', () async {
      final reported = <Object>[];
      final engine = _BrokenLogEngine();
      final controller = SftpDemoController(
        engine: engine,
        navigatorKey: GlobalKey<NavigatorState>(),
        probeSettings: _FakeProbeSettings(),
        errorReporter: ApplicationErrorReporter(
          sink: (error, _) => reported.add(error),
        ),
      );
      addTearDown(engine.close);
      addTearDown(controller.dispose);

      const facts = SftpDemoConnectFacts(
        host: 'example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      );
      // Completes normally: the guarded catch unwedges and reports.
      await controller.connect(facts);

      expect(reported, contains(isA<StateError>()));
      expect(controller.isConnecting, isFalse);
      expect(controller.failureDetail, contains('dead log seam'));
    });

    test('the transcript replay buffer serves one session at a time', () async {
      final engine = successfulEngine()..openLogLines = ['first session'];
      final controller = SftpDemoController(
        engine: engine,
        navigatorKey: GlobalKey<NavigatorState>(),
        probeSettings: _FakeProbeSettings(),
      );
      addTearDown(engine.close);
      addTearDown(controller.dispose);
      controller.start();

      const facts = SftpDemoConnectFacts(
        host: 'example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      );
      await controller.connect(facts);

      // The next session resets the buffer: a fresh listener replays only
      // the new session's transcript lines.
      engine.openLogLines = ['second session'];
      await controller.connect(facts);
      final replayed = <ConnectionLogEvent>[];
      final subscription = controller.connectLog.listen(replayed.add);
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(replayed.map((event) => event.lines).toList(), [
        ['second session'],
      ]);
    });

    test('a stale session line cannot enter the next session buffer', () async {
      final engine = successfulEngine()..openLogLines = ['first session'];
      final controller = SftpDemoController(
        engine: engine,
        navigatorKey: GlobalKey<NavigatorState>(),
        probeSettings: _FakeProbeSettings(),
      );
      addTearDown(engine.close);
      addTearDown(controller.dispose);
      controller.start();

      const facts = SftpDemoConnectFacts(
        host: 'example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      );
      await controller.connect(facts);
      final firstServerId = controller.serverId!;

      engine.openLogLines = ['second session'];
      await controller.connect(facts);

      // A line from the torn-down session, still in flight after the
      // per-session clear, must not consume the new session's buffer.
      engine.logController.add(
        ConnectionLogEvent(serverId: firstServerId, lines: ['stale line']),
      );

      final replayed = <ConnectionLogEvent>[];
      final subscription = controller.connectLog.listen(replayed.add);
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(replayed.map((event) => event.lines).toList(), [
        ['second session'],
      ]);
    });

    test('an oversized transcript event stays in the replay buffer', () async {
      final engine = successfulEngine();
      final controller = SftpDemoController(
        engine: engine,
        navigatorKey: GlobalKey<NavigatorState>(),
        probeSettings: _FakeProbeSettings(),
      );
      addTearDown(engine.close);
      addTearDown(controller.dispose);
      controller.start();

      // The buffer accepts only the current session's lines (see the
      // stale-line test), so the flood must carry the connected id.
      await controller.connect(
        const SftpDemoConnectFacts(
          host: 'example.com',
          port: 22,
          username: 'deploy',
          authMethod: AuthMethod.agent,
        ),
      );
      final serverId = controller.serverId!;

      // One event carrying more lines than the cap: drop-oldest must
      // never evict the newest event — and the replay buffer it feeds.
      final flood = ConnectionLogEvent(
        serverId: serverId,
        lines: List.filled(kSftpDemoTranscriptLineCap + 1, 'x'),
      );
      engine.logController.add(flood);
      await Future<void>.delayed(Duration.zero);

      final replayed = <ConnectionLogEvent>[];
      final first = controller.connectLog.listen(replayed.add);
      await Future<void>.delayed(Duration.zero);
      await first.cancel();
      expect(replayed, [flood]);

      // A follow-up event then evicts the flood, keeping the newest.
      engine.logController.add(
        ConnectionLogEvent(serverId: serverId, lines: ['tail']),
      );
      await Future<void>.delayed(Duration.zero);
      final second = <ConnectionLogEvent>[];
      final sub = controller.connectLog.listen(second.add);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(second.map((event) => event.lines), [
        ['tail'],
      ]);
    });
  });

  group('probe wiring', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    Future<void> resume(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    }

    testWidgets(
      'the app consumer subscribes before sending targets or activity',
      (tester) async {
        final engine = successfulEngine(
          channel: FakeDemoBrowseChannel(
            homePath: '/home/deploy',
            entries: _scriptedEntries,
          ),
        );
        await pumpDemoView(tester, engine);
        await resume(tester);

        await submitDemoForm(tester);
        await tester.pumpAndSettle();

        expect(engine.probeCalls, isNotEmpty);
        expect(engine.probeCommandsSawListener, isTrue);
      },
    );

    testWidgets('renders the engine\'s live status for the listed server', (
      tester,
    ) async {
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(
          homePath: '/home/deploy',
          entries: _scriptedEntries,
        ),
      );
      await pumpDemoView(tester, engine);
      await resume(tester);

      expect(find.byType(ProbeStatusDot), findsNothing);
      await submitDemoForm(tester);
      await tester.pumpAndSettle();

      expect(engine.probeTargets, hasLength(1));
      expect(find.byType(ProbeStatusDot), findsOneWidget);
      expect(find.byTooltip(l10n.probeStatusOnline), findsOneWidget);

      // The dot tracks the engine snapshot, not a local guess: an
      // unsolicited mid-session push reaches it without any reconnect.
      // An offline push cannot flip it while a transport is connected —
      // the push contradicts live truth, so the composed indicator keeps
      // the connected glyph (02 §4).
      engine.probeStatusesController.add(
        ProbeStatusesEvent(
          statuses: {engine.probeTargets.single.id: ProbeStatus.offline},
        ),
      );
      await tester.pump();
      expect(find.byType(ProbeStatusDot), findsNothing);
      expect(find.byTooltip(l10n.connectionStateConnected), findsOneWidget);
    });

    testWidgets('an unscripted snapshot leaves the dot unknown', (
      tester,
    ) async {
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(
          homePath: '/home/deploy',
          entries: _scriptedEntries,
        ),
      )..autoProbeStatus = null;
      await pumpDemoView(tester, engine);
      await resume(tester);

      await submitDemoForm(tester);
      await tester.pumpAndSettle();

      // Connected truth outranks the unknown probe result (02 §4), so the
      // composed glyph answers. The snapshot left the probe unknown — a
      // wrongly-online default would render the probe dot instead.
      expect(find.byType(ProbeStatusDot), findsNothing);
      expect(find.byTooltip(l10n.probeStatusOnline), findsNothing);
      expect(find.byTooltip(l10n.connectionStateConnected), findsOneWidget);
    });

    testWidgets('a global opt-out keeps probes paused and the dot unknown', (
      tester,
    ) async {
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(
          homePath: '/home/deploy',
          entries: _scriptedEntries,
        ),
      );
      final settings = _FakeProbeSettings(global: ProbePreference.disabled);
      await pumpDemoView(tester, engine, probeSettings: settings);
      await resume(tester);

      await submitDemoForm(tester);
      await tester.pumpAndSettle();

      // The opt-out contract: the wiring still configures the engine
      // (the controller owns the pause), but never with targets or
      // running activity. The dot itself: connected truth outranks the
      // unknown probe result (02 §4), so the glyph answers — the pause
      // contract above is what keeps probes from ever flipping it online.
      expect(engine.probeCalls, contains('paused'));
      expect(engine.probeCalls, isNot(contains('running')));
      expect(engine.probeCalls.last, 'targets:');
      expect(find.byTooltip(l10n.probeStatusOnline), findsNothing);
      expect(find.byTooltip(l10n.connectionStateConnected), findsOneWidget);
    });

    testWidgets('hiding the app pauses probes; returning resumes them', (
      tester,
    ) async {
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(
          homePath: '/home/deploy',
          entries: _scriptedEntries,
        ),
      );
      await pumpDemoView(tester, engine);
      await resume(tester);
      await submitDemoForm(tester);
      await tester.pumpAndSettle();
      expect(engine.probeCalls.last, 'running');

      // Clear the pre-hide history so the pause assertion pins the hide
      // transition itself, not an earlier setup-time pause.
      engine.probeCalls.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(engine.probeCalls, contains('paused'));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await resume(tester);
      expect(engine.probeCalls.last, 'running');
    });

    testWidgets('a successful listing persists the connection fact', (
      tester,
    ) async {
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(
          homePath: '/home/deploy',
          entries: _scriptedEntries,
        ),
      );
      final settings = _FakeProbeSettings();
      await pumpDemoView(tester, engine, probeSettings: settings);
      await resume(tester);

      await submitDemoForm(tester);
      await tester.pumpAndSettle();

      expect(settings.calls, contains(startsWith('markSeen:')));
      expect(settings.calls, contains(startsWith('markConnected:')));
      expect(settings.servers.values.single.connected, isTrue);
    });

    testWidgets('disconnecting clears probe targets and hides the dot', (
      tester,
    ) async {
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(
          homePath: '/home/deploy',
          entries: _scriptedEntries,
        ),
      );
      await pumpDemoView(tester, engine);
      await resume(tester);
      await submitDemoForm(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ProbeStatusDot), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sftp-demo-disconnect')));
      await tester.pumpAndSettle();

      expect(engine.probeTargets, isEmpty);
      expect(engine.probeCalls.last, 'targets:');
      expect(find.byType(ProbeStatusDot), findsNothing);
    });

    testWidgets('a blocked connection outranks the online probe dot', (
      tester,
    ) async {
      final engine = successfulEngine(
        channel: FakeDemoBrowseChannel(
          homePath: '/home/deploy',
          entries: _scriptedEntries,
        ),
      );
      await pumpDemoView(tester, engine);
      await resume(tester);
      await submitDemoForm(tester);
      await tester.pumpAndSettle();

      // Probe truth says reachable (the fake's default online snapshot).
      expect(find.byTooltip(l10n.probeStatusOnline), findsOneWidget);

      // The pool then hard-blocks the server (D18). Live connection truth
      // outranks probe results (02 §4), so the green dot must go.
      engine.statesController.add(
        const ServerStatus(
          ServerConnectionState.blocked,
          detail: 'Host key changed for example.com:22.',
        ),
      ); // The stream delivery and the rebuild it triggers each need a turn.
      await tester.pumpAndSettle();

      expect(find.byType(ProbeStatusDot), findsNothing);
      expect(find.byTooltip(l10n.connectionBlockedTitle), findsOneWidget);
    });
  });

  test('the production seam drives the flow over real isolate ports', () async {
    final client = await EngineClient.spawnForTesting(
      const EngineConfig(),
      entrypoint: scriptedDemoEngineMain,
    );
    final engine = sftpDemoEngineOf(client);
    final controller = SftpDemoController(
      engine: engine,
      navigatorKey: GlobalKey<NavigatorState>(),
      probeSettings: _FakeProbeSettings(),
    );
    controller.start();
    final logLines = <String>[];
    final logSub = engine.connectionLog.listen(
      (event) => logLines.addAll(event.lines),
    );

    // Registered teardown preserves the cleanup guarantee even when an
    // assertion fails mid-test: the spawned isolate must never leak.
    // (Registered in reverse execution order: wait, dispose, cancel.)
    addTearDown(() => client.terminated.timeout(const Duration(seconds: 10)));
    addTearDown(controller.dispose);
    addTearDown(logSub.cancel);

    await controller.connect(
      const SftpDemoConnectFacts(
        host: 'demo.example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      ),
    );

    expect(controller.entries.map((entry) => entry.name), [
      'docs',
      'notes.txt',
    ]);
    expect(controller.failureDetail, isNull);
    expect(controller.status?.state, ServerConnectionState.connected);
    expect(logLines, contains('Connecting to demo.example.com'));

    await controller.disconnect();
    // If the shutdown-ack/termination wiring regresses, the isolate never
    // exits; the registered teardown fails fast instead of hanging the
    // shard.
  });
}
