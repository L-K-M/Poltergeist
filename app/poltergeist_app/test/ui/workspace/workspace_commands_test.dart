import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/services/workspace_library.dart';
import 'package:poltergeist_app/services/workspace_list_store.dart';
import 'package:poltergeist_app/services/workspace_state.dart';
import 'package:poltergeist_app/ui/menus/app_menus.dart';
import 'package:poltergeist_app/ui/workspace/workspace_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_bookmark_store.dart';

WorkspacePaneState _pane(
  String paneId,
  List<WorkspaceTabState> tabs, {
  int? activeTab,
}) => WorkspacePaneState(
  paneId: paneId,
  activeTab: activeTab ?? (tabs.isEmpty ? -1 : tabs.length - 1),
  tabs: tabs,
);

WorkspaceTabState _localTab(String path) => WorkspaceTabState(
  session: SessionTabState.local(path: path),
  filterQuery: '',
  filterFieldOpen: false,
  showHidden: false,
  viewMode: PaneViewMode.details,
);

SavedWorkspace _saved(String id, String label, WorkspaceSnapshot snapshot) =>
    SavedWorkspace(
      id: id,
      label: label,
      savedAt: DateTime.utc(2026, 9, 16),
      lastOpenedAt: null,
      snapshot: snapshot,
    );

