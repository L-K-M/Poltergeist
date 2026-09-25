import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/update_check_controller.dart';
import 'package:poltergeist_app/ui/menus/app_menu_commands.dart';
import 'package:poltergeist_app/ui/menus/app_menus.dart';
import 'package:poltergeist_app/ui/settings/app_settings_command.dart';
import 'package:poltergeist_app/ui/settings/general_settings.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// 10 §8's two platform rows: "Check for Updates…" in the macOS
/// application menu (ahead of Settings…), and "Quit" at the end of the
/// Linux/Windows File menu, which quits the way the titlebar's close
/// button does: through the intercepted close and its quit guard.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  UpdateCheckController controllerAnswering(String tag) =>
      UpdateCheckController(
        // The launch check is off: the menu row must still work.
        enabled: false,
        checker: UpdateChecker(
          repo: poltergeistUpdateRepo,
          client: http_testing.MockClient(
            (_) async => http.Response(
              jsonEncode({'tag_name': tag, 'draft': false}),
              200,
            ),
          ),
        ),
      );

  RegisteredCommand settings() => buildAppSettingsCommand(
    settings: () => GeneralSettings(
      checkForUpdates: true,
      onCheckForUpdatesChanged: (_) async {},
    ),
    enabled: () => true,
  );

  List<String> ids(AppMenuModel menu) => [
    for (final group in menu.groups)
      for (final row in group)
        if (row is AppMenuCommandRow) row.command.id,
  ];

  test('Check for Updates… leads the macOS app menu, before Settings…', () {
    final menus = buildAppMenus(
      commands: [
        settings(),
        buildCheckForUpdatesCommand(
          updates: controllerAnswering('v1.0.0'),
          openUrl: (_) async {},
        ),
      ],
      l10n: l10n,
      platform: TargetPlatform.macOS,
    );
    expect(ids(menus.first), [
      kAppCheckForUpdatesCommandId,
      kAppSettingsCommandId,
    ]);
  });

  test('Quit ends the Linux/Windows File menu, after Settings…', () {
    for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
      final menus = buildAppMenus(
        commands: [
          buildQuitCommand(requestClose: () async {}),
          settings(),
        ],
        l10n: l10n,
        platform: platform,
      );
      final file = menus.singleWhere((m) => m.id == AppMenuId.file);
      expect(
        file.groups.last.map((row) => (row as AppMenuCommandRow).command.id),
        [kAppSettingsCommandId, kAppQuitCommandId],
        reason: platform.name,
      );
      expect(
        (file.groups.last.last as AppMenuCommandRow).command.label(l10n),
        'Quit',
      );
    }
  });

  group('running', () {
    late BuildContext context;

    Future<void> pumpHost(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.expand();
            },
          ),
        ),
      );
    }

    testWidgets('a newer release is announced with a link to it', (
      tester,
    ) async {
      await pumpHost(tester);
      final opened = <Uri>[];
      final command = buildCheckForUpdatesCommand(
        updates: controllerAnswering('v9.9.9'),
        currentVersion: () async => '1.0.0',
        openUrl: (url) async => opened.add(url),
      );

      await tester.runAsync(() => command.run(context));
      await tester.pump();

      expect(find.text('Poltergeist 9.9.9 is available'), findsOneWidget);
      await tester.tap(find.text('View Release'));
      await tester.pumpAndSettle();
      expect(opened, [
        Uri.parse('https://github.com/L-K-M/Poltergeist/releases/latest'),
      ]);
    });

    testWidgets('no newer release says so without claiming up to date', (
      tester,
    ) async {
      await pumpHost(tester);
      final command = buildCheckForUpdatesCommand(
        updates: controllerAnswering('v1.0.0'),
        currentVersion: () async => '1.0.0',
        openUrl: (_) async {},
      );

      await tester.runAsync(() => command.run(context));
      await tester.pump();

      expect(
        find.text(
          'No newer version was found. If you’re offline, try again later.',
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('Quit asks the window to close, never to destroy', (
      tester,
    ) async {
      // window_manager's close raises the intercepted close event, which
      // DesktopWindowLifecycle answers with the quit guard, the session
      // flush, and only then destroy; a destroy would skip all of it.
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async {
          calls.add(call.method);
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          null,
        ),
      );
      await pumpHost(tester);

      await buildQuitCommand().run(context);

      expect(calls, ['close']);
    });
  });
}
