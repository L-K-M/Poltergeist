// Ported from Séance app/seance_app/lib/theme/theme_palette.dart @ f4d2f71; see docs/PORTS.md.
// Divergence: no terminal block. Poltergeist has no terminal, so a Séance
// theme's `terminal` key is read past (everything else in it applies) and
// never written back.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;

import 'theme_presets.dart';

/// The palette's colours that may be left Automatic, by the key each is
/// stored under.
///
/// Automatic (null) means "what the app would draw here without a theme":
/// the sibling neutrals for the brightness in force, or, once the palette
/// sets its own [surface], shades mixed from that surface and its text
/// (see `buildPoltergeistThemeFor`). The default preset leaves every one of
/// them Automatic, which is how an install that has never opened
/// Appearance keeps looking exactly as it did.
///
/// The keys are Séance's, so a theme copied in one app pastes into the
/// other.
enum ThemeSlot {
  /// The pane and page background. Also decides the palette's brightness
  /// when set: a theme with its own surface is light or dark by that
  /// surface, whatever the system says.
  surface,

  /// The sidebar and the inspector beside the panes.
  sidebar,

  /// The header toolbar and raised containers; the rest of the container
  /// ladder is mixed from it.
  raised,
  text,
  secondaryText,

  /// Dividers and outlines.
  hairline,

  /// The active pane's selected rows.
  selection,

  /// A connected server, and one that answers its probe.
  online,

  /// A failed connection, a blocked host key, and a server that does not
  /// answer its probe.
  offline,

  /// A connection being made or remade.
  connecting,

  /// A server whose state is not known yet, or that is idle.
  unknown;

  /// Whether a colour here may be translucent. Only the two that are drawn
  /// over something else: a divider or a selection over the listing can be
  /// a tint, but a translucent surface would show whatever the window
  /// happens to clear to, and a translucent text or status colour loses the
  /// contrast the presets are tested for.
  bool get allowsAlpha => this == hairline || this == selection;
}

/// Reads `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA`, in either case, with
/// or without a `#` or `0x`, around any whitespace, or null.
///
/// Lenient on purpose, as in Vervellum: this is the value people paste from
/// a palette they found, and refusing `0xFF8A4C` or a trailing space is a
/// worse experience than reading it. The alpha comes *last*, as CSS writes
/// it, so `0x` here is a prefix, not Flutter's `0xAARRGGBB` order.
Color? parseThemeColor(Object? value) {
  if (value is! String) return null;
  var text = value.trim().toLowerCase();
  for (final prefix in const ['#', '0x']) {
    if (text.startsWith(prefix)) text = text.substring(prefix.length);
  }
  if (!_hexDigits.hasMatch(text)) return null;
  // CSS Color 4's short forms double each digit onto the long ones.
  if (text.length == 3 || text.length == 4) {
    text = [for (final digit in text.split('')) '$digit$digit'].join();
  }
  if (text.length != 6 && text.length != 8) return null;
  final bits = int.parse(text, radix: 16);
  if (text.length == 6) return Color(0xFF000000 | bits);
  return Color((bits & 0xFF) << 24 | bits >> 8);
}

final RegExp _hexDigits = RegExp(r'^[0-9a-f]+$');

/// `#RRGGBB`, or `#RRGGBBAA` when [color] is not opaque: what
/// [parseThemeColor] reads back to the same colour.
String formatThemeColor(Color color) {
  final argb = color.toARGB32();
  final alpha = argb >>> 24;
  final rgb = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
  final hex = alpha == 0xFF
      ? rgb
      : '$rgb${alpha.toRadixString(16).padLeft(2, '0')}';
  return '#${hex.toUpperCase()}';
}

/// [color] at the 8-bit precision the stored form keeps.
///
/// Every colour a palette holds goes through this, so a palette always
/// equals itself after a trip through JSON: a colour straight off an HSV
/// slider carries more precision than `#RRGGBB` can write down, and a
/// palette that compared unequal to its own saved copy would never match
/// its preset again, and would write itself back on every save.
Color _exact(Color color) => Color(color.toARGB32());