void main() {
  final l10n = AppLocalizationsEn();

  late controller_test.FakePaneLanes lanes;
  late Directory temporaryDirectory;
  late WorkspaceLibrary library;
  late PaneTabsController left;
  late PaneTabsController right;
  late WorkspaceController workspace;

  /// The test presenter answers every close-guard ask through
  /// [guardAnswer].
  bool Function(List<TabCloseTrigger>) guardAnswer = (_) => true;

  setUp(() async {
    lanes = controller_test.FakePaneLanes();
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_workspace_commands_test_',
    );
    library = WorkspaceLibrary(
      store: WorkspaceListStore(
        store: SettingsStore(
          path: p.join(temporaryDirectory.path, 'settings.json'),
        ),
      ),
      bookmarks: FakeBookmarkStore(),
    );
    await library.load();
    guardAnswer = (_) => true;
    PaneTabsController strip(String paneId) => PaneTabsController(
      paneId: paneId,
      lanes: lanes,
      confirmClose: (tab, triggers) async => guardAnswer(triggers),
    );
    left = strip(PaneTabsController.leftPaneId);
    right = strip(PaneTabsController.rightPaneId);
    workspace = WorkspaceController(left: left, right: right);
  });

  tearDown(() async {
    workspace.dispose();
    left.dispose();
    right.dispose();
    library.dispose();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  /// Opens a bound local tab browsing [path]. `newTab`'s duplicate
  /// target on an empty strip yields an unbound tab; awaiting
  /// [openLocalAt] flushes the fake channel's microtask bind — a
  /// `Future.delayed` drain would stall in the widget test's fake zone.
  Future<PaneController> openLocalTab(
    PaneTabsController strip,
    String path, {
    List<RemoteFileEntry> listing = const [],
  }) async {
    final channel = controller_test.FakePaneChannel('/home/tester')
      ..listings[path] = listing;
    lanes.nextLocalChannel = channel;
    final tab = strip.newTab();
    await tab.controller.openLocalAt(path);
    return tab.controller;
  }

  List<RegisteredCommand> commands() => buildWorkspaceCommands(
    workspace: workspace,
    library: library,
    enabled: () => true,
  );

  RegisteredCommand byId(String id) =>
      commands().singleWhere((command) => command.id == id);

  group('registration and menu reachability', () {
    test('workspace.save sits in the Commands menu at the §9 slot', () {
      final save = byId('workspace.save');
      expect(save.label(l10n), 'Save Workspace…');
      expect(save.enabled(), isTrue);
      expect(save.menuPlacement?.menu, AppMenuId.commands);
      expect(save.menuPlacement?.order, 50);
      expect(save.menuPlacement?.submenu, isNull);
    });

    test('an empty library renders a disabled Workspaces submenu row', () {
      final open = byId('workspace.open.empty');
      expect(open.label(l10n), 'No Saved Workspaces');
      expect(open.enabled(), isFalse);

      final menus = buildAppMenus(
        commands: commands(),
        l10n: l10n,
        platform: TargetPlatform.linux,
      );
      final commandsMenu = menus.singleWhere(
        (menu) => menu.id == AppMenuId.commands,
      );
      final rows = commandsMenu.groups.expand((group) => group).toList();
      final submenu = rows.whereType<AppMenuSubmenuRow>().single;
      expect(submenu.title, 'Workspaces');
      expect(submenu.items.map((item) => item.command.id), [
        'workspace.open.empty',
      ]);
    });

    test('saved workspaces list in favorites order under the submenu', () async {
      await library.save(
        label: 'First',
        snapshot: WorkspaceSnapshot(
          left: _pane('pane.left', const []),
          right: _pane('pane.right', const []),
        ),
      );
      await library.save(
        label: 'Second',
        snapshot: WorkspaceSnapshot(
          left: _pane('pane.left', const []),
          right: _pane('pane.right', const []),
        ),
      );

      final menus = buildAppMenus(
        commands: commands(),
        l10n: l10n,
        platform: TargetPlatform.linux,
      );
      final submenu = menus
          .singleWhere((menu) => menu.id == AppMenuId.commands)
          .groups
          .expand((group) => group)
          .whereType<AppMenuSubmenuRow>()
          .single;
      // The submenu renders the favorites' own order (the sidebar's
      // sortKey sequence — appended rows land at the tail), so the menu
      // and the sidebar can never disagree about sequence.
      expect(submenu.items.map((item) => item.command.label(l10n)), [
        'First',
        'Second',
      ]);
      expect(submenu.items.map((item) => item.command.id), [
        'workspace.open.${library.workspaces[0].id}',
        'workspace.open.${library.workspaces[1].id}',
      ]);
    });
  });

  group('save flow', () {
    testWidgets('names and saves both panes, then toasts', (tester) async {
      await openLocalTab(left, '/home/tester');
      await openLocalTab(right, '/srv');

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      final context = tester.element(find.byType(Scaffold));

      // The save's settings-store write is real I/O — run the command
      // in a real-async zone while the dialog still takes fake taps.
      await tester.runAsync(() async {
        final ran = byId('workspace.save').run(context);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(
          find.byKey(const Key('workspaceSave.name')),
          'Client X',
        );
        await tester.pump();
        await tester.tap(find.text('Save'));
        await ran;
      });
      await tester.pump();

      expect(library.workspaces.single.label, 'Client X');
      expect(
        library.workspaces.single.snapshot.left.tabs.single.session.path,
        '/home/tester',
      );
      expect(
        library.workspaces.single.snapshot.right.tabs.single.session.path,
        '/srv',
      );
      expect(find.text('Workspace "Client X" saved'), findsOneWidget);
      // Drain the auto-dismiss timer so no pending timer survives the
      // test.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  group('open flow', () {
    testWidgets('replaces both panes and the toast Undo restores them', (
      tester,
    ) async {
      await openLocalTab(left, '/before-left');
      await openLocalTab(right, '/before-right');

      final saved = _saved(
        'ws-1',
        'Client X',
        WorkspaceSnapshot(
          left: _pane('pane.left', [_localTab('/work-left')]),
          right: _pane('pane.right', [_localTab('/work-right')]),
        ),
      );
      await tester.runAsync(
        () => library.save(label: saved.label, snapshot: saved.snapshot),
      );
      // Keep the deterministic fixture id the command keys on.
      final record = library.workspaces.single;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      final context = tester.element(find.byType(Scaffold));

      await tester.runAsync(
        () => byId('workspace.open.${record.id}').run(context),
      );
      await tester.pump();

      expect(left.tabs.single.controller.location?.path, '/work-left');
      expect(right.tabs.single.controller.location?.path, '/work-right');
      expect(find.text('Workspace "Client X" opened'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(left.tabs.single.controller.location?.path, '/before-left');
      expect(right.tabs.single.controller.location?.path, '/before-right');
      // The open stamp moved the record to newest-opened order.
      expect(library.workspaces.single.lastOpenedAt, isNotNull);
    });

    testWidgets('a declined guard applies nothing and shows no toast', (
      tester,
    ) async {
      final controller = await openLocalTab(
        left,
        '/home/tester',
        listing: [
          RemoteFileEntry(
            path: '/home/tester/docs',
            name: 'docs',
            type: RemoteFileType.directory,
          ),
        ],
      );
      // Flush the listing commit so the cursor and rename arm against
      // real rows — openLocalAt's await ends at the bind, not the
      // listing answer.
      await tester.pump();
      controller.setCursorIndex(0);
      controller.startRename();

      await tester.runAsync(
        () => library.save(
          label: 'Client X',
          snapshot: WorkspaceSnapshot(
            left: _pane('pane.left', [_localTab('/work-left')]),
            right: _pane('pane.right', const []),
          ),
        ),
      );
      final record = library.workspaces.single;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      final context = tester.element(find.byType(Scaffold));

      guardAnswer = (_) => false;
      await tester.runAsync(
        () => byId('workspace.open.${record.id}').run(context),
      );
      await tester.pump();

      expect(left.tabs.single.controller, same(controller));
      expect(find.text('Workspace "Client X" opened'), findsNothing);
      // A declined open never stamps lastOpenedAt.
      expect(library.workspaces.single.lastOpenedAt, isNull);
    });
  });
}
