
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_app/ui/adaptive_shell.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
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

/// A pane channel whose close parks on a caller-held completer, so a
/// cancel's awaited channel release can be frozen mid-flight while a
/// sibling acts (the parked-close race window).
class _HeldCloseChannel extends session_test.FakeAppBrowseChannel {
  _HeldCloseChannel({required super.homePath});

  Completer<void>? holdClose;

  @override
  Future<void> close() async {
    await holdClose?.future;
    await super.close();
  }
}

Bookmark _remoteBookmark(String id) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: '$id.example.com',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '$id.example.com',
      port: 22,
      username: 'tester',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/',
  sortKey: id,
  createdAt: DateTime.utc(2026, 9, 12),
  updatedAt: DateTime.utc(2026, 9, 12),
);

/// A pending remote open parks per pane tab, so two panes can share one
/// server while only one of their binds is still in flight.
class _HeldConnectEngine extends session_test.FakeAppEngine {
  final heldOpens = <String, Completer<void>>{};
  final paneChannels = <String, session_test.FakeAppBrowseChannel>{};

  @override
  Future<AppBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  }) async {
    openCalls.add((serverId: serverId, paneTabId: paneTabId, config: config));
    statesControllers
        .putIfAbsent(
          serverId,
          () => StreamController<ServerStatus>.broadcast(sync: true),
        )
        .add(const ServerStatus(ServerConnectionState.connecting));
    final hold = heldOpens[paneTabId];
    if (hold != null) await hold.future;
    final channel = paneChannels[paneTabId];
    if (channel == null) throw StateError('no browse channel scripted');
    statesControllers[serverId]!.add(
      const ServerStatus(ServerConnectionState.connected),
    );
    return channel;
  }
}