Color _opaque(Color color) => Color(0xFF000000 | color.toARGB32());

/// Everything about how the app looks, as one value: this device's theme.
///
/// Séance's port of Vervellum's `PanelPalette`, and it keeps that model.
/// There is one palette per device, not a library of them: a preset
/// ([ThemePresets.all]) is a starting point, not a mode. Picking one copies
/// its values in, and every value then stays editable. Nothing reads a
/// preset by name when drawing, so a preset that is renamed or dropped in a
/// later version cannot leave anyone with an app that will not draw.
///
/// Stored as one JSON object ([toJson]), read back leniently ([fromJson]):
/// this is the setting people will hand-edit and paste to each other, so a
/// document missing half its keys reads as "the default, plus what it did
/// say" rather than costing the whole theme.
///
/// Colour never carries meaning alone, whatever a palette says: each server
/// status keeps its own shape and its words, so the worst a palette can do
/// is be ugly.
@immutable
class ThemePalette {
  /// A palette with its values normalised: [name] trimmed (blank reads as
  /// [customName]), [fontFamily] trimmed (blank reads as the platform's),
  /// [cornerScale] clamped, and every colour at stored precision, opaque
  /// where [ThemeSlot.allowsAlpha] says it must be.
  factory ThemePalette({
    String name = customName,
    required Color accent,
    Color? surface,
    Color? sidebar,
    Color? raised,
    Color? text,
    Color? secondaryText,
    Color? hairline,
    Color? selection,
    Color? online,
    Color? offline,
    Color? connecting,
    Color? unknown,
    String? fontFamily,
    double cornerScale = 1,
  }) {
    final trimmed = name.trim();
    final family = fontFamily?.trim();
    Color? solid(Color? color) => color == null ? null : _opaque(color);
    return ThemePalette._(
      name: trimmed.isEmpty ? customName : trimmed,
      // The accent fills buttons and marks focus: drawn solid, always.
      accent: _opaque(accent),
      surface: solid(surface),
      sidebar: solid(sidebar),
      raised: solid(raised),
      text: solid(text),
      secondaryText: solid(secondaryText),
      hairline: hairline == null ? null : _exact(hairline),
      selection: selection == null ? null : _exact(selection),
      online: solid(online),
      offline: solid(offline),
      connecting: solid(connecting),
      unknown: solid(unknown),
      fontFamily: family == null || family.isEmpty ? null : family,
      cornerScale: _clampCornerScale(cornerScale),
    );
  }

  const ThemePalette._({
    required this.name,
    required this.accent,
    required this.surface,
    required this.sidebar,
    required this.raised,
    required this.text,
    required this.secondaryText,
    required this.hairline,
    required this.selection,
    required this.online,
    required this.offline,
    required this.connecting,
    required this.unknown,
    required this.fontFamily,
    required this.cornerScale,
  });

  /// What a palette that is no preset is called, in the stored form. The
  /// Appearance section never shows it: it names presets in the reader's
  /// language and says "your own colours" for the rest.
  static const String customName = 'Custom';

  static const double minCornerScale = 0;
  static const double maxCornerScale = 2;

  /// The preset this came from, or [customName]. Stored in English, as
  /// Séance stores it, so a theme pasted between the apps keeps its name.
  final String name;

  /// The one colour that is never Automatic: buttons, links, focus, the
  /// active pane's marker. The rest of the Material colour scheme is seeded
  /// from it.
  final Color accent;

  final Color? surface;
  final Color? sidebar;
  final Color? raised;
  final Color? text;
  final Color? secondaryText;
  final Color? hairline;
  final Color? selection;
  final Color? online;
  final Color? offline;
  final Color? connecting;
  final Color? unknown;

  /// The interface's font family, resolved by name by the platform; null
  /// for the platform's own. Listings of code and paths keep their
  /// monospace stack whatever this says.
  final String? fontFamily;

  /// Multiplies every corner radius: 0 is square, 1 as designed, 2 very
  /// round.
  final double cornerScale;

