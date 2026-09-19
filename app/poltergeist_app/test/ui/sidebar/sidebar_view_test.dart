import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/application_error_reporter.dart';
import 'package:poltergeist_app/services/connection_state_bridge.dart';
import 'package:poltergeist_app/services/connection_status_controller.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_bookmark_store.dart';

final _now = DateTime.utc(2026, 10, 1);

Bookmark _remote(
  String id, {
  String? group,
  String? sortKey,
}) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: 'label-$id',
  group: group,
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '$id.example.com',
      port: 22,
      username: 'deploy',
      authMethod: AuthMethod.agent,
    ),
  ),
  remotePath: '/srv/$id',
  // Minted keys are a–z only (04 §2.5); 'mm' ties resolve on the id
  // tiebreaker, which is the deterministic order the store itself uses.
  sortKey: sortKey ?? 'mm',
  createdAt: _now,
  updatedAt: _now,
);

/// Scripted connection-state lanes: one broadcast controller per watched
/// server, like the FakeAppEngine's statesControllers. The recovery lane
/// must stay open: a completed stream reads as engine death to the
/// status controller (03 §3.5's teardown contract).
final class _ConnectionLanes implements ConnectionStateBridge {
  final watches = <String, StreamController<ServerStatus>>{};
  final recovery = StreamController<RecoveryFailedEvent>.broadcast();

  @override
  Stream<ServerStatus> watchServer(String serverId) => watches
      .putIfAbsent(
        serverId,
        () => StreamController<ServerStatus>.broadcast(sync: true),
      )
      .stream;

  @override
  Stream<RecoveryFailedEvent> get recoveryFailures => recovery.stream;
}

