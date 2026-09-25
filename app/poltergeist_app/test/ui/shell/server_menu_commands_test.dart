// The sidebar and connection verbs 10 §8's menus reach as registered
// commands (D21): Server ▸ Disconnect, Save to Favorites…, and Add Current
// Folder to Favorites act on the active tab through the rail's own flows.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/test_panes.dart';
import '../panes/quick_connect_test.dart' show adhocBookmark, connectAdhoc;

Bookmark _server(String id) {
  final now = DateTime.utc(2026, 9, 20);
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: id,
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: '$id.example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/',
    sortKey: id,
    createdAt: now,
    updatedAt: now,
  );
}

/// A two-pane workspace whose left strip holds [left] as its active tab.
WorkspaceController _workspace(
  controller_test.FakePaneLanes lanes,
  PaneController left,
) {
  final strip = testPaneStrip(left, paneId: 'pane.left', lanes: lanes);
  final right = PaneTabsController(paneId: 'pane.right', lanes: lanes);
  addTearDown(right.dispose);
  final workspace = WorkspaceController(left: strip, right: right);
  addTearDown(workspace.dispose);
  workspace.setActivePane(strip);
  return workspace;
}

Future<BuildContext> _context(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: SizedBox.expand()),
    ),
  );
  return tester.element(find.byType(Scaffold));
}

RegisteredCommand _byId(List<RegisteredCommand> commands, String id) =>
    commands.singleWhere((command) => command.id == id);

