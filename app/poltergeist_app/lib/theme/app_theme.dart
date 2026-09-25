import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'family_hues.dart';
import 'app_appearance.dart';
import 'contrast.dart';
import 'theme_palette.dart';
import 'theme_presets.dart';

const _seedColor = Color(0xFF3D8A78);

/// The colour the scheme seeds from, public for the places that draw it
/// directly rather than through the scheme: the server editor's custom
/// colour picker starts from it when no accent is in force, and it is the
/// default theme preset's accent.
const poltergeistSeedColor = _seedColor;

/// The app's monospace family stack — primary first, then the
/// cross-platform fallbacks (a bare 'monospace' does not resolve on
/// every platform, notably macOS/iOS). Also the built-in editor's
/// `monoFontFallback` seam value (06 §2.3).
const poltergeistMonoFontFamilies = [
  'JetBrains Mono',
  'SF Mono',
  'Menlo',
  'Consolas',
  'DejaVu Sans Mono',
  'monospace',
];

const poltergeistMonoTextStyle = TextStyle(
  fontFamily: 'JetBrains Mono',
  fontFamilyFallback: poltergeistMonoFontFamilies,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// The D32 neutral palettes (10 §10's shared design tokens): a slate
/// dark theme in ForkLift's register and a Finder-like light theme. The
/// seed only supplies the accent family; every neutral the chrome
/// paints is pinned here so the two sibling apps (Séance uses the same
/// neutrals with its own accent) look like one product family. The
/// contrast matrix test gates every pair the widgets actually paint.
/// These are what a theme palette's Automatic colours resolve to while its
/// surface is Automatic too (see [buildPoltergeistThemeFor]).
class _Neutrals {
  const _Neutrals({
    required this.surface,
    required this.containerLowest,
    required this.containerLow,
    required this.container,
    required this.containerHigh,
    required this.containerHighest,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.error,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.selection,
    required this.onSelection,
    required this.connected,
    required this.connecting,
  });

  final Color surface;
  final Color containerLowest;
  final Color containerLow;
  final Color container;
  final Color containerHigh;
  final Color containerHighest;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;
  final Color inverseSurface;
  final Color onInverseSurface;
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  final Color error;
  final Color errorContainer;
  final Color onErrorContainer;
  final Color selection;
  final Color onSelection;

  /// The connected/reachable status green: ≥ 3:1 on every surface a
  /// status dot sits on — the rail, its hover fill, the selection pill,
  /// the listing, header, and inspector (pinned by the contrast matrix).
  final Color connected;

  /// The connecting/reconnecting status amber, held to the same floors.
  final Color connecting;
}

const _dark = _Neutrals(
  surface: Color(0xFF232932),
  containerLowest: Color(0xFF1C2128),
  containerLow: Color(0xFF2A313B),
  container: Color(0xFF2D3440),
  containerHigh: Color(0xFF353D49),
  containerHighest: Color(0xFF3B4452),
  onSurface: Color(0xFFE7EAEF),
  onSurfaceVariant: Color(0xFFB4BCC8),
  // ≥ 3:1 on every slate chrome surface (sidebar, header, inspector):
  // outline paints the idle/unknown server dot, a non-text indicator.
  outline: Color(0xFF77818F),
  outlineVariant: Color(0xFF3A424E),
  inverseSurface: Color(0xFFE7EAEF),
  onInverseSurface: Color(0xFF232932),
  primary: Color(0xFF5CC3AA),
  onPrimary: Color(0xFF00241D),
  primaryContainer: Color(0xFF1E5B4E),
  onPrimaryContainer: Color(0xFFC4F3E5),
  secondaryContainer: Color(0xFF3B4758),
  onSecondaryContainer: Color(0xFFDCE4EF),
  error: Color(0xFFFF9E94),
  errorContainer: Color(0xFF5C1F1B),
  onErrorContainer: Color(0xFFFFDAD5),
  selection: Color(0xFF2F7F6D),
  onSelection: Color(0xFFFFFFFF),
  connected: Color(0xFF4CAF50),
  connecting: Color(0xFFD99A1E),
);

const _light = _Neutrals(
  surface: Color(0xFFFFFFFF),
  containerLowest: Color(0xFFFFFFFF),
  containerLow: Color(0xFFF1F2F4),
  container: Color(0xFFF6F6F8),
  containerHigh: Color(0xFFEBECEF),
  containerHighest: Color(0xFFE2E5EA),
  onSurface: Color(0xFF1C1F24),
  onSurfaceVariant: Color(0xFF596170),
  outline: Color(0xFF7D8591),
  outlineVariant: Color(0xFFDADDE3),
  inverseSurface: Color(0xFF2D323A),
  onInverseSurface: Color(0xFFF1F2F4),
  primary: Color(0xFF1B7563),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFC9EDE3),
  onPrimaryContainer: Color(0xFF00382D),
  secondaryContainer: Color(0xFFDCE3EC),
  onSecondaryContainer: Color(0xFF18222E),
  error: Color(0xFFB3261E),
  errorContainer: Color(0xFFF9DEDC),
  onErrorContainer: Color(0xFF410E0B),
  selection: Color(0xFF1F7A67),
  onSelection: Color(0xFFFFFFFF),
  connected: Color(0xFF2E7D32),
  connecting: Color(0xFFA86400),
);

