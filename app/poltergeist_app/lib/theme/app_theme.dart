import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'family_hues.dart';

const _seedColor = Color(0xFF3D8A78);

/// The colour the scheme seeds from, public for the two places that draw it
/// directly rather than through the scheme: the server editor's custom
/// colour picker starts from it when no accent is in force.
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
    required this.headerHeight,
    required this.rowExtent,
    required this.sidebarRowExtent,
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

  /// Header toolbar height (logical px).
  final double headerHeight;

  /// Listing row extent before text scaling (D32: 22 px desktop).
  final double rowExtent;

  /// Sidebar row extent before text scaling.
  final double sidebarRowExtent;

  /// The chrome for [theme], falling back to the dark or light defaults
  /// when a host theme (a test harness, a dialog subtree) carries none.
  static PoltergeistChrome of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<PoltergeistChrome>() ??
        _chromeFor(theme.brightness, theme.platform);
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
    double? headerHeight,
    double? rowExtent,
    double? sidebarRowExtent,
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
      headerHeight: headerHeight ?? this.headerHeight,
      rowExtent: rowExtent ?? this.rowExtent,
      sidebarRowExtent: sidebarRowExtent ?? this.sidebarRowExtent,
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
      // Linear like the colours: a stepped extent would snap mid-way
      // through MaterialApp's theme animation while everything fades.
      headerHeight: lerpDouble(headerHeight, other.headerHeight, t)!,
      rowExtent: lerpDouble(rowExtent, other.rowExtent, t)!,
      sidebarRowExtent:
          lerpDouble(sidebarRowExtent, other.sidebarRowExtent, t)!,
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

PoltergeistChrome _chromeFor(Brightness brightness, TargetPlatform platform) {
  final n = brightness == Brightness.dark ? _dark : _light;
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
    statusConnected: n.connected,
    statusConnecting: n.connecting,
    // macOS: the unified toolbar band is 52 pt (D32 §3).
    headerHeight: platform == TargetPlatform.macOS ? 52 : (desktop ? 44 : 56),
    rowExtent: desktop ? 22 : 48,
    sidebarRowExtent: desktop ? 26 : 40,
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

ThemeData buildPoltergeistTheme(
  Brightness brightness, {
  TargetPlatform? platform,
}) {
  final resolvedPlatform = platform ?? defaultTargetPlatform;
  final n = brightness == Brightness.dark ? _dark : _light;
  final scheme =
      ColorScheme.fromSeed(seedColor: _seedColor, brightness: brightness)
          .copyWith(
            surface: n.surface,
            surfaceContainerLowest: n.containerLowest,
            surfaceContainerLow: n.containerLow,
            surfaceContainer: n.container,
            surfaceContainerHigh: n.containerHigh,
            surfaceContainerHighest: n.containerHighest,
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
  final chrome = _chromeFor(brightness, resolvedPlatform);
  final base = ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    useMaterial3: true,
    platform: platform,
  );
  final desktop = isDesktopPlatform(resolvedPlatform);

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
      textStyle: TextStyle(fontSize: desktop ? 12 : 14, color: scheme.onInverseSurface),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(6),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      titleTextStyle: desktop
          ? _desktopText(
              base.textTheme,
            ).titleLarge?.copyWith(color: scheme.onSurface)
          : null,
    ),
    extensions: [chrome, FamilyPalette.forBrightness(brightness)],
  );
}
