import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/registered_command.dart';
import '../../services/sidebar_controller.dart';
import '../../services/workspace_controller.dart';

/// 10 §5's sidebar filter chord.
const kViewFilterSidebarCommandId = 'view.filterSidebar';

/// `view.filterSidebar` (⌥⌘F on macOS, Ctrl+Alt+F elsewhere): shows the
/// sidebar if it is hidden, then opens and focuses its filter field. The
/// field shows on its own at eight servers; this reaches it below that.
///
/// Below the inline stage the sidebar lives in the shell's drawer, which
/// [toggleSidebarDrawer] opens — a chord can only reach this command
/// while focus is outside that drawer, so the toggle opens it.
RegisteredCommand buildSidebarFilterCommand({
  required SidebarController sidebar,
  required WorkspaceController workspace,
  required bool Function() sidebarIsDrawer,
  required VoidCallback toggleSidebarDrawer,
}) => RegisteredCommand(
  id: kViewFilterSidebarCommandId,
  scope: CommandScope.app,
  label: (l10n) => l10n.viewFilterSidebarLabel,
  icon: Icons.manage_search,
  activators: (platform) => platform == TargetPlatform.macOS
      ? const [SingleActivator(LogicalKeyboardKey.keyF, meta: true, alt: true)]
      : const [
          SingleActivator(LogicalKeyboardKey.keyF, control: true, alt: true),
        ],
  run: (context) async {
    if (sidebarIsDrawer()) {
      toggleSidebarDrawer();
    } else if (workspace.sidebarHidden) {
      workspace.setSidebarHidden(false);
    }
    sidebar.requestFilter();
  },
  // 10 §8's View menu: beside Show/Hide Sidebar (slot 60).
  menuPlacement: const CommandMenuPlacement(menu: AppMenuId.view, order: 61),
);