const Color _white = Color(0xFFFFFFFF);
const Color _black = Color(0xFF000000);

/// How far each Automatic shade is mixed from a palette's own surface
/// toward its text (or, for secondary text, from the text toward the
/// surface). Séance's ratios, measured against the shared dark table:
/// mixed from its own surface and text, these land within 6 units per
/// channel of its container ladder and lines, and within 18 of its
/// secondary text and outline, which the table tints bluer than a straight
/// mix can. So a palette that brings a surface of its own gets a ladder
/// shaped like the one it replaces, the same in both apps.
const double _sidebarMix = 0.04;
const double _raisedMix = 0.06;
const double _highMix = 0.05;
const double _highestMix = 0.08;
const double _secondaryTextMix = 0.3;
const double _outlineMix = 0.45;
const double _hairlineMix = 0.14;
const double _secondaryContainerMix = 0.22;
const double _lowestMix = 0.2;

/// The WCAG AA ratio for body text, which a derived selection keeps under
/// white text.
const double _textContrast = 4.5;

Color _mix(Color from, Color to, double t) => Color.lerp(from, to, t)!;

/// The brightness [palette] is drawn at when Automatic colours follow
/// [brightness]: see [resolveBrightness].
Brightness _drawnAt(ThemePalette palette, Brightness brightness) {
  final surface = palette.surface;
  return surface == null ? brightness : surfaceBrightness(surface);
}

