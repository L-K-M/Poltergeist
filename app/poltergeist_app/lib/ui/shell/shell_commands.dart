import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/file_manager_reveal.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_location.dart';
import '../../services/pane_drop.dart';
import '../../services/pane_tabs_controller.dart';
import '../../services/registered_command.dart';
import '../../services/workspace_controller.dart';
import 'keyboard_shortcuts_dialog.dart';

const kViewToggleInspectorCommandId = 'view.toggleInspector';
const kViewShowAlertsCommandId = 'view.showAlerts';
const kConnectQuickConnectCommandId = 'connect.quickConnect';
const kSelectionTransferToOtherPaneCommandId =
    'selection.transferToOtherPane';
const kSelectionMoveToOtherPaneCommandId = 'selection.moveToOtherPane';
const kFileRevealCommandId = 'file.reveal';
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

List<RegisteredCommand> buildShellCommands({
  required WorkspaceController workspace,
  required PaneDropDelegate? Function() dropDelegate,
  required VoidCallback openConnect,
  required List<RegisteredCommand> Function() allCommands,
  required Future<void> Function(Uri url) openUrl,
  FileManagerRevealer revealer = const FileManagerRevealer(),
}) {
  return [
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
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.help,
        order: 20,
        group: 1,
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
        group: 1,
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
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.view,
        order: 75,
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
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.view,
        order: 95,
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
      id: kSelectionTransferToOtherPaneCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.selectionCopyToOtherPaneLabel,
      icon: Icons.content_copy_outlined,
      activators: (_) => const [SingleActivator(LogicalKeyboardKey.f5)],
      enabled: () =>
          _canTransfer(workspace, dropDelegate, TransferOperation.copy),
      disabledReason: (l10n) => l10n.commandDisabledNeedsTwoPanes,
      run: (_) async =>
          _transfer(workspace, dropDelegate, TransferOperation.copy),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 80,
        group: 2,
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
        group: 2,
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
  ];
}
