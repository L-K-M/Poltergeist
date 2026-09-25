// Ported from Séance app/seance_app/lib/theme/theme_presets.dart @ f4d2f71; see docs/PORTS.md.
// Divergence: the default is Poltergeist's teal, not Séance's violet, and
// no preset carries a terminal block. The other nine keep Séance's values,
// so a shared preset looks the same in both apps.
import 'dart:ui' show Color;

import 'app_theme.dart' show poltergeistSeedColor;
import 'theme_palette.dart';

/// The themes Poltergeist ships with, after Vervellum's `ThemePresets.swift`
/// by way of Séance.
///
/// A preset is a starting point, not a mode: picking one copies its values
/// into the device's palette, which the user is then free to change. Every
/// one but the two that follow the system is complete (its own surface,
/// sidebar, lines, selection and status colours) because a preset that
/// left the sidebar Automatic would frame a Solarized pane in slate. The
/// default leaves everything Automatic, which is what reproduces the app as
/// it looked before themes existed.
///
/// Each has to pass `theme_presets_test.dart`: text and secondary text on
/// its surface and sidebar, the accent and every status colour on its
/// surface, and the selection's label, the thresholds the default neutrals
/// already meet. The accents are Vervellum's, except Bubblegum's, which is a
/// shade deeper than Vervellum's #FF59AD: that pink is 2.7:1 on its own
/// surface.
///
/// The names are the stored form, in English and the same as Séance's, so
/// a pasted theme keeps its name in either app. The Appearance section
/// shows each in the reader's language instead.
abstract final class ThemePresets {
  /// The default: Poltergeist's teal over the sibling neutrals, which
  /// follow the system's light or dark appearance.
  static final ThemePalette poltergeist = ThemePalette(
    name: 'Poltergeist',
    accent: poltergeistSeedColor,
  );

  /// Quiet: a muted blue-grey accent for anyone who finds colour
  /// distracting, over the same neutrals.
  static final ThemePalette graphite = ThemePalette(
    name: 'Graphite',
    accent: const Color(0xFF6B859E),
    cornerScale: 0.8,
  );

  /// Warm, light and a little square.
  static final ThemePalette paper = ThemePalette(
    name: 'Paper',
    accent: const Color(0xFF8C5729),
    surface: const Color(0xFFFAF5E8),
    sidebar: const Color(0xFFF2EBDA),
    raised: const Color(0xFFF6F0E1),
    text: const Color(0xFF29241C),
    secondaryText: const Color(0xFF61594C),
    hairline: const Color(0xFFDDD2BC),
    selection: const Color(0xFF80502A),
    online: const Color(0xFF2F7A3A),
    offline: const Color(0xFFB3261E),
    connecting: const Color(0xFF915C00),
    unknown: const Color(0xFF6E665A),
    cornerScale: 0.5,
  );

  /// Black, white and a red pencil; sharp corners.
  static final ThemePalette newsprint = ThemePalette(
    name: 'Newsprint',
    // The same red as `offline`, deliberately, as in Vervellum: one ink.
    accent: const Color(0xFFB81C1C),
    surface: const Color(0xFFF7F7F2),
    sidebar: const Color(0xFFEDEDE6),
    raised: const Color(0xFFF2F2EC),
    text: const Color(0xFF121212),
    secondaryText: const Color(0xFF595959),
    hairline: const Color(0xFFC9C9C2),
    selection: const Color(0xFF262626),
    online: const Color(0xFF1A6B33),
    offline: const Color(0xFFB81C1C),
    connecting: const Color(0xFF8F610A),
    unknown: const Color(0xFF4D5766),
    cornerScale: 0.2,
  );

  /// Solarized dark.
  ///
  /// The one preset whose secondary text is under 4.5:1 (3.3): Solarized's
  /// hierarchy puts it below base0, which is itself only 4.7:1 on base03,
  /// and a Solarized that brightened it would no longer be Solarized. The
  /// sidebar and header sit a shade *darker* than base03 rather than on
  /// base02, where base0 text drops to 4.1:1.
  static final ThemePalette solarized = ThemePalette(
    name: 'Solarized',
    accent: const Color(0xFFB58900),
    surface: const Color(0xFF002B36),
    sidebar: const Color(0xFF00252F),
    raised: const Color(0xFF012E39),
    text: const Color(0xFF839496),
    secondaryText: const Color(0xFF667A82),
    hairline: const Color(0xFF174552),
    selection: const Color(0xFF1C6A9E),
    online: const Color(0xFF859900),
    offline: const Color(0xFFDC322F),
    connecting: const Color(0xFFB58900),
    unknown: const Color(0xFF839496),
  );