/// The neutrals [palette] draws with at [brightness] (already resolved by
/// [_drawnAt]): the table for that brightness, with every slot the palette
/// sets laid over it.
///
/// An Automatic slot is the table's while the surface is the table's too.
/// Once the palette brings a surface of its own, the Automatic slots are
/// mixed from that surface and the palette's text instead: the table's
/// slate sidebar beside a Solarized pane would be neither theme. The
/// default palette sets nothing, so it gets the tables unchanged. The error
/// colours are the table's in every case: they are text colours with a
/// contrast floor of their own, not a status the palette names.
_Neutrals _neutralsFor(ThemePalette palette, Brightness brightness) {
  final table = brightness == Brightness.dark ? _dark : _light;
  final ownSurface = palette.surface != null;
  final surface = palette.surface ?? table.surface;
  final text = palette.text ?? table.onSurface;
  Color auto(Color fromTable, Color mixed) => ownSurface ? mixed : fromTable;

  // The rest of the container ladder hangs off the raised colour, so a
  // palette that sets only that still gets high and highest ordered above
  // it rather than the table's, which may sit below it.
  final container =
      palette.raised ?? auto(table.container, _mix(surface, text, _raisedMix));
  final ownContainer = ownSurface || palette.raised != null;

  // The table's primary family is the hand-tuned rendering of the teal
  // seed (a lighter teal on dark, a deeper one on light, each clearing its
  // surface), so the seed keeps it. Any other accent is drawn as picked,
  // which is what the colour well promises; its primary containers come
  // from Material's scheme for it.
  final tuned = palette.accent == _seedColor;
  final seeded = tuned
      ? null
      : ColorScheme.fromSeed(seedColor: palette.accent, brightness: brightness);
  final primary = tuned ? table.primary : palette.accent;

  final ownSelection = palette.selection != null || !tuned;
  final selection =
      palette.selection ??
      (tuned ? table.selection : _selectionFor(palette.accent));

  return _Neutrals(
    surface: surface,
    containerLowest: auto(
      table.containerLowest,
      _mix(
        surface,
        brightness == Brightness.dark ? _black : _white,
        _lowestMix,
      ),
    ),
    containerLow:
        palette.sidebar ??
        auto(table.containerLow, _mix(surface, text, _sidebarMix)),
    container: container,
    containerHigh: ownContainer
        ? _mix(container, text, _highMix)
        : table.containerHigh,
    containerHighest: ownContainer
        ? _mix(container, text, _highestMix)
        : table.containerHighest,
    onSurface: text,
    onSurfaceVariant:
        palette.secondaryText ??
        auto(table.onSurfaceVariant, _mix(text, surface, _secondaryTextMix)),
    outline: auto(table.outline, _mix(surface, text, _outlineMix)),
    outlineVariant:
        palette.hairline ??
        auto(table.outlineVariant, _mix(surface, text, _hairlineMix)),
    inverseSurface: auto(table.inverseSurface, text),
    onInverseSurface: auto(table.onInverseSurface, surface),
    primary: primary,
    onPrimary: seeded == null ? table.onPrimary : legibleOn(primary),
    primaryContainer: seeded?.primaryContainer ?? table.primaryContainer,
    onPrimaryContainer: seeded?.onPrimaryContainer ?? table.onPrimaryContainer,
    secondaryContainer: auto(
      table.secondaryContainer,
      _mix(surface, primary, _secondaryContainerMix),
    ),
    onSecondaryContainer: auto(table.onSecondaryContainer, text),
    error: table.error,
    errorContainer: table.errorContainer,
    onErrorContainer: table.onErrorContainer,
    selection: selection,
    // The active pane's selected rows paint over the listing, so the label
    // is chosen against the fill as it shows there, since a palette may
    // make the fill a tint: white for the tables' teal, black for a
    // palette that picks a light one (High contrast's yellow).
    onSelection: ownSelection
        ? legibleOn(compositeOver(selection, surface))
        : table.onSelection,
    connected: table.connected,
    connecting: table.connecting,
  );
}

/// An Automatic selection for an accent other than the seed: the accent's
/// own hue, darkened until white text on it clears 4.5:1, the convention
/// the tables' teal selection keeps. The accent itself when it already
/// does.
Color _selectionFor(Color accent) {
  const steps = 20;
  for (var step = 0; step < steps; step++) {
    final candidate = _mix(accent, _black, step / steps);
    if (contrastRatio(_white, candidate) >= _textContrast) return candidate;
  }
  return _black;
}

/// The four status colours a palette names, as [n] resolves them.
typedef _StatusColors = ({
  Color online,
  Color offline,
  Color connecting,
  Color unknown,
});

/// The status colours for [palette] over its resolved neutrals [n]. The
/// Automatic ones are what the app always painted: the tables' connected
/// green and connecting amber, the error red for failures, and the outline
/// grey for an unknown or idle server.
_StatusColors _statusFor(ThemePalette palette, _Neutrals n) => (
  online: palette.online ?? n.connected,
  offline: palette.offline ?? n.error,
  connecting: palette.connecting ?? n.connecting,
  unknown: palette.unknown ?? n.outline,
);

