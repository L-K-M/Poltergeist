// Poltergeist's theme as it was built before device themes existed:
// lib/theme/app_theme.dart at c4d4512, frozen here, tables and all, so the
// comparison in theme_build_test.dart cannot drift with the code it checks.
// An install that has never opened Appearance must see exactly this.
// Only the chrome extension is left out: [legacyChrome] lists its values,
// since the extension has no value equality to compare by.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:poltergeist_app/theme/app_theme.dart' show isDesktopPlatform;

const _seedColor = Color(0xFF3D8A78);

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

Map<String, Object> legacyChrome(
  Brightness brightness,
  TargetPlatform platform,
) {
  final n = brightness == Brightness.dark ? _dark : _light;
  final desktop = isDesktopPlatform(platform);
  return {
    'sidebarBackground': n.containerLow,
    'headerBackground': n.container,
    'paneBackground': n.surface,
    'inspectorBackground': n.containerLow,
    'separator': n.outlineVariant,
    'hoverFill': n.onSurface.withValues(alpha: 0.06),
    'capsuleFill': n.containerHigh,
    'selectionFill': n.selection,
    'onSelection': n.onSelection,
    'inactiveSelectionFill': n.containerHighest,
    'activePaneIndicator': n.primary,
    'secondaryText': n.onSurfaceVariant,
    'statusConnected': n.connected,
    'statusConnecting': n.connecting,
    // macOS: the unified toolbar band is 52 pt (D32 §3).
    'headerHeight': platform == TargetPlatform.macOS ? 52 : (desktop ? 44 : 56),
    'rowExtent': desktop ? 22 : 48,
    'sidebarRowExtent': desktop ? 26 : 48,
  };
}

/// A desktop menu row's height (context menus and the ☰ tree).
const double _desktopMenuRowExtent = 26;

/// Desktop type ramp (13 px body, 11 px captions — the macOS system
/// sizes); touch platforms keep Material's defaults.
TextTheme _desktopText(TextTheme base) => base.copyWith(
  titleLarge: base.titleLarge?.copyWith(
    fontSize: 17,
    fontWeight: FontWeight.w600,
  ),
  titleMedium: base.titleMedium?.copyWith(
    fontSize: 14,
    fontWeight: FontWeight.w600,
  ),
  titleSmall: base.titleSmall?.copyWith(
    fontSize: 13,
    fontWeight: FontWeight.w600,
  ),
  bodyLarge: base.bodyLarge?.copyWith(fontSize: 14),
  bodyMedium: base.bodyMedium?.copyWith(fontSize: 13),
  bodySmall: base.bodySmall?.copyWith(fontSize: 12),
  labelLarge: base.labelLarge?.copyWith(fontSize: 13),
  labelMedium: base.labelMedium?.copyWith(fontSize: 12),
  labelSmall: base.labelSmall?.copyWith(fontSize: 11, letterSpacing: 0.2),
);

ThemeData legacyTheme(Brightness brightness, {TargetPlatform? platform}) {
  final resolvedPlatform = platform ?? defaultTargetPlatform;
  final n = brightness == Brightness.dark ? _dark : _light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: _seedColor,
        brightness: brightness,
      ).copyWith(
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
    hoverColor: n.onSurface.withValues(alpha: 0.06),
    textTheme: desktop ? _desktopText(base.textTheme) : base.textTheme,
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      space: 1,
      thickness: 1,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      textStyle: TextStyle(
        fontSize: desktop ? 12 : 14,
        color: scheme.onInverseSurface,
      ),
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
  );
}
