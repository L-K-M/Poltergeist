import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/sftp_demo_controller.dart';
import 'package:poltergeist_app/ui/demo/sftp_demo_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

const _commandButtonKey = ValueKey('command.connect.demoListing');

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

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
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
  final _pendingReplies = <String, Completer<PromptReply>>{};

  final replies = <(String, EnginePromptKind, PromptReply)>[];
  final openCalls =
      <({String serverId, String paneTabId, ServerConfig config})>[];

  /// Emitted (and awaited) in order inside [openBrowseChannel].
  List<EnginePromptEvent> promptScript = const [];

  /// Blocks every open until completed (the re-entrancy guard test).
  Completer<void>? openGate;

  /// Transcript lines every open emits — the "during connect" material.
  List<String> openLogLines = const ['Connecting to example.com:22'];

  Object? openFailure;
  FakeDemoBrowseChannel? channel;
  int disconnectCalls = 0;
  int shutdownCalls = 0;

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
  Future<SftpDemoBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  }) async {
    openCalls.add((serverId: serverId, paneTabId: paneTabId, config: config));
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
      // The engine's teardown fan-out: the failed connect ends with the
      // failure detail on the disconnected state.
      statesController.add(
        ServerStatus(
          ServerConnectionState.disconnected,
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
    final completer = Completer<PromptReply>();
    _pendingReplies[promptId] = completer;
    return completer.future;
  }

  @override
  Future<void> disconnectServer(String serverId) async {
    disconnectCalls++;
  }

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
  }

  Future<void> close() async {
    await promptsController.close();
    await dismissalsController.close();
    await statesController.close();
    await logController.close();
  }
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
  FakeSftpDemoEngine engine,
) async {
  // Desktop-sized viewport: the panel below the form must stay on screen
  // for its transcript to be tappable.
  tester.view.physicalSize = const Size(1180, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  addTearDown(engine.close);
  final controller = SftpDemoController(
    engine: engine,
    navigatorKey: GlobalKey<NavigatorState>(),
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
}) async {
  final engine = FakeSftpDemoEngine();
  addTearDown(engine.close);
  await tester.pumpWidget(
    PoltergeistApp(
      debugDemoEnabled: debugDemoEnabled,
      sftpDemoEngineFactory: () async => engine,
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
    await tester.tap(find.byKey(const ValueKey('sftp-demo-auth')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Password').last);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('sftp-demo-connect')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Opens the panel's collapsed transcript with fixed pumps (the pending
/// view's spinner keeps pumpAndSettle from settling).
Future<void> expandTranscript(WidgetTester tester) async {
  await tester.tap(find.text('Connection log'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
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
      case final ShutdownRequest request:
        events.send(
          ResponseEvent(requestId: request.requestId, result: EngineAck()),
        );
      default:
        break;
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
      await tester.tap(find.byKey(_commandButtonKey));
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
      final engine =
          successfulEngine(
              channel: FakeDemoBrowseChannel(
                homePath: '/home/deploy',
                entries: _scriptedEntries,
              ),
            )
            ..promptScript = [_hostKeyFirstUse('p1')]
            ..openGate = Completer<void>();
      await pumpDemoView(tester, engine);

      await submitDemoForm(tester);

      // The transcript renders while the connect is still pending (the
      // gate holds the open before the prompt appears, so the panel is
      // tappable).
      await expandTranscript(tester);
      expect(
        find.textContaining('Connecting to example.com:22'),
        findsOneWidget,
      );

      engine.openGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
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
        await pumpDemoView(tester, engine);

        await submitDemoForm(tester);

        // The transcript renders during connect, before the prompt shows.
        await expandTranscript(tester);
        expect(find.textContaining('Offering the server key'), findsOneWidget);

        engine.openGate!.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('HOST KEY CHANGED'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pump();

        engine.statesController.add(
          const ServerStatus(
            ServerConnectionState.blocked,
            detail: 'The host key changed.',
          ),
        );
        await tester.pumpAndSettle();

        expect(
          (engine.replies.single.$3 as HostKeyPromptReply).accepted,
          isFalse,
        );
        expect(find.text('Connection blocked'), findsOneWidget);
        expect(
          find.text('The host key changed for example.com:22.'),
          findsOneWidget,
        );
        expect(find.text('docs'), findsNothing);

        // The transcript rendered during connect stays visible on failure.
        expect(find.textContaining('Offering the server key'), findsOneWidget);
      },
    );

    testWidgets('a failed listing keeps the transcript and the one-liner', (
      tester,
    ) async {
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
      await pumpDemoView(tester, engine);

      await submitDemoForm(tester);

      // The transcript renders while the connect is still pending.
      await expandTranscript(tester);
      expect(find.textContaining('Authentication succeeded'), findsOneWidget);

      engine.openGate!.complete();
      await tester.pumpAndSettle();

      expect(find.text('Permission denied.'), findsOneWidget);
      expect(find.text('docs'), findsNothing);
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
      expect(find.text('The directory is empty.'), findsOneWidget);
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
      );

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
      await engine.close();
      controller.dispose();

      expect(engine.openCalls, hasLength(1));
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
    );
    controller.start();
    final logLines = <String>[];
    final logSub = engine.connectionLog.listen(
      (event) => logLines.addAll(event.lines),
    );

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
    await logSub.cancel();
    controller.dispose();
    await client.terminated;
  });
}
