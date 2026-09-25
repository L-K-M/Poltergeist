import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/drag_out_controller.dart';
import '../../services/os_drag_out.dart';

/// The pill's height, padding, glyph, and label bounds: the in-app
/// avatar's proportions (`PaneEntryDragAvatar`), so the drag looks the
/// same on both sides of the window edge.
const double _pillHeight = 30;
const double _padding = 10;
const double _glyphSize = 18;
const double _gap = 6;
const double _maxLabelWidth = 240;
const double _fontSize = 13;
const double _radius = 6;

/// The count badge's diameter and how far it hangs past the pill's
/// top-right corner (the avatar's `top: -6, end: -6`).
const double _badgeSize = 18;
const double _badgeOverhang = 6;

/// Renders the native session's drag image (00 D14's drag-out
/// amendment): a glyph, the item's name or "N items", and a count badge
/// for several items, painted straight onto a `dart:ui` canvas so no
/// mounted widget is needed at the window edge. The PNG is rendered at
/// the spec's device pixel ratio; the anchor is the pill's top-left
/// corner, where the in-app avatar's pointer anchor holds it too.
///
/// macOS may still prefer its own per-item file icons; Linux and
/// Windows show this image.
Future<DragOutImage?> renderDragOutImage(DragOutImageSpec spec) async {
  final palette = spec.palette;
  final label = TextPainter(
    text: TextSpan(
      text: spec.label,
      style: TextStyle(fontSize: _fontSize, color: palette.foreground),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: _maxLabelWidth);
  final glyph = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(
        (spec.isDirectory
                ? Icons.folder_outlined
                : Icons.insert_drive_file_outlined)
            .codePoint,
      ),
      style: TextStyle(
        fontSize: _glyphSize,
        fontFamily: Icons.folder_outlined.fontFamily,
        package: Icons.folder_outlined.fontPackage,
        color: palette.foreground,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  final several = spec.count > 1;
  final pillWidth = _padding + _glyphSize + _gap + label.width + _padding;
  final top = several ? _badgeOverhang : 0.0;
  final size = Size(
    pillWidth + (several ? _badgeOverhang : 0),
    _pillHeight + top,
  );

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(spec.devicePixelRatio);
  final pill = RRect.fromRectAndRadius(
    Rect.fromLTWH(0, top, pillWidth, _pillHeight),
    const Radius.circular(_radius),
  );
  canvas
    ..drawRRect(pill, Paint()..color = palette.background)
    ..drawRRect(
      pill,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = palette.foreground.withValues(alpha: 0.18),
    );
  glyph.paint(canvas, Offset(_padding, top + (_pillHeight - glyph.height) / 2));
  label.paint(
    canvas,
    Offset(
      _padding + _glyphSize + _gap,
      top + (_pillHeight - label.height) / 2,
    ),
  );
  if (several) {
    final count = TextPainter(
      text: TextSpan(
        text: spec.count.toString(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: palette.onBadge,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = math.max(_badgeSize, count.width + 8);
    final badge = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width - width, 0, width, _badgeSize),
      const Radius.circular(_badgeSize / 2),
    );
    canvas.drawRRect(badge, Paint()..color = palette.badge);
    count.paint(
      canvas,
      Offset(
        badge.left + (width - count.width) / 2,
        (_badgeSize - count.height) / 2,
      ),
    );
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (size.width * spec.devicePixelRatio).ceil(),
    (size.height * spec.devicePixelRatio).ceil(),
  );
  picture.dispose();
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return null;
    return DragOutImage(
      png: bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      size: size,
      anchor: Offset(0, top),
    );
  } finally {
    image.dispose();
  }
}