/// The D32 chrome tokens every shell surface reads instead of picking
/// scheme roles ad hoc — one place decides what the sidebar, header,
/// inspector, and listing paint, so the regions read as one window and
/// the Séance port (10 §10) copies one table.
@immutable
class PoltergeistChrome extends ThemeExtension<PoltergeistChrome> {
  const PoltergeistChrome({
    required this.sidebarBackground,
    required this.headerBackground,
    required this.paneBackground,
    required this.inspectorBackground,
    required this.separator,
    required this.hoverFill,
    required this.capsuleFill,
    required this.selectionFill,
    required this.onSelection,
    required this.inactiveSelectionFill,
    required this.activePaneIndicator,
    required this.secondaryText,
    required this.statusConnected,
    required this.statusConnecting,
    required this.statusFailed,
    required this.statusUnknown,
    required this.headerHeight,
    required this.rowExtent,
    required this.sidebarRowExtent,
    this.cornerScale = 1,
  });

  /// The full-height sidebar column (Finder's source-list tint).
  final Color sidebarBackground;

  /// The header toolbar band above panes and inspector.
  final Color headerBackground;

  /// Listing surfaces.
  final Color paneBackground;

  /// The right inspector column.
  final Color inspectorBackground;

  /// 1 px region separators and splitter lines.
  final Color separator;

  /// Pointer hover on rows and toolbar buttons.
  final Color hoverFill;

  /// The rounded group behind related toolbar buttons (ForkLift's
  /// capsules) and the inspector's tab switcher.
  final Color capsuleFill;

  /// Selected rows in the ACTIVE pane — accent fill, on-accent text.
  final Color selectionFill;
  final Color onSelection;

  /// Selected rows in the inactive pane and the sidebar's selected pill.
  final Color inactiveSelectionFill;

  /// The 2 px line under the active pane's tab bar (ForkLift's marker).
  final Color activePaneIndicator;

  /// Captions: item counts, trailing sidebar metadata, subtitles.
  final Color secondaryText;

  /// The one "connected" status colour (server dots in the rail, tab
  /// chips, probe dots): a per-theme green that keeps the 3:1 non-text
  /// floor on the sidebar's selection pill as well as its resting and
  /// hover rows, which a single green shared by both themes could not.
  final Color statusConnected;

  /// The rail's "connecting" dot (10 §5): an amber per theme, held to
  /// the same 3:1 floors as [statusConnected].
  final Color statusConnecting;

  /// A failed connection's dot, the blocked host key's no-entry dot, and
  /// the unreachable ring. The scheme's error red unless the theme palette
  /// names an `offline` colour: a status colour of its own rather than the
  /// scheme's error, so a palette's red dot cannot restyle the error text
  /// and banners, which carry a text contrast floor.
  final Color statusFailed;

  /// An unknown or idle server's dot: the scheme's outline grey unless the
  /// theme palette names an `unknown` colour.
  final Color statusUnknown;

  /// Header toolbar height (logical px).
  final double headerHeight;

  /// Listing row extent before text scaling (D32: 22 px desktop).
  final double rowExtent;

  /// Sidebar row extent before text scaling.
  final double sidebarRowExtent;

  /// The theme's corner multiplier ([ThemePalette.cornerScale]), for what
  /// the app draws by hand: Material's components take it through their
  /// own themes, and a hand-drawn pill opts in with [corner].
  final double cornerScale;

  /// A [base] corner radius as the theme scales it.
  double corner(double base) => base * cornerScale;

