import 'package:flutter/material.dart';

import '../../services/bookmark_backup_service.dart';
import '../../services/registered_command.dart';
import '../../services/settings_window/settings_window_link.dart';
import '../../services/sync_account_gate.dart';
import 'backup_settings.dart';

/// The registered id of the Settings → Backup entry command (D21).
const kOpenSettingsBackupCommandId = 'open-settings-backup';

/// Opens the Settings → Backup surface. No chord is bound (02 §8.3 binds
/// ⌘,/Ctrl+, to the general `app.settings` command, a later slice), so
/// §8.1's menu-or-shortcut invariant needs a menu path: the File menu's
/// trailing group, where Windows/Linux carry Settings… per 02 §9.
///
/// On desktop it opens the Settings window on Sync ([openWindow]); the
/// Backup dialog remains for a runner without one.
RegisteredCommand buildOpenSettingsBackupCommand({
  required BookmarkBackupService service,
  SyncAccountGate gate = const SyncAccountGate.production(),
  required bool Function() enabled,
  OpenSettingsWindow? openWindow,
}) {
  return RegisteredCommand(
    id: kOpenSettingsBackupCommandId,
    scope: CommandScope.app,
    label: (l10n) => l10n.settingsBackupCommand,
    icon: Icons.backup_outlined,
    enabled: enabled,
    disabledReason: (l10n) => l10n.commandDisabledBusy,
    run: (context) async {
      if (await openWindow?.call(SettingsWindowTab.sync) ?? false) return;
      if (!context.mounted) return;
      await showBackupSettingsDialog(context, service: service, gate: gate);
    },
    menuPlacement: const CommandMenuPlacement(
      menu: AppMenuId.server,
      order: 45,
      group: 2,
    ),
  );
}