void main() {
  group('connect.disconnect', () {
    List<RegisteredCommand> shellCommands(
      WorkspaceController workspace,
      Future<void> Function(String serverId)? disconnect,
    ) => buildShellCommands(
      workspace: workspace,
      dropDelegate: () => null,
      openConnect: () {},
      allCommands: () => const [],
      openUrl: (_) async {},
      fileOps: () => null,
      reportFailure: (_) {},
      locationLabel: (_) => '',
      disconnectServer: disconnect,
    );

    testWidgets('drops the active tab\'s live server, the sidebar row\'s '
        'Disconnect, from Server ▸ Disconnect', (tester) async {
      final lanes = controller_test.FakePaneLanes();
      lanes.nextRemoteChannel = controller_test.FakePaneChannel('/srv')
        ..listings['/srv'] = const [];
      final pane = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
      addTearDown(pane.dispose);
      await pane.connectRemote(_server('demo'), initialPath: '/srv');
      await tester.pump();
      final workspace = _workspace(lanes, pane);
      final disconnect = _byId(
        shellCommands(workspace, lanes.disconnectServer),
        kConnectDisconnectCommandId,
      );

      // 02 §8.3's chord and 10 §8's slot: Connect… ⌘K, Disconnect.
      expect(disconnect.activators!(TargetPlatform.macOS), const [
        SingleActivator(LogicalKeyboardKey.keyK, meta: true, shift: true),
      ]);
      expect(disconnect.activators!(TargetPlatform.linux), const [
        SingleActivator(LogicalKeyboardKey.keyK, control: true, shift: true),
      ]);
      expect(disconnect.menuPlacement?.menu, AppMenuId.server);
      expect(disconnect.menuPlacement?.group, 0);

      expect(disconnect.enabled(), isTrue);
      await disconnect.run(await _context(tester));
      await tester.pump();

      expect(lanes.disconnects, ['demo']);
      // The pool reports the drop: nothing live is left to disconnect.
      expect(disconnect.enabled(), isFalse);
    });

    testWidgets('a local tab, or no pool seam, leaves it disabled', (
      tester,
    ) async {
      final lanes = controller_test.FakePaneLanes();
      lanes.nextLocalChannel = controller_test.FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = const [];
      final pane = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
      addTearDown(pane.dispose);
      await pane.openLocalHome();
      await tester.pump();
      final workspace = _workspace(lanes, pane);

      final disconnect = _byId(
        shellCommands(workspace, lanes.disconnectServer),
        kConnectDisconnectCommandId,
      );
      expect(disconnect.enabled(), isFalse);
      expect(
        disconnect.disabledReason!(lookupAppLocalizations(const Locale('en'))),
        'Requires a tab connected to a server',
      );

      final remote = PaneController(paneTabId: 'pane.left.tab2', lanes: lanes);
      addTearDown(remote.dispose);
      lanes.nextRemoteChannel = controller_test.FakePaneChannel('/srv')
        ..listings['/srv'] = const [];
      await remote.connectRemote(_server('demo'), initialPath: '/srv');
      await tester.pump();
      final unwired = _byId(
        shellCommands(_workspace(lanes, remote), null),
        kConnectDisconnectCommandId,
      );
      expect(unwired.enabled(), isFalse);
    });
  });

  group('the sidebar verbs', () {
    testWidgets('Add Current Folder to Favorites saves the active local '
        'folder', (tester) async {
      final lanes = controller_test.FakePaneLanes();
      lanes.nextLocalChannel = controller_test.FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = const [];
      final pane = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
      addTearDown(pane.dispose);
      await pane.openLocalHome();
      await tester.pump();
      final workspace = _workspace(lanes, pane);
      final store = FakeBookmarkStore();
      final sidebar = SidebarController(store: store);
      addTearDown(sidebar.dispose);

      final add = _byId(
        buildSidebarVerbCommands(sidebar: sidebar, workspace: workspace),
        kFavoriteAddCommandId,
      );
      expect(add.menuPlacement?.menu, AppMenuId.server);
      expect(add.enabled(), isTrue);

      final context = await _context(tester);
      await tester.runAsync(() => add.run(context));

      expect(store.bookmarks, hasLength(1));
      expect(store.bookmarks.single.kind, BookmarkKind.localFolder);
      expect(store.bookmarks.single.localPath, '/home/tester');
    });

    testWidgets('Save to Favorites… saves the active Quick Connect session, '
        'then retires', (tester) async {
      final lanes = controller_test.FakePaneLanes();
      final pane = await connectAdhoc(lanes, adhocBookmark());
      addTearDown(pane.dispose);
      await tester.pump();
      final workspace = _workspace(lanes, pane);
      final store = FakeBookmarkStore();
      final sidebar = SidebarController(store: store);
      addTearDown(sidebar.dispose);
      await tester.runAsync(sidebar.reload);

      final save = _byId(
        buildSidebarVerbCommands(sidebar: sidebar, workspace: workspace),
        kConnectSaveToServersCommandId,
      );
      expect(save.menuPlacement?.menu, AppMenuId.server);
      expect(save.menuPlacement?.group, 0);
      expect(save.enabled(), isTrue);

      final context = await _context(tester);
      final running = save.run(context);
      await tester.pumpAndSettle();
      // The rail's own name prompt, prefilled with the endpoint.
      final field = tester.widget<TextFormField>(
        find.byKey(const ValueKey('sidebar.saveServerField')),
      );
      expect(field.initialValue, 'deploy@example.com');
      await tester.tap(find.byKey(const ValueKey('sidebar.saveServerSave')));
      await tester.pumpAndSettle();
      await running;
      await tester.runAsync(sidebar.reload);

      expect(store.bookmarks, hasLength(1));
      expect(store.bookmarks.single.id.startsWith('adhoc:'), isFalse);
      expect(store.bookmarks.single.remotePath, '/srv/www');
      // A stored server now carries the endpoint: nothing left to save.
      expect(save.enabled(), isFalse);
    });

    testWidgets('Save to Favorites… is disabled on a saved server\'s tab', (
      tester,
    ) async {
      final lanes = controller_test.FakePaneLanes();
      lanes.nextRemoteChannel = controller_test.FakePaneChannel('/srv')
        ..listings['/srv'] = const [];
      final pane = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
      addTearDown(pane.dispose);
      await pane.connectRemote(_server('demo'), initialPath: '/srv');
      await tester.pump();
      final sidebar = SidebarController(store: FakeBookmarkStore());
      addTearDown(sidebar.dispose);

      final save = _byId(
        buildSidebarVerbCommands(
          sidebar: sidebar,
          workspace: _workspace(lanes, pane),
        ),
        kConnectSaveToServersCommandId,
      );
      expect(save.enabled(), isFalse);
    });
  });
}