  /// [value] inside the range. NaN is the case that needs care: it has no
  /// order, so a plain clamp hands it back, and one NaN would reach every
  /// corner radius and `jsonEncode`, which refuses it and with it the whole
  /// settings file. It reads as the designed corner. An infinity compares
  /// fine and clamps to the end it is at.
  static double _clampCornerScale(double value) {
    if (value.isNaN) return 1;
    return value.clamp(minCornerScale, maxCornerScale).toDouble();
  }

  /// The colour in [slot], or null when it is Automatic.
  Color? slot(ThemeSlot slot) => switch (slot) {
    ThemeSlot.surface => surface,
    ThemeSlot.sidebar => sidebar,
    ThemeSlot.raised => raised,
    ThemeSlot.text => text,
    ThemeSlot.secondaryText => secondaryText,
    ThemeSlot.hairline => hairline,
    ThemeSlot.selection => selection,
    ThemeSlot.online => online,
    ThemeSlot.offline => offline,
    ThemeSlot.connecting => connecting,
    ThemeSlot.unknown => unknown,
  };

  /// This palette with [slot] set to [value], or handed back to Automatic
  /// when [value] is null: the one thing [copyWith] cannot say.
  ThemePalette withSlot(ThemeSlot slot, Color? value) {
    Color? pick(ThemeSlot candidate) =>
        candidate == slot ? value : this.slot(candidate);
    return ThemePalette(
      name: name,
      accent: accent,
      surface: pick(ThemeSlot.surface),
      sidebar: pick(ThemeSlot.sidebar),
      raised: pick(ThemeSlot.raised),
      text: pick(ThemeSlot.text),
      secondaryText: pick(ThemeSlot.secondaryText),
      hairline: pick(ThemeSlot.hairline),
      selection: pick(ThemeSlot.selection),
      online: pick(ThemeSlot.online),
      offline: pick(ThemeSlot.offline),
      connecting: pick(ThemeSlot.connecting),
      unknown: pick(ThemeSlot.unknown),
      fontFamily: fontFamily,
      cornerScale: cornerScale,
    );
  }

  /// This palette with its interface font replaced, or handed back to the
  /// platform's when [family] is null or blank.
  ThemePalette withFontFamily(String? family) => _copy(fontFamily: family);

  /// The non-nullable fields; see [withSlot] and [withFontFamily] for the
  /// rest.
  ThemePalette copyWith({String? name, Color? accent, double? cornerScale}) =>
      _copy(
        name: name,
        accent: accent,
        cornerScale: cornerScale,
        fontFamily: fontFamily,
      );

  ThemePalette _copy({
    String? name,
    Color? accent,
    double? cornerScale,
    required String? fontFamily,
  }) => ThemePalette(
    name: name ?? this.name,
    accent: accent ?? this.accent,
    surface: surface,
    sidebar: sidebar,
    raised: raised,
    text: text,
    secondaryText: secondaryText,
    hairline: hairline,
    selection: selection,
    online: online,
    offline: offline,
    connecting: connecting,
    unknown: unknown,
    fontFamily: fontFamily,
    cornerScale: cornerScale ?? this.cornerScale,
  );

  /// The preset whose values these are, if any.
  ///
  /// Compared on the values rather than the name, so a palette edited back
  /// to exactly what a preset says is that preset again, and one that only
  /// borrowed a preset's name is not.
  ThemePalette? get matchingPreset {
    for (final preset in ThemePresets.all) {
      if (preset._sameValuesAs(this)) return preset;
    }
    return null;
  }

  /// This palette named for what its values are: the matching preset's
  /// name, or [customName]. What every edit is followed by: the name is
  /// what the Appearance section says out loud, so it stops claiming to be
  /// Terminal the moment it stops looking like it.
  ThemePalette relabelled() =>
      copyWith(name: matchingPreset?.name ?? customName);

  bool _sameValuesAs(ThemePalette other) =>
      other.accent == accent &&
      ThemeSlot.values.every((slot) => other.slot(slot) == this.slot(slot)) &&
      other.fontFamily == fontFamily &&
      other.cornerScale == cornerScale;

