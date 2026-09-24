import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';

/// D32's ☰ main menu (10 §8) sits at the header's trailing edge, so
/// every menu it opens has to fit on the anchor's side: the top-level
/// panel against the window's end, each submenu flipped over to the
/// start, nested ones (View ▸ Sort By) included — at the 720 px content
/// minimum as well as an ordinary window.
void main() {
  for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
    for (final width in [720.0, 1180.0]) {
      testWidgets('every ☰ submenu stays inside a ${width.round()} px '
          '${platform.name} window', (tester) async {
        tester.view.physicalSize = Size(width, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildPoltergeistTheme(Brightness.light, platform: platform),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const WorkspaceShell(),
          ),
        );
        await tester.pumpAndSettle();
        final window = Offset.zero & Size(width, 760);

        void expectInside(String what) {
          final rows = [
            ...find.byType(MenuItemButton).evaluate(),
            ...find.byType(SubmenuButton).evaluate(),
          ];
          expect(rows, isNotEmpty, reason: what);
          for (final row in rows) {
            final rect = tester.getRect(find.byWidget(row.widget));
            expect(
              rect.left >= window.left && rect.right <= window.right,
              isTrue,
              reason: '$what: a row at $rect leaves $window',
            );
          }
        }

        await tester.tap(find.byKey(const ValueKey('menu.main')));
        await tester.pumpAndSettle();
        expectInside('the ☰ menu');
        var nestedChecked = 0;

        for (final menu in AppMenuId.values) {
          final submenu = find.byKey(ValueKey('menu.${menu.name}'));
          if (submenu.evaluate().isEmpty) continue;
          await tester.tap(submenu);
          await tester.pumpAndSettle();
          expectInside(menu.name);

          // Nested submenus (View ▸ Sort By, File ▸ Open With) open from
          // a row that already sits left of the ☰ panel.
          final nested = find.descendant(
            of: find.byType(Overlay),
            matching: find.byWidgetPredicate(
              (widget) => widget is SubmenuButton && widget.key == null,
            ),
          );
          for (final element in nested.evaluate().toList()) {
            await tester.tap(find.byWidget(element.widget));
            await tester.pumpAndSettle();
            expectInside('${menu.name} ▸ nested');
            nestedChecked++;
          }
        }
        // View ▸ Sort By at least — the deepest flip the tree has.
        expect(nestedChecked, greaterThan(0));
      });
    }
  }
}
