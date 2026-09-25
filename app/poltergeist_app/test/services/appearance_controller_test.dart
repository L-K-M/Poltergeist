import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/appearance_controller.dart';
import 'package:poltergeist_app/theme/app_appearance.dart';
import 'package:poltergeist_app/theme/theme_palette.dart';
import 'package:poltergeist_app/theme/theme_presets.dart';

/// The app's side of the device theme: what the MaterialApp listens to, and
/// what the Appearance section writes through.
void main() {
  test('starts at the default theme unless told otherwise', () {
    expect(AppearanceController().value, AppAppearance.initial);
    final loaded = AppAppearance(
      palette: ThemePresets.paper,
      mode: ThemeModePreference.dark,
    );
    expect(AppearanceController(initial: loaded).value, loaded);
  });

  test('re-themes, then saves', () async {
    final events = <String>[];
    late AppearanceController controller;
    controller = AppearanceController(
      save: (appearance) async {
        // The app already shows it by the time the write starts.
        events.add('save ${controller.value.palette.name}');
      },
    );
    controller.addListener(() => events.add('notify'));

    await controller.setAppearance(
      ThemePresets.midnight,
      ThemeModePreference.light,
    );

    expect(events, ['notify', 'save Midnight']);
    expect(
      controller.value,
      AppAppearance(
        palette: ThemePresets.midnight,
        mode: ThemeModePreference.light,
      ),
    );
  });

  test('writing what is already there does nothing', () async {
    var saves = 0;
    var notifies = 0;
    final controller = AppearanceController(
      initial: AppAppearance(palette: ThemePresets.paper),
      save: (_) async => saves++,
    )..addListener(() => notifies++);

    // An equal palette, not the same object: what a trip through the link
    // or the settings file hands back.
    await controller.setAppearance(
      ThemePalette.decodeStored(ThemePresets.paper.toJson()),
      ThemeModePreference.system,
    );

    expect(saves, 0);
    expect(notifies, 0);
  });

  test('a failed write keeps the theme on screen, and says so', () async {
    final controller = AppearanceController(
      save: (_) async => throw StateError('disk full'),
    );

    await expectLater(
      controller.setAppearance(ThemePresets.vapor, ThemeModePreference.system),
      throwsA(isA<StateError>()),
    );
    // Applied before the write: the app shows what the section shows, and
    // the next write carries it.
    expect(controller.value.palette, ThemePresets.vapor);
  });
}
