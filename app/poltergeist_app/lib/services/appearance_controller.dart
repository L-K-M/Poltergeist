import 'package:flutter/foundation.dart';

import '../theme/app_appearance.dart';
import '../theme/theme_palette.dart';
import 'settings_models.dart';

/// This device's theme in the app's isolate: what the MaterialApp is drawn
/// in, and the model the Appearance section writes through, in the Settings
/// dialog and (over the link) in the Settings window.
///
/// Its own notifier rather than a field the shell reads on rebuild, so the
/// MaterialApp above the whole app rebuilds when the theme changes and for
/// nothing else.
///
/// Applies a change before persisting it, as Séance's settings backend
/// does, rather than persist-first like the General switch: the section
/// writes through on every change, a corner drag included, and the app
/// repainting only after the disk caught up would make each edit lag by a
/// save. A failed write keeps the change on screen and throws, so the
/// section can say it was not saved; the next write carries it.
final class AppearanceController extends ChangeNotifier
    implements AppearanceSettingsModel {
  AppearanceController({AppAppearance? initial, this._save})
    : _value = initial ?? AppAppearance.initial;

  AppAppearance _value;
  final Future<void> Function(AppAppearance appearance)? _save;

  @override
  AppAppearance get value => _value;

  @override
  Future<void> setAppearance(
    ThemePalette palette,
    ThemeModePreference mode,
  ) async {
    final next = AppAppearance(palette: palette, mode: mode);
    if (next == _value) return;
    _value = next;
    notifyListeners();
    await _save?.call(next);
  }
}
