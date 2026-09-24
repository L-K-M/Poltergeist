// The sync commands (05 §7/§9): `sync.synchronizePanes` — ⌥⌘Y /
// Ctrl+Alt+Y (02 §8.3) — builds an ad-hoc pair from the two panes'
// current locations and opens its plan view; `sync.newSavedSync`
// opens the pair editor and persists the result as a savedSync
// bookmark; `sync.copyRsyncCommand` copies the active plan's rsync
// export (05 §2.1). All live in 02 §9's Commands menu.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/registered_command.dart';
import '../../services/workspace_controller.dart';

const kSyncSynchronizePanesCommandId = 'sync.synchronizePanes';
const kSyncNewSavedSyncCommandId = 'sync.newSavedSync';
const kSyncCopyRsyncCommandId = 'sync.copyRsyncCommand';

/// The sync command registrations. The verbs themselves are shell
/// operations (pair construction reads both pane strips; the editor's
/// save writes the bookmark store and opens a plan tab), so they
/// arrive as delegates — the shell owns the seams, this file owns the
/// registration surface.
List<RegisteredCommand> buildSyncCommands({
  required WorkspaceController workspace,
  required bool Function() synchronizeEnabled,
  required bool Function() savedSyncEnabled,
  required bool Function() copyRsyncEnabled,
  required FutureOr<void> Function(BuildContext context) synchronizePanes,
  required FutureOr<void> Function(BuildContext context) newSavedSync,
  required FutureOr<void> Function(BuildContext context) copyRsync,
}) {
  return [
    RegisteredCommand(
      id: kSyncSynchronizePanesCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.syncSynchronizePanes,
      icon: Icons.sync_alt,
      // ⌥⌘Y on macOS, Ctrl+Alt+Y elsewhere (02 §8.3's table).
      activators: (platform) => platform == TargetPlatform.macOS
          ? const [
              SingleActivator(LogicalKeyboardKey.keyY, meta: true, alt: true),
            ]
          : const [
              SingleActivator(
                LogicalKeyboardKey.keyY,
                control: true,
                alt: true,
              ),
            ],
      enabled: synchronizeEnabled,
      disabledReason: (l10n) => l10n.commandDisabledSyncAnchors,
      run: (context) async => synchronizePanes(context),
      // 02 §9's Commands table: "Synchronize…" holds the third slot —
      // between the transfer/move block and Calculate Folder Sizes.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.commands,
        order: 30,
      ),
    ),
    RegisteredCommand(
      id: kSyncNewSavedSyncCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.syncNewSavedSync,
      icon: Icons.sync_outlined,
      // No chord in 02 §8.3 — menu/palette reachable.
      enabled: savedSyncEnabled,
      disabledReason: (l10n) => l10n.commandDisabledNoBookmarks,
      run: (context) async => newSavedSync(context),
      // Directly under Synchronize…; the §9 table names no saved-sync
      // slot, so it sits in the gap before Calculate Folder Sizes (40).
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.commands,
        order: 35,
      ),
    ),
    RegisteredCommand(
      id: kSyncCopyRsyncCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.syncCopyRsyncCommand,
      icon: Icons.terminal,
      // No chord in 02 §8.3 — menu/palette reachable; the plan view's
      // action bar renders the same command.
      enabled: copyRsyncEnabled,
      disabledReason: (l10n) => l10n.commandDisabledNoPlan,
      run: (context) async => copyRsync(context),
      // The sync block's third row — enabled only while an exportable
      // plan tab is focused (05 §2.1: the exporter is reachable only
      // from the plan view).
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.commands,
        order: 37,
      ),
    ),
  ];
}
