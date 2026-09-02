import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/window_geometry.dart';

void main() {
  const primaryWorkArea = Rect.fromLTWH(0, 0, 1920, 1040);

  group('clampWindowBounds', () {
    test('keeps visible bounds unchanged', () {
      const bounds = Rect.fromLTWH(80, 60, 1180, 760);

      expect(
        clampWindowBounds(
          bounds: bounds,
          workAreas: const [primaryWorkArea],
          fallbackWorkArea: primaryWorkArea,
        ),
        bounds,
      );
    });

    test('moves an orphaned window onto the primary work area', () {
      final result = clampWindowBounds(
        bounds: const Rect.fromLTWH(3000, 2000, 1180, 760),
        workAreas: const [primaryWorkArea],
        fallbackWorkArea: primaryWorkArea,
      );

      expect(result, const Rect.fromLTWH(370, 140, 1180, 760));
    });

    test('uses the fallback when no work areas are reported', () {
      final result = clampWindowBounds(
        bounds: const Rect.fromLTWH(3000, 2000, 1180, 760),
        workAreas: const [],
        fallbackWorkArea: primaryWorkArea,
      );

      expect(result, const Rect.fromLTWH(370, 140, 1180, 760));
    });

    test('shrinks oversized bounds to the chosen work area', () {
      final result = clampWindowBounds(
        bounds: const Rect.fromLTWH(-50, -40, 2200, 1200),
        workAreas: const [primaryWorkArea],
        fallbackWorkArea: primaryWorkArea,
      );

      expect(result, primaryWorkArea);
    });
  });
}
