import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import '../../services/shortcut_format.dart';
import '../../theme/app_theme.dart';
import '../menus/app_menus.dart' show appMenuTitle;

/// Help ▸ Keyboard Shortcuts (10 §8): every registered command that has a
/// chord, grouped by the menu it lives in — generated from the registry
/// (D21), so the sheet can never drift from what the keys actually do.
Future<void> showKeyboardShortcutsDialog(
  BuildContext context,
  List<RegisteredCommand> commands,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => _KeyboardShortcutsDialog(commands: commands),
  );
}

class _KeyboardShortcutsDialog extends StatelessWidget {
  const _KeyboardShortcutsDialog({required this.commands});

  final List<RegisteredCommand> commands;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final platform = theme.platform;

    final grouped = <AppMenuId?, List<(String, String)>>{};
    for (final command in commands) {
      final activators = command.activators?.call(platform);
      if (activators == null || activators.isEmpty) continue;
      final chords = [
        for (final activator in activators)
          ?formatShortcutActivator(activator, platform),
      ];
      if (chords.isEmpty) continue;
      grouped
          .putIfAbsent(command.menuPlacement?.menu, () => [])
          .add((command.label(l10n), chords.join('  ·  ')));
    }
    final menus = [
      for (final id in AppMenuId.values)
        if (grouped.containsKey(id)) id,
      if (grouped.containsKey(null)) null,
    ];

    return Dialog(
      key: const ValueKey('help.shortcuts.dialog'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.helpKeyboardShortcutsLabel,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                shrinkWrap: true,
                children: [
                  for (final menu in menus) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 14, bottom: 4),
                      child: Text(
                        menu == null
                            ? l10n.helpShortcutsOtherGroup
                            : appMenuTitle(menu, l10n),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: chrome.secondaryText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (final (label, chord) in grouped[menu]!)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                label,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            Text(
                              chord,
                              style: poltergeistMonoTextStyle.copyWith(
                                fontSize: 12,
                                color: chrome.secondaryText,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
