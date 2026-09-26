// Ported from Séance app/seance_app/lib/ui/server_color_picker.dart @
// 035b0d8 (tag v0.9.1); see docs/PORTS.md. Reduced to a wrapper over
// color_picker.dart as Séance's was (f4d2f71).
// Divergence: strings localize through ARB (D20).
import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import 'color_picker.dart';
import 'server_appearance.dart';

/// Picks a colour of the user's own for a server's accent.
///
/// Returns the chosen colour, or null if the dialog was dismissed. [mark] is
/// what the server is currently marked with, so the preview shows the badge
/// the colour will actually be drawn under rather than an empty swatch.
Future<Color?> showServerColorPicker(
  BuildContext context, {
  required Color initial,
  required ServerMark mark,
}) {
  final l10n = AppLocalizations.of(context);
  return showColorPicker(
    context,
    initial: initial,
    title: l10n.serverColorPickerTitle,
    preview: (context, color) {
      // One tint for both halves of the preview: the bar and the badge show
      // the same colour two ways, and building it twice is how they drift
      // apart.
      final tint = ServerTint(custom: color);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Previewed as the list will draw it, in this theme: the line is
          // derived from the picked colour rather than painted raw, and
          // this is where that shows.
          ServerAccentBar(tint: tint, height: 48),
          const SizedBox(width: 12),
          ServerBadge(tint: tint, mark: mark, size: 48),
        ],
      );
    },
    note: l10n.serverColorPickerHint,
  );
}
