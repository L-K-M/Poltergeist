import 'package:flutter/material.dart';

import '../../theme/family_hues.dart';
import 'pane_format.dart';

/// A listing kind's glyph and family hue (D32 §6 as D34 colours it):
/// one table for the desktop rows, the phone's kind badges, and every
/// other surface that names an item by its kind. The glyphs are the
/// filled faces, since a hairline outline at 16 px carries too little
/// colour to be told apart at a glance; the active selection repaints
/// them on-accent, where the tint would sink into the fill.
(IconData, FamilyHue) kindGlyph(PaneKindCategory category) =>
    switch (category) {
      PaneKindCategory.folder => (Icons.folder, FamilyHue.blue),
      PaneKindCategory.link => (Icons.shortcut, FamilyHue.cyan),
      PaneKindCategory.image => (Icons.image, FamilyHue.pink),
      PaneKindCategory.document => (Icons.description, FamilyHue.graphite),
      PaneKindCategory.code => (
        Icons.integration_instructions,
        FamilyHue.orange,
      ),
      PaneKindCategory.archive => (Icons.inventory_2, FamilyHue.brown),
      PaneKindCategory.pdf => (Icons.picture_as_pdf, FamilyHue.red),
      PaneKindCategory.audio => (Icons.audio_file, FamilyHue.purple),
      PaneKindCategory.video => (Icons.video_file, FamilyHue.purple),
      PaneKindCategory.other => (Icons.insert_drive_file, FamilyHue.graphite),
    };

/// [category]'s glyph as an [Icon] in its hue for [context]'s theme.
Icon kindIcon(
  BuildContext context,
  PaneKindCategory category, {
  required double size,
}) {
  final (glyph, hue) = kindGlyph(category);
  return Icon(glyph, size: size, color: FamilyPalette.of(context).glyph(hue));
}
