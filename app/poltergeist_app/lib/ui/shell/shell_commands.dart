import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/file_manager_reveal.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_location.dart';
import '../../services/pane_drop.dart';
import '../../services/pane_file_ops.dart';
import '../../services/pane_tabs_controller.dart';
import '../../services/registered_command.dart';
import '../../services/window_full_screen.dart';
import '../../services/workspace_controller.dart';
import 'delete_confirm_dialog.dart';
import 'keyboard_shortcuts_dialog.dart';

const kViewToggleInspectorCommandId = 'view.toggleInspector';
const kViewShowAlertsCommandId = 'view.showAlerts';
const kConnectQuickConnectCommandId = 'connect.quickConnect';
const kConnectDisconnectCommandId = 'connect.disconnect';
const kViewToggleFullScreenCommandId = 'view.toggleFullScreen';
const kSelectionTransferToOtherPaneCommandId =
    'selection.transferToOtherPane';
const kSelectionMoveToOtherPaneCommandId = 'selection.moveToOtherPane';
const kFileRevealCommandId = 'file.reveal';
const kFileNewFolderCommandId = 'file.newFolder';
const kFileNewFileCommandId = 'file.newFile';
const kFileDeleteCommandId = 'file.delete';
const kFileDeletePermanentlyCommandId = 'file.deletePermanently';
const kFileDuplicateCommandId = 'file.duplicate';
const kHelpKeyboardShortcutsCommandId = 'help.keyboardShortcuts';
const kHelpReleaseNotesCommandId = 'help.releaseNotes';
const kHelpReportIssueCommandId = 'help.reportIssue';

/// The project pages the Help menu links to (D19: links only — the app
/// never downloads or phones home).
final _releasesPage = Uri.parse('https://github.com/L-K-M/Poltergeist/releases');
final _issuesPage = Uri.parse('https://github.com/L-K-M/Poltergeist/issues');

List<ShortcutActivator> Function(TargetPlatform) _perPlatform({
  required List<ShortcutActivator> macOS,
  required List<ShortcutActivator> other,
}) =>
    (platform) => platform == TargetPlatform.macOS ? macOS : other;

/// The pane the selection verbs send to: the other visible pane's
/// active tab, when it is bound to a location.
PaneController? _otherPaneTarget(WorkspaceController workspace) {
  if (!workspace.secondPaneShown) return null;
  final PaneTabsController other = identical(
        workspace.activePane,
        workspace.left,
      )
      ? workspace.right
      : workspace.left;
  final target = other.activeTab?.controller;
  if (target == null || target.location == null) return null;
  return target;
}

/// The roots a selection verb acts on: the selected rows, else the
/// cursor row (Finder's "the focused item is the selection" rule).
List<String> _selectionRoots(PaneController pane) {
  final selected = pane.selectedEntries;
  if (selected.isNotEmpty) return [for (final e in selected) e.path];
  final cursor = pane.cursorIndex;
  if (cursor == null || cursor < 0 || cursor >= pane.entries.length) {
    return const [];
  }
  return [pane.entries[cursor].path];
}

/// Whether Copy/Move to Other Pane can run now: both panes bound, a
/// non-empty selection, a queue to receive it, and a drop the 02 §5.1
/// containment rules allow.
bool _canTransfer(
  WorkspaceController workspace,
  PaneDropDelegate? Function() delegate,
  TransferOperation operation,
) {
  if (delegate() == null) return false;
  final source = workspace.activeTabController;
  final target = _otherPaneTarget(workspace);
  if (source == null || target == null || !source.verbsEnabled) return false;
  final sourceLocation = source.location;
  final targetLocation = target.location;
  if (sourceLocation == null || targetLocation == null) return false;
  final roots = _selectionRoots(source);
  if (roots.isEmpty) return false;
  return paneDropAllowed(
    source: fsLocationForLocation(sourceLocation),
    sourceRoots: roots,
    destination: fsLocationForLocation(targetLocation),
    destinationDir: targetLocation.path,
    operation: operation,
  );
}

void _transfer(
  WorkspaceController workspace,
  PaneDropDelegate? Function() delegate,
  TransferOperation operation,
) {
  final queue = delegate();
  final source = workspace.activeTabController;
  final target = _otherPaneTarget(workspace);
  if (queue == null || source == null || target == null) return;
  final sourceLocation = source.location;
  final targetLocation = target.location;
  if (sourceLocation == null || targetLocation == null) return;
  queue.enqueue(
    source: fsLocationForLocation(sourceLocation),
    rootPaths: _selectionRoots(source),
    destination: fsLocationForLocation(targetLocation),
    destinationDir: targetLocation.path,
    operation: operation,
  );
}

