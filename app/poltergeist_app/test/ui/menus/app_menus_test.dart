import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';
import 'package:poltergeist_app/services/uuid.dart';
import 'package:poltergeist_app/ui/menus/app_menu_host.dart';
import 'package:poltergeist_app/ui/menus/app_menus.dart';
import 'package:poltergeist_app/ui/menus/menu_shortcut_hint.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/fake_ssh_config_source.dart';

RegisteredCommand _command(
  String id, {
  CommandMenuPlacement? placement,
  List<ShortcutActivator> Function(TargetPlatform)? activators,
  bool Function()? enabled,
  void Function()? onRun,
}) {
  return RegisteredCommand(
    id: id,
    scope: CommandScope.app,
    label: (l10n) => id,
    activators: activators,
    enabled: enabled ?? () => true,
    menuPlacement: placement,
    run: (_) async => onRun?.call(),
  );
}

/// Records the menus PlatformMenuBar pushes so the macOS branch can be
/// exercised on a Linux test host (the default delegate's serialization
/// asserts the real platform for provided items).
class _RecordingMenuDelegate extends PlatformMenuDelegate {
  List<PlatformMenuItem> menus = const [];
  var pushes = 0;

  @override
  void clearMenus() => menus = const [];

  @override
  void setMenus(List<PlatformMenuItem> topLevelMenus) {
    pushes++;
    menus = topLevelMenus;
  }

  @override
  bool debugLockDelegate(BuildContext context) => true;

  @override
  bool debugUnlockDelegate(BuildContext context) => true;
}

void _useRecordingMenuDelegate() {
  final original = WidgetsBinding.instance.platformMenuDelegate;
  WidgetsBinding.instance.platformMenuDelegate = _RecordingMenuDelegate();
  addTearDown(() {
    WidgetsBinding.instance.platformMenuDelegate = original;
  });
}

List<String> _commandIds(AppMenuModel menu) => [
  for (final group in menu.groups)
    for (final row in group)
      if (row is AppMenuCommandRow) row.command.id,
];

List<PlatformMenuItem> _leavesOf(PlatformMenu menu) => [
  for (final member in menu.menus)
    ...(member is PlatformMenuItemGroup ? member.members : [member]),
];

PlatformMenu _menuNamed(PlatformMenuBar bar, String label) =>
    bar.menus.whereType<PlatformMenu>().singleWhere((m) => m.label == label);

