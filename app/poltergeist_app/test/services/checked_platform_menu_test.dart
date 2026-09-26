import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/checked_platform_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const checks = MethodChannel('poltergeist/menu_checks');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.menu, null);
    messenger.setMockMethodCallHandler(checks, null);
    // Each delegate installs its native callback handler on the menu channel.
    SystemChannels.menu.setMethodCallHandler(null);
  });

  test(
    'installs nested checkmarks after Flutter creates their menu IDs',
    () async {
      final installed = Completer<void>();
      final nativeChecks = Completer<Map<dynamic, dynamic>>();
      late Map<dynamic, dynamic> menu;
      messenger.setMockMethodCallHandler(SystemChannels.menu, (call) async {
        expect(call.method, 'Menu.setMenus');
        menu = call.arguments as Map<dynamic, dynamic>;
        await installed.future;
        return null;
      });
      messenger.setMockMethodCallHandler(checks, (call) async {
        expect(call.method, 'setChecked');
        nativeChecks.complete(call.arguments as Map<dynamic, dynamic>);
        return null;
      });

      CheckedPlatformMenuDelegate().setMenus([
        PlatformMenu(
          label: 'View',
          menus: [
            CheckedPlatformMenuItem(
              label: 'Show hidden files',
              checked: true,
              onSelected: () {},
              shortcut: const SingleActivator(
                LogicalKeyboardKey.period,
                meta: true,
                shift: true,
              ),
            ),
            PlatformMenu(
              label: 'Sort By',
              menus: [
                CheckedPlatformMenuItem(
                  label: 'Name',
                  checked: false,
                  onSelected: () {},
                ),
                PlatformMenuItem(label: 'Refresh', onSelected: () {}),
              ],
            ),
          ],
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(nativeChecks.isCompleted, isFalse);
      final view = (menu['0'] as List).single as Map;
      final children = view['children'] as List;
      final hidden = children.first as Map;
      final sort = (children.last as Map)['children'] as List;
      final name = sort.first as Map;
      expect(hidden['label'], 'Show hidden files');
      expect(hidden['enabled'], isTrue);
      expect(hidden['shortcutTrigger'], LogicalKeyboardKey.period.keyId);

      installed.complete();
      expect(await nativeChecks.future, {
        '${hidden['id']}': true,
        '${name['id']}': false,
      });
    },
  );

  test(
    'new menu pushes use new IDs, including across window switches',
    () async {
      final updates = <Map<dynamic, dynamic>>[];
      messenger.setMockMethodCallHandler(SystemChannels.menu, (_) async => null);
      messenger.setMockMethodCallHandler(checks, (call) async {
        updates.add(call.arguments as Map<dynamic, dynamic>);
        return null;
      });
      final delegate = CheckedPlatformMenuDelegate();
      for (final checked in [false, true]) {
        delegate.setMenus([
          PlatformMenu(
            label: 'View',
            menus: [
              CheckedPlatformMenuItem(
                label: 'Show hidden files',
                checked: checked,
              ),
            ],
          ),
        ]);
        await Future<void>.delayed(Duration.zero);
      }
      expect(updates[0].values, [false]);
      expect(updates[1].values, [true]);
      expect(updates[0].keys.single, isNot(updates[1].keys.single));
    },
  );
}