  /// Deep blue, for a dark desk at night.
  static final ThemePalette midnight = ThemePalette(
    name: 'Midnight',
    accent: const Color(0xFF66ADFF),
    surface: const Color(0xFF0E131F),
    sidebar: const Color(0xFF0A0E18),
    raised: const Color(0xFF151C2B),
    text: const Color(0xFFE6EDFA),
    secondaryText: const Color(0xFF9EADC7),
    hairline: const Color(0xFF26314A),
    selection: const Color(0xFF2A5DA8),
    online: const Color(0xFF4DD18C),
    offline: const Color(0xFFFF6B73),
    connecting: const Color(0xFFFFC252),
    unknown: const Color(0xFF8CA3CC),
  );

  /// Green on black, and square.
  static final ThemePalette terminal = ThemePalette(
    name: 'Terminal',
    // The same green as `online`, deliberately: a terminal has one colour,
    // and that is the preset. The statuses stay apart from each other.
    accent: const Color(0xFF33FF73),
    surface: const Color(0xFF050D08),
    sidebar: const Color(0xFF030805),
    raised: const Color(0xFF0A1A10),
    text: const Color(0xFFC7FFD1),
    secondaryText: const Color(0xFF6BBD80),
    hairline: const Color(0xFF1A4D2B),
    selection: const Color(0xFF1F7A3D),
    online: const Color(0xFF33FF73),
    offline: const Color(0xFFFF4747),
    connecting: const Color(0xFFFFDB33),
    unknown: const Color(0xFF73B8D9),
    cornerScale: 0,
  );

  /// Magenta and cyan over violet-black, and rounder.
  static final ThemePalette vapor = ThemePalette(
    name: 'Vapor',
    accent: const Color(0xFFFF4CD9),
    surface: const Color(0xFF170A29),
    sidebar: const Color(0xFF12071F),
    raised: const Color(0xFF200F38),
    text: const Color(0xFFEDE6FF),
    secondaryText: const Color(0xFF99D9F2),
    hairline: const Color(0xFF3A2466),
    selection: const Color(0xFF8C1FA3),
    online: const Color(0xFF4DFFCC),
    offline: const Color(0xFFFF4073),
    connecting: const Color(0xFFFFCC4D),
    unknown: const Color(0xFF8CB3FF),
    cornerScale: 1.4,
  );

  /// Pink, purple and very round.
  static final ThemePalette bubblegum = ThemePalette(
    name: 'Bubblegum',
    accent: const Color(0xFFE63A91),
    surface: const Color(0xFFFFF2FA),
    sidebar: const Color(0xFFFAE4F1),
    raised: const Color(0xFFFDEBF6),
    text: const Color(0xFF3D1A3D),
    secondaryText: const Color(0xFF7A4D7A),
    hairline: const Color(0xFFEBC4DD),
    selection: const Color(0xFFB8337A),
    online: const Color(0xFF0F7A55),
    offline: const Color(0xFFC21E4A),
    connecting: const Color(0xFFA35C00),
    unknown: const Color(0xFF666699),
    cornerScale: 1.8,
  );

  /// The most separation between text and surface, and between statuses.
  static final ThemePalette highContrast = ThemePalette(
    name: 'High contrast',
    accent: const Color(0xFFFFD900),
    surface: const Color(0xFF000000),
    sidebar: const Color(0xFF000000),
    raised: const Color(0xFF141414),
    text: const Color(0xFFFFFFFF),
    secondaryText: const Color(0xFFD9D9D9),
    hairline: const Color(0xFF8C8C8C),
    // Yellow under black text, the usual high-contrast highlight.
    selection: const Color(0xFFFFD900),
    online: const Color(0xFF33FF66),
    offline: const Color(0xFFFF5959),
    // Orange rather than the accent's yellow, so a connecting dot and the
    // accent are never the same colour in the preset about separation.
    connecting: const Color(0xFFFF9E00),
    unknown: const Color(0xFF80CCFF),
    cornerScale: 0.4,
  );

  /// Every preset, in the order the Appearance section shows them: the two
  /// that follow the system's light or dark (the default first), then the
  /// light ones with surfaces of their own, then the dark ones, then the
  /// loud ones.
  static final List<ThemePalette> all = List.unmodifiable([
    poltergeist,
    graphite,
    paper,
    newsprint,
    solarized,
    midnight,
    terminal,
    vapor,
    bubblegum,
    highContrast,
  ]);

  /// What a device starts with, and what Reset puts back.
  static ThemePalette get initial => poltergeist;
}
