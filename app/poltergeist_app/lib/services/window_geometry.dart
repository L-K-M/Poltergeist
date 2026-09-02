import 'dart:ui';

Rect clampWindowBounds({
  required Rect bounds,
  required List<Rect> workAreas,
  required Rect fallbackWorkArea,
}) {
  final target = _bestWorkArea(bounds, workAreas) ?? fallbackWorkArea;
  final width = bounds.width.clamp(0, target.width).toDouble();
  final height = bounds.height.clamp(0, target.height).toDouble();
  final size = Size(width, height);

  if (!_overlaps(bounds, target)) {
    final left = target.left + (target.width - size.width) / 2;
    final top = target.top + (target.height - size.height) / 2;
    return Rect.fromLTWH(left, top, size.width, size.height);
  }

  final left = bounds.left.clamp(target.left, target.right - width).toDouble();
  final top = bounds.top.clamp(target.top, target.bottom - height).toDouble();
  return Rect.fromLTWH(left, top, width, height);
}

Rect? _bestWorkArea(Rect bounds, List<Rect> workAreas) {
  Rect? best;
  var bestOverlap = 0.0;
  for (final workArea in workAreas) {
    final overlap = bounds.intersect(workArea);
    final area =
        (overlap.width.clamp(0, double.infinity) *
                overlap.height.clamp(0, double.infinity))
            .toDouble();
    if (area <= bestOverlap) continue;

    best = workArea;
    bestOverlap = area;
  }

  return best;
}

bool _overlaps(Rect first, Rect second) {
  final overlap = first.intersect(second);
  return overlap.width > 0 && overlap.height > 0;
}
