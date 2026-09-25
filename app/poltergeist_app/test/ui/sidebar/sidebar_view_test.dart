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
import 'package:poltergeist_app/services/local_volumes.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/server_appearance.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_kit.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_app_transfer_queue.dart';
import '../../support/fake_bookmark_store.dart';
import '../../support/test_panes.dart';

final _now = DateTime.utc(2026, 10, 1);

Bookmark _remote(String id, {String? group, String? sortKey}) => Bookmark(
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

Bookmark _local(
  String id, {
  String? label,
  String? path,
  String? group,
  String sortKey = 'mm',
}) => Bookmark(
  id: id,
  kind: BookmarkKind.localFolder,
  label: label ?? 'folder-$id',
  localPath: path ?? '/home/deploy/$id',
  group: group,
  sortKey: sortKey,
  createdAt: _now,
  updatedAt: _now,
);

/// Scripted connection-state lanes: one broadcast controller per watched
/// server. The recovery lane must stay open: a completed stream reads as
/// engine death to the status controller (03 §3.5's teardown contract).
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

/// DEVICES without the host: a scripted mount list, folder set, and eject
/// answer — the sidebar must never depend on what this machine mounts.
final class _FakeVolumes implements LocalVolumeSource {
  List<LocalVolume> volumes = const [];
  List<String> standard = const [];
  String? home = '/home/deploy';
  Set<String> directories = {};
  bool ejectResult = true;
  final ejects = <String>[];
  int listCalls = 0;
  final changesLane = StreamController<void>.broadcast();

  @override
  Future<List<LocalVolume>> list() async {
    listCalls++;
    return volumes;
  }

  /// Free-space answers the test holds back; unlisted rows answer the
  /// number they were scripted with.
  final pendingFree = <String, Completer<int?>>{};

  @override
  Future<int?> freeBytes(LocalVolume volume) =>
      pendingFree[volume.path]?.future ?? Future.value(volume.freeBytes);

  @override
  Future<List<String>> standardFolders() async => standard;

  @override
  String? get homeDirectory => home;

  @override
  Future<bool> isDirectory(String path) async => directories.contains(path);

  @override
  Stream<void> get changes => changesLane.stream;

  @override
  Future<bool> eject(LocalVolume volume) async {
    ejects.add(volume.path);
    return ejectResult;
  }
}

const _home = LocalVolume(
  path: '/home/deploy',
  name: 'deploy',
  kind: LocalVolumeKind.home,
  freeBytes: 69000000000,
);
const _root = LocalVolume(
  path: '/',
  name: 'Macintosh HD',
  kind: LocalVolumeKind.root,
  freeBytes: 69000000000,
);
const _usb = LocalVolume(
  path: '/Volumes/STICK',
  name: 'STICK',
  kind: LocalVolumeKind.removable,
  freeBytes: 2000000000,
);

void main() {
  late FakeBookmarkStore store;
  late List<(Bookmark, SidebarOpenAction)> opens;
  late List<Bookmark> workspaceUpdates;
  late List<ConnectionServer> disconnected;
  late List<ConnectionServer> reviewed;
  late List<Set<String>> collapsedWrites;
  late List<SidebarDensity> densityWrites;
  late List<String> removedIds;
  late _ConnectionLanes lanes;
  ConnectionStatusController? connections;

  Future<SidebarController> pumpSidebar(
    WidgetTester tester, {
    bool withConnections = false,
    bool withWorkspaceUpdate = false,
    bool withOpen = true,
    VoidCallback? onImportSshConfig,
    ApplicationErrorReporter? errors,
    LocalVolumeSource? volumes,
    WorkspaceController? workspace,
    SidebarSyncStatus Function()? syncStatus,
    VoidCallback? onSyncNow,
    VoidCallback? onOpenSyncSettings,
    VoidCallback? onQuickConnect,
    VoidCallback? onOpenSettings,
    VoidCallback? onAddServer,
    PaneDropDelegate? dropDelegate,
    DateTime Function()? clock,
    Widget? dragSource,
    double height = 800,
    bool settle = true,
    // The one-line rail most of these tests describe; null leaves the
    // controller's own default (comfortable) in force.
    SidebarDensity? density = SidebarDensity.compact,
  }) async {
    // Wider than the rail: the drop tests park a drag source beside it,
    // and a context menu needs room to open where it was asked.
    tester.view.physicalSize = Size(900, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = density == null
        ? SidebarController(
            store: store,
            onCollapsedChanged: collapsedWrites.add,
            onDensityChanged: densityWrites.add,
            onBookmarkRemoved: removedIds.add,
            errors: errors,
          )
        : SidebarController(
            store: store,
            density: density,
            onCollapsedChanged: collapsedWrites.add,
            onDensityChanged: densityWrites.add,
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

    final sidebar = SidebarView(
      controller: controller,
      connections: connections,
      onOpenFavorite: withOpen
          ? (bookmark, action) => opens.add((bookmark, action))
          : null,
      onDisconnect: disconnected.add,
      onReviewBlocked: reviewed.add,
      onUpdateWorkspace: withWorkspaceUpdate ? workspaceUpdates.add : null,
      onImportSshConfig: onImportSshConfig,
      volumes: volumes,
      workspace: workspace,
      syncStatus: syncStatus,
      onSyncNow: onSyncNow,
      onOpenSyncSettings: onOpenSyncSettings,
      onQuickConnect: onQuickConnect,
      onOpenSettings: onOpenSettings,
      onAddCatalogServer: onAddServer,
      dropDelegate: dropDelegate,
      clock: clock ?? DateTime.now,
    );
    await tester.pumpWidget(
      MaterialApp(
        // The desktop density tokens (26 px rows) the rail is drawn in.
        theme: buildPoltergeistTheme(
          Brightness.light,
          platform: TargetPlatform.linux,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(width: 300, child: sidebar),
              if (dragSource != null) Expanded(child: dragSource),
            ],
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // A syncing chip animates its spinner — settling would never end.
      await tester.pump();
      await tester.pump();
    }
    return controller;
  }

  /// Secondary-taps a bookmark row to raise its context menu.
  Future<void> openMenu(WidgetTester tester, String id) async {
    await tester.tap(
      find.byKey(ValueKey('sidebar.favorite.$id')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
  }

  SidebarRow rowOf(WidgetTester tester, Finder row) =>
      tester.widget<SidebarRow>(
        find.descendant(of: row, matching: find.byType(SidebarRow)),
      );

  setUp(() {
    store = FakeBookmarkStore();
    opens = [];
    workspaceUpdates = [];
    disconnected = [];
    reviewed = [];
    collapsedWrites = [];
    densityWrites = [];
    removedIds = [];
    lanes = _ConnectionLanes();
    connections = null;
  });

  group('sections', () {
    testWidgets('every bookmark kind lands in FAVORITES on one line', (
      tester,
    ) async {
      store.bookmarks = [
        _remote('r1'),
        _local('l1', label: 'Docs', path: '/home/deploy/docs'),
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

      Finder inSection(String id) =>
          find.byKey(ValueKey('sidebar.favorite.$id'));
      for (final id in ['r1', 'l1', 'w1', 's1']) {
        expect(inSection(id), findsOneWidget, reason: 'missing row for $id');
      }
      // Every kind sits under FAVORITES (10 §5, D33): the remote
      // location beside the local folder, the workspace and the sync.
      // SERVERS below keeps the account's servers and live sessions.
      final favoritesHeader = tester.getTopLeft(
        find.byKey(const ValueKey('sidebar.section.sec:favorites')),
      );
      final serversHeader = tester.getTopLeft(
        find.byKey(const ValueKey('sidebar.section.sec:servers')),
      );
      for (final id in ['r1', 'l1', 'w1', 's1']) {
        final y = tester.getTopLeft(inSection(id)).dy;
        expect(y, greaterThan(favoritesHeader.dy));
        expect(y, lessThan(serversHeader.dy));
      }

      // One line per row (10 §5): paths are tooltips, never subtitles.
      expect(find.text('/home/deploy/docs'), findsNothing);
      expect(find.text('/srv/r1'), findsNothing);
      expect(find.byTooltip('/home/deploy/docs'), findsOneWidget);
      expect(
        find.byTooltip('deploy@r1.example.com:22\n/srv/r1'),
        findsOneWidget,
      );
      expect(tester.getSize(inSection('l1')).height, 26);
      // Headers render their titles in caps; no Connections section.
      expect(find.text('FAVORITES'), findsOneWidget);
      expect(find.text('SERVERS'), findsOneWidget);
      expect(find.text('Connections'), findsNothing);
    });

    testWidgets('tapping a row opens it plain; every kind forwards', (
      tester,
    ) async {
      store.bookmarks = [
        _remote('r1', sortKey: 'ma'),
        _local('l1', sortKey: 'mb'),
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

      for (final id in ['r1', 'l1', 'w1', 's1']) {
        await tester.tap(find.byKey(ValueKey('sidebar.favorite.$id')));
      }
      expect(opens.map((open) => open.$1.id).toSet(), {'r1', 'l1', 'w1', 's1'});
      expect(opens.every((open) => open.$2 == SidebarOpenAction.plain), isTrue);
    });

    testWidgets('an empty store renders both honest empty states', (
      tester,
    ) async {
      await pumpSidebar(tester);

      expect(find.textContaining('Drag folders here'), findsOneWidget);
      // Without the shared account SERVERS holds only live sessions, and
      // says where a saved one goes.
      expect(
        find.textContaining('Quick Connect sessions show here'),
        findsOneWidget,
      );
      // No import seam: D22's offer stays absent, not dead.
      expect(
        find.byKey(const ValueKey('sidebar.importSshConfig')),
        findsNothing,
      );
      // Nothing is ever seeded behind the user's back — favorites sync.
      expect(store.bookmarks, isEmpty);
    });

    testWidgets('the empty favorites state offers the ssh_config import', (
      tester,
    ) async {
      var taps = 0;
      await pumpSidebar(tester, onImportSshConfig: () => taps++);

      // Imported hosts land in FAVORITES, so the offer sits there.
      final offer = find.descendant(
        of: find.byKey(const ValueKey('sidebar.favorites.empty')),
        matching: find.byKey(const ValueKey('sidebar.importSshConfig')),
      );
      expect(offer, findsOneWidget);
      await tester.tap(offer);
      expect(taps, 1);
    });

    testWidgets('the import offer hides once any favorite exists', (
      tester,
    ) async {
      store.bookmarks = [_local('l1')];
      await pumpSidebar(tester, onImportSshConfig: () {});

      expect(
        find.byKey(const ValueKey('sidebar.importSshConfig')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('sidebar.favorite.l1')), findsOneWidget);
    });

    testWidgets('a failed load shows the error and retry recovers', (
      tester,
    ) async {
      store.failure = StateError('unreadable');
      final reported = <Object>[];
      await pumpSidebar(
        tester,
        errors: ApplicationErrorReporter(
          sink: (error, _) {
            reported.add(error);
          },
        ),
      );

      // The failure surfaces through the reporter exactly once.
      expect(reported, hasLength(1));
      expect(find.byKey(const ValueKey('sidebar.retry')), findsOneWidget);

      store
        ..failure = null
        ..bookmarks = [_remote('r1')];
      await tester.tap(find.byKey(const ValueKey('sidebar.retry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sidebar.favorite.r1')), findsOneWidget);
    });
  });

  group('groups and collapse', () {
    testWidgets('favorite groups nest and persist a fav: key', (tester) async {
      store.bookmarks = [
        _local('a', group: 'work'),
        _local('u', sortKey: 'mb'),
      ];
      await pumpSidebar(tester);

      expect(find.text('work'), findsOneWidget);
      // Members indent one level under their disclosure row.
      final a = rowOf(tester, find.byKey(const ValueKey('sidebar.favorite.a')));
      final u = rowOf(tester, find.byKey(const ValueKey('sidebar.favorite.u')));
      expect(a.depth, 1);
      expect(u.depth, 0);

      await tester.tap(find.text('work'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sidebar.favorite.a')), findsNothing);
      expect(find.byKey(const ValueKey('sidebar.favorite.u')), findsOneWidget);
      expect(collapsedWrites, [
        {'fav:work'},
      ]);

      await tester.tap(find.text('work'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sidebar.favorite.a')), findsOneWidget);
      expect(collapsedWrites.last, isEmpty);
    });

    testWidgets('a remote favorite and a local one share their group', (
      tester,
    ) async {
      store.bookmarks = [
        _local('f', group: 'work'),
        _remote('s', group: 'work', sortKey: 'mn'),
      ];
      await pumpSidebar(tester);

      // One group under FAVORITES holds both kinds, as before D32. (A
      // catalog group of the same name folds apart: the catalog test.)
      expect(find.text('work'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sidebar.section.fav:work')));
      await tester.pumpAndSettle();

      expect(collapsedWrites.last, {'fav:work'});
      expect(find.byKey(const ValueKey('sidebar.favorite.s')), findsNothing);
      expect(find.byKey(const ValueKey('sidebar.favorite.f')), findsNothing);
    });

    testWidgets('a local folder reorders among remote favorites', (
      tester,
    ) async {
      store.bookmarks = [
        _remote('a', sortKey: 'ma'),
        _local('b', sortKey: 'mb'),
        _remote('c', sortKey: 'mc'),
      ];
      final controller = await pumpSidebar(tester);
      Finder row(String id) => find.byKey(ValueKey('sidebar.favorite.$id'));

      final gesture = await tester.startGesture(
        tester.getTopLeft(row('b')) + const Offset(10, 2),
      );
      await tester.pump();
      await gesture.moveTo(tester.getCenter(row('c')) + const Offset(0, 8));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final order = [
        for (final section in controller.sections)
          for (final bookmark in section.bookmarks) bookmark.id,
      ];
      expect(order, ['a', 'c', 'b']);
    });

    testWidgets('a section folds whole and shows its count only then', (
      tester,
    ) async {
      store.bookmarks = [_local('a'), _local('b', sortKey: 'mb')];
      await pumpSidebar(tester);
      final header = find.byKey(
        const ValueKey('sidebar.section.sec:favorites'),
      );
      expect(
        find.descendant(of: header, matching: find.text('2')),
        findsNothing,
      );

      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(collapsedWrites.last, {'sec:favorites'});
      expect(find.byKey(const ValueKey('sidebar.favorite.a')), findsNothing);
      expect(
        find.descendant(of: header, matching: find.text('2')),
        findsOneWidget,
      );
    });

    testWidgets('a legacy collapse set migrates into the namespaces', (
      tester,
    ) async {
      store.bookmarks = [
        _local('f', group: 'work'),
        _remote('s', group: 'ops'),
      ];
      final controller = SidebarController(
        store: store,
        initiallyCollapsed: {
          'work',
          'sidebar.catalog.ops',
          'sidebar.connections',
        },
      );
      addTearDown(controller.dispose);
      await controller.reload();

      expect(controller.collapsedGroups, {'fav:work', 'srv:ops'});
    });

    testWidgets('a tapped header holds focus for keyboard toggles', (
      tester,
    ) async {
      store.bookmarks = [_local('a', group: 'work')];
      await pumpSidebar(tester);

      await tester.tap(find.text('work'));
      await tester.pumpAndSettle();
      expect(collapsedWrites, [
        {'fav:work'},
      ]);

      // Focus must sit on the header itself: Enter toggles it back.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(collapsedWrites.last, isEmpty);
      expect(find.byKey(const ValueKey('sidebar.favorite.a')), findsOneWidget);
    });
  });

  group('keyboard and menus', () {
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

    testWidgets('right-click opens the menu at the pointer', (tester) async {
      store.bookmarks = [_remote('r1')];
      await pumpSidebar(tester);

      final row = find.byKey(const ValueKey('sidebar.favorite.r1'));
      final at = tester.getTopLeft(row) + const Offset(200, 10);
      await tester.tapAt(at, buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      final open = find.byKey(const ValueKey('sidebar.menu.open'));
      expect(open, findsOneWidget);
      // The menu's first item hangs from the click, not the row's start.
      expect(tester.getTopLeft(open).dx, greaterThan(150));
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

    // Comfortable, the default, draws every row's "⋮", and a focused row
    // its hover action: the arrows walk the rows past both.
    for (final density in SidebarDensity.values) {
      testWidgets('the arrows walk past the rows\' buttons '
          '(${density.name})', (tester) async {
        store.bookmarks = [
          _local('a', label: 'Alpha', sortKey: 'ma'),
          _local('b', label: 'Beta', sortKey: 'mb'),
          _local('c', label: 'Gamma', sortKey: 'mc'),
        ];
        await pumpSidebar(tester, density: density);
        await tester.tap(find.byKey(const ValueKey('sidebar.favorite.a')));
        await tester.pumpAndSettle();
        opens.clear();

        Future<void> press(LogicalKeyboardKey key) async {
          await tester.sendKeyEvent(key);
          await tester.pump();
        }

        await press(LogicalKeyboardKey.arrowDown);
        await press(LogicalKeyboardKey.arrowDown);
        await press(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(opens.map((open) => open.$1.id), ['c']);
        opens.clear();

        await press(LogicalKeyboardKey.arrowUp);
        await press(LogicalKeyboardKey.arrowUp);
        await press(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(opens.map((open) => open.$1.id), ['a']);
      });
    }

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
      expect(find.byKey(const ValueKey('sidebar.menu.rename')), findsOneWidget);
    });

    testWidgets('a clicked row wears no focus ring until a key arrives', (
      tester,
    ) async {
      store.bookmarks = [_local('a', sortKey: 'ma'), _local('b')];
      await pumpSidebar(tester);

      Border? borderOf(String id) {
        final boxes = tester.widgetList<Container>(
          find.descendant(
            of: find.byKey(ValueKey('sidebar.favorite.$id')),
            matching: find.byType(Container),
          ),
        );
        // The ring paints over the row (the kit's foreground decoration),
        // so it never shifts what it frames.
        for (final box in boxes) {
          final decoration = box.foregroundDecoration;
          if (decoration is BoxDecoration && decoration.border != null) {
            return decoration.border! as Border;
          }
        }
        return null;
      }

      await tester.tap(find.byKey(const ValueKey('sidebar.favorite.a')));
      await tester.pumpAndSettle();
      expect(borderOf('a'), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(borderOf('b'), isNotNull);
    });

    testWidgets('a touch long-press opens the verbs as a bottom sheet', (
      tester,
    ) async {
      store.bookmarks = [_local('a')];
      await pumpSidebar(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('sidebar.favorite.a'))),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      // The sheet's heading spells the row's second line under its name,
      // the one place a compact row's path shows on touch.
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('/home/deploy/a'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('sidebar.menu.open')));
      await tester.pumpAndSettle();
      expect(opens.single.$1.id, 'a');
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('every row kind carries its D20 semantics', (tester) async {
      final semantics = tester.ensureSemantics();
      store.bookmarks = [
        _remote('r2', sortKey: 'ma'),
        _local('l1', label: 'Docs', sortKey: 'mb'),
        Bookmark(
          id: 'w1',
          kind: BookmarkKind.workspace,
          label: 'Daily pair',
          sortKey: 'mc',
          createdAt: _now,
          updatedAt: _now,
        ),
        _remote('r1', group: 'work', sortKey: 'me'),
      ];
      try {
        final controller = await pumpSidebar(tester, withConnections: true);
        lanes.watches['r1']!.add(
          const ServerStatus(ServerConnectionState.connected),
        );
        await tester.pumpAndSettle();

        dataOf(Finder finder) => tester.getSemantics(finder).getSemanticsData();

        for (final label in const [
          // A server row names its endpoint and landing folder on the
          // compact rail too: the tooltip is not a screen reader's.
          'label-r2, deploy@r2.example.com · /srv/r2',
          'Docs',
          'Daily pair',
        ]) {
          final data = dataOf(
            find.bySemanticsLabel(RegExp('^${RegExp.escape(label)}\$')),
          );
          expect(
            data.flagsCollection.isButton,
            isTrue,
            reason: '$label must announce as a button',
          );
        }
        // The live server row folds its state into the label.
        final live = dataOf(
          find.bySemanticsLabel(
            'label-r1, Connected, deploy@r1.example.com · /srv/r1',
          ),
        );
        expect(live.flagsCollection.isButton, isTrue);

        controller.toggleCollapsed('fav:work');
        await tester.pumpAndSettle();
        final group = dataOf(
          find.byKey(const ValueKey('sidebar.section.fav:work')),
        );
        expect(group.flagsCollection.isHeader, isTrue);
        expect(group.flagsCollection.isButton, isTrue);
        expect(group.flagsCollection.isExpanded, ui.Tristate.isFalse);
        final servers = dataOf(
          find.byKey(const ValueKey('sidebar.section.sec:servers')),
        );
        expect(servers.flagsCollection.isHeader, isTrue);
        expect(servers.flagsCollection.isExpanded, ui.Tristate.isTrue);
        // The caps are visual: the announcement keeps the authored name.
        expect(servers.label, startsWith('Servers'));
      } finally {
        semantics.dispose();
      }
    });
  });

  group('store verbs', () {
    testWidgets('rename through the menu dialog lands on the store', (
      tester,
    ) async {
      store.bookmarks = [_remote('r1')];
      await pumpSidebar(tester);

      await openMenu(tester, 'r1');
      await tester.tap(find.byKey(const ValueKey('sidebar.menu.rename')));
      await tester.pumpAndSettle();
      expect(find.text('Rename Server'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('sidebar.renameField')),
        'renamed',
      );
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

      expect(find.textContaining('label-r1'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('sidebar.deleteConfirm')));
      await tester.pumpAndSettle();

      expect(store.bookmarks.map((bookmark) => bookmark.id), ['r2']);
      expect(removedIds, ['r1']);
      expect(find.byKey(const ValueKey('sidebar.favorite.r1')), findsNothing);
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
      await tester.tap(find.byKey(const ValueKey('sidebar.menu.moveToGroup')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'home'));
      await tester.pumpAndSettle();

      expect(
        store.bookmarks.firstWhere((bookmark) => bookmark.id == 'a').group,
        'home',
      );

      await openMenu(tester, 'a');
      await tester.tap(find.byKey(const ValueKey('sidebar.menu.moveToGroup')));
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
      await tester.tap(find.byKey(const ValueKey('sidebar.menu.moveToGroup')));
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

    testWidgets('a null open seam renders rows inert, not buttons', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      store.bookmarks = [_remote('r1')];
      try {
        await pumpSidebar(tester, withOpen: false);
        await tester.tap(find.byKey(const ValueKey('sidebar.favorite.r1')));
        expect(opens, isEmpty);
        // An announced-but-inert button is a dead affordance (WCAG 4.1.2).
        final data = tester
            .getSemantics(find.bySemanticsLabel(RegExp('^label-r1, ')))
            .getSemanticsData();
        expect(data.flagsCollection.isButton, isFalse);
      } finally {
        semantics.dispose();
      }
    });
  });

  group('hidden live connections', () {
    SidebarSectionHeader headerOf(WidgetTester tester, String key) =>
        tester.widget<SidebarSectionHeader>(
          find.ancestor(
            of: find.byKey(ValueKey('sidebar.section.$key')),
            matching: find.byType(SidebarSectionHeader),
          ),
        );

    Future<PoltergeistChrome> connect(WidgetTester tester, String id) async {
      lanes.watches[id]!.add(
        const ServerStatus(ServerConnectionState.connected),
      );
      await tester.pumpAndSettle();
      return PoltergeistChrome.of(tester.element(find.byType(SidebarView)));
    }

    testWidgets('a folded group shows the live server it hides', (
      tester,
    ) async {
      store.bookmarks = [
        _remote('r1', group: 'work'),
        _local('l1', group: 'work', sortKey: 'mn'),
      ];
      final controller = await pumpSidebar(tester, withConnections: true);
      final chrome = await connect(tester, 'r1');

      // Open, the row wears its own dot; the header needs none.
      expect(headerOf(tester, 'fav:work').status, isNull);

      controller.toggleCollapsed('fav:work');
      await tester.pumpAndSettle();
      expect(
        headerOf(tester, 'fav:work').status,
        SidebarStatusDot(chrome.statusConnected),
      );
    });

    testWidgets('a folded section shows the live server it hides', (
      tester,
    ) async {
      store.bookmarks = [_remote('r1')];
      final controller = await pumpSidebar(tester, withConnections: true);
      final chrome = await connect(tester, 'r1');
      expect(headerOf(tester, 'sec:favorites').status, isNull);

      controller.toggleCollapsed('sec:favorites');
      await tester.pumpAndSettle();
      expect(
        headerOf(tester, 'sec:favorites').status,
        SidebarStatusDot(chrome.statusConnected),
      );
    });

    testWidgets('a live server the filter hides keeps its dot in view', (
      tester,
    ) async {
      store.bookmarks = [
        _remote('r1', sortKey: 'ma'),
        _local('l1', label: 'Docs', sortKey: 'mb'),
      ];
      final controller = await pumpSidebar(tester, withConnections: true);
      final chrome = await connect(tester, 'r1');
      controller.requestFilter();
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('sidebar.filter.field')),
        'Docs',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sidebar.favorite.r1')), findsNothing);
      expect(
        headerOf(tester, 'sec:favorites').status,
        SidebarStatusDot(chrome.statusConnected),
      );

      // Nothing matches at all: the section's header stays for the dot.
      await tester.enterText(
        find.byKey(const ValueKey('sidebar.filter.field')),
        'zzz',
      );
      await tester.pumpAndSettle();
      expect(
        headerOf(tester, 'sec:favorites').status,
        SidebarStatusDot(chrome.statusConnected),
      );
    });

    testWidgets('an idle server hidden in a fold marks nothing', (
      tester,
    ) async {
      store.bookmarks = [_remote('r1', group: 'work')];
      final controller = await pumpSidebar(tester, withConnections: true);
      controller.toggleCollapsed('fav:work');
      await tester.pumpAndSettle();
      expect(headerOf(tester, 'fav:work').status, isNull);
      expect(headerOf(tester, 'sec:favorites').status, isNull);
    });
  });

  group('servers', () {
    testWidgets('a saved server carries its live state as its one dot, with '
        'no Connections copy', (tester) async {
      store.bookmarks = [_remote('b1')];
      await pumpSidebar(tester, withConnections: true);
      final row = find.byKey(const ValueKey('sidebar.favorite.b1'));
      expect(rowOf(tester, row).status, isNull);

      lanes.watches['b1']!.add(
        const ServerStatus(ServerConnectionState.connected),
      );
      await tester.pumpAndSettle();

      expect(row, findsOneWidget);
      final chrome = PoltergeistChrome.of(tester.element(row));
      expect(
        rowOf(tester, row).status,
        SidebarStatusDot(chrome.statusConnected),
      );
      // The state is in words too: the tooltip names it.
      expect(rowOf(tester, row).tooltip, startsWith('Connected\n'));
      expect(find.byKey(const ValueKey('sidebar.connection.b1')), findsNothing);

      // A reconnect attempt turns the dot amber (10 §5's connecting).
      lanes.watches['b1']!.add(
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await tester.pump();
      expect(
        rowOf(tester, row).status,
        SidebarStatusDot(chrome.statusConnecting),
      );
    });

    testWidgets('a live row disconnects from its menu and its hover glyph', (
      tester,
    ) async {
      store.bookmarks = [_remote('b1')];
      await pumpSidebar(tester, withConnections: true);
      final glyph = find.byKey(const ValueKey('sidebar.row.disconnect.b1'));

      // Idle: Disconnect is visible but disabled, and no hover glyph.
      await openMenu(tester, 'b1');
      expect(
        tester
            .widget<MenuItemButton>(
              find.byKey(const ValueKey('sidebar.menu.disconnect')),
            )
            .onPressed,
        isNull,
      );
      // An outside click dismisses the menu.
      await tester.tapAt(const Offset(600, 700));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('sidebar.menu.disconnect')),
        findsNothing,
      );

      lanes.watches['b1']!.add(
        const ServerStatus(ServerConnectionState.connected),
      );
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      expect(glyph, findsNothing);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('sidebar.favorite.b1'))),
      );
      await tester.pumpAndSettle();
      expect(glyph, findsOneWidget);
      await tester.tap(glyph);
      await tester.pump();
      expect(disconnected.map((server) => server.serverId), ['b1']);

      await openMenu(tester, 'b1');
      await tester.tap(find.byKey(const ValueKey('sidebar.menu.disconnect')));
      await tester.pump();
      expect(disconnected.map((server) => server.serverId), ['b1', 'b1']);
    });

    testWidgets('a blocked server offers the host-key review', (tester) async {
      store.bookmarks = [_remote('b1')];
      await pumpSidebar(tester, withConnections: true);
      lanes.watches['b1']!.add(
        const ServerStatus(
          ServerConnectionState.blocked,
          detail: 'Host key changed.',
        ),
      );
      await tester.pumpAndSettle();

      // The failure detail lives in the tooltip, not a second line.
      expect(find.text('Host key changed.'), findsNothing);
      final tooltip = tester.widget<Tooltip>(
        find.descendant(
          of: find.byKey(const ValueKey('sidebar.favorite.b1')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tooltip.message, contains('Host key changed.'));

      await openMenu(tester, 'b1');
      await tester.tap(find.byKey(const ValueKey('sidebar.menu.review.b1')));
      await tester.pumpAndSettle();
      expect(reviewed.map((server) => server.serverId), ['b1']);
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

      List<String> order() => [
        for (final section in controller.sections)
          ...section.bookmarks.map((bookmark) => bookmark.id),
      ];

      await dragOnto('a', tester.getCenter(row('c')) + const Offset(0, 8));
      expect(order(), ['b', 'c', 'a']);

      await dragOnto('a', tester.getCenter(row('b')) - const Offset(0, 8));
      expect(order(), ['a', 'b', 'c']);
    });

    testWidgets('a drop on a group row refiles the bookmark', (tester) async {
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
  });

  group('devices', () {
    late _FakeVolumes volumes;

    setUp(() {
      volumes = _FakeVolumes()..volumes = const [_home, _root, _usb];
    });

    testWidgets('Home, the root volume and mounts list with free space', (
      tester,
    ) async {
      await pumpSidebar(tester, volumes: volumes);

      expect(find.text('DEVICES'), findsOneWidget);
      for (final volume in [_home, _root, _usb]) {
        expect(
          find.byKey(ValueKey('sidebar.device.${volume.path}')),
          findsOneWidget,
        );
      }
      final home = rowOf(
        tester,
        find.byKey(const ValueKey('sidebar.device./home/deploy')),
      );
      expect(home.title, 'deploy');
      expect(home.trailingText, '69 GB');
    });

    testWidgets('rows list before free space answers, then fill in', (
      tester,
    ) async {
      // A hung df over a dead network mount answers late or never: the
      // section still appears, and only that row lacks its number.
      volumes
        ..volumes = [
          for (final volume in const [_home, _root, _usb])
            volume.withFreeBytes(null),
        ]
        ..pendingFree['/home/deploy'] = Completer<int?>()
        ..pendingFree['/Volumes/STICK'] = Completer<int?>();
      await pumpSidebar(tester, volumes: volumes);

      SidebarRow row(String path) =>
          rowOf(tester, find.byKey(ValueKey('sidebar.device.$path')));
      expect(find.text('DEVICES'), findsOneWidget);
      expect(row('/home/deploy').trailingText, isNull);
      expect(row('/Volumes/STICK').trailingText, isNull);

      volumes.pendingFree['/home/deploy']!.complete(69000000000);
      await tester.pumpAndSettle();
      expect(row('/home/deploy').trailingText, '69 GB');
      expect(row('/Volumes/STICK').trailingText, isNull);
    });

    testWidgets('no source renders no DEVICES section', (tester) async {
      await pumpSidebar(tester);
      expect(find.text('DEVICES'), findsNothing);
    });

    testWidgets('a device opens its folder through the favorite path', (
      tester,
    ) async {
      await pumpSidebar(tester, volumes: volumes);

      await tester.tap(find.byKey(const ValueKey('sidebar.device./')));
      final (bookmark, action) = opens.single;
      expect(bookmark.kind, BookmarkKind.localFolder);
      expect(bookmark.localPath, '/');
      expect(action, SidebarOpenAction.plain);
      // Transient: opening a device never writes the store.
      expect(store.bookmarks, isEmpty);
    });

    testWidgets('only removable volumes offer Eject, and a refusal says so', (
      tester,
    ) async {
      await pumpSidebar(tester, volumes: volumes);
      expect(
        rowOf(
          tester,
          find.byKey(const ValueKey('sidebar.device./')),
        ).hoverAction,
        isNull,
      );
      expect(
        rowOf(
          tester,
          find.byKey(const ValueKey('sidebar.device./Volumes/STICK')),
        ).hoverAction,
        isNotNull,
      );

      volumes.ejectResult = false;
      await tester.tap(
        find.byKey(const ValueKey('sidebar.device./Volumes/STICK')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar.menu.eject')));
      await tester.pumpAndSettle();
      expect(volumes.ejects, ['/Volumes/STICK']);
      expect(find.textContaining('eject “STICK”'), findsOneWidget);

      // A successful eject re-reads the mounts.
      final before = volumes.listCalls;
      volumes.ejectResult = true;
      volumes.volumes = const [_home, _root];
      await tester.tap(
        find.byKey(const ValueKey('sidebar.device./Volumes/STICK')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar.menu.eject')));
      await tester.pumpAndSettle();
      expect(volumes.listCalls, greaterThan(before));
      expect(
        find.byKey(const ValueKey('sidebar.device./Volumes/STICK')),
        findsNothing,
      );
    });

    testWidgets('a mount change re-lists the devices', (tester) async {
      await pumpSidebar(tester, volumes: volumes);
      volumes.volumes = const [_home, _root];
      volumes.changesLane.add(null);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('sidebar.device./Volumes/STICK')),
        findsNothing,
      );
    });

    testWidgets('the empty favorites offer adds only folders that exist, '
        'and only on the click', (tester) async {
      volumes.standard = ['/home/deploy/Desktop', '/home/deploy/Downloads'];
      await pumpSidebar(tester, volumes: volumes);
      expect(store.bookmarks, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('sidebar.favorites.addStandard')),
      );
      await tester.pumpAndSettle();

      expect(
        [for (final bookmark in store.bookmarks) bookmark.localPath],
        ['/home/deploy/Desktop', '/home/deploy/Downloads'],
      );
      expect(
        [for (final bookmark in store.bookmarks) bookmark.label],
        ['Desktop', 'Downloads'],
      );
      expect(
        find.byKey(const ValueKey('sidebar.favorites.addStandard')),
        findsNothing,
      );
    });
  });

  group('filter', () {
    testWidgets('the field appears at five servers and filters every '
        'section', (tester) async {
      // Five, as both apps drew it before the kit (D33); remote
      // favorites count, being the user's servers without the account.
      store.bookmarks = [
        for (var i = 0; i < 4; i++) _remote('srv$i', sortKey: 'm$i'),
        _local('web-assets', label: 'web-assets'),
      ];
      final volumes = _FakeVolumes()..volumes = const [_home, _root];
      await pumpSidebar(tester, volumes: volumes, height: 1000);
      expect(find.byKey(const ValueKey('sidebar.filter')), findsNothing);

      store.bookmarks = [...store.bookmarks, _remote('webhost', sortKey: 'mz')];
      final controller = tester
          .widget<SidebarView>(find.byType(SidebarView))
          .controller;
      await controller.reload();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sidebar.filter')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('sidebar.filter.field')),
        'web',
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('sidebar.favorite.web-assets')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sidebar.favorite.webhost')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('sidebar.favorite.srv0')), findsNothing);
      // DEVICES matches nothing, so it steps aside entirely.
      expect(find.text('DEVICES'), findsNothing);
      // The count names Enter's shortcut while there is a first match.
      expect(find.text('2 of 8 · ↵ opens the first'), findsOneWidget);

      // Enter opens the first visible match in rail order.
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      expect(opens.single.$1.id, 'web-assets');

      // Esc clears the query; the field stays at this server count.
      await tester.tap(find.byKey(const ValueKey('sidebar.filter.field')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.filterQuery, isEmpty);
      expect(
        find.byKey(const ValueKey('sidebar.favorite.srv0')),
        findsOneWidget,
      );
    });

    testWidgets('with nothing to open the count drops the Enter hint, and '
        'Clear filter brings the rows back', (tester) async {
      store.bookmarks = [_local('l1', label: 'Docs')];
      final controller = await pumpSidebar(tester);
      controller.requestFilter();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sidebar.filter.field')),
        'zzz',
      );
      await tester.pumpAndSettle();

      expect(find.text('0 of 1'), findsOneWidget);
      expect(find.text('No matches'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sidebar.noMatches.clear')));
      await tester.pumpAndSettle();

      expect(controller.filterQuery, isEmpty);
      expect(find.byKey(const ValueKey('sidebar.favorite.l1')), findsOneWidget);
    });

    testWidgets('a query drops itself once the rail it filtered empties', (
      tester,
    ) async {
      // Séance's rule: a stale query would greet the next row the user
      // adds with "No matches".
      store.bookmarks = [_local('l1', label: 'Docs')];
      final controller = await pumpSidebar(tester);
      controller.requestFilter();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sidebar.filter.field')),
        'Docs',
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() => store.remove('l1'));
      await tester.runAsync(controller.reload);
      await tester.pumpAndSettle();
      expect(controller.filterQuery, isEmpty);

      await tester.runAsync(() => store.save(_local('l2', label: 'Music')));
      await tester.runAsync(controller.reload);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sidebar.favorite.l2')), findsOneWidget);
      expect(find.text('No matches'), findsNothing);
    });

    testWidgets('a query folds nothing: collapsed groups open while it runs', (
      tester,
    ) async {
      store.bookmarks = [_remote('a', group: 'work')];
      final controller = await pumpSidebar(tester);
      controller.toggleCollapsed('fav:work');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sidebar.favorite.a')), findsNothing);

      controller.requestFilter();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sidebar.filter.field')),
        'label-a',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sidebar.favorite.a')), findsOneWidget);
      expect(find.text('No matches'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('sidebar.filter.field')),
        'zzz',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);
    });

    testWidgets('requestFilter opens and focuses the field below the '
        'threshold; Esc on an empty query closes it', (tester) async {
      store.bookmarks = [_remote('a')];
      final controller = await pumpSidebar(tester);
      expect(find.byKey(const ValueKey('sidebar.filter')), findsNothing);

      controller.requestFilter();
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('sidebar.filter.field'));
      expect(field, findsOneWidget);
      final editable = tester.widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sidebar.filter')), findsNothing);
    });
  });

  group('comfortable rows', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    Finder row(String key) => find.byKey(ValueKey(key));

    testWidgets('every row kind spells its second line', (tester) async {
      store.bookmarks = [
        _local('l1', label: 'Docs', path: '/home/deploy/docs', sortKey: 'ma'),
        Bookmark(
          id: 'w1',
          kind: BookmarkKind.workspace,
          label: 'Daily pair',
          sortKey: 'mb',
          createdAt: _now,
          updatedAt: _now,
        ),
        _remote('r1', sortKey: 'mc'),
      ];
      final volumes = _FakeVolumes()..volumes = const [_home, _usb];
      await pumpSidebar(
        tester,
        volumes: volumes,
        density: SidebarDensity.comfortable,
      );

      // DEVICES: free space moves from the trailing text to the line.
      expect(find.text('69 GB free'), findsOneWidget);
      expect(
        rowOf(tester, row('sidebar.device./home/deploy')).trailingText,
        isNull,
      );
      // A folder home-relative, a workspace by kind.
      expect(find.text('~/docs'), findsOneWidget);
      expect(find.text('Workspace'), findsOneWidget);
      // A remote favorite: the endpoint and the folder it lands in.
      expect(find.text('deploy@r1.example.com · /srv/r1'), findsOneWidget);
      // The tooltips stay: a second line has room for one fact.
      expect(find.byTooltip('/home/deploy/docs'), findsOneWidget);
    });

    testWidgets('a server line leads with the state words it needs', (
      tester,
    ) async {
      store.bookmarks = [_remote('r1')];
      await pumpSidebar(
        tester,
        withConnections: true,
        density: SidebarDensity.comfortable,
      );
      const endpoint = 'deploy@r1.example.com · /srv/r1';

      lanes.watches['r1']!.add(
        const ServerStatus(ServerConnectionState.connecting),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('${l10n.connectionStateConnecting} · $endpoint'),
        findsOneWidget,
      );

      lanes.watches['r1']!.add(
        const ServerStatus(
          ServerConnectionState.blocked,
          detail: 'Host key changed.',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('${l10n.connectionBlockedTitle} · $endpoint'),
        findsOneWidget,
      );

      // Connected needs no words: the dot and the ring say it.
      lanes.watches['r1']!.add(
        const ServerStatus(ServerConnectionState.connected),
      );
      await tester.pumpAndSettle();
      expect(find.text(endpoint), findsOneWidget);
    });

    testWidgets('marks are 32 px: a badge for a server, a tile for a place', (
      tester,
    ) async {
      store.bookmarks = [
        _local('l1', label: 'Docs', sortKey: 'ma'),
        _remote('r1', sortKey: 'mb'),
      ];
      await pumpSidebar(tester, density: SidebarDensity.comfortable);

      // An uncoloured server still wears its badge: the neutral tile.
      final badge = tester.widget<ServerBadge>(
        find.descendant(
          of: row('sidebar.favorite.r1'),
          matching: find.byType(ServerBadge),
        ),
      );
      expect(badge.size, 32);
      final glyph = find.descendant(
        of: row('sidebar.favorite.l1'),
        matching: find.byIcon(Icons.folder_outlined),
      );
      expect(tester.widget<Icon>(glyph).size, 20);
      expect(
        tester.getSize(
          find.ancestor(of: glyph, matching: find.byType(DecoratedBox)).first,
        ),
        const Size(32, 32),
      );
    });

    testWidgets('the row ⋮ is drawn when comfortable, not on a compact rail', (
      tester,
    ) async {
      store.bookmarks = [_local('l1')];
      await pumpSidebar(tester, density: SidebarDensity.comfortable);
      expect(
        find.descendant(
          of: row('sidebar.favorite.l1'),
          matching: find.byIcon(Icons.more_vert),
        ),
        findsOneWidget,
      );
    });

    for (final density in SidebarDensity.values) {
      testWidgets('a coloured server leads with its colour line '
          '(${density.name})', (tester) async {
        store.bookmarks = [
          Bookmark(
            id: 'c1',
            kind: BookmarkKind.remotePath,
            label: 'prod',
            color: ServerColor.red,
            server: _remote('x').server,
            remotePath: '/srv',
            sortKey: 'ma',
            createdAt: _now,
            updatedAt: _now,
          ),
          _remote('plain', sortKey: 'mb'),
        ];
        await pumpSidebar(tester, density: density);

        final coloured = row('sidebar.favorite.c1');
        final line = serverAccent(
          tester.element(coloured),
          const ServerTint(named: ServerColor.red),
        )!.line;
        expect(rowOf(tester, coloured).accent, line);
        expect(rowOf(tester, row('sidebar.favorite.plain')).accent, isNull);
        // The editor's preview of the line is the same width (D33).
        final drawn = find.descendant(
          of: coloured,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).color == line,
          ),
        );
        expect(tester.getSize(drawn).width, ServerAccentBar.width);
      });
    }

    testWidgets('a connected server wears the green ring beside its dot', (
      tester,
    ) async {
      store.bookmarks = [_remote('r1')];
      await pumpSidebar(tester, withConnections: true);
      final chrome = PoltergeistChrome.of(
        tester.element(row('sidebar.favorite.r1')),
      );

      lanes.watches['r1']!.add(
        const ServerStatus(ServerConnectionState.connecting),
      );
      await tester.pumpAndSettle();
      expect(rowOf(tester, row('sidebar.favorite.r1')).markRing, isNull);

      lanes.watches['r1']!.add(
        const ServerStatus(ServerConnectionState.connected),
      );
      await tester.pumpAndSettle();
      final connected = rowOf(tester, row('sidebar.favorite.r1'));
      expect(connected.markRing, chrome.statusConnected);
      expect(connected.status?.color, chrome.statusConnected);
    });

    testWidgets('the compact rail keeps the row ⋮ to the right-click', (
      tester,
    ) async {
      store.bookmarks = [_local('l1')];
      await pumpSidebar(tester);
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });
  });

  group('density', () {
    testWidgets('a controller left at its default draws comfortable rows', (
      tester,
    ) async {
      store.bookmarks = [_local('l1', label: 'Docs')];
      await pumpSidebar(tester, density: null);

      final row = find.byKey(const ValueKey('sidebar.favorite.l1'));
      expect(tester.getSize(row).height, 52);
      expect(
        SidebarKitScope.densityOf(tester.element(find.byType(SidebarRow))),
        SidebarKitDensity.comfortable,
      );
    });

    testWidgets('the bottom bar switch picks the density and persists it', (
      tester,
    ) async {
      store.bookmarks = [_local('l1', label: 'Docs')];
      final controller = await pumpSidebar(tester);
      final row = find.byKey(const ValueKey('sidebar.favorite.l1'));
      expect(tester.getSize(row).height, 26);

      final bar = find.byKey(const ValueKey('sidebar.bottomBar'));
      expect(
        find.descendant(of: bar, matching: find.byType(SidebarDensitySwitch)),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: bar, matching: find.byTooltip('Comfortable rows')),
      );
      await tester.pumpAndSettle();

      expect(controller.density, SidebarDensity.comfortable);
      expect(densityWrites, [SidebarDensity.comfortable]);
      expect(tester.getSize(row).height, 52);

      await tester.tap(
        find.descendant(of: bar, matching: find.byTooltip('Compact rows')),
      );
      await tester.pumpAndSettle();
      expect(controller.density, SidebarDensity.compact);
      expect(tester.getSize(row).height, 26);
    });
  });

  group('bottom bar', () {
    testWidgets('the + menu gates its verbs on their seams', (tester) async {
      var quick = 0;
      var added = 0;
      await pumpSidebar(
        tester,
        onQuickConnect: () => quick++,
        onAddServer: () => added++,
        onImportSshConfig: () {},
      );

      await tester.tap(find.byKey(const ValueKey('sidebar.add')));
      await tester.pumpAndSettle();
      for (final key in [
        'sidebar.add.newServer',
        'sidebar.add.quickConnect',
        'sidebar.add.currentFolder',
        'sidebar.add.newGroup',
        'sidebar.add.importSshConfig',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      // No workspace: nothing is "current" to add.
      expect(
        tester
            .widget<MenuItemButton>(
              find.byKey(const ValueKey('sidebar.add.currentFolder')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('sidebar.add.quickConnect')));
      await tester.pumpAndSettle();
      expect(quick, 1);
      expect(added, 0);
    });

    testWidgets('New Group… holds an empty group until a favorite joins', (
      tester,
    ) async {
      store.bookmarks = [_local('a')];
      final controller = await pumpSidebar(tester);

      await tester.tap(find.byKey(const ValueKey('sidebar.add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar.add.newGroup')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sidebar.groupField')),
        'Clients',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sidebar.groupSave')));
      await tester.pumpAndSettle();

      expect(find.text('Clients'), findsOneWidget);
      expect(find.text('Drag favorites here'), findsOneWidget);
      // Nothing was written: the store has no group records to write.
      expect(store.bookmarks.single.group, isNull);

      await controller.moveToGroup('a', 'Clients');
      await tester.pumpAndSettle();
      expect(controller.pendingGroups, isEmpty);
      expect(find.text('Clients'), findsOneWidget);
      expect(find.text('Drag favorites here'), findsNothing);
    });

    testWidgets('the gear opens Settings', (tester) async {
      var settings = 0;
      await pumpSidebar(tester, onOpenSettings: () => settings++);
      await tester.tap(find.byKey(const ValueKey('sidebar.settings')));
      expect(settings, 1);
    });

    testWidgets('the sync chip reads the backup status', (tester) async {
      var status = const SidebarSyncStatus(enrolled: false);
      var syncs = 0;
      var setups = 0;
      final now = DateTime.utc(2026, 10, 1, 12);
      Future<void> pump() => pumpSidebar(
        tester,
        syncStatus: () => status,
        onSyncNow: () => syncs++,
        onOpenSyncSettings: () => setups++,
        clock: () => now,
      );
      final chip = find.byKey(const ValueKey('sidebar.syncChip'));

      await pump();
      expect(find.text('Sync off'), findsOneWidget);
      await tester.tap(chip);
      expect(setups, 1);

      status = SidebarSyncStatus(
        enrolled: true,
        lastSyncAt: now.subtract(const Duration(minutes: 2)),
      );
      await pump();
      expect(find.text('Synced · 2 min'), findsOneWidget);
      await tester.tap(chip);
      expect(syncs, 1);

      status = const SidebarSyncStatus(enrolled: true, error: 'refused');
      await pump();
      expect(find.text('Sync failed'), findsOneWidget);
      await tester.tap(chip);
      expect(syncs, 2);

      status = const SidebarSyncStatus(enrolled: true, syncing: true);
      await pumpSidebar(tester, syncStatus: () => status, settle: false);
      expect(find.text('Syncing…'), findsOneWidget);
    });

    testWidgets('no backup service renders no chip', (tester) async {
      await pumpSidebar(tester);
      expect(find.byKey(const ValueKey('sidebar.syncChip')), findsNothing);
    });
  });

  group('panes', () {
    late controller_test.FakePaneLanes paneLanes;
    late WorkspaceController workspace;
    late PaneController left;
    late PaneController right;

    setUp(() {
      paneLanes = controller_test.FakePaneLanes();
      left = PaneController(paneTabId: 'pane.left.tab1', lanes: paneLanes);
      right = PaneController(paneTabId: 'pane.right.tab1', lanes: paneLanes);
      workspace = WorkspaceController(
        left: testPaneStrip(left),
        right: testPaneStrip(right),
      );
      addTearDown(workspace.dispose);
    });

    Future<void> openLocal(
      WidgetTester tester,
      PaneController pane,
      String path,
    ) async {
      paneLanes.nextLocalChannel = controller_test.FakePaneChannel(path);
      await pane.openLocalAt(path);
      await tester.pumpAndSettle();
    }

    testWidgets('the selection pill follows the active pane', (tester) async {
      store.bookmarks = [
        _local('docs', path: '/home/deploy/docs'),
        _remote('srv'),
      ];
      final volumes = _FakeVolumes()..volumes = const [_home, _root];
      await pumpSidebar(tester, volumes: volumes, workspace: workspace);

      bool selected(String key) =>
          rowOf(tester, find.byKey(ValueKey(key))).selected;

      await openLocal(tester, left, '/home/deploy/docs');
      expect(selected('sidebar.favorite.docs'), isTrue);
      expect(selected('sidebar.device./home/deploy'), isFalse);

      await openLocal(tester, left, '/home/deploy');
      expect(selected('sidebar.device./home/deploy'), isTrue);
      expect(selected('sidebar.favorite.docs'), isFalse);

      // The pill is the ACTIVE pane's: moving activity moves it.
      await left.connectRemote(_remote('srv'));
      await tester.pumpAndSettle();
      expect(selected('sidebar.favorite.srv'), isTrue);
      await openLocal(tester, right, '/');
      workspace.setActivePane(workspace.right);
      await tester.pumpAndSettle();
      expect(selected('sidebar.device./'), isTrue);
      expect(selected('sidebar.favorite.srv'), isFalse);
    });

    testWidgets('Add Current Folder saves the active local folder once', (
      tester,
    ) async {
      await pumpSidebar(tester, workspace: workspace);
      await openLocal(tester, left, '/home/deploy/site');

      Future<void> addCurrent() async {
        await tester.tap(find.byKey(const ValueKey('sidebar.add')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('sidebar.add.currentFolder')),
        );
        await tester.pumpAndSettle();
      }

      await addCurrent();
      expect(store.bookmarks.single.localPath, '/home/deploy/site');
      expect(store.bookmarks.single.label, 'site');

      await addCurrent();
      expect(store.bookmarks, hasLength(1));
      expect(find.textContaining('already in Favorites'), findsOneWidget);
    });

    testWidgets('a live Quick Connect session lists in italics and saves '
        'to Servers', (tester) async {
      final adhoc = Bookmark(
        id: 'adhoc:1',
        kind: BookmarkKind.remotePath,
        label: 'demo@sandbox.example.com',
        server: BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: 'sandbox.example.com',
            port: 2222,
            username: 'demo',
            authMethod: AuthMethod.password,
          ),
        ),
        remotePath: '/',
        sortKey: 'adhoc:1',
        createdAt: _now,
        updatedAt: _now,
      );
      await pumpSidebar(tester, workspace: workspace);
      await left.connectRemote(adhoc);
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('sidebar.adhoc.adhoc:1'));
      expect(row, findsOneWidget);
      expect(rowOf(tester, row).italic, isTrue);
      expect(rowOf(tester, row).selected, isTrue);

      await tester.tap(row, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar.adhoc.menu.save')));
      await tester.pumpAndSettle();
      // Prefilled from the live endpoint, never the raw address.
      expect(find.text('demo@sandbox.example.com:2222'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sidebar.saveServerSave')));
      await tester.pumpAndSettle();

      final saved = store.bookmarks.single;
      expect(saved.id, isNot(startsWith('adhoc:')));
      expect(saved.server?.identity?.host, 'sandbox.example.com');
      expect(saved.remotePath, '/srv/home');
      // The saved row replaces the italic one — and, since the pane still
      // browses the session, carries the pill.
      expect(row, findsNothing);
      final savedRow = find.byKey(ValueKey('sidebar.favorite.${saved.id}'));
      expect(savedRow, findsOneWidget);
      expect(rowOf(tester, savedRow).selected, isTrue);
      // …and the session's own connection: a solid connected dot (not the
      // probe's reachable ring), and Disconnect drops the live session.
      final chrome = PoltergeistChrome.of(tester.element(savedRow));
      expect(
        rowOf(tester, savedRow).status,
        SidebarStatusDot(chrome.statusConnected),
      );
      await tester.tap(savedRow, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar.menu.disconnect')));
      await tester.pump();
      expect(disconnected.map((server) => server.serverId), ['adhoc:1']);
    });
  });

  group('drops', () {
    testWidgets('a local folder dropped on FAVORITES becomes a favorite', (
      tester,
    ) async {
      final volumes = _FakeVolumes()..directories = {'/home/deploy/site'};
      final drag = PaneEntryDrag(
        source: const LocalFsLocation(),
        rootPaths: ['/home/deploy/site', '/home/deploy/notes.txt'],
      );
      await pumpSidebar(
        tester,
        volumes: volumes,
        dragSource: Center(
          child: Draggable<Object>(
            data: drag,
            feedback: const SizedBox(width: 4, height: 4),
            child: const Text('drag-me'),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('drag-me')),
      );
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('sidebar.section.sec:favorites')),
        ),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // The file among the roots is skipped — only folders become rows.
      expect(
        [for (final bookmark in store.bookmarks) bookmark.localPath],
        ['/home/deploy/site'],
      );
    });

    testWidgets('pane rows dropped on a device copy into it', (tester) async {
      final queue = FakeAppTransferQueue();
      final volumes = _FakeVolumes()..volumes = const [_home, _usb];
      final drag = PaneEntryDrag(
        source: const ServerFsLocation('srv'),
        rootPaths: ['/srv/report.pdf'],
      );
      await pumpSidebar(
        tester,
        volumes: volumes,
        dropDelegate: PaneDropDelegate(queue: queue),
        dragSource: Center(
          child: Draggable<Object>(
            data: drag,
            feedback: const SizedBox(width: 4, height: 4),
            child: const Text('drag-me'),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('drag-me')),
      );
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('sidebar.device./Volumes/STICK')),
        ),
      );
      await tester.pump();
      expect(drag.verb.value, TransferOperation.copy);
      await gesture.up();
      await tester.pumpAndSettle();

      final spec = queue.enqueuedSpecs.single;
      expect(spec.destination, const LocalFsLocation());
      expect(spec.destinationDir, '/Volumes/STICK');
      expect(spec.rootPaths, ['/srv/report.pdf']);
      expect(spec.operation, TransferOperation.copy);
    });

    testWidgets('a pane-row drop waits out an OS drag-out hand-off in '
        'flight', (tester) async {
      final queue = FakeAppTransferQueue();
      final volumes = _FakeVolumes()..volumes = const [_home, _usb];
      final drag = PaneEntryDrag(
        source: const ServerFsLocation('srv'),
        rootPaths: ['/srv/report.pdf'],
      );
      await pumpSidebar(
        tester,
        volumes: volumes,
        dropDelegate: PaneDropDelegate(queue: queue),
        dragSource: Center(
          child: Draggable<Object>(
            data: drag,
            feedback: const SizedBox(width: 4, height: 4),
            child: const Text('drag-me'),
          ),
        ),
      );

      Future<void> dropOnDevice(bool started) async {
        final handOff = Completer<bool>();
        drag.holdDropsUntil(handOff.future);
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('drag-me')),
        );
        await tester.pump();
        await gesture.moveTo(
          tester.getCenter(
            find.byKey(const ValueKey('sidebar.device./Volumes/STICK')),
          ),
        );
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(queue.enqueuedSpecs, isEmpty);
        handOff.complete(started);
        await tester.pumpAndSettle();
      }

      // The native session took the drag: the release was its own.
      await dropOnDevice(true);
      expect(queue.enqueuedSpecs, isEmpty);

      // Nothing started: the user's release is the drop.
      await dropOnDevice(false);
      expect(queue.enqueuedSpecs.single.destinationDir, '/Volumes/STICK');
    });

    testWidgets('local pane rows dropped on a device copy too; only the '
        'move modifier moves them', (tester) async {
      final queue = FakeAppTransferQueue();
      final volumes = _FakeVolumes()..volumes = const [_home, _usb];
      final drag = PaneEntryDrag(
        source: const LocalFsLocation(),
        rootPaths: ['/home/deploy/Documents/report.pdf'],
      );
      await pumpSidebar(
        tester,
        volumes: volumes,
        dropDelegate: PaneDropDelegate(queue: queue),
        dragSource: Center(
          child: Draggable<Object>(
            data: drag,
            feedback: const SizedBox(width: 4, height: 4),
            child: const Text('drag-me'),
          ),
        ),
      );
      final stick = find.byKey(const ValueKey('sidebar.device./Volumes/STICK'));

      Future<void> dropOnStick() async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('drag-me')),
        );
        await tester.pump();
        await gesture.moveTo(tester.getCenter(stick));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      // A local source is one POSIX namespace to the gesture, but the
      // stick is another disk: a plain drop must not delete the source.
      await dropOnStick();
      expect(queue.enqueuedSpecs.single.operation, TransferOperation.copy);
      expect(queue.enqueuedSpecs.single.destinationDir, '/Volumes/STICK');

      // The move modifier (Shift off macOS, Cmd on it) still moves.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await dropOnStick();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(queue.enqueuedSpecs.last.operation, TransferOperation.move);
    });
  });
}
