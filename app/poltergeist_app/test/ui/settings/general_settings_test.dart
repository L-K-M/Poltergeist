// The Settings → General surface's first section (02 §10's tab list,
// D19): the update-check opt-out toggle. Follows the settings idiom —
// immediate persist, revert the field and toast on a failed write.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/ui/settings/app_settings_command.dart';
import 'package:poltergeist_app/ui/settings/general_settings.dart';

void main() {
  Widget wrap(GeneralSettings settings) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: GeneralSection(settings: settings),
      ),
    ),
  );

  GeneralSettings settings({
    bool checkForUpdates = true,
    Future<void> Function(bool)? onCheckForUpdatesChanged,
  }) => GeneralSettings(
    checkForUpdates: checkForUpdates,
    onCheckForUpdatesChanged:
        onCheckForUpdatesChanged ?? (_) async {},
  );

  testWidgets('the toggle commits the opt-out through its sink', (
    tester,
  ) async {
    final committed = <bool>[];
    await tester.pumpWidget(
      wrap(
        settings(
          onCheckForUpdatesChanged: (value) async => committed.add(value),
        ),
      ),
    );

    final toggle = find.byKey(const ValueKey('updates.checkEnabled'));
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(committed, [false]);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
  });

  testWidgets('a failed persist reverts the switch', (tester) async {
    await tester.pumpWidget(
      wrap(
        settings(
          onCheckForUpdatesChanged: (_) async =>
              throw StateError('disk full'),
        ),
      ),
    );

    final toggle = find.byKey(const ValueKey('updates.checkEnabled'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    // The failed write was reported through the app's error reporter —
    // drain it so the framework doesn't flag it as unexpected.
    expect(tester.takeException(), isA<StateError>());
  });

  group('app.settings command', () {
    final command = buildAppSettingsCommand(
      settings: () => settings(),
      enabled: () => true,
    );

    test('is the 02 §9 row: app scope, ⌘,/Ctrl+,, File-menu reachable', () {
      expect(command.id, 'app.settings');
      expect(command.scope, CommandScope.app);
      expect(command.menuPlacement?.menu, AppMenuId.file);

      final mac = command.activators!(TargetPlatform.macOS);
      final linux = command.activators!(TargetPlatform.linux);
      expect(mac, hasLength(1));
      expect(linux, hasLength(1));
    });
  });
}
