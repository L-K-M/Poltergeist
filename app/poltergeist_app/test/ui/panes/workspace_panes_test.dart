
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';

RemoteFileEntry _entry(String name, {String parent = '/home/tester'}) =>
    RemoteFileEntry(
      path: '$parent/$name',
      name: name,
      type: RemoteFileType.file,
      size: 10,
    );

class _HeldListingChannel extends session_test.FakeAppBrowseChannel {
  _HeldListingChannel({super.homePath = '/home/tester'});

  Completer<List<RemoteFileEntry>>? nextListing;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) {
    final held = nextListing;
    nextListing = null;
    return held?.future ?? super.listDirectory(path);
  }
}

void main() {
  final connectionsButton = find.byKey(
    const ValueKey('command.view.connections'),
  );

  late session_test.FakeAppEngine engine;

  Future<EngineSession?> pumpApp(
    WidgetTester tester, {
    FakeBookmarkStore? bookmarks,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(engine.close);
    // A per-test temp directory: the injected in-memory stores never
    // touch it, but nothing should write into the checkout either.
    final supportDir = Directory.systemTemp.createTempSync('pg-panes-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
      bookmarks: bookmarks ?? FakeBookmarkStore(),
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    addTearDown(session!.shutdown);


    await tester.pumpWidget(
      PoltergeistApp(
        bookmarks: bookmarks,
        engineSession: session,
        navigatorKey: navigatorKey,
      ),
    );
    await tester.pump();
    return session;
  }

  setUp(() {
    engine = session_test.FakeAppEngine();
    final left = session_test.FakeAppBrowseChannel(homePath: '/home/tester');
    left.listings['/home/tester'] = [_entry('left.txt')];
    final right = session_test.FakeAppBrowseChannel(homePath: '/home/tester');
    right.listings['/home/tester'] = [_entry('right.txt')];
    engine.localChannels.addAll([left, right]);
  });

  testWidgets('panes browse the local home through the engine seam', (
    tester,
  ) async {
    await pumpApp(tester);

    // Both panes opened local channels and listed their canonical home.
    expect(
      engine.localChannels.map((c) => c.listCalls).toList(),
      [
        ['/home/tester'],
        ['/home/tester'],
      ],
    );
    // The home anchor is the engine-expanded '~', never a raw path.
    expect(engine.localChannelRoots, ['~', '~']);
    expect(find.text('left.txt'), findsOneWidget);
    expect(find.text('right.txt'), findsOneWidget);
  });

  testWidgets('toolbar refresh becomes available after initial binding', (tester) async {
    await pumpApp(tester);
    await tester.pumpAndSettle();

    final refresh = find.byKey(const ValueKey('command.$kViewRefreshCommandId'));
    expect(tester.widget<TextButton>(refresh).onPressed, isNotNull);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(engine.localChannels[0].listCalls, ['/home/tester', '/home/tester']);
    expect(engine.localChannels[1].listCalls, ['/home/tester']);
  });

  testWidgets('toolbar open follows cursor and active pane changes', (tester) async {
    engine.localChannels[0].listings['/home/tester'] = [
      const RemoteFileEntry(path: '/home/tester/docs', name: 'docs', type: RemoteFileType.directory),
    ];
    await pumpApp(tester);
    await tester.pumpAndSettle();
    final open = find.byKey(const ValueKey('command.$kGoOpenCommandId'));
    expect(tester.widget<TextButton>(open).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('command.$kPaneFocusLeftCommandId')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<TextButton>(open).onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('command.$kPaneFocusRightCommandId')));
    await tester.pump();
    expect(tester.widget<TextButton>(open).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('command.$kPaneFocusLeftCommandId')));
    await tester.pump();
    expect(tester.widget<TextButton>(open).onPressed, isNotNull);

    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(engine.localChannels[0].listCalls, ['/home/tester', '/home/tester/docs']);
    expect(engine.localChannels[1].listCalls, ['/home/tester']);
    expect(tester.widget<TextButton>(open).onPressed, isNull);
  });

  testWidgets('toolbar parent tracks pending and completed listings', (tester) async {
    final channel = _HeldListingChannel();
    engine.localChannels[0] = channel;
    await pumpApp(tester);
    await tester.pumpAndSettle();
    final parent = find.byKey(const ValueKey('command.$kGoEnclosingCommandId'));
    expect(tester.widget<TextButton>(parent).onPressed, isNotNull);

    final held = Completer<List<RemoteFileEntry>>();
    channel.nextListing = held;
    await tester.tap(find.byKey(const ValueKey('command.$kViewRefreshCommandId')));
    await tester.pump();
    expect(tester.widget<TextButton>(parent).onPressed, isNull);
    held.complete([_entry('fresh.txt')]);
    await tester.pumpAndSettle();
    expect(find.text('fresh.txt'), findsOneWidget);
    expect(tester.widget<TextButton>(parent).onPressed, isNotNull);
  });

  testWidgets('placeholder panes are gone; the demo command is retired', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('Choose a location'), findsNothing);
    expect(
      find.byKey(const ValueKey('command.connect.demoListing')),
      findsNothing,
    );
    // The pane commands are registered (D21).
    expect(
      find.byKey(const ValueKey('command.$kViewRefreshCommandId')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('command.$kGoEnclosingCommandId')),
      findsOneWidget,
    );
  });

  testWidgets('Ctrl+R refreshes the focused pane only', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpApp(tester);

      // Focus the right pane's listing, then fire the chord.
      await tester.tap(find.text('right.txt'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(engine.localChannels[0].listCalls, hasLength(1));
      expect(engine.localChannels[1].listCalls, hasLength(2));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Meta+R refreshes on macOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await pumpApp(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      // The left pane starts focused: it refreshed.
      expect(engine.localChannels[0].listCalls, hasLength(2));
      expect(engine.localChannels[1].listCalls, hasLength(1));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('pane focus commands move focus between panes', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await pumpApp(tester);

      await tester.tap(
        find.byKey(const ValueKey('command.$kPaneFocusRightCommandId')),
      );
      await tester.pump();

      // The focused pane is right: refresh through the chord targets it.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(engine.localChannels[1].listCalls, hasLength(2));
      expect(engine.localChannels[0].listCalls, hasLength(1));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('without an engine the panes render the no-engine state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const PoltergeistApp());

    expect(find.textContaining('Browsing is unavailable'), findsNWidgets(2));
    expect(find.text('left.txt'), findsNothing);
  });

  testWidgets('a session arriving later gains live connections truth', (
    tester,
  ) async {
    // The startup posture: the shell mounts before any engine exists,
    // then the session arrives (main.dart awaits it before runApp, but
    // the swap is the didUpdateWidget contract the shell must honor).
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final now = DateTime.utc(2026, 9, 12);
    final store = FakeBookmarkStore([
      Bookmark(
        id: 'srv-x',
        kind: BookmarkKind.remotePath,
        label: 'late.example.com',
        server: BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: 'late.example.com',
            port: 22,
            username: 'tester',
            authMethod: AuthMethod.password,
          ),
        ),
        remotePath: '/',
        sortKey: 'k',
        createdAt: now,
        updatedAt: now,
      ),
    ]);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      PoltergeistApp(
        bookmarks: store,
        engineSession: null,
        navigatorKey: navigatorKey,
      ),
    );
    await tester.pump();
    expect(find.textContaining('Browsing is unavailable'), findsNWidgets(2));

    addTearDown(engine.close);
    final supportDir = Directory.systemTemp.createTempSync('pg-panes-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
      bookmarks: store,
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    addTearDown(session!.shutdown);

    // Same store, session added: the panes bind and the Connections
    // surface must pick the session's lanes (a stale null bridge would
    // leave every row reading not connected).
    await tester.pumpWidget(
      PoltergeistApp(
        bookmarks: store,
        engineSession: session,
        navigatorKey: navigatorKey,
      ),
    );
    await tester.pump();
    expect(find.text('left.txt'), findsOneWidget);

    await tester.tap(connectionsButton);
    await tester.pumpAndSettle();
    engine.statesControllers.putIfAbsent(
      'srv-x',
      () => StreamController<ServerStatus>.broadcast(sync: true),
    );
    engine.statesControllers['srv-x']!.add(
      const ServerStatus(ServerConnectionState.connected),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('a remote bookmark opens in the active pane from Connections', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 9, 12);
    final store = FakeBookmarkStore([
      Bookmark(
        id: 'srv-9',
        kind: BookmarkKind.remotePath,
        label: 'storage.example.com',
        server: BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: 'storage.example.com',
            port: 22,
            username: 'tester',
            authMethod: AuthMethod.password,
          ),
        ),
        remotePath: '/',
        sortKey: 'k',
        createdAt: now,
        updatedAt: now,
      ),
    ]);

    final remote = _HeldListingChannel(homePath: '/srv/home');
    remote.listings['/srv/home'] = [
      _entry('from-remote.txt', parent: '/srv/home'),
    ];
    engine.channel = remote;

    await pumpApp(tester, bookmarks: store);

    await tester.tap(connectionsButton);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('connection.open.srv-9')));
    // The open pops the route itself — the pane it opened is revealed.
    await tester.pump();
    await tester.pumpAndSettle();

    // The left pane (active by default) now browses the remote listing.
    expect(find.text('from-remote.txt'), findsOneWidget);
    expect(engine.openCalls.map((c) => c.serverId), ['srv-9']);

    final refresh = find.byKey(const ValueKey('command.$kViewRefreshCommandId'));
    final parent = find.byKey(const ValueKey('command.$kGoEnclosingCommandId'));
    expect(tester.widget<TextButton>(refresh).onPressed, isNotNull);
    engine.statesControllers['srv-9']!.add(
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    await tester.pump();
    expect(tester.widget<TextButton>(refresh).onPressed, isNull);
    expect(tester.widget<TextButton>(parent).onPressed, isNull);
    expect(find.text('from-remote.txt'), findsOneWidget);

    final listing = Completer<List<RemoteFileEntry>>();
    remote.nextListing = listing;
    engine.statesControllers['srv-9']!.add(
      const ServerStatus(ServerConnectionState.connected),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('pane.banner')), findsOneWidget);
    expect(tester.widget<TextButton>(refresh).onPressed, isNull);
    listing.complete([_entry('healed.txt', parent: '/srv/home')]);
    await tester.pumpAndSettle();
    expect(find.text('healed.txt'), findsOneWidget);
    expect(find.byKey(const ValueKey('pane.banner')), findsNothing);
    expect(tester.widget<TextButton>(refresh).onPressed, isNotNull);
    expect(engine.localChannels[1].listCalls, ['/home/tester']);
    expect(find.text('right.txt'), findsOneWidget);
  });
}