  /// The chrome for [theme], falling back to the dark or light defaults
  /// when a host theme (a test harness, a dialog subtree) carries none.
  static PoltergeistChrome of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<PoltergeistChrome>() ??
        _chromeFor(ThemePresets.initial, theme.brightness, theme.platform);
  }

  @override
  PoltergeistChrome copyWith({
    Color? sidebarBackground,
    Color? headerBackground,
    Color? paneBackground,
    Color? inspectorBackground,
    Color? separator,
    Color? hoverFill,
    Color? capsuleFill,
    Color? selectionFill,
    Color? onSelection,
    Color? inactiveSelectionFill,
    Color? activePaneIndicator,
    Color? secondaryText,
    Color? statusConnected,
    Color? statusConnecting,
    Color? statusFailed,
    Color? statusUnknown,
    double? headerHeight,
    double? rowExtent,
    double? sidebarRowExtent,
    double? cornerScale,
  }) {
    return PoltergeistChrome(
      sidebarBackground: sidebarBackground ?? this.sidebarBackground,
      headerBackground: headerBackground ?? this.headerBackground,
      paneBackground: paneBackground ?? this.paneBackground,
      inspectorBackground: inspectorBackground ?? this.inspectorBackground,
      separator: separator ?? this.separator,
      hoverFill: hoverFill ?? this.hoverFill,
      capsuleFill: capsuleFill ?? this.capsuleFill,
      selectionFill: selectionFill ?? this.selectionFill,
      onSelection: onSelection ?? this.onSelection,
      inactiveSelectionFill:
          inactiveSelectionFill ?? this.inactiveSelectionFill,
      activePaneIndicator: activePaneIndicator ?? this.activePaneIndicator,
      secondaryText: secondaryText ?? this.secondaryText,
      statusConnected: statusConnected ?? this.statusConnected,
      statusConnecting: statusConnecting ?? this.statusConnecting,
      statusFailed: statusFailed ?? this.statusFailed,
      statusUnknown: statusUnknown ?? this.statusUnknown,
      headerHeight: headerHeight ?? this.headerHeight,
      rowExtent: rowExtent ?? this.rowExtent,
      sidebarRowExtent: sidebarRowExtent ?? this.sidebarRowExtent,
      cornerScale: cornerScale ?? this.cornerScale,
    );
  }

  @override
  PoltergeistChrome lerp(PoltergeistChrome? other, double t) {
    if (other == null) return this;
    return PoltergeistChrome(
      sidebarBackground:
          Color.lerp(sidebarBackground, other.sidebarBackground, t)!,
      headerBackground: Color.lerp(headerBackground, other.headerBackground, t)!,
      paneBackground: Color.lerp(paneBackground, other.paneBackground, t)!,
      inspectorBackground:
          Color.lerp(inspectorBackground, other.inspectorBackground, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      hoverFill: Color.lerp(hoverFill, other.hoverFill, t)!,
      capsuleFill: Color.lerp(capsuleFill, other.capsuleFill, t)!,
      selectionFill: Color.lerp(selectionFill, other.selectionFill, t)!,
      onSelection: Color.lerp(onSelection, other.onSelection, t)!,
      inactiveSelectionFill:
          Color.lerp(inactiveSelectionFill, other.inactiveSelectionFill, t)!,
      activePaneIndicator:
          Color.lerp(activePaneIndicator, other.activePaneIndicator, t)!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
      statusConnected:
          Color.lerp(statusConnected, other.statusConnected, t)!,
      statusConnecting:
          Color.lerp(statusConnecting, other.statusConnecting, t)!,
      statusFailed: Color.lerp(statusFailed, other.statusFailed, t)!,
      statusUnknown: Color.lerp(statusUnknown, other.statusUnknown, t)!,
      // Linear like the colours: a stepped extent would snap mid-way
      // through MaterialApp's theme animation while everything fades.
      headerHeight: lerpDouble(headerHeight, other.headerHeight, t)!,
      rowExtent: lerpDouble(rowExtent, other.rowExtent, t)!,
      sidebarRowExtent:
          lerpDouble(sidebarRowExtent, other.sidebarRowExtent, t)!,
      // Corners blend like Material's own shapes, which are lerped through
      // the same animation.
      cornerScale: lerpDouble(cornerScale, other.cornerScale, t)!,
    );
  }
}

/// Whether [platform] gets the desktop density tokens (13 px text, 22 px
/// rows) — touch platforms keep Material's touch-sized defaults (D32 §9).
bool isDesktopPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS ||
  TargetPlatform.linux ||
  TargetPlatform.windows => true,
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => false,
};

/// The chrome [palette] paints on [platform] when its Automatic colours
/// follow [brightness].
PoltergeistChrome _chromeFor(
  ThemePalette palette,
  Brightness brightness,
  TargetPlatform platform,
) {
  final n = _neutralsFor(palette, _drawnAt(palette, brightness));
  return _chromeOver(
    n,
    _statusFor(palette, n),
    platform,
    cornerScale: palette.cornerScale,
  );
}

