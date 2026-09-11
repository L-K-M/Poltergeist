import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/probe_controller.dart';
import 'package:poltergeist_app/services/probe_settings_store.dart';
import 'package:poltergeist_app/ui/connections/connections_command.dart';
import 'package:poltergeist_app/ui/demo/sftp_demo_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../services/engine_session_test.dart' as session_test;
import '../support/fake_bookmark_store.dart';

final _now = DateTime.utc(2026, 9, 11, 9);

Bookmark _blockedBookmark() {
  return Bookmark(
    id: 'b1',
    kind: BookmarkKind.remotePath,
    label: 'web',
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 2222,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      ),
    ),
    remotePath: '/',
    sortKey: 'b1',
    createdAt: _now,
    updatedAt: _now,
  );
}

/// Probe settings over nothing persisted: the demo session requires the
/// seam, and an in-memory sink keeps this suite off the disk.
class _NoopProbeSettings implements ProbeSettings {
  @override
  Future<ProbePreference> loadGlobalPreference() async =>
      ProbePreference.enabled;

  @override
  Future<ProbeServerFacts> loadServerFacts({
    required String serverId,
    required String host,
    required int port,
  }) async => ProbeServerFacts.unseen;

  @override
  Future<void> markConnected({
    required String serverId,
    required String host,
    required int port,
  }) async {}

  @override
  Future<void> markSeen({
    required String serverId,
    required String host,
    required int port,
  }) async {}

  @override
  Future<void> removeServer(String serverId) async {}
}

