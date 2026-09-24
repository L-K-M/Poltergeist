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
}
