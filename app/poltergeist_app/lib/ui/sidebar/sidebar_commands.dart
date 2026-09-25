import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart' show BookmarkKind;

import '../../services/pane_controller.dart' show PanePhase;
import '../../services/quick_connect_address.dart'
    show quickConnectAdhocIdPrefix;
import '../../services/registered_command.dart';
import '../../services/sidebar_controller.dart';
import '../../services/workspace_controller.dart';
import '../save_to_servers.dart' show sessionEndpointKey;
import 'sidebar_facts.dart';
import 'sidebar_view.dart' show addLocationToFavorites, saveSessionToServers;

/// 10 §5's sidebar filter chord.
const kViewFilterSidebarCommandId = 'view.filterSidebar';

/// The sidebar's "+" and row verbs that act on the active pane (D21).
const kFavoriteAddCommandId = 'favorite.add';
const kConnectSaveToServersCommandId = 'connect.saveToServers';

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
  // Beside Filter in the Edit menu's last section: 10 §8's table does
  // not list this chord's row, and its View section is Sidebar,
  // Inspector, Second Pane with nothing between them.
  menuPlacement: const CommandMenuPlacement(
    menu: AppMenuId.edit,
    order: 95,
    group: 4,
  ),
);

/// The sidebar verbs that act on the active pane, as registered commands
/// (D21), so the menus and the palette reach them too: the "+" menu's
/// Add Current Folder to Favorites and an unsaved Quick Connect row's
/// Save to Servers…. Both run the rail's own flows.
List<RegisteredCommand> buildSidebarVerbCommands({
  required SidebarController sidebar,
  required WorkspaceController workspace,
}) {
  SidebarAdhocSession? unsavedSession() =>
      _activeUnsavedSession(workspace, sidebar);

  return [
    RegisteredCommand(
      id: kFavoriteAddCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.sidebarAddCurrentFolder,
      icon: Icons.star_outline,
      enabled: () {
        final pane = workspace.activeTabController;
        return canAddLocationToFavorites(pane?.location, pane?.remoteBookmark);
      },
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (context) async {
        final pane = workspace.activeTabController;
        final location = pane?.location;
        if (pane == null || location == null) return;
        await addLocationToFavorites(
          context,
          sidebar,
          location: location,
          remote: pane.remoteBookmark,
        );
      },
      // 02 §9 kept Add to Favorites… in the menu D32 renamed Server; it
      // sits with Save Workspace…, the other verb that saves where you
      // are.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.server,
        order: 48,
        group: 3,
      ),
    ),
    RegisteredCommand(
      id: kConnectSaveToServersCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.sidebarSaveToServers,
      icon: Icons.bookmark_add_outlined,
      enabled: () => unsavedSession() != null,
      disabledReason: (l10n) => l10n.commandDisabledNoQuickConnect,
      run: (context) async {
        final session = unsavedSession();
        if (session == null) return;
        await saveSessionToServers(context, sidebar, session);
      },
      // 10 §8's Server menu: after Connect… and Disconnect, the other
      // verb on the connection the active tab shows.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.server,
        order: 25,
      ),
    ),
  ];
}

/// The Quick Connect session the active tab browses while no stored
/// server carries its endpoint: what the sidebar's italic row and the
/// pane's "Not saved" banner offer to save. Only a live, browsing session
/// is worth saving (sidebarPaneFactsOf's rule).
SidebarAdhocSession? _activeUnsavedSession(
  WorkspaceController workspace,
  SidebarController sidebar,
) {
  final pane = workspace.activeTabController;
  final remote = pane?.remoteBookmark;
  if (pane == null || remote == null) return null;
  if (!remote.id.startsWith(quickConnectAdhocIdPrefix)) return null;
  if (pane.phase != PanePhase.browsing) return null;
  final endpoint = sessionEndpointKey(remote);
  final saved = sidebar.bookmarks.any(
    (row) =>
        row.kind == BookmarkKind.remotePath &&
        !row.id.startsWith(quickConnectAdhocIdPrefix) &&
        sessionEndpointKey(row) == endpoint,
  );
  if (saved) return null;
  return SidebarAdhocSession(bookmark: remote, path: pane.location?.path);
}
