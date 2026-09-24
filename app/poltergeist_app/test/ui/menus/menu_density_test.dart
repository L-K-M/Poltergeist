import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/menus/menu_shortcut_hint.dart';

/// D32's menu density (10 §2: density without clutter): on desktop the
/// context menus and the ☰ tree draw compact rows — 26 px, 13 px text,
/// a tight inset, the shortcut hint in the secondary colour — from the
/// theme, so every MenuAnchor in the app gets them. Touch platforms keep
/// Material's 48 dp rows.
void main() {
  Future<void> pumpMenu(WidgetTester tester, TargetPlatform platform) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPoltergeistTheme(Brightness.light, platform: platform),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MenuAnchor(
            menuChildren: [
              MenuItemButton(
                key: const ValueKey('plain'),
                onPressed: () {},
                trailingIcon: const MenuShortcutHint(
                  SingleActivator(LogicalKeyboardKey.keyN, control: true),
                ),
                child: const Text('New Folder'),
              ),
              CheckboxMenuButton(
                key: const ValueKey('check'),
                value: true,
                onChanged: (_) {},
                child: const Text('Show Hidden Files'),
              ),
              SubmenuButton(
                key: const ValueKey('sub'),
                menuChildren: [
                  MenuItemButton(onPressed: () {}, child: const Text('Name')),
                ],
                child: const Text('Sort By'),
              ),
            ],
            builder: (context, controller, _) => TextButton(
              key: const ValueKey('anchor'),
              onPressed: controller.open,
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('anchor')));
    await tester.pumpAndSettle();
  }

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    testWidgets('${platform.name} menus draw compact rows', (tester) async {
      await pumpMenu(tester, platform);
      for (final key in ['plain', 'check', 'sub']) {
        final height = tester.getSize(find.byKey(ValueKey(key)).first).height;
        expect(height, inInclusiveRange(24, 28), reason: key);
      }
      final label = tester.widget<Text>(find.text('New Folder'));
      final style = DefaultTextStyle.of(
        tester.element(find.text('New Folder')),
      ).style.merge(label.style);
      expect(style.fontSize, 13);

      // The hint trails in the secondary colour; the label leads.
      final chrome = PoltergeistChrome.of(
        tester.element(find.byType(MenuShortcutHint)),
      );
      final hint = tester.widget<Text>(
        find.descendant(
          of: find.byType(MenuShortcutHint),
          matching: find.byType(Text),
        ),
      );
      expect(hint.data, platform == TargetPlatform.macOS ? '⌃N' : 'Ctrl+N');
      expect(hint.style?.color, chrome.secondaryText);
    });
  }

  testWidgets('touch keeps Material\'s 48 dp rows', (tester) async {
    await pumpMenu(tester, TargetPlatform.android);
    for (final key in ['plain', 'check', 'sub']) {
      expect(
        tester.getSize(find.byKey(ValueKey(key)).first).height,
        greaterThanOrEqualTo(40),
        reason: key,
      );
    }
  });
}
