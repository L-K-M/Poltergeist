import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 02 §4's non-text contrast floor — the one every status indicator's
/// colors are pinned to (the SEA-019 fix).
const minimumNonTextContrast = 3.0;

/// WCAG relative luminance, shared by every contrast pin so one formula
/// cannot drift from another.
double relativeLuminance(Color color) {
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