/// The chrome the resolved neutrals [n] and [status] paint, on [platform].
/// [cornerScale] rides along for the hand-drawn corners (see
/// [PoltergeistChrome.corner]).
PoltergeistChrome _chromeOver(
  _Neutrals n,
  _StatusColors status,
  TargetPlatform platform, {
  required double cornerScale,
}) {
  final desktop = isDesktopPlatform(platform);
  return PoltergeistChrome(
    sidebarBackground: n.containerLow,
    headerBackground: n.container,
    paneBackground: n.surface,
    inspectorBackground: n.containerLow,
    separator: n.outlineVariant,
    hoverFill: n.onSurface.withValues(alpha: 0.06),
    capsuleFill: n.containerHigh,
    selectionFill: n.selection,
    onSelection: n.onSelection,
    inactiveSelectionFill: n.containerHighest,
    activePaneIndicator: n.primary,
    secondaryText: n.onSurfaceVariant,
    statusConnected: status.online,
    statusConnecting: status.connecting,
    statusFailed: status.offline,
    statusUnknown: status.unknown,
    // macOS: the unified toolbar band is 52 pt (D32 §3).
    headerHeight: platform == TargetPlatform.macOS ? 52 : (desktop ? 44 : 56),
    rowExtent: desktop ? 22 : 48,
    sidebarRowExtent: desktop ? 26 : 40,
    cornerScale: cornerScale,
  );
}

/// A desktop menu row's height (context menus and the ☰ tree).
const double _desktopMenuRowExtent = 26;

/// Desktop type ramp (13 px body, 11 px captions — the macOS system
/// sizes); touch platforms keep Material's defaults.
TextTheme _desktopText(TextTheme base) => base.copyWith(
  titleLarge: base.titleLarge?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
  titleMedium: base.titleMedium?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
  titleSmall: base.titleSmall?.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
  bodyLarge: base.bodyLarge?.copyWith(fontSize: 14),
  bodyMedium: base.bodyMedium?.copyWith(fontSize: 13),
  bodySmall: base.bodySmall?.copyWith(fontSize: 12),
  labelLarge: base.labelLarge?.copyWith(fontSize: 13),
  labelMedium: base.labelMedium?.copyWith(fontSize: 12),
  labelSmall: base.labelSmall?.copyWith(fontSize: 11, letterSpacing: 0.2),
);

/// Material's own corner radii, which [ThemePalette.cornerScale] scales:
/// the dialog, menu and tooltip radii this theme already set before themes
/// existed, and the M3 defaults for the rest. A button's is half its
/// standard 40 px height, where Material draws a stadium. The same values
/// as Séance's, apart from the dialog's, which Poltergeist sets to 12, and
/// the floating button's, which Séance has no use for.
const double _dialogRadius = 12;
const double _cardRadius = 12;
const double _menuRadius = 8;
const double _popupMenuRadius = 4;
const double _tooltipRadius = 6;
const double _inputRadius = 4;
const double _buttonRadius = 20;
const double _chipRadius = 8;
const double _bottomSheetRadius = 28;
const double _snackBarRadius = 4;
const double _fabRadius = 16;

/// Poltergeist's theme in the default palette: the teal accent over the
/// sibling tables, unchanged. [platform] overrides the host platform the
/// type ramp and row extents are chosen for.
ThemeData buildPoltergeistTheme(
  Brightness brightness, {
  TargetPlatform? platform,
}) => buildPoltergeistThemeFor(
  ThemePresets.initial,
  brightness,
  platform: platform,
);

/// The three theme arguments of a MaterialApp drawn in [appearance].
///
/// A palette with its own surface is one theme, at that surface's
/// brightness, whatever the system or the mode says; otherwise a light and
/// a dark one, picked between by the mode.
({ThemeData theme, ThemeData darkTheme, ThemeMode themeMode})
poltergeistThemesFor(AppAppearance appearance, {TargetPlatform? platform}) {
  final palette = appearance.palette;
  if (palette.surface != null) {
    final theme = buildPoltergeistThemeFor(
      palette,
      Brightness.light,
      platform: platform,
    );
    return (theme: theme, darkTheme: theme, themeMode: ThemeMode.light);
  }
  return (
    theme: buildPoltergeistThemeFor(
      palette,
      Brightness.light,
      platform: platform,
    ),
    darkTheme: buildPoltergeistThemeFor(
      palette,
      Brightness.dark,
      platform: platform,
    ),
    themeMode: switch (appearance.mode) {
      ThemeModePreference.system => ThemeMode.system,
      ThemeModePreference.light => ThemeMode.light,
      ThemeModePreference.dark => ThemeMode.dark,
    },
  );
}

