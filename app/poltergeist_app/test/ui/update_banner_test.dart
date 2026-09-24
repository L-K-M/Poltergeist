// The D19 update banner (00 D19/D23, 07 §3.10): a dismissible strip
// that names the newer tag and links out to the releases page. The
// launch seam is injected so the widget test can prove the button hands
// the releases URL — never an asset URL — to the OS browser.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/update_check_controller.dart';
import 'package:poltergeist_app/ui/settings/app_settings_command.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_app/ui/update_banner.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/shell_menus.dart';

void main() {
  final info = UpdateInfo(
    latestVersion: '9.9.9',
    releasesUrl: Uri.parse(
      'https://github.com/L-K-M/Poltergeist/releases/latest',
    ),
  );

  Widget wrap({
    VoidCallback? onDismiss,
    Future<bool> Function(Uri)? launch,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: UpdateBanner(
        info: info,
        onDismiss: onDismiss ?? () {},
        launch: launch,
      ),
    ),
  );

  testWidgets('names the newer version and links to the releases page', (
    tester,
  ) async {
    final launched = <Uri>[];
    await tester.pumpWidget(wrap(launch: (uri) async {
      launched.add(uri);
      return true;
    }));

    expect(find.text('Poltergeist 9.9.9 is available.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('update.viewRelease')));
    await tester.pumpAndSettle();
    // The link, and only the link: the human-facing releases page is
    // the whole affordance — no asset URL ever reaches the launcher.
    expect(launched, [info.releasesUrl]);
  });

  testWidgets('the dismiss affordance fires its callback', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(wrap(onDismiss: () => dismissed++));

    await tester.tap(find.byKey(const ValueKey('update.dismiss')));
    expect(dismissed, 1);
  });

  group('workspace shell mount', () {
    UpdateCheckController controller() => UpdateCheckController(
      checker: UpdateChecker(
        repo: poltergeistUpdateRepo,
        client: http_testing.MockClient(
          (request) async => http.Response(
            jsonEncode({'tag_name': 'v9.9.9'}),
            200,
          ),
        ),
      ),
    );

    Future<void> pumpShell(
      WidgetTester tester,
      UpdateCheckController updateCheck,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates:
              AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WorkspaceShell(updateCheck: updateCheck),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a newer tag raises an Alerts row and badges the '
        'inspector toggle; dismiss clears both (D32)', (tester) async {
      final updateCheck = controller();
      await pumpShell(tester, updateCheck);
      final toggle = find.byKey(
        const ValueKey('command.$kViewToggleInspectorCommandId'),
      );
      Finder badgeOn(Finder button) =>
          find.descendant(of: button, matching: find.text('1'));
      // Nothing shown before the check resolves.
      expect(badgeOn(toggle), findsNothing);

      await updateCheck.checkForUpdate('0.2.0');
      await tester.pumpAndSettle();
      // D32 §3: the update is an alert, not a strip above the panes.
      expect(find.byType(UpdateBanner), findsNothing);
      expect(badgeOn(toggle), findsOneWidget);
      final alertsTab = find.byKey(const ValueKey('inspector.tab.alerts'));
      expect(badgeOn(alertsTab), findsOneWidget);

      await tester.tap(alertsTab);
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('alert.update:9.9.9'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.text('Poltergeist 9.9.9 is available'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.widgetWithText(TextButton, 'View Release'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('alert.update:9.9.9.dismiss')),
      );
      await tester.pumpAndSettle();
      expect(row, findsNothing);
      expect(badgeOn(toggle), findsNothing);
      // The check's own state agrees — nothing resurfaces it.
      expect(updateCheck.update, isNull);
    });

    testWidgets('the File menu carries the Settings row', (
      tester,
    ) async {
      await pumpShell(tester, controller());
      // 02 §9's row: the File menu carries Settings… while the
      // update-check seam exists (the macOS app menu takes it there).
      await openShellMenu(tester, AppMenuId.file);
      expect(
        find.byKey(const ValueKey('menu.item.$kAppSettingsCommandId')),
        findsOneWidget,
      );
      expect(find.text('Settings…'), findsOneWidget);
      // Close the menu before teardown.
      await closeShellMenus(tester);
    });
  });
}
