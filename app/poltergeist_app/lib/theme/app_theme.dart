import 'package:flutter/material.dart';

const _seedColor = Color(0xFF3D8A78);

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

ThemeData buildPoltergeistTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: brightness,
  );

  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: scheme.surface,
    dividerColor: scheme.outlineVariant,
    focusColor: scheme.primary.withValues(alpha: 0.18),
  );
}
