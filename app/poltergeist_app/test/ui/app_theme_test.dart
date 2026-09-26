import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/theme/app_theme.dart';

/// Theme-level decisions that every surface inherits.
void main() {
  group('dialog titles', () {
    Future<TextStyle> titleStyle(
      WidgetTester tester,
      TargetPlatform platform,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPoltergeistTheme(Brightness.light, platform: platform),
          home: const AlertDialog(
            title: Text('Unknown host key'),
            content: Text('body'),
          ),
        ),
      );
      final title = find.text('Unknown host key');
      return DefaultTextStyle.of(tester.element(title)).style;
    }

    testWidgets('desktop titles sit on the 13 px ramp at 17 px semibold', (
      tester,
    ) async {
      for (final platform in [
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      ]) {
        final style = await titleStyle(tester, platform);
        expect(style.fontSize, 17, reason: platform.name);
        expect(style.fontWeight, FontWeight.w600, reason: platform.name);
      }
    });

    testWidgets('touch keeps Material\'s title size', (tester) async {
      final style = await titleStyle(tester, TargetPlatform.android);
      expect(style.fontSize, 24);
    });
  });

  group('PoltergeistChrome', () {
    final dark = buildPoltergeistTheme(
      Brightness.dark,
      platform: TargetPlatform.linux,
    ).extension<PoltergeistChrome>()!;
    final light = buildPoltergeistTheme(
      Brightness.light,
      platform: TargetPlatform.linux,
    ).extension<PoltergeistChrome>()!;

    test('lerp interpolates every field instead of snapping mid-way', () {
      final mid = dark.lerp(light, 0.5);
      Color half(Color a, Color b) => Color.lerp(a, b, 0.5)!;
      expect(
        mid.sidebarBackground,
        half(dark.sidebarBackground, light.sidebarBackground),
      );
      expect(mid.selectionFill, half(dark.selectionFill, light.selectionFill));
      expect(
        mid.statusConnected,
        half(dark.statusConnected, light.statusConnected),
      );
      expect(mid.statusFailed, half(dark.statusFailed, light.statusFailed));
      expect(mid.statusUnknown, half(dark.statusUnknown, light.statusUnknown));
      expect(mid.sidebarBackground, isNot(dark.sidebarBackground));
      expect(mid.sidebarBackground, isNot(light.sidebarBackground));

      // Extents are linear too (touch ↔ desktop chrome differ in them).
      final touch = dark.copyWith(
        headerHeight: 56,
        rowExtent: 48,
        sidebarRowExtent: 48,
      );
      final between = dark.lerp(touch, 0.25);
      expect(between.headerHeight, closeTo(44 + 12 * 0.25, 1e-9));
      expect(between.rowExtent, closeTo(22 + 26 * 0.25, 1e-9));
      expect(between.sidebarRowExtent, closeTo(26 + 22 * 0.25, 1e-9));

      // Corners too: Material's own shapes lerp through the same theme
      // animation, and the hand-drawn corners that follow the same scale
      // blend with them.
      final square = dark.copyWith(cornerScale: 0);
      final round = dark.copyWith(cornerScale: 2);
      expect(square.lerp(round, 0.25).cornerScale, 0.5);
      expect(round.corner(6), 12);

      expect(dark.lerp(light, 0), _sameChrome(dark));
      expect(dark.lerp(light, 1), _sameChrome(light));
      expect(dark.lerp(null, 0.5), same(dark));
    });

    test('copyWith changes only the fields it is given', () {
      final copy = dark.copyWith(
        separator: const Color(0xFF123456),
        rowExtent: 30,
        cornerScale: 0.5,
      );
      expect(copy.separator, const Color(0xFF123456));
      expect(copy.rowExtent, 30);
      expect(copy.cornerScale, 0.5);
      expect(
        copy.copyWith(
          separator: dark.separator,
          rowExtent: dark.rowExtent,
          cornerScale: dark.cornerScale,
        ),
        _sameChrome(dark),
      );
    });
  });
}

/// Field-by-field equality: the extension has no value `==`.
Matcher _sameChrome(PoltergeistChrome expected) => predicate<PoltergeistChrome>(
  (actual) =>
      actual.sidebarBackground == expected.sidebarBackground &&
      actual.headerBackground == expected.headerBackground &&
      actual.paneBackground == expected.paneBackground &&
      actual.inspectorBackground == expected.inspectorBackground &&
      actual.separator == expected.separator &&
      actual.hoverFill == expected.hoverFill &&
      actual.capsuleFill == expected.capsuleFill &&
      actual.selectionFill == expected.selectionFill &&
      actual.onSelection == expected.onSelection &&
      actual.inactiveSelectionFill == expected.inactiveSelectionFill &&
      actual.activePaneIndicator == expected.activePaneIndicator &&
      actual.secondaryText == expected.secondaryText &&
      actual.statusConnected == expected.statusConnected &&
      actual.statusConnecting == expected.statusConnecting &&
      actual.statusFailed == expected.statusFailed &&
      actual.statusUnknown == expected.statusUnknown &&
      actual.headerHeight == expected.headerHeight &&
      actual.rowExtent == expected.rowExtent &&
      actual.sidebarRowExtent == expected.sidebarRowExtent &&
      actual.cornerScale == expected.cornerScale,
  'the same chrome, field by field',
);
