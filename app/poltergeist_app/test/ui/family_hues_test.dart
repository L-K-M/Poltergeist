import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/theme/family_hues.dart';
import 'package:poltergeist_app/ui/inspector/inspector_view.dart';

import 'contrast_math.dart';

/// D34's colour vocabulary against 02 §13's non-text floor: every hue's
/// bare glyph on every chrome surface a glyph sits on, at rest, hovered
/// and on the neutral selection (the accent selection repaints glyphs
/// on-accent, pinned in the contrast matrix), and every tile's glyph on
/// both ends of its lit fill.
void main() {
  for (final brightness in Brightness.values) {
    group('${brightness.name} theme', () {
      final theme = buildPoltergeistTheme(brightness);
      final chrome = theme.extension<PoltergeistChrome>()!;
      final palette = theme.extension<FamilyPalette>();

      test('carries the family palette for its brightness', () {
        expect(palette, same(FamilyPalette.forBrightness(brightness)));
      });

      test('every glyph hue stays ≥ 3:1 on every chrome surface', () {
        final surfaces = <(String, Color)>[
          ('listing', chrome.paneBackground),
          ('sidebar', chrome.sidebarBackground),
          ('header', chrome.headerBackground),
          ('inspector', chrome.inspectorBackground),
          ('toolbar capsule', chrome.capsuleFill),
          ('menu', theme.colorScheme.surfaceContainer),
        ];
        final states = <(String, Color)>[
          for (final (name, surface) in surfaces) ...[
            (name, surface),
            ('$name hovered', Color.alphaBlend(chrome.hoverFill, surface)),
            (
              '$name neutral selection',
              Color.alphaBlend(chrome.inactiveSelectionFill, surface),
            ),
          ],
        ];
        for (final hue in FamilyHue.values) {
          for (final (state, surface) in states) {
            expect(
              contrast(palette!.glyph(hue), surface),
              greaterThanOrEqualTo(minimumNonTextContrast),
              reason: '${hue.name} glyph on $state (${brightness.name})',
            );
          }
        }
      });

      test('a hue\'s glyph stays ≥ 3:1 on a wash of its own colour', () {
        // The selected inspector tab lights up in its hue, and the phone's
        // kind badges and Home discs sit their glyph on a disc of it.
        final washes = <(String, double, Color)>[
          (
            'inspector tab',
            inspectorTabWashAlpha,
            chrome.inspectorBackground,
          ),
          (
            'kind badge and Home disc',
            FamilyPalette.discWashAlpha,
            chrome.paneBackground,
          ),
        ];
        for (final hue in FamilyHue.values) {
          final glyph = palette!.glyph(hue);
          for (final (name, alpha, surface) in washes) {
            final wash = Color.alphaBlend(
              glyph.withValues(alpha: alpha),
              surface,
            );
            expect(
              contrast(glyph, wash),
              greaterThanOrEqualTo(minimumNonTextContrast),
              reason: '${hue.name} on its $name wash (${brightness.name})',
            );
          }
        }
      });

      test('graphite is the neutrals\' secondary text', () {
        expect(palette!.glyph(FamilyHue.graphite), chrome.secondaryText);
      });
    });
  }

  test('every tile glyph stays ≥ 3:1 on both ends of its fill', () {
    for (final hue in FamilyHue.values) {
      for (final (end, fill) in [('sheen', hue.tileSheen), ('fill', hue.tileFill)]) {
        expect(
          contrast(hue.onTile, fill),
          greaterThanOrEqualTo(minimumNonTextContrast),
          reason: '${hue.name} tile glyph on its $end',
        );
      }
    }
  });

  testWidgets('a tile paints its glyph in the on-tile colour', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: FamilyHueTile(
            hue: FamilyHue.blue,
            glyph: Icons.home,
            extent: 32,
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(FamilyHueTile)), const Size(32, 32));
    final icon = tester.widget<Icon>(find.byIcon(Icons.home));
    expect(icon.color, FamilyHue.blue.onTile);
    expect(icon.size, 20);
  });
}
