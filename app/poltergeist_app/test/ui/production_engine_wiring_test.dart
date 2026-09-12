import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/ui/connections/connections_command.dart';
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

/// The two-pane shell binds one local channel per pane at startup:
/// every engine fixture here scripts exactly that pair.
session_test.FakeAppEngine engineWithTwoLocalPanes() =>
    session_test.FakeAppEngine()
      ..localChannels.addAll([
        session_test.FakeAppBrowseChannel(homePath: '/home/deploy'),
        session_test.FakeAppBrowseChannel(homePath: '/home/deploy'),
      ]);

void main() {
  final connectionsButton = find.byKey(
    const ValueKey('command.$kConnectionsCommandId'),
  );

  testWidgets('Connections surface consumes the production engine', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final engine = engineWithTwoLocalPanes();
    addTearDown(engine.close);
    // One store shared by the session and the app, as main.dart wires it.
    final bookmarks = FakeBookmarkStore([_blockedBookmark()]);
    final session = await startEngineSession(
      supportDirectoryPath: Directory.systemTemp
          .createTempSync('pg-engine-session-')
          .path,
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
    final engine = engineWithTwoLocalPanes();
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
      supportDirectoryPath: Directory.systemTemp
          .createTempSync('pg-engine-session-')
          .path,
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

  testWidgets('app detach shuts the production engine down', (tester) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final engine = engineWithTwoLocalPanes();
    addTearDown(engine.close);
    final session = await startEngineSession(
      supportDirectoryPath: Directory.systemTemp
          .createTempSync('pg-engine-session-')
          .path,
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
