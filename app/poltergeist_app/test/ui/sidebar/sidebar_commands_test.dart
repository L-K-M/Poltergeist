import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_commands.dart';

import '../../support/fake_bookmark_store.dart';

void main() {
  late SidebarController sidebar;
  late WorkspaceController workspace;
  late int drawerToggles;
  late bool drawer;
  late RegisteredCommand command;

  setUp(() {
    sidebar = SidebarController(store: FakeBookmarkStore());
    workspace = WorkspaceController(
      left: PaneTabsController(paneId: PaneTabsController.leftPaneId),
      right: PaneTabsController(paneId: PaneTabsController.rightPaneId),
    );
    drawerToggles = 0;
    drawer = false;
    command = buildSidebarFilterCommand(
      sidebar: sidebar,
      workspace: workspace,
      sidebarIsDrawer: () => drawer,
      toggleSidebarDrawer: () => drawerToggles++,
    );
  });

  tearDown(() {
    sidebar.dispose();
    workspace.dispose();
  });

  test('⌥⌘F on macOS, Ctrl+Alt+F elsewhere, beside Filter in Edit', () {
    expect(command.id, kViewFilterSidebarCommandId);
    expect(command.activators!(TargetPlatform.macOS), const [
      SingleActivator(LogicalKeyboardKey.keyF, meta: true, alt: true),
    ]);
    expect(command.activators!(TargetPlatform.linux), const [
      SingleActivator(LogicalKeyboardKey.keyF, control: true, alt: true),
    ]);
    expect(command.menuPlacement?.menu, AppMenuId.edit);
  });

  testWidgets('running it reveals a hidden sidebar and asks for the field', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    workspace.setSidebarHidden(true);

    await command.run(context);

    expect(workspace.sidebarHidden, isFalse);
    expect(sidebar.filterOpen, isTrue);
    expect(sidebar.filterFocusPending, isTrue);
    expect(drawerToggles, 0);
  });

  testWidgets('the density toggle names the other density and sets it', (
    tester,
  ) async {
    final toggle = buildSidebarDensityCommand(sidebar: sidebar);
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(toggle.id, kViewToggleSidebarDensityCommandId);
    expect(toggle.scope, CommandScope.app);
    // 10 §8's View section, between the sidebar (60) and the inspector
    // (65). No chord: the menu row is its reachable path.
    expect(toggle.menuPlacement?.menu, AppMenuId.view);
    expect(toggle.menuPlacement?.group, 0);
    expect(toggle.menuPlacement?.order, 62);
    expect(toggle.activators, isNull);
    // macOS drops a menu item's check, so the label carries the state.
    expect(toggle.checked, isNull);

    expect(sidebar.density, SidebarDensity.comfortable);
    expect(toggle.label(l10n), 'Use Compact Sidebar Rows');

    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    await toggle.run(context);
    expect(sidebar.density, SidebarDensity.compact);
    expect(toggle.label(l10n), 'Use Comfortable Sidebar Rows');

    await toggle.run(context);
    expect(sidebar.density, SidebarDensity.comfortable);
  });

  testWidgets('below the inline stage it opens the drawer instead', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    drawer = true;

    await command.run(context);

    expect(drawerToggles, 1);
    expect(sidebar.filterOpen, isTrue);
  });
}