/// D32's shell-level commands (10 §4, §8): the inspector toggle and its
/// Alerts tab, Connect (⌘K), and the dual-pane Copy/Move to Other Pane
/// verbs (F5/F6, the Commander convention every two-pane manager uses).
/// The local path "Show in Finder" acts on: the cursor row of a local
/// tab, else its first selected row — null for remote tabs (a remote
/// item has no local file to reveal).
String? _revealTarget(WorkspaceController workspace) {
  final pane = workspace.activeTabController;
  if (pane == null || pane.location is! LocalPaneLocation) return null;
  final roots = _selectionRoots(pane);
  return roots.isEmpty ? null : roots.first;
}

/// The server Server ▸ Disconnect drops: the one the active tab browses,
/// while its connection is live (the sidebar row's rule, which offers
/// Disconnect only then). The pool's own state leads; before its first
/// report the tab's binding phase stands in.
String? _disconnectTarget(WorkspaceController workspace) {
  final pane = workspace.activeTabController;
  final server = pane?.remoteBookmark;
  if (pane == null || server == null) return null;
  final live = switch (pane.connectionStatus?.state) {
    ServerConnectionState.connecting ||
    ServerConnectionState.connected ||
    ServerConnectionState.reconnecting => true,
    null =>
      pane.phase == PanePhase.browsing ||
          pane.phase == PanePhase.connectingRemote,
    _ => false,
  };
  return live ? server.id : null;
}

