import 'package:flutter/material.dart';

const _seedColor = Color(0xFF3D8A78);

const poltergeistMonoTextStyle = TextStyle(
  fontFamily: 'JetBrains Mono',
  fontFamilyFallback: [
    'SF Mono',
    'Menlo',
    'Consolas',
    'DejaVu Sans Mono',
    'monospace',
  ],
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
