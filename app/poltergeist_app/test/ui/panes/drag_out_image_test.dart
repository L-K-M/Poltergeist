import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/drag_out_controller.dart';
import 'package:poltergeist_app/ui/panes/drag_out_image.dart';

const _palette = DragOutImagePalette(
  background: Color(0xFFEEEEEE),
  foreground: Color(0xFF111111),
  badge: Color(0xFF3355FF),
  onBadge: Color(0xFFFFFFFF),
);

/// The PNG's IHDR width and height.
(int, int) _pngSize(Uint8List png) {
  final data = ByteData.sublistView(png);
  return (data.getUint32(16), data.getUint32(20));
}

void main() {
  testWidgets('renders a PNG at the device pixel ratio, anchored at the '
      'pill corner', (tester) async {
    final image = await tester.runAsync(
      () => renderDragOutImage(
        const DragOutImageSpec(
          label: 'report.txt',
          count: 1,
          isDirectory: false,
          palette: _palette,
          devicePixelRatio: 2,
        ),
      ),
    );
    expect(image, isNotNull);
    expect(image!.png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    final (width, height) = _pngSize(image.png);
    expect(width, (image.size.width * 2).ceil());
    expect(height, (image.size.height * 2).ceil());
    expect(image.size.height, greaterThanOrEqualTo(28));
    // The pointer holds the pill's top-left corner, like the in-app
    // avatar's pointer anchor.
    expect(image.anchor.dx, 0);
    expect(image.anchor.dy, lessThan(image.size.height / 2));
    final decoded = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(image.png);
      return (await codec.getNextFrame()).image;
    });
    expect(decoded!.width, width);
    decoded.dispose();
  });

  testWidgets('several items get a wider image with room for the count '
      'badge', (tester) async {
    Future<Size> sizeFor(int count) async => (await tester.runAsync(
      () => renderDragOutImage(
        DragOutImageSpec(
          label: count == 1 ? 'a' : '$count items',
          count: count,
          isDirectory: true,
          palette: _palette,
          devicePixelRatio: 1,
        ),
      ),
    ))!.size;
    final single = await sizeFor(1);
    final several = await sizeFor(12);
    expect(several.width, greaterThan(single.width));
    expect(several.height, greaterThan(single.height));
  });
}