  /// Automatic colours and the platform font are left out rather than
  /// written as null: a missing key reads back as exactly that.
  Map<String, Object> toJson() => {
    'name': name,
    'accent': formatThemeColor(accent),
    for (final slot in ThemeSlot.values)
      if (this.slot(slot) case final color?) slot.name: formatThemeColor(color),
    'fontFamily': ?fontFamily,
    'cornerScale': cornerScale,
  };

  /// A palette from [json], leniently: a missing or unreadable accent or
  /// corner scale takes the Poltergeist preset's, and a missing or
  /// unreadable Automatic-able colour is Automatic. The gaps fill from
  /// Poltergeist rather than from the default ([ThemePresets.initial])
  /// because Poltergeist is the preset whose colours are all Automatic, so
  /// a partial theme completes as one look. A blank or missing name is
  /// whatever the values match ([relabelled]), so a hand-written theme that
  /// says nothing but a preset's colours is that preset. Keys this model
  /// does not have (Séance's `terminal`) are read past.
  factory ThemePalette.fromJson(Map<String, Object?> json) {
    final fallback = ThemePresets.poltergeist;
    final name = json['name'];
    final named = name is String && name.trim().isNotEmpty;
    final family = json['fontFamily'];
    final corners = json['cornerScale'];
    Color? color(ThemeSlot slot) => parseThemeColor(json[slot.name]);
    final palette = ThemePalette(
      name: named ? name : customName,
      accent: parseThemeColor(json['accent']) ?? fallback.accent,
      surface: color(ThemeSlot.surface),
      sidebar: color(ThemeSlot.sidebar),
      raised: color(ThemeSlot.raised),
      text: color(ThemeSlot.text),
      secondaryText: color(ThemeSlot.secondaryText),
      hairline: color(ThemeSlot.hairline),
      selection: color(ThemeSlot.selection),
      online: color(ThemeSlot.online),
      offline: color(ThemeSlot.offline),
      connecting: color(ThemeSlot.connecting),
      unknown: color(ThemeSlot.unknown),
      fontFamily: family is String ? family : null,
      cornerScale: corners is num ? corners.toDouble() : fallback.cornerScale,
    );
    return named ? palette : palette.relabelled();
  }

  /// The palette a settings file holds under its key: the default preset
  /// when it holds nothing usable, which includes a map that names none
  /// of a palette's values. Never throws: a theme is not worth a failed
  /// launch.
  static ThemePalette decodeStored(Object? json) {
    if (json is! Map || !json.keys.any(_valueKeys.contains)) {
      return ThemePresets.initial;
    }
    try {
      return ThemePalette.fromJson(json.cast<String, Object?>());
    } catch (_) {
      // A map with non-string keys: nothing in it was written by this app.
      return ThemePresets.initial;
    }
  }

  /// A palette from text someone pasted, or null when the text is not a
  /// theme at all: not JSON, not an object, or an object that names none
  /// of a palette's keys. Past that it is as lenient as [fromJson], so a
  /// theme from a newer build, from Séance, or one trimmed by hand still
  /// pastes.
  static ThemePalette? tryParse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || !decoded.keys.any(_valueKeys.contains)) {
      return null;
    }
    return decodeStored(decoded);
  }

  /// Every key but `name`: a name alone says nothing about how anything
  /// looks, and `{"name": "x"}` is more likely a stray clipboard than a
  /// theme. Séance's `terminal` is not one either: nothing in it applies
  /// here, so an object holding only that would change nothing.
  static final Set<String> _valueKeys = {
    'accent',
    for (final slot in ThemeSlot.values) slot.name,
    'fontFamily',
    'cornerScale',
  };

  @override
  bool operator ==(Object other) =>
      other is ThemePalette && other.name == name && other._sameValuesAs(this);

  @override
  int get hashCode => Object.hash(
    name,
    accent,
    Object.hashAll(ThemeSlot.values.map(slot)),
    fontFamily,
    cornerScale,
  );
}
