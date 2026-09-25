import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../services/registered_command.dart';
import '../../services/settings_models.dart' show AppearanceSettingsModel;
import '../../services/settings_window/settings_window_link.dart';
import 'general_settings.dart';

/// The registered id of the app Settings command (02 §8.1's
/// `app.settings` row — the five-tab screen of §10 lands later; this
/// opens the bounded General dialog that already exists).
const kAppSettingsCommandId = 'app.settings';

/// 02 §9's Settings row: ⌘, on macOS, Ctrl+, elsewhere. The File menu's
/// trailing group carries it beside Settings → Backup — on Windows and
/// Linux that group is where §9 puts Settings…, and macOS's app-menu
/// placement is platform chrome the registry does not render, so File
/// is the reachable path everywhere the menu bar exists.
///
/// On desktop it opens the Settings window on General ([openWindow]); the
/// Settings dialog remains for a runner without one, and is what phones and
/// tablets get: General's rows ([settings]) and Appearance ([appearance]),
/// whichever the app has.
RegisteredCommand buildAppSettingsCommand({
  GeneralSettings Function()? settings,
  AppearanceSettingsModel? appearance,
  required bool Function() enabled,
  OpenSettingsWindow? openWindow,
}) {
  assert(
    settings != null || appearance != null,
    'Settings needs a section to show.',
  );
  return RegisteredCommand(
    id: kAppSettingsCommandId,
    scope: CommandScope.app,
    label: (l10n) => l10n.settingsCommand,
    activators: (platform) => platform == TargetPlatform.macOS
        ? const [
            SingleActivator(LogicalKeyboardKey.comma, meta: true),
          ]
        : const [
            SingleActivator(LogicalKeyboardKey.comma, control: true),
          ],
    enabled: enabled,
    disabledReason: (l10n) => l10n.commandDisabledBusy,
    run: (context) async {
      if (await openWindow?.call(SettingsWindowTab.general) ?? false) return;
      if (!context.mounted) return;
      await showGeneralSettingsDialog(
        context,
        settings: settings?.call(),
        appearance: appearance,
      );
    },
    // 10 §8: the macOS app menu on Mac (AppKit convention), File's
    // last section elsewhere, after the tab section (group 5).
    menuPlacement: const CommandMenuPlacement(
      menu: AppMenuId.file,
      order: 170,
      group: 6,
      appMenuOnMac: true,
    ),
  );
}