/// What every slot of [palette] draws as when its Automatic colours follow
/// [brightness]: the colour an Automatic slot stands for right now, which is
/// where the Appearance section starts a slot that stops being Automatic,
/// and what a preset's swatch shows.
Map<ThemeSlot, Color> resolvedThemeSlots(
  ThemePalette palette,
  Brightness brightness,
) {
  final n = _neutralsFor(palette, _drawnAt(palette, brightness));
  final status = _statusFor(palette, n);
  return {
    ThemeSlot.surface: n.surface,
    ThemeSlot.sidebar: n.containerLow,
    ThemeSlot.raised: n.container,
    ThemeSlot.text: n.onSurface,
    ThemeSlot.secondaryText: n.onSurfaceVariant,
    ThemeSlot.hairline: n.outlineVariant,
    ThemeSlot.selection: n.selection,
    ThemeSlot.online: status.online,
    ThemeSlot.offline: status.offline,
    ThemeSlot.connecting: status.connecting,
    ThemeSlot.unknown: status.unknown,
  };
}

/// [palette] as a theme. [brightness] is what its Automatic colours follow
/// (the system's, or the mode's); a palette that sets its own surface is
/// drawn at that surface's brightness instead (see [resolveBrightness]).
ThemeData buildPoltergeistThemeFor(
  ThemePalette palette,
  Brightness brightness, {
  TargetPlatform? platform,
}) {
  final resolvedPlatform = platform ?? defaultTargetPlatform;
  final drawnAt = _drawnAt(palette, brightness);
  final n = _neutralsFor(palette, drawnAt);
  final ownSurface = palette.surface != null;
  final scheme =
      ColorScheme.fromSeed(seedColor: palette.accent, brightness: drawnAt)
          .copyWith(
            surface: n.surface,
            surfaceContainerLowest: n.containerLowest,
            surfaceContainerLow: n.containerLow,
            surfaceContainer: n.container,
            surfaceContainerHigh: n.containerHigh,
            surfaceContainerHighest: n.containerHighest,
            // The seed's own dim and bright stay with the tables, as they
            // always have; a surface of its own takes its ladder's ends.
            surfaceDim: ownSurface
                ? (drawnAt == Brightness.dark ? n.surface : n.containerHighest)
                : null,
            surfaceBright: ownSurface
                ? (drawnAt == Brightness.dark ? n.containerHighest : n.surface)
                : null,
            onSurface: n.onSurface,
            onSurfaceVariant: n.onSurfaceVariant,
            outline: n.outline,
            outlineVariant: n.outlineVariant,
            inverseSurface: n.inverseSurface,
            onInverseSurface: n.onInverseSurface,
            primary: n.primary,
            onPrimary: n.onPrimary,
            primaryContainer: n.primaryContainer,
            onPrimaryContainer: n.onPrimaryContainer,
            secondaryContainer: n.secondaryContainer,
            onSecondaryContainer: n.onSecondaryContainer,
            error: n.error,
            errorContainer: n.errorContainer,
            onErrorContainer: n.onErrorContainer,
          );
  final scale = palette.cornerScale;
  final chrome = _chromeOver(
    n,
    _statusFor(palette, n),
    resolvedPlatform,
    cornerScale: scale,
  );
  final base = ThemeData(
    brightness: drawnAt,
    colorScheme: scheme,
    useMaterial3: true,
    platform: platform,
    // Null leaves the platform's own face, as before themes existed.
    fontFamily: palette.fontFamily,
  );
  final desktop = isDesktopPlatform(resolvedPlatform);
  RoundedRectangleBorder rounded(double radius) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(radius * scale),
  );
  // At the designed scale every component keeps the shape it had before
  // corners could change (Material's own, stadium buttons included), so
  // the default theme is exactly what it was. Any other scale replaces each
  // with a rounded rectangle of its scaled radius.
  final scaled = scale != 1;
  final buttonShape = rounded(_buttonRadius);

  return base.copyWith(
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: scheme.surface,
    dividerColor: scheme.outlineVariant,
    focusColor: scheme.primary.withValues(alpha: 0.18),
    hoverColor: chrome.hoverFill,
    textTheme: desktop ? _desktopText(base.textTheme) : base.textTheme,
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      space: 1,
      thickness: 1,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      textStyle: TextStyle(
        // A tooltip's style replaces the text theme's rather than merging
        // with it, so the interface font is named here too.
        fontFamily: palette.fontFamily,
        fontSize: desktop ? 12 : 14,
        color: scheme.onInverseSurface,
      ),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(_tooltipRadius * scale),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        shape: WidgetStatePropertyAll(rounded(_menuRadius)),
        // Desktop panels hug their compact rows (Finder's 4 px inset).
        padding: desktop
            ? const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4))
            : null,
      ),
    ),
    // D32's desktop menu rows (context menus, the ☰ tree, every
    // MenuAnchor): 26 px, 13 px text, a tight inset. Touch keeps
    // Material's 48 dp rows. The density is pinned to standard so the
    // theme-wide compact density does not shave the row below 26 px.
    menuButtonTheme: desktop
        ? MenuButtonThemeData(
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(
                Size(64, _desktopMenuRowExtent),
              ),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 10),
              ),
              visualDensity: VisualDensity.standard,
              iconSize: const WidgetStatePropertyAll(16),
              textStyle: WidgetStatePropertyAll(
                _desktopText(base.textTheme).bodyMedium,
              ),
            ),
          )
        : null,
    // Desktop dialog titles sit on the 13 px ramp at 17 px semibold
    // (Material's 24 px headlineSmall reads oversized beside it); touch
    // keeps Material's title.
    dialogTheme: DialogThemeData(
      shape: rounded(_dialogRadius),
      titleTextStyle: desktop
          ? _desktopText(
              base.textTheme,
            ).titleLarge?.copyWith(color: scheme.onSurface)
          : null,
    ),
    cardTheme: scaled ? CardThemeData(shape: rounded(_cardRadius)) : null,
    popupMenuTheme: scaled
        ? PopupMenuThemeData(shape: rounded(_popupMenuRadius))
        : null,
    // The underline Material draws by default, with its filled corners
    // scaled: an outline here would restyle every field in the app.
    inputDecorationTheme: scaled
        ? InputDecorationThemeData(
            border: UnderlineInputBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(_inputRadius * scale),
              ),
            ),
          )
        : null,
    filledButtonTheme: scaled
        ? FilledButtonThemeData(
            style: FilledButton.styleFrom(shape: buttonShape),
          )
        : null,
    // The phone sidebar's add button, the one floating button the app has.
    floatingActionButtonTheme: scaled
        ? FloatingActionButtonThemeData(shape: rounded(_fabRadius))
        : null,
    outlinedButtonTheme: scaled
        ? OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(shape: buttonShape),
          )
        : null,
    textButtonTheme: scaled
        ? TextButtonThemeData(style: TextButton.styleFrom(shape: buttonShape))
        : null,
    segmentedButtonTheme: scaled
        ? SegmentedButtonThemeData(
            style: ButtonStyle(shape: WidgetStatePropertyAll(buttonShape)),
          )
        : null,
    chipTheme: scaled ? ChipThemeData(shape: rounded(_chipRadius)) : null,
    bottomSheetTheme: scaled
        ? BottomSheetThemeData(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(_bottomSheetRadius * scale),
              ),
            ),
          )
        : null,
    snackBarTheme: scaled
        ? SnackBarThemeData(shape: rounded(_snackBarRadius))
        : null,
    extensions: [chrome, FamilyPalette.forBrightness(drawnAt)],
  );
}
