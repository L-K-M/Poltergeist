import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/appearance_controller.dart';
import 'package:poltergeist_app/services/update_check_controller.dart';
import 'package:poltergeist_app/theme/app_appearance.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/theme/theme_presets.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';

/// The MaterialApp above the whole app is drawn in the device's theme and
/// rebuilds for a theme change and for nothing else: the shell below it
/// keeps its state through a re-theme.
void main() {
  testWidgets('the app re-themes live, and only for its theme', (tester) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final appearance = AppearanceController();
    final updates = UpdateCheckController(
      enabled: true,
      onEnabledChanged: (_) async {},
    );

    await tester.pumpWidget(
      PoltergeistApp(appearance: appearance, updateCheck: updates),
    );
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    final before = app();
    final shell = tester.state(find.byType(WorkspaceShell));
    // A new device starts in Vapor.
    expect(before.theme?.colorScheme.surface, ThemePresets.vapor.surface);

    // Something else the app listens to changes: no re-theme.
    await updates.setEnabled(false);
    await tester.pump();
    expect(app(), same(before));

    await appearance.setAppearance(
      ThemePresets.solarized,
      ThemeModePreference.system,
    );
    await tester.pumpAndSettle();
    expect(app(), isNot(same(before)));
    expect(app().theme?.colorScheme.surface, ThemePresets.solarized.surface);
    // A surface of its own is one theme whatever the system says.
    expect(app().themeMode, ThemeMode.light);
    expect(
      Theme.of(tester.element(find.byType(WorkspaceShell))).colorScheme.surface,
      ThemePresets.solarized.surface,
    );
    // The same shell, re-themed rather than rebuilt from scratch.
    expect(tester.state(find.byType(WorkspaceShell)), same(shell));
  });

  testWidgets('without a theme seam the app draws the default', (tester) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const PoltergeistApp());

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    final expected = poltergeistThemesFor(AppAppearance.initial);
    expect(app.themeMode, expected.themeMode);
    expect(app.theme?.colorScheme, expected.theme.colorScheme);
    expect(app.darkTheme?.colorScheme, expected.darkTheme.colorScheme);
    expect(app.theme?.colorScheme.surface, ThemePresets.vapor.surface);
  });
}