List<RegisteredCommand> buildShellCommands({
  required WorkspaceController workspace,
  required PaneDropDelegate? Function() dropDelegate,
  required VoidCallback openConnect,
  required List<RegisteredCommand> Function() allCommands,
  required Future<void> Function(Uri url) openUrl,
  required PaneFileOps? Function() fileOps,
  required void Function(Object error) reportFailure,
  required String Function(PaneController pane) locationLabel,
  FileManagerRevealer revealer = const FileManagerRevealer(),

  /// Drops the pool's reference for a server: the sidebar row's
  /// Disconnect, which Server ▸ Disconnect reuses. Null leaves the menu
  /// row disabled.
  Future<void> Function(String serverId)? disconnectServer,
  WindowFullScreen? fullScreen,
}) {
  final window = fullScreen ?? WindowManagerFullScreen.instance;
  bool browsing() => workspace.activeTabController?.verbsEnabled ?? false;
  // Delete and Duplicate act on the selected rows only (PaneFileOps),
  // never on a bare cursor row: after a Ctrl-click deselect or an
  // invert, the cursor can rest on a row the user just deselected, and
  // a destructive verb must not pick it up. Enablement follows the same
  // rule, so the verbs are never enabled while having nothing to do.
  bool hasSelection() {
    final pane = workspace.activeTabController;
    return pane != null &&
        pane.verbsEnabled &&
        pane.selectedEntries.isNotEmpty;
  }

  Future<void> create(Future<String?> Function(PaneController) verb) async {
    final pane = workspace.activeTabController;
    if (pane == null) return;
    try {
      await verb(pane);
    } on Object catch (error) {
      reportFailure(error);
    }
  }

  /// 02 §10's delete flow: a local Move to Trash is reversible, so it
  /// runs without a dialog (Finder's behavior) unless the trash turns
  /// out unavailable; every permanent or remote delete confirms first.
  Future<void> delete(BuildContext context, {required bool permanent}) async {
    final pane = workspace.activeTabController;
    final ops = fileOps();
    if (pane == null || ops == null) return;
    try {
      final local = pane.location is LocalPaneLocation;
      if (local && !permanent) {
        final confirmation = await ops.prepareDeleteSelection(pane);
        if (confirmation == null) return;
        if (confirmation.effectiveDisposition == DeleteDisposition.trash &&
            !confirmation.trashUnavailable) {
          await ops.deleteSelection(
            confirmation,
            disposition: DeleteDisposition.trash,
            pane: pane,
          );
          return;
        }
      }
      if (!context.mounted) return;
      DeleteConfirmation? confirmed;
      final decision = await showDeleteConfirmDialog(
        context,
        locationLabel: locationLabel(pane),
        prepare: (cancellation) async {
          confirmed = await ops.prepareDeleteSelection(
            pane,
            permanent: permanent,
            cancellation: cancellation,
          );
          return confirmed;
        },
      );
      final confirmation = confirmed;
      if (decision is! DeleteConfirmed || confirmation == null) return;
      await ops.deleteSelection(
        confirmation,
        disposition: decision.disposition,
        pane: pane,
      );
    } on Object catch (error) {
      reportFailure(error);
    }
  }

  return [
    RegisteredCommand(
      id: kFileNewFolderCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.fileNewFolderLabel,
      icon: Icons.create_new_folder_outlined,
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyN, meta: true, shift: true),
          SingleActivator(LogicalKeyboardKey.f7),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true),
          SingleActivator(LogicalKeyboardKey.f7),
        ],
      ),
      enabled: browsing,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) => create((pane) => pane.createFolder()),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 12,
      ),
      toolbarPlacement: const CommandToolbarPlacement(
        slot: ToolbarSlot.actions,
        order: 10,
      ),
    ),
    RegisteredCommand(
      id: kFileNewFileCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.fileNewFileLabel,
      icon: Icons.note_add_outlined,
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyN, meta: true, alt: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyN, control: true, alt: true),
        ],
      ),
      enabled: browsing,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) => create((pane) => pane.createFile()),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 14,
      ),
    ),
    RegisteredCommand(
      id: kFileDuplicateCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.fileDuplicateLabel,
      icon: Icons.control_point_duplicate_outlined,
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyD, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyD, control: true)],
      ),
      enabled: () => fileOps() != null && hasSelection(),
      disabledReason: (l10n) => l10n.commandDisabledNoSelection,
      run: (_) async {
        final pane = workspace.activeTabController;
        final ops = fileOps();
        if (pane == null || ops == null) return;
        try {
          ops.duplicateSelection(pane);
        } on Object catch (error) {
          reportFailure(error);
        }
      },
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 72,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kFileDeleteCommandId,
      scope: CommandScope.selection,
      label: (l10n) => workspace.activeTabController?.location
              is RemotePaneLocation
          ? l10n.fileDeleteRemoteLabel
          : (defaultTargetPlatform == TargetPlatform.windows
                ? l10n.fileMoveToRecycleBinLabel
                : l10n.fileMoveToTrashLabel),
      icon: Icons.delete_outline,
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.backspace, meta: true),
        ],
        other: const [SingleActivator(LogicalKeyboardKey.delete)],
      ),
      enabled: () => fileOps() != null && hasSelection(),
      disabledReason: (l10n) => l10n.commandDisabledNoSelection,
      run: (context) => delete(context, permanent: false),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 90,
        group: 4,
      ),
      toolbarPlacement: const CommandToolbarPlacement(
        slot: ToolbarSlot.actions,
        order: 20,
      ),
    ),
    RegisteredCommand(
      id: kFileDeletePermanentlyCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.fileDeletePermanentlyLabel,
      icon: Icons.delete_forever_outlined,
      activators: _perPlatform(
        macOS: const [
          SingleActivator(
            LogicalKeyboardKey.backspace,
            meta: true,
            alt: true,
          ),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.delete, shift: true),
        ],
      ),
      enabled: () => fileOps() != null && hasSelection(),
      disabledReason: (l10n) => l10n.commandDisabledNoSelection,
      run: (context) => delete(context, permanent: true),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 92,
        group: 4,
      ),
    ),
    RegisteredCommand(
      id: kHelpKeyboardShortcutsCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.helpKeyboardShortcutsLabel,
      icon: Icons.keyboard_outlined,
      // ⌘/ is the macOS Help-menu convention for a shortcuts sheet.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.slash, meta: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.slash, control: true),
        ],
      ),
      run: (context) => showKeyboardShortcutsDialog(context, allCommands()),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.help,
        order: 10,
      ),
    ),
    RegisteredCommand(
      id: kHelpReleaseNotesCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.helpReleaseNotesLabel,
      icon: Icons.new_releases_outlined,
      run: (_) => openUrl(_releasesPage),
      // 10 §8's Help menu is one section.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.help,
        order: 20,
      ),
    ),
    RegisteredCommand(
      id: kHelpReportIssueCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.helpReportIssueLabel,
      icon: Icons.bug_report_outlined,
      run: (_) => openUrl(_issuesPage),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.help,
        order: 30,
      ),
    ),
    RegisteredCommand(
      id: kViewToggleInspectorCommandId,
      scope: CommandScope.app,
      label: (l10n) => workspace.inspectorHidden
          ? l10n.viewShowInspectorLabel
          : l10n.viewHideInspectorLabel,
      icon: Icons.view_sidebar_outlined,
      checked: () => !workspace.inspectorHidden,
      // ⌥⌘I is Finder's Show Inspector chord.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyI, meta: true, alt: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyI, control: true, alt: true),
        ],
      ),
      run: (_) async => workspace.toggleInspector(),
      // 10 §8's View menu: Sidebar (60), Inspector, Second Pane (70).
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.view,
        order: 65,
      ),
      toolbarPlacement: const CommandToolbarPlacement(
        slot: ToolbarSlot.status,
        order: 20,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kViewShowAlertsCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.viewShowAlertsLabel,
      icon: Icons.warning_amber_outlined,
      run: (_) async => workspace.showInspector(InspectorTab.alerts),
      // 10 §8's View menu: Info (80), Transfers (85), Alerts.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.view,
        order: 90,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kConnectQuickConnectCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.connectQuickConnectLabel,
      shortLabel: (l10n) => l10n.connectShortLabel,
      icon: Icons.power_outlined,
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyK, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyK, control: true)],
      ),
      run: (_) async => openConnect(),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.server,
        order: 10,
      ),
      toolbarPlacement: const CommandToolbarPlacement(
        slot: ToolbarSlot.primary,
        order: 20,
        labelled: true,
      ),
    ),
    RegisteredCommand(
      id: kConnectDisconnectCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.sidebarDisconnect,
      icon: Icons.eject,
      // ⇧⌘K on macOS, Ctrl+Shift+K elsewhere (02 §8.3's table).
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyK, meta: true, shift: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyK, control: true, shift: true),
        ],
      ),
      enabled: () =>
          disconnectServer != null && _disconnectTarget(workspace) != null,
      disabledReason: (l10n) => l10n.commandDisabledNotConnected,
      run: (_) async {
        final serverId = _disconnectTarget(workspace);
        if (serverId == null || disconnectServer == null) return;
        await disconnectServer(serverId);
      },
      // 10 §8's Server menu: Connect… ⌘K, Disconnect.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.server,
        order: 20,
      ),
    ),
    RegisteredCommand(
      id: kSelectionTransferToOtherPaneCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.selectionCopyToOtherPaneLabel,
      icon: Icons.content_copy_outlined,
      // F5 / ⇧⌘C (10 §4). A Mac laptop's F5 is a media key unless Fn is
      // held, so ⇧⌘C leads there: the first chord is the one the header
      // tooltip and the native key equivalent carry. Elsewhere F5 is
      // the Commander convention and leads.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyC, meta: true, shift: true),
          SingleActivator(LogicalKeyboardKey.f5),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.f5),
          SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true),
        ],
      ),
      enabled: () =>
          _canTransfer(workspace, dropDelegate, TransferOperation.copy),
      disabledReason: (l10n) => l10n.commandDisabledNeedsTwoPanes,
      run: (_) async =>
          _transfer(workspace, dropDelegate, TransferOperation.copy),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 80,
        group: 3,
      ),
      toolbarPlacement: const CommandToolbarPlacement(
        slot: ToolbarSlot.actions,
        order: 30,
      ),
    ),
    RegisteredCommand(
      id: kSelectionMoveToOtherPaneCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.selectionMoveToOtherPaneLabel,
      icon: Icons.drive_file_move_outline,
      activators: (_) => const [SingleActivator(LogicalKeyboardKey.f6)],
      enabled: () =>
          _canTransfer(workspace, dropDelegate, TransferOperation.move),
      disabledReason: (l10n) => l10n.commandDisabledNeedsTwoPanes,
      run: (_) async =>
          _transfer(workspace, dropDelegate, TransferOperation.move),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 82,
        group: 3,
      ),
    ),
      if (revealer.supported)
      RegisteredCommand(
        id: kFileRevealCommandId,
        scope: CommandScope.selection,
        label: (l10n) => switch (defaultTargetPlatform) {
          TargetPlatform.macOS => l10n.fileRevealMacLabel,
          TargetPlatform.windows => l10n.fileRevealWindowsLabel,
          _ => l10n.fileRevealLinuxLabel,
        },
        icon: Icons.folder_open_outlined,
        enabled: () => _revealTarget(workspace) != null,
        disabledReason: (l10n) => l10n.commandDisabledRevealLocalOnly,
        run: (_) async {
          final path = _revealTarget(workspace);
          if (path != null) await revealer.reveal(path);
        },
        menuPlacement: const CommandMenuPlacement(
          menu: AppMenuId.file,
          order: 68,
          group: 1,
        ),
      ),
    // 10 §8's View menu ends with Enter Full Screen on every platform;
    // macOS renders AppKit's own item there instead of this command.
    // No F11 chord yet: the chord layer binds unmodified keys only from
    // its function-key list, and the menu row alone keeps the command
    // reachable (02 §8.1).
    if (window.supported)
      RegisteredCommand(
        id: kViewToggleFullScreenCommandId,
        scope: CommandScope.app,
        label: (l10n) => window.isFullScreen
            ? l10n.viewExitFullScreenLabel
            : l10n.viewEnterFullScreenLabel,
        icon: Icons.fullscreen,
        run: (_) => window.toggle(),
        menuPlacement: const CommandMenuPlacement(
          menu: AppMenuId.view,
          order: 120,
          group: 4,
        ),
      ),
  ];
}
