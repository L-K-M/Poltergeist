import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller.dart';
import '../../services/pane_drop.dart';
import '../../services/pane_tabs_controller.dart';
import '../../services/registered_command.dart';
import '../../services/workspace_controller.dart';

const kViewToggleInspectorCommandId = 'view.toggleInspector';
const kViewShowAlertsCommandId = 'view.showAlerts';
const kConnectQuickConnectCommandId = 'connect.quickConnect';
const kSelectionTransferToOtherPaneCommandId =
    'selection.transferToOtherPane';
const kSelectionMoveToOtherPaneCommandId = 'selection.moveToOtherPane';

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
List<RegisteredCommand> buildShellCommands({
  required WorkspaceController workspace,
  required PaneDropDelegate? Function() dropDelegate,
  required VoidCallback openConnect,
}) {
  return [
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
  ];
}
