import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/registered_command.dart';

/// Opens the top-level [menu] of D32's Windows/Linux main menu (10 §8):
/// the header's ☰ button (`menu.main`) first, then the `menu.<id>`
/// submenu, so its `menu.item.<id>` rows are on screen. The test
/// platform is not macOS, so this is the tree the shell renders — the
/// Flutter menu-bar strip no longer exists.
///
/// Pumps fixed frames rather than settling, so it works both in the
/// fake zone and inside `runAsync`. A main menu that is already open is
/// reused (tapping ☰ again would close it).
Future<void> openShellMenu(WidgetTester tester, AppMenuId menu) async {
  final submenu = find.byKey(ValueKey('menu.${menu.name}'));
  if (submenu.evaluate().isEmpty) {
    final main = find.byKey(const ValueKey('menu.main'));
    expect(main, findsOneWidget, reason: 'the header ☰ is not mounted');
    await tester.tap(main);
    await _menuFrames(tester);
  }
  expect(submenu, findsOneWidget, reason: 'menu.${menu.name} is missing');
  await tester.tap(submenu);
  await _menuFrames(tester);
}

/// Closes the main menu and any open submenu (Esc walks one level per
/// press, so press until the top-level rows are gone).
Future<void> closeShellMenus(WidgetTester tester) async {
  for (var i = 0; i < 3 && _mainMenuOpen(); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _menuFrames(tester);
  }
  expect(_mainMenuOpen(), isFalse, reason: 'the main menu did not close');
}

/// Whether any top-level `menu.<id>` row of the ☰ menu is on screen.
bool _mainMenuOpen() => AppMenuId.values.any(
  (id) => find.byKey(ValueKey('menu.${id.name}')).evaluate().isNotEmpty,
);

Future<void> _menuFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}
