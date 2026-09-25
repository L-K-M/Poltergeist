import 'package:flutter/material.dart';

import '../../services/registered_command.dart';
import '../../theme/family_hues.dart';

/// [command]'s glyph for a toolbar, menu, or palette row: in the verb's
/// family hue (D34) while [enabled], else in [ink], the surface's own
/// colour. A null [ink] leaves it to the enclosing button or menu, so a
/// disabled row still dims the way it always has. One rule for every
/// surface a command renders on, so Trash is the same red in the
/// toolbar, the context menu, and the palette.
Icon commandIcon(
  BuildContext context,
  RegisteredCommand command, {
  required double size,
  required bool enabled,
  Color? ink,
  IconData fallback = Icons.circle_outlined,
}) {
  final hue = command.hue;
  return Icon(
    command.icon ?? fallback,
    size: size,
    color: enabled && hue != null
        ? FamilyPalette.of(context).glyph(hue)
        : ink,
  );
}
