import 'package:flutter/material.dart';

/// A count badge on a small desktop glyph's top-end corner: the header's
/// alert count and the inspector tabs' counts.
///
/// Material 3's label badge overlaps its icon by design, sized for the
/// 24 px icons of a navigation bar. On the header's and the inspector's
/// 17–18 px glyphs that overlap hid most of the glyph, so this badge is
/// smaller and sits mostly past the corner, over the glyph by a few
/// pixels only. The compact posture's 20 dp tab icons keep Material's.
class CornerCountBadge extends StatelessWidget {
  const CornerCountBadge({
    super.key,
    required this.label,
    required this.backgroundColor,
    required this.textColor,
    required this.child,
  });

  /// The painted count ("3", "99+").
  final String label;
  final Color backgroundColor;
  final Color textColor;
  final Widget child;

  static const double _size = 14;

  /// Past the top-end corner: Badge places the label's start `_size`
  /// before the child's end edge, so this leaves a 4 px overlap.
  static const double _outward = _size - 4;
  static const double _up = -6;

  @override
  Widget build(BuildContext context) {
    final ltr = Directionality.of(context) == TextDirection.ltr;
    return Badge(
      label: Text(label),
      largeSize: _size,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      offset: Offset(ltr ? _outward : -_outward, _up),
      backgroundColor: backgroundColor,
      textColor: textColor,
      child: child,
    );
  }
}