void main() {
  late FakeBookmarkStore store;
  late List<(Bookmark, SidebarOpenAction)> opens;
  late List<Bookmark> workspaceUpdates;
  late List<ConnectionServer> openedConnections;
  late List<ConnectionServer> disconnected;
  late List<Set<String>> collapsedWrites;
  late List<String> removedIds;
  late _ConnectionLanes lanes;
  ConnectionStatusController? connections;

  Future<SidebarController> pumpSidebar(
    WidgetTester tester, {
    bool withConnections = false,
    bool withWorkspaceUpdate = false,
    ApplicationErrorReporter? errors,
  }) async {
    tester.view.physicalSize = const Size(300, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = SidebarController(
      store: store,
      onCollapsedChanged: collapsedWrites.add,
      onBookmarkRemoved: removedIds.add,
      errors: errors,
    );
    addTearDown(controller.dispose);
    unawaited(controller.reload());

    if (withConnections) {
      connections = ConnectionStatusController(
        bookmarks: store,
        bridge: lanes,
        errors: ApplicationErrorReporter(sink: (_, _) {}),
      );
      addTearDown(connections!.dispose);
      unawaited(connections!.loadServers());
    }

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: SidebarView(
              controller: controller,
              connections: connections,
              onOpenFavorite: (bookmark, action) =>
                  opens.add((bookmark, action)),
              onOpenConnection: openedConnections.add,
              onDisconnect: disconnected.add,
              onReviewBlocked: (_) {},
              onUpdateWorkspace: withWorkspaceUpdate
                  ? workspaceUpdates.add
                  : null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  /// Secondary-taps a favorite row to raise its context menu.
  Future<void> openMenu(WidgetTester tester, String id) async {
    await tester.tap(
      find.byKey(ValueKey('sidebar.favorite.$id')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    store = FakeBookmarkStore();
    opens = [];
    workspaceUpdates = [];
    openedConnections = [];
    disconnected = [];
    collapsedWrites = [];
    removedIds = [];
    lanes = _ConnectionLanes();
    connections = null;
  });

  testWidgets('all four bookmark kinds render with their subtitles', (
    tester,
  ) async {
    store.bookmarks = [
      _remote('r1'),
      Bookmark(
        id: 'l1',
        kind: BookmarkKind.localFolder,
        label: 'Docs',
        localPath: '/home/deploy/docs',
        sortKey: 'k1',
        createdAt: _now,
        updatedAt: _now,
      ),
      Bookmark(
        id: 'w1',
        kind: BookmarkKind.workspace,
        label: 'Daily pair',
        sortKey: 'k2',
        createdAt: _now,
        updatedAt: _now,
      ),
      Bookmark(
        id: 's1',
        kind: BookmarkKind.savedSync,
        label: 'Mirror',
        sortKey: 'k3',
        createdAt: _now,
        updatedAt: _now,
      ),
    ];
    await pumpSidebar(tester);

    for (final id in ['r1', 'l1', 'w1', 's1']) {
      expect(
        find.byKey(ValueKey('sidebar.favorite.$id')),
        findsOneWidget,
        reason: 'missing row for $id',
      );
    }
    expect(find.text('/srv/r1'), findsOneWidget);
    expect(find.text('/home/deploy/docs'), findsOneWidget);
    // Kind names stand in as the subtitle when no single path exists.
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Saved sync'), findsOneWidget);
    // A flat list has no group headers.
    expect(find.text('Favorites'), findsNothing);
  });

  testWidgets('tapping a favorite opens it plain; every kind forwards', (
    tester,
  ) async {
    store.bookmarks = [
      _remote('r1', sortKey: 'ma'),
      Bookmark(
        id: 'l1',
        kind: BookmarkKind.localFolder,
        label: 'Docs',
        localPath: '/home/deploy/docs',
        sortKey: 'mb',
        createdAt: _now,
        updatedAt: _now,
      ),
      Bookmark(
        id: 'w1',
        kind: BookmarkKind.workspace,
        label: 'Daily pair',
        sortKey: 'mc',
        createdAt: _now,
        updatedAt: _now,
      ),
      Bookmark(
        id: 's1',
        kind: BookmarkKind.savedSync,
        label: 'Mirror',
        sortKey: 'md',
        createdAt: _now,
        updatedAt: _now,
      ),
    ];
    await pumpSidebar(tester);

    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.r1')));
    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.l1')));
    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.w1')));
    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.s1')));

    expect(opens.map((open) => open.$1.id), ['r1', 'l1', 'w1', 's1']);
    // The view forwards every kind; the honest workspace/sync notices
    // are the shell's call (02 §4).
    expect(opens.every((open) => open.$2 == SidebarOpenAction.plain), isTrue);
  });

  testWidgets('the menu exposes the three open actions', (tester) async {
    store.bookmarks = [_remote('r1')];
    await pumpSidebar(tester);

    await openMenu(tester, 'r1');
    await tester.tap(find.byKey(const ValueKey('sidebar.menu.openNewTab')));
    await tester.pumpAndSettle();
    expect(opens.single.$2, SidebarOpenAction.newTab);

    await openMenu(tester, 'r1');
    await tester.tap(
      find.byKey(const ValueKey('sidebar.menu.openOtherPane')),
    );
    await tester.pumpAndSettle();
    expect(opens.last.$2, SidebarOpenAction.oppositePane);
  });

  Bookmark workspace(String id) => Bookmark(
    id: id,
    kind: BookmarkKind.workspace,
    label: 'Daily pair',
    left: const BookmarkLocation(path: '/home/a'),
    right: const BookmarkLocation(path: '/srv/b'),
    sortKey: 'm$id',
    createdAt: _now,
    updatedAt: _now,
  );

  testWidgets('a workspace row swaps the modifier verbs for Update '
      'Workspace', (tester) async {
    store.bookmarks = [workspace('w1')];
    await pumpSidebar(tester, withWorkspaceUpdate: true);

    await openMenu(tester, 'w1');
    // One open verb (the workspace replaces BOTH panes — the pane-target
    // modifiers mean nothing for it) and the re-capture verb beside it.
    expect(find.byKey(const ValueKey('sidebar.menu.open')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sidebar.menu.openNewTab')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('sidebar.menu.openOtherPane')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('sidebar.menu.updateWorkspace')),
    );
    await tester.pumpAndSettle();
    expect(workspaceUpdates.map((bookmark) => bookmark.id), ['w1']);
    expect(opens, isEmpty);
  });

  testWidgets('a workspace row without the update seam hides the verb', (
    tester,
  ) async {
    store.bookmarks = [workspace('w1')];
    await pumpSidebar(tester);

    await openMenu(tester, 'w1');
    expect(find.byKey(const ValueKey('sidebar.menu.open')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sidebar.menu.updateWorkspace')),
      findsNothing,
    );
  });

  testWidgets('group headers collapse their rows and persist the state', (
    tester,
  ) async {
    store.bookmarks = [
      _remote('a', group: 'work'),
      _remote('u'),
    ];
    await pumpSidebar(tester);

    expect(find.text('work'), findsOneWidget);
    expect(find.text('Favorites'), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar.favorite.a')), findsOneWidget);

    await tester.tap(find.text('work'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sidebar.favorite.a')), findsNothing);
    expect(find.byKey(const ValueKey('sidebar.favorite.u')), findsOneWidget);
    // The group key is the normalized name (serverGroupKey of 'work').
    expect(collapsedWrites, [
      {'work'},
    ]);

    await tester.tap(find.text('work'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sidebar.favorite.a')), findsOneWidget);
    expect(collapsedWrites.last, isEmpty);
  });

  testWidgets('a tapped header holds focus for keyboard toggles', (
    tester,
  ) async {
    store.bookmarks = [_remote('a', group: 'work')];
    await pumpSidebar(tester);

    await tester.tap(find.text('work'));
    await tester.pumpAndSettle();
    expect(collapsedWrites, [
      {'work'},
    ]);

    // Focus must sit on the header itself: Enter toggles it back.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(collapsedWrites.last, isEmpty);
    expect(
      find.byKey(const ValueKey('sidebar.favorite.a')),
      findsOneWidget,
    );
  });

  testWidgets('arrow keys traverse the rows and Enter opens the '
      'focused one', (tester) async {
    store.bookmarks = [
      _remote('a', sortKey: 'ma'),
      _remote('b', sortKey: 'mb'),
      _remote('c', sortKey: 'mc'),
    ];
    await pumpSidebar(tester);

    // The pointer moves focus with it (02 §4); arrows walk from there.
    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.a')));
    await tester.pumpAndSettle();
    opens.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(opens.single.$1.id, 'b');
    expect(opens.single.$2, SidebarOpenAction.plain);
    opens.clear();

    // Up returns; Space activates the same row Enter would.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(opens.single.$1.id, 'a');
  });

  testWidgets('Shift+F10 raises the focused row\'s context menu', (
    tester,
  ) async {
    store.bookmarks = [_remote('a', sortKey: 'ma'), _remote('b')];
    await pumpSidebar(tester);

    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.b')));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sidebar.menu.open')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sidebar.menu.rename')),
      findsOneWidget,
    );
  });

  testWidgets('every row kind carries its D20 button semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    store.bookmarks = [
      _remote('r2', sortKey: 'ma'),
      Bookmark(
        id: 'l1',
        kind: BookmarkKind.localFolder,
        label: 'Docs',
        localPath: '/home/deploy/docs',
        sortKey: 'mb',
        createdAt: _now,
        updatedAt: _now,
      ),
      Bookmark(
        id: 'w1',
        kind: BookmarkKind.workspace,
        label: 'Daily pair',
        sortKey: 'mc',
        createdAt: _now,
        updatedAt: _now,
      ),
      Bookmark(
        id: 's1',
        kind: BookmarkKind.savedSync,
        label: 'Mirror',
        sortKey: 'md',
        createdAt: _now,
        updatedAt: _now,
      ),
      _remote('r1', group: 'work', sortKey: 'me'),
      _remote('g1', group: 'work', sortKey: 'mf'),
    ];
    try {
      final controller = await pumpSidebar(tester, withConnections: true);
      lanes.watches['r1']!.add(
        const ServerStatus(ServerConnectionState.connected),
      );
      await tester.pumpAndSettle();

      // Collapsing 'work' unmounts r1's favorite row, leaving its
      // CONNECTION row as the only 'label-r1' node in the semantics tree.
      controller.toggleCollapsed('work');
      await tester.pumpAndSettle();

      dataOf(Finder finder) =>
          tester.getSemantics(finder).getSemanticsData();

      // Every favorite kind announces itself as a labelled button — not
      // only the kind that happened to be covered when the row grew. The
      // keyed containers sit under ExcludeSemantics, so the announced node
      // is found by its label, the way assistive tech sees it.
      for (final label in const [
        'label-r2',
        'Docs',
        'Daily pair',
        'Mirror',
      ]) {
        final data = dataOf(
          find.bySemanticsLabel(RegExp('^$label\$')),
        );
        expect(
          data.flagsCollection.isButton,
          isTrue,
          reason: '$label must announce as a button',
        );
      }

      // The live connection row is a button with its server label plus
      // the status suffix (the row folds dynamic state into the label).
      final connection = dataOf(
        find.bySemanticsLabel(RegExp('^label-r1, ')),
      );
      expect(connection.flagsCollection.isButton, isTrue);

      // Section headers announce header + button + expansion state — the
      // collapsed group header reads expanded:false, the live Connections
      // header expanded:true.
      final group = dataOf(find.byKey(const ValueKey('sidebar.section.work')));
      expect(group.flagsCollection.isHeader, isTrue);
      expect(group.flagsCollection.isButton, isTrue);
      expect(group.flagsCollection.isExpanded, ui.Tristate.isFalse);
      final connectionsHeader = dataOf(
        find.byKey(const ValueKey('sidebar.section.sidebar.connections')),
      );
      expect(
        connectionsHeader.flagsCollection.isHeader,
        isTrue,
      );
      expect(
        connectionsHeader.flagsCollection.isExpanded,
        ui.Tristate.isTrue,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('rename through the menu dialog lands on the store', (
    tester,
  ) async {
    store.bookmarks = [_remote('r1')];
    await pumpSidebar(tester);

    await openMenu(tester, 'r1');
    await tester.tap(find.byKey(const ValueKey('sidebar.menu.rename')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('sidebar.renameField')),
      'renamed',
    );
    // The field's onChanged → setState needs a frame before the save
    // button's onPressed is live.
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sidebar.renameSave')));
    await tester.pumpAndSettle();

    expect(store.bookmarks.single.label, 'renamed');
    expect(find.text('renamed'), findsOneWidget);
  });

  testWidgets('delete confirms then removes and cascades', (tester) async {
    store.bookmarks = [_remote('r1'), _remote('r2')];
    await pumpSidebar(tester);

    await openMenu(tester, 'r1');
    await tester.tap(find.byKey(const ValueKey('sidebar.menu.delete')));
    await tester.pumpAndSettle();

    // The confirm dialog names the row before the destructive verb.
    expect(find.textContaining('label-r1'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('sidebar.deleteConfirm')));
    await tester.pumpAndSettle();

    expect(store.bookmarks.map((bookmark) => bookmark.id), ['r2']);
    expect(removedIds, ['r1']);
    expect(
      find.byKey(const ValueKey('sidebar.favorite.r1')),
      findsNothing,
    );
  });

  testWidgets('the Move to Group submenu refiles through the store', (
    tester,
  ) async {
    store.bookmarks = [
      _remote('a', group: 'work'),
      _remote('b', group: 'home'),
    ];
    await pumpSidebar(tester);

    await openMenu(tester, 'a');
    await tester.tap(
      find.byKey(const ValueKey('sidebar.menu.moveToGroup')),
    );
    await tester.pumpAndSettle();
    // The group header 'home' is mounted beside the menu item — the
    // widgetWithText finder hits the button, not the header.
    await tester.tap(find.widgetWithText(MenuItemButton, 'home'));
    await tester.pumpAndSettle();

    expect(
      store.bookmarks.firstWhere((bookmark) => bookmark.id == 'a').group,
      'home',
    );

    // Ungrouping is the same menu's null target.
    await openMenu(tester, 'a');
    await tester.tap(
      find.byKey(const ValueKey('sidebar.menu.moveToGroup')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar.menu.ungroup')));
    await tester.pumpAndSettle();

    expect(
      store.bookmarks.firstWhere((bookmark) => bookmark.id == 'a').group,
      isNull,
    );
  });

  testWidgets('the new-group dialog creates the group by the move', (
    tester,
  ) async {
    store.bookmarks = [_remote('a')];
    await pumpSidebar(tester);

    await openMenu(tester, 'a');
    await tester.tap(
      find.byKey(const ValueKey('sidebar.menu.moveToGroup')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar.menu.newGroup')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('sidebar.groupField')),
      'fresh',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sidebar.groupSave')));
    await tester.pumpAndSettle();

    expect(
      store.bookmarks.firstWhere((bookmark) => bookmark.id == 'a').group,
      'fresh',
    );
    expect(find.text('fresh'), findsOneWidget);
  });

  testWidgets('Enter on a focused row opens it plain', (tester) async {
    store.bookmarks = [_remote('r1')];
    await pumpSidebar(tester);

    // The tap lands focus on the row; the keyboard press is the second
    // activation this test asserts on.
    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.r1')));
    opens.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(opens.single.$2, SidebarOpenAction.plain);
  });

  testWidgets('the Connections section lists only live pool rows', (
    tester,
  ) async {
    store.bookmarks = [_remote('b1')];
    await pumpSidebar(tester, withConnections: true);

    // Nothing live yet: the section itself stays unmounted.
    expect(find.text('Connections'), findsNothing);
    expect(
      find.byKey(const ValueKey('sidebar.connection.b1')),
      findsNothing,
    );

    lanes.watches['b1']!.add(
      const ServerStatus(ServerConnectionState.connected),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connections'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sidebar.connection.b1')),
      findsOneWidget,
    );

    // Tapping the row routes through the other-pane open seam.
    await tester.tap(
      find.byKey(const ValueKey('sidebar.connection.b1')),
    );
    expect(openedConnections.map((server) => server.serverId), ['b1']);
  });

  testWidgets('the connection menu disconnects a live row', (tester) async {
    store.bookmarks = [_remote('b1')];
    await pumpSidebar(tester, withConnections: true);
    lanes.watches['b1']!.add(
      const ServerStatus(ServerConnectionState.connected),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('sidebar.connection.b1')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('sidebar.menu.disconnect')),
    );
    // The menu item's onPressed lands on the next frame after the tap.
    await tester.pump();

    expect(disconnected.map((server) => server.serverId), ['b1']);
  });

  testWidgets('an empty store renders the honest empty state', (
    tester,
  ) async {
    await pumpSidebar(tester);

    expect(
      find.textContaining('No favorites yet'),
      findsOneWidget,
    );
  });

  testWidgets('a failed load shows the error and retry recovers', (
    tester,
  ) async {
    store.failure = StateError('unreadable');
    final reported = <Object>[];
    await pumpSidebar(
      tester,
      errors: ApplicationErrorReporter(sink: (error, _) {
        reported.add(error);
      }),
    );

    // The failure must surface through the reporter exactly once — a
    // silent retry state would hide the diagnostic path.
    expect(reported, hasLength(1));
    expect(find.byKey(const ValueKey('sidebar.retry')), findsOneWidget);

    store
      ..failure = null
      ..bookmarks = [_remote('r1')];
    await tester.tap(find.byKey(const ValueKey('sidebar.retry')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('sidebar.favorite.r1')),
      findsOneWidget,
    );
  });

  testWidgets('a null open seam renders rows non-interactive', (
    tester,
  ) async {
    store.bookmarks = [_remote('r1')];
    tester.view.physicalSize = const Size(300, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = SidebarController(store: store);
    addTearDown(controller.dispose);
    unawaited(controller.reload());
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: SidebarView(
              controller: controller,
              onOpenFavorite: null,
              onOpenConnection: openedConnections.add,
              onDisconnect: disconnected.add,
              onReviewBlocked: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The row renders but a tap must not forward — the honest disabled
    // posture the connection rows already had.
    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.r1')));
    expect(opens, isEmpty);
  });

  testWidgets('a favorite with no open seam announces inert, not a '
      'button (D20)', (tester) async {
    final semantics = tester.ensureSemantics();
    store.bookmarks = [_remote('r1')];
    tester.view.physicalSize = const Size(300, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = SidebarController(store: store);
    addTearDown(controller.dispose);
    unawaited(controller.reload());
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: SidebarView(
                controller: controller,
                onOpenFavorite: null,
                onOpenConnection: openedConnections.add,
                onDisconnect: disconnected.add,
                onReviewBlocked: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // An announced-but-inert button is a dead affordance (WCAG 4.1.2)
      // — the same rule the connection row's `button:` gate applies.
      final data = tester
          .getSemantics(find.bySemanticsLabel('label-r1'))
          .getSemanticsData();
      expect(data.flagsCollection.isButton, isFalse);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a drop on a row lands on its edge side', (tester) async {
    store.bookmarks = [
      _remote('a', sortKey: 'ma'),
      _remote('b', sortKey: 'mb'),
      _remote('c', sortKey: 'mc'),
    ];
    final controller = await pumpSidebar(tester);

    // DragTarget's details.offset is the feedback avatar's TOP-LEFT —
    // grab the row at its top edge so the anchor (~2px) makes the
    // pointer position and the drop offset nearly coincide.
    Finder row(String id) => find.byKey(ValueKey('sidebar.favorite.$id'));

    Future<void> dragOnto(String id, Offset target) async {
      final gesture = await tester.startGesture(
        tester.getTopLeft(row(id)) + const Offset(10, 2),
      );
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    // The controller's sections carry the store's SORT order — the raw
    // `store.bookmarks` list keeps insertion order under an upsert.
    List<String> order() => [
      for (final section in controller.sections)
        ...section.bookmarks.map((bookmark) => bookmark.id),
    ];

    // Drop on the bottom half of 'c' — the row is the `beforeId` under
    // the store's between-neighbors convention, so 'a' lands last.
    await dragOnto('a', tester.getCenter(row('c')) + const Offset(0, 10));
    expect(order(), ['b', 'c', 'a']);

    // Drop on the TOP half of 'b' — lands before it.
    await dragOnto('a', tester.getCenter(row('b')) - const Offset(0, 10));
    expect(order(), ['a', 'b', 'c']);
  });

  testWidgets('a drop on a group header refiles the bookmark', (
    tester,
  ) async {
    store.bookmarks = [
      _remote('a', group: 'work'),
      _remote('u', sortKey: 'mb'),
    ];
    await pumpSidebar(tester);

    final gesture = await tester.startGesture(
      tester.getTopLeft(find.byKey(const ValueKey('sidebar.favorite.u'))) +
          const Offset(10, 2),
    );
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('work')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      store.bookmarks.firstWhere((bookmark) => bookmark.id == 'u').group,
      'work',
    );
  });
}