void main() {
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

    // Same store, session added: the panes bind and the sidebar's
    // Connections section must pick the session's lanes (a stale null
    // bridge would never surface the row).
    await tester.pumpWidget(
      PoltergeistApp(
        bookmarks: store,
        engineSession: session,
        navigatorKey: navigatorKey,
      ),
    );
    await tester.pump();
    expect(find.text('left.txt'), findsOneWidget);

    engine.statesControllers.putIfAbsent(
      'srv-x',
      () => StreamController<ServerStatus>.broadcast(sync: true),
    );
    engine.statesControllers['srv-x']!.add(
      const ServerStatus(ServerConnectionState.connected),
    );
    await tester.pumpAndSettle();

    // The Connections section surfaces pool-held servers only, so the
    // row itself is the live-truth assertion — and the lane proves the
    // row reads THIS session's state stream (no pane binds srv-x, so
    // the sidebar's controller is the only possible listener).
    expect(
      find.byKey(const ValueKey('sidebar.connection.srv-x')),
      findsOneWidget,
    );
    expect(engine.statesControllers['srv-x']!.hasListener, isTrue);
  });

  testWidgets('a remote bookmark opens in the active pane from the sidebar', (
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
    await tester.pumpAndSettle();

    // The favorite row mounts inline at desktop width; its tap opens the
    // bookmark in the target pane (no preferred pane → the active one).
    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.srv-9')));
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

  _HeldConnectEngine heldConnectEngine() {
    final held = _HeldConnectEngine();
    for (final name in ['left.txt', 'right.txt']) {
      held.localChannels.add(
        session_test.FakeAppBrowseChannel(homePath: '/home/tester')
          ..listings['/home/tester'] = [_entry(name)],
      );
    }
    return held;
  }

  (PaneController, PaneController) paneControllers(WidgetTester tester) {
    final panes = tester.widgetList<PaneView>(find.byType(PaneView)).toList();
    return (panes[0].controller, panes[1].controller);
  }

  testWidgets(
    'Esc cancels a pending remote bind without severing a same-server sibling',
    (tester) async {
      final held = heldConnectEngine();
      final sibling = session_test.FakeAppBrowseChannel(homePath: '/srv/home')
        ..listings['/srv/home'] = [
          _entry('sibling.txt', parent: '/srv/home'),
        ];
      final lateLeft = session_test.FakeAppBrowseChannel(homePath: '/srv/home')
        ..listings['/srv/home'] = [_entry('late.txt', parent: '/srv/home')];
      held.paneChannels['pane.right.tab1'] = sibling;
      held.paneChannels['pane.left.tab1'] = lateLeft;
      held.heldOpens['pane.left.tab1'] = Completer<void>();
      engine = held;

      await pumpApp(tester);
      final (left, right) = paneControllers(tester);
      final rightConnect = right.connectRemote(_remoteBookmark('srv-1'));
      final leftConnect = left.connectRemote(_remoteBookmark('srv-1'));
      await rightConnect;
      // Bounded pumps only: the connecting pane's spinner animates, so
      // pumpAndSettle would never settle while the bind is pending.
      await tester.pump();
      expect(find.text('sibling.txt'), findsOneWidget);
      expect(left.phase, PanePhase.connectingRemote);

      // Focus the connecting pane through the production focus command,
      // then cancel the pending bind with plain Esc.
      await tester.tap(
        find.byKey(const ValueKey('command.$kPaneFocusLeftCommandId')),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      // Bounded pumps here too: while the held open is still in flight
      // the shared srv-1 status stays `connecting`, and the SIBLING's
      // tab-strip dot animates on that lane — pumpAndSettle cannot
      // settle until the held open resolves below.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The pane had a live LOCAL binding when the remote bind started,
      // so Esc rolls the candidate back and restores it whole — only a
      // genuinely-fresh pane detaches to the launcher (02 §2.8).
      expect(left.phase, PanePhase.browsing);
      expect(left.remoteBookmark, isNull);
      expect(find.text('left.txt'), findsOneWidget);
      expect(
        held.disconnectIds,
        isEmpty,
        reason: 'the sibling still browses srv-1 — only the candidate retires',
      );
      expect(right.phase, PanePhase.browsing);
      expect(find.text('sibling.txt'), findsOneWidget);

      // The late open's orphaned channel is retired; it never repaints.
      held.heldOpens['pane.left.tab1']!.complete();
      await leftConnect;
      await tester.pumpAndSettle();
      expect(lateLeft.closeCalls, 1);
      expect(lateLeft.listCalls, isEmpty);
      expect(find.text('late.txt'), findsNothing);
      expect(right.phase, PanePhase.browsing);
    },
  );

  testWidgets(
    'the connecting Cancel action drops the server reference when alone',
    (tester) async {
      final held = heldConnectEngine();
      final lateLeft = session_test.FakeAppBrowseChannel(homePath: '/srv/home')
        ..listings['/srv/home'] = [_entry('late.txt', parent: '/srv/home')];
      held.paneChannels['pane.left.tab1'] = lateLeft;
      held.heldOpens['pane.left.tab1'] = Completer<void>();
      engine = held;

      await pumpApp(tester);
      final (left, _) = paneControllers(tester);
      final leftConnect = left.connectRemote(_remoteBookmark('srv-1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(left.phase, PanePhase.connectingRemote);

      // The post-grace cancel affordance rides the same sibling-aware
      // path as Esc — here no sibling shares the server, so its
      // reference is dropped.
      final cancel = find.descendant(
        of: find.byType(PaneView).first,
        matching: find.byKey(const ValueKey('pane.connect.cancel')),
      );
      expect(cancel, findsOneWidget);
      await tester.tap(cancel);
      await tester.pumpAndSettle();

      // The prior local binding is restored; the "alone" decision now
      // only governs whether the CANDIDATE's server reference drops —
      // and with no sibling on srv-1 it does.
      expect(left.phase, PanePhase.browsing);
      expect(left.remoteBookmark, isNull);
      expect(find.text('left.txt'), findsOneWidget);
      expect(held.disconnectIds, ['srv-1']);

      held.heldOpens['pane.left.tab1']!.complete();
      await leftConnect;
      await tester.pumpAndSettle();
      expect(lateLeft.closeCalls, 1);
      expect(lateLeft.listCalls, isEmpty);
      expect(find.text('late.txt'), findsNothing);
      expect(find.text('right.txt'), findsOneWidget);
    },
  );

  testWidgets(
    'an alone-decided cancel keeps a reference a sibling binds mid-detach',
    (tester) async {
      final held = heldConnectEngine();
      final leftChannel = _HeldCloseChannel(homePath: '/srv/home')
        ..listings['/srv/home'] = [
          _entry('bound-then-lost.txt', parent: '/srv/home'),
        ];
      final rightChannel = session_test.FakeAppBrowseChannel(
        homePath: '/srv/home',
      )
        ..listings['/srv/home'] = [_entry('sibling-late.txt', parent: '/srv/home')];
      held.paneChannels['pane.left.tab1'] = leftChannel;
      held.paneChannels['pane.right.tab1'] = rightChannel;
      engine = held;

      await pumpApp(tester);
      final (left, right) = paneControllers(tester);

      // Pane A binds srv-1 alone and browses; the sibling stays local.
      await left.connectRemote(_remoteBookmark('srv-1'));
      await tester.pumpAndSettle();
      expect(find.text('bound-then-lost.txt'), findsOneWidget);

      // The transport severs: the connection-lost banner offers Cancel.
      held.statesControllers['srv-1']!.add(
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(PaneView).first,
          matching: find.byKey(const ValueKey('pane.banner')),
        ),
        findsOneWidget,
      );

      // Park A's channel close, then cancel: the shell decides A is
      // alone (the sibling is local) before detachRemote's awaited
      // release — the decision point the race hides behind.
      final releaseClose = Completer<void>();
      addTearDown(() {
        if (!releaseClose.isCompleted) releaseClose.complete();
      });
      leftChannel.holdClose = releaseClose;
      await tester.tap(find.byKey(const ValueKey('pane.banner.cancel')));
      await tester.pump();
      expect(left.phase, PanePhase.unbound);
      expect(leftChannel.closeCalls, 0, reason: 'the close is parked');

      // While A's release is parked, pane B binds the SAME server and
      // starts listing on it — the reference A was about to drop.
      await right.connectRemote(_remoteBookmark('srv-1'));
      await tester.pumpAndSettle();
      expect(right.phase, PanePhase.browsing);
      expect(find.text('sibling-late.txt'), findsOneWidget);

      // Releasing A must not drop the server reference B now shares:
      // a late disconnect would sever B's fresh binding.
      releaseClose.complete();
      await tester.pumpAndSettle();

      expect(
        held.disconnectIds,
        isEmpty,
        reason: 'the sibling took the reference during the detach await',
      );
      expect(right.phase, PanePhase.browsing);
      expect(find.text('sibling-late.txt'), findsOneWidget);
      expect(leftChannel.closeCalls, 1);
    },
  );

  testWidgets(
    "a mid-flight sibling bind is visible to the cancel's late check",
    (tester) async {
      final held = heldConnectEngine();
      final leftChannel = _HeldCloseChannel(homePath: '/srv/home')
        ..listings['/srv/home'] = [
          _entry('bound-then-lost.txt', parent: '/srv/home'),
        ];
      final rightChannel = session_test.FakeAppBrowseChannel(
        homePath: '/srv/home',
      )
        ..listings['/srv/home'] = [_entry('late-open.txt', parent: '/srv/home')];
      held.paneChannels['pane.left.tab1'] = leftChannel;
      held.paneChannels['pane.right.tab1'] = rightChannel;
      // The sibling's open parks engine-side: its bind has STARTED (the
      // pending binding published synchronously at connectRemote entry)
      // but has not settled — the window a committed-state-only check
      // would miss.
      final heldRightOpen = Completer<void>();
      held.heldOpens['pane.right.tab1'] = heldRightOpen;
      addTearDown(() {
        if (!heldRightOpen.isCompleted) heldRightOpen.complete();
      });
      engine = held;

      await pumpApp(tester);
      final (left, right) = paneControllers(tester);

      await left.connectRemote(_remoteBookmark('srv-1'));
      await tester.pumpAndSettle();
      held.statesControllers['srv-1']!.add(
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await tester.pump();

      // Cancel A (decided alone) with its channel close parked.
      final releaseClose = Completer<void>();
      addTearDown(() {
        if (!releaseClose.isCompleted) releaseClose.complete();
      });
      leftChannel.holdClose = releaseClose;
      await tester.tap(find.byKey(const ValueKey('pane.banner.cancel')));
      await tester.pump();
      expect(left.phase, PanePhase.unbound);

      // B starts binding the same server; its open parks at the engine.
      final rightConnect = right.connectRemote(_remoteBookmark('srv-1'));
      await tester.pump();
      expect(right.phase, PanePhase.connectingRemote);
      expect(heldRightOpen.isCompleted, isFalse);

      // Releasing A mid-flight-B must not drop the shared reference.
      // Bounded pumps: the connecting pane's spinner animates, so
      // pumpAndSettle would never settle while the bind is pending.
      releaseClose.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(held.disconnectIds, isEmpty);

      // B's parked open completes: it binds and lists undisturbed.
      heldRightOpen.complete();
      await rightConnect;
      await tester.pumpAndSettle();
      // Re-assert after settle PLUS an explicit time step: pumpAndSettle
      // stops once frames settle, so a disconnect deferred behind a
      // timer that schedules no frame never fires under it alone.
      await tester.pump(const Duration(seconds: 1));
      expect(held.disconnectIds, isEmpty);
      expect(right.phase, PanePhase.browsing);
      expect(find.text('late-open.txt'), findsOneWidget);
      expect(left.phase, PanePhase.unbound);
    },
  );

  group('second-pane toggle (02 §3)', () {
    /// Drains the fake-channel microtask hops a navigation takes.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump();
      }
    }

    /// The per-tab state a hide must preserve whole (02 §3): location
    /// and listing, selection and cursor, the filter lens, the hidden
    /// override, view mode, history, Quick Select, and the rename
    /// session.
    void expectTabState(
      PaneController controller, {
      required String location,
      required String committed,
      required List<String> entries,
      required int selectedCount,
      required List<bool> selectedRows,
      required int cursor,
      required String filterQuery,
      required bool filterFieldOpen,
      required bool showHidden,
      required PaneViewMode viewMode,
      required bool canGoBack,
      required bool canGoForward,
      required bool quickSelectActive,
      required String quickSelectQuery,
      required String? renameTarget,
      required String renameSeed,
    }) {
      expect(controller.location?.path, location);
      expect(controller.committedLocation?.path, committed);
      expect(controller.entries.map((e) => e.path).toList(), entries);
      expect(controller.selectedCount, selectedCount);
      expect(
        [
          for (var i = 0; i < selectedRows.length; i++)
            controller.isRowSelected(i),
        ],
        selectedRows,
      );
      expect(controller.cursorIndex, cursor);
      expect(controller.filterQuery, filterQuery);
      expect(controller.filterFieldOpen, filterFieldOpen);
      expect(controller.showHidden, showHidden);
      expect(controller.viewMode, viewMode);
      expect(controller.canGoBack, canGoBack);
      expect(controller.canGoForward, canGoForward);
      expect(controller.quickSelectActive, quickSelectActive);
      expect(controller.quickSelectQuery, quickSelectQuery);
      expect(controller.renameTarget?.path, renameTarget);
      expect(controller.renameSeed, renameSeed);
    }

    testWidgets('hiding the focused pane B hands focus and commands to '
        'pane A', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await pumpApp(tester);
        await tester.pumpAndSettle();

        // Focus pane B through the production focus command.
        await tester.tap(
          find.byKey(const ValueKey('command.$kPaneFocusRightCommandId')),
        );
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'pane.right.listing',
        );

        // The chord hides pane B (Ctrl+Shift+D / ⇧⌘D, 02 §8.3): its
        // surface unmounts and focus lands on the surviving pane, not
        // on the unmounted node.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();

        expect(
          find.byKey(AdaptiveShell.secondaryPaneKey),
          findsNothing,
        );
        expect(find.text('right.txt'), findsNothing);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'pane.left.listing',
        );

        // Pane commands resolve the ACTIVE pane — it retargeted to pane
        // A, so the refresh chord lists pane A's channel again and pane
        // B's scripted channel is never touched while hidden.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(engine.localChannels[0].listCalls, hasLength(2));
        expect(engine.localChannels[1].listCalls, hasLength(1));

        // pane.focusRight cannot reach a hidden pane: it resolves to
        // the visible survivor and the next chord still targets pane A.
        await tester.tap(
          find.byKey(const ValueKey('command.$kPaneFocusRightCommandId')),
        );
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'pane.left.listing',
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(engine.localChannels[0].listCalls, hasLength(3));
        expect(engine.localChannels[1].listCalls, hasLength(1));

        // Plain Tab inside the listing swaps panes (02 §8.2) — with
        // only one pane it stays put.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'pane.left.listing',
        );

        // Re-showing restores pane B's surface.
        await tester.tap(
          find.byKey(
            const ValueKey('command.$kViewToggleSecondPaneCommandId'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(AdaptiveShell.secondaryPaneKey),
          findsOneWidget,
        );
        expect(find.text('right.txt'), findsOneWidget);

        // Re-showing must not re-grab the active pane: the next
        // refresh chord still lists pane A's channel, not pane B's.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(engine.localChannels[0].listCalls, hasLength(4));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('hiding pane B while a strip control holds focus still '
        'hands focus to pane A', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await pumpApp(tester);
        await tester.pumpAndSettle();

        // The strip's own focusables — chips, the new-tab button — are
        // siblings of the listing's Focus node, not its descendants.
        // Keyboard traversal can land on them; the hide handoff must
        // cover that too. Seeding the scope's focus history with pane
        // A's button first makes the test decisive: without an explicit
        // handoff, the unmount's focus restoration would park on that
        // still-mounted button instead of the surviving listing.
        final leftAddFocus = Focus.of(
          tester.element(
            find.descendant(
              of: find.byKey(const ValueKey('pane.left.tab.new')),
              matching: find.byType(Icon),
            ),
          ),
        );
        leftAddFocus.requestFocus();
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus,
          leftAddFocus,
        );
        final rightAddFocus = Focus.of(
          tester.element(
            find.descendant(
              of: find.byKey(const ValueKey('pane.right.tab.new')),
              matching: find.byType(Icon),
            ),
          ),
        );
        rightAddFocus.requestFocus();
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus,
          rightAddFocus,
        );

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();

        expect(
          find.byKey(AdaptiveShell.secondaryPaneKey),
          findsNothing,
        );
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'pane.left.listing',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('pane B keeps every tab and all per-tab state across a '
        'hide/show', (tester) async {
      // Pane B's scripted channel carries a subfolder so the tab can
      // build history; a third channel backs the strip's second tab.
      engine.localChannels[1].listings['/home/tester'] = [
        _entry('alpha.txt'),
        _entry('beta.txt'),
        const RemoteFileEntry(
          path: '/home/tester/docs',
          name: 'docs',
          type: RemoteFileType.directory,
        ),
      ];
      engine.localChannels[1].listings['/home/tester/docs'] = [
        _entry('inner.txt', parent: '/home/tester/docs'),
      ];
      engine.localChannels.add(
        session_test.FakeAppBrowseChannel(homePath: '/srv/deep')
          ..listings['/srv/deep'] = [
            _entry('deep.txt', parent: '/srv/deep'),
          ],
      );
      await pumpApp(tester);
      await tester.pumpAndSettle();

      final rightStrip = tester
          .widgetList<PaneTabsView>(find.byType(PaneTabsView))
          .toList()[1]
          .tabs;
      final tab1 = rightStrip.tabs[0];
      final c1 = tab1.controller;

      // Layer every per-tab state kind onto the first tab: a history
      // step, a filtered lens, the hidden override, a non-default view
      // mode, a cursor+selection, an open Quick Select session, and an
      // open inline-rename editor.
      c1.navigate('/home/tester/docs');
      await settle(tester);
      c1.openFilter();
      c1.changeFilterQuery('inn');
      c1.showHidden = true;
      c1.viewMode = PaneViewMode.details;
      c1.setCursorIndex(0);
      c1.startRename();
      c1.openQuickSelect();
      c1.changeQuickSelectQuery('in');

      void expectFirstTab() => expectTabState(
        c1,
        location: '/home/tester/docs',
        committed: '/home/tester/docs',
        entries: ['/home/tester/docs/inner.txt'],
        selectedCount: 1,
        selectedRows: [true],
        cursor: 0,
        filterQuery: 'inn',
        filterFieldOpen: true,
        showHidden: true,
        viewMode: PaneViewMode.details,
        canGoBack: true,
        canGoForward: false,
        quickSelectActive: true,
        quickSelectQuery: 'in',
        renameTarget: '/home/tester/docs/inner.txt',
        renameSeed: 'inner.txt',
      );
      expectFirstTab();

      // A second tab with its own location — the strip survives with
      // its WHOLE tab set, not just the active one.
      final tab2 = rightStrip.newTab(target: NewTabTarget.home);
      await settle(tester);
      final c2 = tab2.controller;
      expect(rightStrip.tabs, hasLength(2));
      expect(identical(rightStrip.activeTab, tab2), isTrue);
      expect(c2.location?.path, '/srv/deep');

      // Hide through the registered command: the surface unmounts.
      await tester.tap(
        find.byKey(
          const ValueKey('command.$kViewToggleSecondPaneCommandId'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(AdaptiveShell.secondaryPaneKey), findsNothing);
      expect(find.text('deep.txt'), findsNothing);

      // Nothing was disposed or reset: the strip, both tab objects, and
      // both controllers are the same instances with the same state.
      expect(rightStrip.tabs, hasLength(2));
      expect(identical(rightStrip.tabs[0], tab1), isTrue);
      expect(identical(rightStrip.tabs[1], tab2), isTrue);
      expect(identical(rightStrip.tabs[0].controller, c1), isTrue);
      expect(identical(rightStrip.activeTab, tab2), isTrue);
      expectFirstTab();
      expect(c2.location?.path, '/srv/deep');
      expect(c2.entries.map((e) => e.path), ['/srv/deep/deep.txt']);

      // Re-showing restores it exactly — the remembered pane renders
      // the same active tab and every lens rides again.
      await tester.tap(
        find.byKey(
          const ValueKey('command.$kViewToggleSecondPaneCommandId'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(AdaptiveShell.secondaryPaneKey), findsOneWidget);
      expect(find.text('deep.txt'), findsOneWidget);
      expectFirstTab();
      expect(c2.location?.path, '/srv/deep');

      // History survived the round-trip too: Back on the first tab
      // lands on the pre-hide parent.
      c1.goBack();
      await settle(tester);
      expect(c1.location?.path, '/home/tester');
    });

    testWidgets('the stage-2 auto-hide shares the seam and never '
        'latches the toggle intent', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await pumpApp(tester);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('command.$kPaneFocusRightCommandId')),
        );
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'pane.right.listing',
        );

        // Below 02 §1's stage-2 boundary the shell's own allocation
        // hides pane B — the same mechanism view.toggleSecondPane
        // feeds, so focus and the active pane move to the survivor.
        // pumpApp pins devicePixelRatio to 1.0, so these sizes are
        // logical pixels straddling the real stage-2 breakpoint.
        tester.view.physicalSize = const Size(600, 900);
        await tester.pumpAndSettle();

        expect(
          find.byKey(AdaptiveShell.secondaryPaneKey),
          findsNothing,
        );
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'pane.left.listing',
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(engine.localChannels[0].listCalls, hasLength(2));
        expect(engine.localChannels[1].listCalls, hasLength(1));

        // Regrowth restores pane B on its own: the auto-hide was
        // transient and never latched the toggle's user intent. Same
        // DPR-1.0 logical-pixel sizing as the hide above.
        tester.view.physicalSize = const Size(1400, 900);
        await tester.pumpAndSettle();
        expect(
          find.byKey(AdaptiveShell.secondaryPaneKey),
          findsOneWidget,
        );
        expect(find.text('right.txt'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