void main() {
  final connectionsButton = find.byKey(
    const ValueKey('command.$kConnectionsCommandId'),
  );
  final demoButton = find.byKey(
    const ValueKey('command.$kSftpDemoCommandId'),
  );

  testWidgets('Connections surface consumes the production engine', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final engine = session_test.FakeAppEngine();
    addTearDown(engine.close);
    // One store shared by the session and the app, as main.dart wires it.
    final bookmarks = FakeBookmarkStore([_blockedBookmark()]);
    final session = await startEngineSession(
      supportDirectoryPath: './engine-session',
      bookmarks: bookmarks,
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    addTearDown(session!.shutdown);

    // The engine's state lane feeds the rows: the watch must be live
    // before the surface reads it, like the engine's own replay.
    engine.statesControllers.putIfAbsent(
      'b1',
      () => StreamController<ServerStatus>.broadcast(sync: true),
    );

    await tester.pumpWidget(
      PoltergeistApp(
        // The production engine is not debug-gated: the surface stays
        // live with the demo disabled.
        debugDemoEnabled: false,
        bookmarks: bookmarks,
        engineSession: session,
        navigatorKey: navigatorKey,
      ),
    );
    await tester.pump();

    await tester.tap(connectionsButton);
    await tester.pumpAndSettle();

    // The row renders live truth from the engine's lanes.
    expect(engine.statesControllers['b1']!.hasListener, isTrue);

    // Live blocked truth from the engine's lane.
    engine.statesControllers['b1']!.add(
      const ServerStatus(
        ServerConnectionState.blocked,
        detail: 'Host key changed.',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Host key changed.'), findsOneWidget);

    // The blocked review affordance is reachable from the production
    // surface (previously null: no composition could start a connect).
    expect(
      find.byKey(const ValueKey('connection.review.b1')),
      findsOneWidget,
    );
  });

  testWidgets('review affordance reaches the changed-key prompt', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final engine = session_test.FakeAppEngine();
    engine.promptScript = [
      EnginePromptEvent(
        promptId: 'p1',
        kind: EnginePromptKind.hostKeyChanged,
        data: HostKeyPromptData(
          host: 'web.example.com',
          port: 2222,
          keyType: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:presented',
          pinnedFingerprintSha256: 'SHA256:pinned',
        ),
      ),
    ];
    engine.channel = session_test.FakeAppBrowseChannel();
    // One store shared by the session and the app, as main.dart wires it.
    final bookmarks = FakeBookmarkStore([_blockedBookmark()]);
    final session = await startEngineSession(
      supportDirectoryPath: './engine-session',
      bookmarks: bookmarks,
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    addTearDown(engine.close);
    addTearDown(session!.shutdown);

    await tester.pumpWidget(
      PoltergeistApp(
        debugDemoEnabled: false,
        bookmarks: bookmarks,
        engineSession: session,
        navigatorKey: navigatorKey,
      ),
    );
    await tester.pump();

    await tester.tap(connectionsButton);
    await tester.pumpAndSettle();
    // The row must read blocked before its review affordance renders.
    engine.statesControllers.putIfAbsent(
      'b1',
      () => StreamController<ServerStatus>.broadcast(sync: true),
    );
    engine.statesControllers['b1']!.add(
      const ServerStatus(ServerConnectionState.blocked),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connection.review.b1')));
    // Not pumpAndSettle: the review connect leaves the row `connecting`
    // (its glyph is an indeterminate spinner) while the changed-key
    // dialog awaits the user, so frames never stop being scheduled.
    await tester.pump();
    await tester.pump();

    // The changed-key review dialog renders from the production surface
    // through the app-level coordinator.
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('demo command reuses the production engine, no second spawn', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final engine = session_test.FakeAppEngine();
    engine.channel = session_test.FakeAppBrowseChannel(
      entries: const [
        RemoteFileEntry(
          path: '/home/deploy/docs',
          name: 'docs',
          type: RemoteFileType.directory,
        ),
      ],
    );
    addTearDown(engine.close);
    final session = await startEngineSession(
      supportDirectoryPath: './engine-session',
      bookmarks: FakeBookmarkStore(),
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    addTearDown(session!.shutdown);
    var sentinelSpawns = 0;

    await tester.pumpWidget(
      PoltergeistApp(
        debugDemoEnabled: true,
        probeSettings: _NoopProbeSettings(),
        engineSession: session,
        navigatorKey: navigatorKey,
        // A session must override any factory: only one engine per process.
        sftpDemoEngineFactory: () async {
          sentinelSpawns++;
          throw StateError('a second engine must never spawn');
        },
      ),
    );
    await tester.pump();

    await tester.tap(demoButton);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('sftp-demo-host')),
      'example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sftp-demo-port')),
      '22',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sftp-demo-username')),
      'deploy',
    );
    await tester.tap(find.byKey(const ValueKey('sftp-demo-connect')));
    await tester.pumpAndSettle();

    // The connect ran through the production engine, not the sentinel.
    expect(sentinelSpawns, 0);
    expect(engine.openCalls, hasLength(1));
    expect(find.text('docs'), findsOneWidget);

    // Closing the demo tears its session down without stopping the
    // production engine.
    await tester.tap(find.byKey(const ValueKey('sftp-demo-close')));
    await tester.pumpAndSettle();
    expect(engine.shutdownCalls, 0);
    expect(engine.disconnectIds, isNotEmpty);
  });

  testWidgets('demo prompts render through the session coordinator', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final engine = session_test.FakeAppEngine();
    addTearDown(engine.close);
    // A first-use trust prompt on the demo connect: the session's one
    // coordinator must render it (a second, demo-owned coordinator would
    // render it twice) — on the root navigator, above the demo route.
    engine.promptScript = [
      EnginePromptEvent(
        promptId: 'p1',
        kind: EnginePromptKind.hostKeyFirstUse,
        data: HostKeyPromptData(
          host: 'example.com',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:presented',
        ),
      ),
    ];
    engine.channel = session_test.FakeAppBrowseChannel();
    final session = await startEngineSession(
      supportDirectoryPath: './engine-session',
      bookmarks: FakeBookmarkStore(),
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    // Idempotent insurance, registered before anything risky runs.
    addTearDown(() {
      unawaited(session!.shutdown());
    });

    await tester.pumpWidget(
      PoltergeistApp(
        debugDemoEnabled: true,
        probeSettings: _NoopProbeSettings(),
        engineSession: session,
        navigatorKey: navigatorKey,
      ),
    );
    await tester.pump();

    await tester.tap(demoButton);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('sftp-demo-host')),
      'example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sftp-demo-port')),
      '22',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sftp-demo-username')),
      'deploy',
    );
    await tester.tap(find.byKey(const ValueKey('sftp-demo-connect')));
    await tester.pump();
    await tester.pump();

    // Exactly one dialog: the shared coordinator owns the prompt.
    expect(find.byType(AlertDialog), findsOneWidget);

    // Shutdown drains in the body, not an awaited teardown: the chain's
    // future does not re-complete inside the fake-async zone once it has
    // been entered, so an awaited teardown would hang the suite.
    unawaited(session!.shutdown());
    for (var i = 0; i < 50 && engine.shutdownCalls == 0; i++) {
      await tester.pump();
    }
    expect(engine.shutdownCalls, 1);
  });

  testWidgets('app detach shuts the production engine down', (tester) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final engine = session_test.FakeAppEngine();
    addTearDown(engine.close);
    final session = await startEngineSession(
      supportDirectoryPath: './engine-session',
      bookmarks: FakeBookmarkStore(),
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    // Safety net: if the detach path ever stops triggering shutdown, the
    // session must still not leak past this test (idempotent either way).
    addTearDown(() {
      unawaited(session!.shutdown());
    });

    await tester.pumpWidget(
      PoltergeistApp(
        debugDemoEnabled: false,
        engineSession: session,
        navigatorKey: navigatorKey,
      ),
    );
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    // The shutdown chain crosses several awaits; pump until it lands
    // rather than coupling the test to the chain's depth.
    for (var i = 0; i < 50 && engine.shutdownCalls == 0; i++) {
      await tester.pump();
    }

    expect(engine.shutdownCalls, 1);
  });
}
