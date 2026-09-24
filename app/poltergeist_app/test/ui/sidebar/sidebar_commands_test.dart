import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('⌥⌘F on macOS, Ctrl+Alt+F elsewhere, in the View menu', () {
    expect(command.id, kViewFilterSidebarCommandId);
    expect(command.activators!(TargetPlatform.macOS), const [
      SingleActivator(LogicalKeyboardKey.keyF, meta: true, alt: true),
    ]);
    expect(command.activators!(TargetPlatform.linux), const [
      SingleActivator(LogicalKeyboardKey.keyF, control: true, alt: true),
    ]);
    expect(command.menuPlacement?.menu, AppMenuId.view);
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
