import 'package:flutter/material.dart';

import '../../services/bookmark_backup_service.dart';
import '../../services/registered_command.dart';
import '../../services/sync_account_gate.dart';
import 'backup_settings.dart';

/// The registered id of the Settings → Backup entry command (D21).
const kOpenSettingsBackupCommandId = 'open-settings-backup';

/// Opens the Settings → Backup surface. No chord is bound (02 §8.3 binds
/// ⌘,/Ctrl+, to the general `app.settings` command, a later slice), so
/// §8.1's menu-or-shortcut invariant needs a menu path: the File menu's
/// trailing group, where Windows/Linux carry Settings… per 02 §9.
RegisteredCommand buildOpenSettingsBackupCommand({
  required BookmarkBackupService service,
  SyncAccountGate gate = const SyncAccountGate.production(),
  required bool Function() enabled,
}) {
  return RegisteredCommand(
    id: kOpenSettingsBackupCommandId,
    scope: CommandScope.app,
    label: (l10n) => l10n.settingsBackupCommand,
    icon: Icons.backup_outlined,
    enabled: enabled,
    disabledReason: (l10n) => l10n.commandDisabledBusy,
    run: (context) =>
        showBackupSettingsDialog(context, service: service, gate: gate),
    menuPlacement: const CommandMenuPlacement(
      menu: AppMenuId.file,
      order: 160,
      group: 3,
    ),
  );
}
