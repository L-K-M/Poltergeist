import 'package:flutter/material.dart';

import '../../services/registered_command.dart';
import '../../services/shortcut_format.dart';
import '../../theme/app_theme.dart';

/// The trailing shortcut hint a registry menu row shows (10 §8): the
/// command's first registered activator — the chord layer's own binding,
/// so hint and dispatch cannot drift — spelled by the formatter the
/// toolbar tooltips and the palette share, and set in the secondary text
/// colour so the label leads. Display only: the chord layer dispatches.
class MenuShortcutHint extends StatelessWidget {
  const MenuShortcutHint(this.activator, {super.key, this.enabled = true});

  /// The hint for [command]'s first activator on [platform], or null
  /// when it has none.
  static MenuShortcutHint? forCommand(
    RegisteredCommand command,
    TargetPlatform platform,
  ) {
    final activators = command.activators?.call(platform);
    if (activators == null || activators.isEmpty) return null;
    return MenuShortcutHint(activators.first, enabled: command.enabled());
  }

  final ShortcutActivator activator;

  /// A disabled row dims its hint with its label.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = formatShortcutActivator(activator, theme.platform);
    if (text == null) return const SizedBox.shrink();
    final color = enabled
        ? PoltergeistChrome.of(context).secondaryText
        : theme.colorScheme.onSurface.withValues(alpha: 0.38);
    return Text(
      text,
      style: TextStyle(
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
