import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/registered_command.dart';
import '../../services/workspace_controller.dart';
import '../../services/workspace_library.dart';
import '../../services/workspace_state.dart';
import '../top_toast.dart';
import 'save_workspace_dialog.dart';

/// §10's action-toast duration: the opened toast carries Undo.
const _openToastDuration = Duration(seconds: 12);

/// The workspace commands (02 §3's final slice): `workspace.save` and the
/// per-workspace `workspace.open.<id>` items the "Workspaces" submenu
/// renders in newest-first order.
///
/// Menu placement follows 02 §9's Commands table — "Save Workspace…"
/// holds the slot between "Add to Favorites…" (40) and "Copy as rsync
/// Command" (60); the submenu the table does not name sits immediately
/// after it, each saved workspace one row.
List<RegisteredCommand> buildWorkspaceCommands({
  required WorkspaceController workspace,
  required WorkspaceLibrary library,
  required bool Function() enabled,
}) {
  return [
    RegisteredCommand(
      id: 'workspace.save',
      scope: CommandScope.app,
      label: (l10n) => l10n.workspaceSaveCommand,
      enabled: enabled,
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.commands,
        order: 50,
      ),
      run: (context) =>
          _saveWorkspace(context, workspace: workspace, library: library),
    ),
    if (library.workspaces.isEmpty)
      // The submenu keeps a disabled row when nothing is saved yet, so
      // the open affordance stays discoverable instead of a menu entry
      // that vanishes.
      RegisteredCommand(
        id: 'workspace.open.empty',
        scope: CommandScope.app,
        label: (l10n) => l10n.workspaceMenuEmpty,
        enabled: () => false,
        menuPlacement: CommandMenuPlacement(
          menu: AppMenuId.commands,
          order: 55,
          submenu: (l10n) => l10n.menuWorkspaces,
        ),
        run: (_) async {},
      )
    else
      for (var i = 0; i < library.workspaces.length; i++)
        _openCommand(
          library.workspaces[i],
          rank: i,
          workspace: workspace,
          library: library,
          enabled: enabled,
        ),
  ];
}

RegisteredCommand _openCommand(
  SavedWorkspace saved, {
  required int rank,
  required WorkspaceController workspace,
  required WorkspaceLibrary library,
  required bool Function() enabled,
}) {
  return RegisteredCommand(
    // The workspace's persisted id keeps the command id stable across
    // reorders — the menu key and any future activator ride it.
    id: 'workspace.open.${saved.id}',
    scope: CommandScope.app,
    // The user-chosen name is data, not authored copy — it renders as
    // the row's label verbatim.
    label: (_) => saved.label,
    enabled: enabled,
    menuPlacement: CommandMenuPlacement(
      menu: AppMenuId.commands,
      order: 55 + rank,
      submenu: (l10n) => l10n.menuWorkspaces,
    ),
    run: (context) =>
        _openWorkspace(context, saved, workspace: workspace, library: library),
  );
}

Future<void> _saveWorkspace(
  BuildContext context, {
  required WorkspaceController workspace,
  required WorkspaceLibrary library,
}) async {
  final l10n = AppLocalizations.of(context);
  final label = await showDialog<String>(
    context: context,
    builder: (_) => const SaveWorkspaceDialog(),
  );
  if (label == null) return;
  final saved = await library.save(
    label: label,
    snapshot: workspace.captureWorkspace(),
  );
  if (!context.mounted) return;
  showTopToastIn(context, message: l10n.workspaceSavedToast(saved.label));
}

Future<void> _openWorkspace(
  BuildContext context,
  SavedWorkspace saved, {
  required WorkspaceController workspace,
  required WorkspaceLibrary library,
}) async {
  final l10n = AppLocalizations.of(context);
  // The guarded replace: every existing tab's in-flight state is
  // confirmed through the strips' shared close-guard registry BEFORE
  // anything is replaced (02 §3). Null means a guard declined — the
  // workspace stands exactly as it was, no toast.
  final prior = await workspace.requestApplyWorkspace(saved.snapshot);
  if (prior == null) return;
  // Persist the open for the menu's newest-first order — reported like
  // any other store fault, never silently.
  await library.markOpened(saved.id);
  if (!context.mounted) return;
  showTopToastIn(
    context,
    message: l10n.workspaceOpenedToast(saved.label),
    duration: _openToastDuration,
    actionLabel: l10n.workspaceUndoAction,
    // Undo routes through the SAME guarded operation — a workspace tab
    // that has since gone in-flight is confirmed again rather than
    // dropped silently.
    onAction: () => unawaited(_restorePrior(workspace, prior)),
  );
}

Future<void> _restorePrior(
  WorkspaceController workspace,
  WorkspaceSnapshot prior,
) async {
  try {
    await workspace.requestApplyWorkspace(prior);
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
  }
}
