import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 02 §4's non-text contrast floor — the one every status indicator's
/// colors are pinned to (the SEA-019 fix).
const minimumNonTextContrast = 3.0;

/// WCAG relative luminance, shared by every contrast pin so one formula
/// cannot drift from another.
double relativeLuminance(Color color) {
  // The math assumes an opaque color: a translucent one must be composited
  // against its real background (e.g. Color.alphaBlend) before measuring,
  // or the pin reports a ratio the user never sees.
  assert(
    color.a == 1.0,
    'Contrast math assumes opaque colors; composite translucent colors '
    'against their background before measuring.',
  );
  double channel(double value) => value <= 0.03928
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();

  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double contrast(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}