void main() {
  final l10n = AppLocalizationsEn();

  group('buildAppMenus', () {
    test('renders the registry: placement, order, groups; omits unplaced '
        'commands and empty menus', () {
      final commands = [
        _command(
          'a.last',
          placement: const CommandMenuPlacement(
            menu: AppMenuId.file,
            order: 30,
          ),
        ),
        _command(
          'a.first',
          placement: const CommandMenuPlacement(
            menu: AppMenuId.file,
            order: 10,
          ),
        ),
        _command(
          'a.grouped',
          placement: const CommandMenuPlacement(
            menu: AppMenuId.file,
            order: 20,
            group: 1,
          ),
        ),
        _command('a.unplaced'),
        _command(
          'a.edit',
          placement: const CommandMenuPlacement(
            menu: AppMenuId.edit,
            order: 10,
          ),
        ),
      ];

      final menus = buildAppMenus(
        commands: commands,
        l10n: l10n,
        platform: TargetPlatform.linux,
      );

      // Empty menus (View/Go/Commands/Window/Help) never render.
      expect(menus.map((m) => m.id), [AppMenuId.file, AppMenuId.edit]);
      expect(menus.first.title, 'File');
      expect(menus.last.title, 'Edit');

      // Order sorts inside a group; a changed group value splits the
      // divider sections.
      final file = menus.first;
      expect(file.groups.length, 2);
      expect(file.groups[0].length, 2);
      expect(file.groups[1].length, 1);
      expect(_commandIds(file), ['a.first', 'a.last', 'a.grouped']);
      expect(_commandIds(menus.last), ['a.edit']);
    });

    test('nests commands under a shared submenu row', () {
      String submenuTitle(AppLocalizations l10n) => 'Sort By';
      final commands = [
        _command(
          'a.byName',
          placement: CommandMenuPlacement(
            menu: AppMenuId.view,
            order: 30,
            submenu: submenuTitle,
          ),
        ),
        _command(
          'a.bySize',
          placement: CommandMenuPlacement(
            menu: AppMenuId.view,
            order: 31,
            submenu: submenuTitle,
          ),
        ),
      ];

      final menus = buildAppMenus(
        commands: commands,
        l10n: l10n,
        platform: TargetPlatform.linux,
      );

      final row = menus.single.groups.single.single;
      final submenu = row as AppMenuSubmenuRow;
      expect(submenu.title, 'Sort By');
      expect(
        submenu.items.map((item) => item.command.id),
        ['a.byName', 'a.bySize'],
      );
    });

    test('adds the platform chrome only on macOS', () {
      final commands = [
        _command(
          'a.tab',
          placement: const CommandMenuPlacement(
            menu: AppMenuId.window,
            order: 10,
          ),
        ),
      ];

      final mac = buildAppMenus(
        commands: commands,
        l10n: l10n,
        platform: TargetPlatform.macOS,
      );
      // The application menu leads (02 §9's "Poltergeist" row).
      expect(mac.first.id, AppMenuId.app);
      expect(mac.first.title, 'Poltergeist');
      expect(
        mac.first.groups.expand((g) => g),
        everyElement(isA<AppMenuProvidedRow>()),
      );
      // Window carries the standard items ahead of the commands.
      final window = mac.firstWhere((m) => m.id == AppMenuId.window);
      expect(window.groups.first, everyElement(isA<AppMenuProvidedRow>()));
      expect(_commandIds(window), ['a.tab']);

      final linux = buildAppMenus(
        commands: commands,
        l10n: l10n,
        platform: TargetPlatform.linux,
      );
      expect(linux.single.id, AppMenuId.window);
      expect(
        linux.single.groups.expand((g) => g),
        everyElement(isA<AppMenuCommandRow>()),
      );
    });

    test('appMenuOnMac rows join the macOS application menu and keep '
        'their own menu elsewhere (D32 §8)', () {
      final commands = [
        _command(
          'a.settings',
          placement: const CommandMenuPlacement(
            menu: AppMenuId.file,
            order: 90,
            appMenuOnMac: true,
          ),
        ),
        _command(
          'a.open',
          placement: const CommandMenuPlacement(
            menu: AppMenuId.file,
            order: 10,
          ),
        ),
      ];

      final mac = buildAppMenus(
        commands: commands,
        l10n: l10n,
        platform: TargetPlatform.macOS,
      );
      final app = mac.first;
      expect(app.id, AppMenuId.app);
      // About leads; the command sits right under it, ahead of Services.
      expect(
        (app.groups.first.single as AppMenuProvidedRow).type,
        PlatformProvidedMenuItemType.about,
      );
      expect(_commandIds(app), ['a.settings']);
      expect(
        _commandIds(mac.firstWhere((m) => m.id == AppMenuId.file)),
        ['a.open'],
      );

      final linux = buildAppMenus(
        commands: commands,
        l10n: l10n,
        platform: TargetPlatform.linux,
      );
      expect(linux.map((m) => m.id), [AppMenuId.file]);
      expect(_commandIds(linux.single), ['a.open', 'a.settings']);
    });
  });

  group('MenuBar branch (Windows/Linux)', () {
    Widget host(
      List<RegisteredCommand> commands, {
      required Future<void> Function(RegisteredCommand) onRun,
      TargetPlatform platform = TargetPlatform.linux,
    }) {
      return MaterialApp(
        theme: ThemeData(platform: platform),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AppMenuHost(
            commands: commands,
            onRun: onRun,
            child: const SizedBox.expand(),
          ),
        ),
      );
    }

    Future<void> pumpHost(
      WidgetTester tester,
      List<RegisteredCommand> commands, {
      required Future<void> Function(RegisteredCommand) onRun,
      TargetPlatform platform = TargetPlatform.linux,
    }) async {
      await tester.pumpWidget(
        host(commands, onRun: onRun, platform: platform),
      );
      await tester.pump();
    }

    testWidgets('renders menu titles and command rows', (tester) async {
      await pumpHost(
        tester,
        [
          _command(
            'x.newTab',
            placement: const CommandMenuPlacement(
              menu: AppMenuId.file,
              order: 10,
            ),
          ),
        ],
        onRun: (_) async {},
      );

      expect(find.byType(MenuBar), findsOneWidget);
      expect(find.byType(SubmenuButton), findsOneWidget);
      expect(find.text('File'), findsOneWidget);

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      expect(find.text('x.newTab'), findsOneWidget);
    });

    testWidgets('items follow command enablement and run through onRun', (
      tester,
    ) async {
      var enabled = false;
      var ran = false;
      final commands = [
        _command(
          'x.verb',
          placement: const CommandMenuPlacement(
            menu: AppMenuId.file,
            order: 10,
          ),
          enabled: () => enabled,
        ),
      ];
      Future<void> onRun(RegisteredCommand command) async => ran = true;
      await tester.pumpWidget(host(commands, onRun: onRun));

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      var item = tester.widget<MenuItemButton>(
        find.ancestor(
          of: find.text('x.verb'),
          matching: find.byType(MenuItemButton),
        ),
      );
      // The disabled command renders but cannot run — the same predicate
      // the chord layer consults, not a second enablement source.
      expect(item.onPressed, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(ran, isFalse);

      // In the shell the shared enablement listenable marks the host
      // dirty; the test triggers the same rebuild by re-pumping.
      enabled = true;
      await tester.pumpWidget(host(commands, onRun: onRun));
      await tester.pump();
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      item = tester.widget<MenuItemButton>(
        find.ancestor(
          of: find.text('x.verb'),
          matching: find.byType(MenuItemButton),
        ),
      );
      expect(item.onPressed, isNotNull);
      await tester.tap(find.text('x.verb'));
      await tester.pumpAndSettle();
      expect(ran, isTrue);
    });

    testWidgets('menu hints show the command\'s registered shortcut', (
      tester,
    ) async {
      const chord = SingleActivator(LogicalKeyboardKey.keyR, control: true);
      await pumpHost(
        tester,
        [
          _command(
            'x.refresh',
            activators: (_) => const [chord],
            placement: const CommandMenuPlacement(
              menu: AppMenuId.view,
              order: 10,
            ),
          ),
        ],
        onRun: (_) async {},
      );

      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      final item = tester.widget<MenuItemButton>(
        find.ancestor(
          of: find.text('x.refresh'),
          matching: find.byType(MenuItemButton),
        ),
      );
      // Single source: the hint IS the registered activator, never a
      // duplicated chord spelling.
      expect(item.trailingIcon, isA<MenuShortcutHint>());
      expect((item.trailingIcon! as MenuShortcutHint).activator, same(chord));
      expect(find.text('Ctrl+R'), findsOneWidget);
    });

    testWidgets('renders shared submenu rows as nested submenus', (
      tester,
    ) async {
      String submenuTitle(AppLocalizations l10n) => 'Sort By';
      await pumpHost(
        tester,
        [
          _command(
            'x.byName',
            placement: CommandMenuPlacement(
              menu: AppMenuId.view,
              order: 10,
              submenu: submenuTitle,
            ),
          ),
          _command(
            'x.bySize',
            placement: CommandMenuPlacement(
              menu: AppMenuId.view,
              order: 11,
              submenu: submenuTitle,
            ),
          ),
        ],
        onRun: (_) async {},
      );

      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sort By'));
      await tester.pumpAndSettle();
      expect(find.text('x.byName'), findsOneWidget);
      expect(find.text('x.bySize'), findsOneWidget);
    });
  });

  group('AppMainMenuButton (D32 Windows/Linux)', () {
    testWidgets('showMenuBar: false renders no strip; the ☰ button opens '
        'the same tree with keyed, runnable rows', (tester) async {
      var checked = false;
      final ran = <String>[];
      final commands = [
        _command(
          'x.open',
          placement: const CommandMenuPlacement(
            menu: AppMenuId.file,
            order: 10,
          ),
          onRun: () => ran.add('x.open'),
        ),
        _command(
          'x.off',
          placement: const CommandMenuPlacement(
            menu: AppMenuId.file,
            order: 20,
          ),
          enabled: () => false,
        ),
        RegisteredCommand(
          id: 'x.toggle',
          scope: CommandScope.app,
          label: (l10n) => 'x.toggle',
          checked: () => checked,
          menuPlacement: const CommandMenuPlacement(
            menu: AppMenuId.view,
            order: 10,
          ),
          run: (_) async => checked = !checked,
        ),
      ];
      Future<void> onRun(RegisteredCommand command) => command.run(
        tester.element(find.byType(Scaffold)),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AppMenuHost(
              commands: commands,
              onRun: onRun,
              showMenuBar: false,
              child: Align(
                alignment: Alignment.topRight,
                child: AppMainMenuButton(commands: commands, onRun: onRun),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(MenuBar), findsNothing);

      await tester.tap(find.byKey(const ValueKey('menu.main')));
      await tester.pumpAndSettle();
      // One submenu per populated menu, keyed by the menu id.
      expect(find.byKey(const ValueKey('menu.file')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu.view')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu.edit')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('menu.file')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MenuItemButton>(
              find.byKey(const ValueKey('menu.item.x.off')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('menu.item.x.open')));
      await tester.pumpAndSettle();
      expect(ran, ['x.open']);

      // A checkable row renders a checkbox item and carries its key
      // exactly once (CheckboxMenuButton alone would forward it to the
      // MenuItemButton it builds).
      await tester.tap(find.byKey(const ValueKey('menu.main')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu.view')));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('menu.item.x.toggle'));
      expect(toggle, findsOneWidget);
      expect(
        find.descendant(of: toggle, matching: find.byType(Checkbox)),
        findsOneWidget,
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(checked, isTrue);
    });
  });

  group('PlatformMenuBar branch (macOS)', () {
    testWidgets('pushes the derived menus to the platform delegate', (
      tester,
    ) async {
      _useRecordingMenuDelegate();
      var ran = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AppMenuHost(
              commands: [
                _command(
                  'x.go',
                  activators: (_) => const [
                    SingleActivator(LogicalKeyboardKey.keyG, meta: true),
                  ],
                  placement: const CommandMenuPlacement(
                    menu: AppMenuId.go,
                    order: 10,
                  ),
                ),
              ],
              onRun: (_) async => ran = true,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();

      final bar = tester.widget<PlatformMenuBar>(
        find.byType(PlatformMenuBar),
      );
      // The delegate received the push itself, not just the widget's
      // configuration: app chrome first, then View (always present on
      // macOS for its provided Enter Full Screen row, D32 §8), then Go,
      // then Window.
      final pushed =
          WidgetsBinding.instance.platformMenuDelegate
              as _RecordingMenuDelegate;
      final titles = pushed.menus.map((m) => (m as PlatformMenu).label);
      expect(titles, ['Poltergeist', 'View', 'Go', 'Window']);

      final goMenu = _menuNamed(bar, 'Go');
      final item = _leavesOf(goMenu).single;
      expect(item.label, 'x.go');
      // The registered chord is bound natively — single source again.
      expect(
        item.shortcut,
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true),
      );
      expect(item.onSelected, isNotNull);
      item.onSelected!();
      await tester.pump();
      expect(ran, isTrue);
    });

    testWidgets('nests submenu rows under a nested PlatformMenu', (
      tester,
    ) async {
      _useRecordingMenuDelegate();
      String submenuTitle(AppLocalizations l10n) => 'Sort By';
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AppMenuHost(
              commands: [
                _command(
                  'x.byName',
                  placement: CommandMenuPlacement(
                    menu: AppMenuId.view,
                    order: 10,
                    submenu: submenuTitle,
                  ),
                ),
                _command(
                  'x.bySize',
                  placement: CommandMenuPlacement(
                    menu: AppMenuId.view,
                    order: 11,
                    submenu: submenuTitle,
                  ),
                ),
              ],
              onRun: (_) async {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();

      final pushed =
          WidgetsBinding.instance.platformMenuDelegate
              as _RecordingMenuDelegate;
      final view = pushed.menus
          .whereType<PlatformMenu>()
          .singleWhere((m) => m.label == 'View');
      final leaves = _leavesOf(view);
      final nested = leaves.whereType<PlatformMenu>().single;
      expect(nested.label, 'Sort By');
      // macOS View ends with the provided Enter Full Screen item.
      expect(
        (leaves.last as PlatformProvidedMenuItem).type,
        PlatformProvidedMenuItemType.toggleFullScreen,
      );
      expect(
        _leavesOf(nested).map((item) => item.label),
        ['x.byName', 'x.bySize'],
      );
    });

    testWidgets('a disabled command pushes a disabled item', (tester) async {
      _useRecordingMenuDelegate();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AppMenuHost(
              commands: [
                _command(
                  'x.off',
                  enabled: () => false,
                  placement: const CommandMenuPlacement(
                    menu: AppMenuId.file,
                    order: 10,
                  ),
                ),
              ],
              onRun: (_) async {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();

      final bar = tester.widget<PlatformMenuBar>(
        find.byType(PlatformMenuBar),
      );
      final item = _leavesOf(_menuNamed(bar, 'File')).single;
      expect(item.onSelected, isNull);
    });

    testWidgets('an unchanged menu signature skips the channel re-sync', (
      tester,
    ) async {
      _useRecordingMenuDelegate();
      var enabled = true;
      final commands = [
        _command(
          'x.verb',
          enabled: () => enabled,
          placement: const CommandMenuPlacement(
            menu: AppMenuId.file,
            order: 10,
          ),
        ),
      ];
      Future<void> onRun(RegisteredCommand command) async {}
      Widget host() => MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AppMenuHost(
            commands: commands,
            onRun: onRun,
            child: const SizedBox.expand(),
          ),
        ),
      );

      // PlatformMenuBar populates its descendant baseline on the first
      // didUpdateWidget, so one update syncs once regardless — warm it,
      // then take the baseline.
      await tester.pumpWidget(host());
      await tester.pumpWidget(host());
      await tester.pump();
      final pushed =
          WidgetsBinding.instance.platformMenuDelegate
              as _RecordingMenuDelegate;
      final afterFirst = pushed.pushes;
      final firstMenus = pushed.menus;

      // A rebuild with an unchanged signature reuses the item objects —
      // the platform bar's listEquals check then short-circuits.
      await tester.pumpWidget(host());
      await tester.pump();
      expect(pushed.pushes, afterFirst);
      expect(identical(pushed.menus, firstMenus), isTrue);

      // A flipped enablement is a new signature and does re-sync.
      enabled = false;
      await tester.pumpWidget(host());
      await tester.pump();
      expect(pushed.pushes, greaterThan(afterFirst));
      expect(identical(pushed.menus, firstMenus), isFalse);
    });

    testWidgets('a field-owned chord retargets to the focused text field', (
      tester,
    ) async {
      _useRecordingMenuDelegate();
      var ran = false;
      final fieldNode = FocusNode();
      addTearDown(fieldNode.dispose);
      final controller = TextEditingController(text: 'query text');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AppMenuHost(
              commands: [
                _command(
                  'edit.selectAll',
                  activators: (_) => const [
                    SingleActivator(LogicalKeyboardKey.keyA, meta: true),
                  ],
                  placement: const CommandMenuPlacement(
                    menu: AppMenuId.edit,
                    order: 10,
                  ),
                ),
              ],
              onRun: (_) async => ran = true,
              child: Column(
                children: [
                  TextField(focusNode: fieldNode, controller: controller),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final bar = tester.widget<PlatformMenuBar>(
        find.byType(PlatformMenuBar),
      );
      final item = _leavesOf(_menuNamed(bar, 'Edit')).single;
      expect(item.label, 'edit.selectAll');

      // 02 §8.2/§9's retargeting: a natively bound ⌘A reaching the menu
      // while a text field holds focus must select the field's text, not
      // run the pane command.
      fieldNode.requestFocus();
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 0);
      item.onSelected!();
      await tester.pump();
      expect(ran, isFalse);
      expect(
        controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 10),
      );

      // Focus outside any text surface: the same item runs the command.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      item.onSelected!();
      await tester.pump();
      expect(ran, isTrue);
    });
  });

  group('registry invariant', () {
    testWidgets('every registered command is menu- or shortcut-reachable '
        'on every platform (02 §8.1)', (tester) async {
      final engine = session_test.FakeAppEngine();
      engine.localChannels.addAll([
        session_test.FakeAppBrowseChannel(homePath: '/home/tester'),
        session_test.FakeAppBrowseChannel(homePath: '/home/tester'),
      ]);
      addTearDown(engine.close);

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final navigatorKey = GlobalKey<NavigatorState>();
      final supportDir = Directory.systemTemp.createTempSync('pg-menus-');
      addTearDown(() {
        try {
          supportDir.deleteSync(recursive: true);
        } on FileSystemException {
          // Best-effort: a stuck engine handle must not mask the result.
        }
      });
      final bookmarks = FakeBookmarkStore();
      final session = await startEngineSession(
        supportDirectoryPath: supportDir.path,
        bookmarks: bookmarks,
        navigatorKey: navigatorKey,
        pinStore: InMemoryHostKeyStore(),
        incidentStore: InMemoryIncidentStore(),
        spawn: (config) async => engine,
      );
      addTearDown(session!.shutdown);

      await tester.pumpWidget(
        PoltergeistApp(
          bookmarks: bookmarks,
          engineSession: session,
          navigatorKey: navigatorKey,
          sshConfigImport: SshConfigImportSetup(
            service: SshConfigImportService(
              homeDirectory: '/home/tester',
              source: FakeSshConfigSource(const {}),
              mintId: uuidV4,
            ),
            bookmarks: bookmarks,
            configPath: '/home/tester/.ssh/config',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The registry as actually wired in the shell — never a re-typed
      // copy of it.
      final commands = tester
          .widget<CommandChordScope>(find.byType(CommandChordScope))
          .commands;
      expect(commands, isNotEmpty);

      const platforms = [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      ];
      for (final platform in platforms) {
        for (final command in commands) {
          final hasChord =
              command.activators?.call(platform).isNotEmpty ?? false;
          final hasMenu = command.menuPlacement != null;
          expect(
            hasChord ||
                hasMenu ||
                kMenuReachabilityExceptions.containsKey(command.id),
            isTrue,
            reason:
                '${command.id} is reachable by neither menu nor '
                'shortcut on ${platform.name} and is not a documented '
                'exception',
          );
        }
      }

      // Exception-list hygiene: every entry is a documented reason bound
      // to a live registration.
      for (final entry in kMenuReachabilityExceptions.entries) {
        expect(entry.value, isNotEmpty, reason: entry.key);
        expect(
          commands.any((c) => c.id == entry.key),
          isTrue,
          reason: 'stale exception: ${entry.key}',
        );
      }
    });
  });
}
