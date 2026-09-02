import 'dart:ui';

import 'settings_store.dart';

const _defaultPaneRatio = 0.5;
const _paneRatioKey = 'layout.paneRatio';
const _windowLeftKey = 'window.left';
const _windowTopKey = 'window.top';
const _windowWidthKey = 'window.width';
const _windowHeightKey = 'window.height';

class AppPreferences {
  AppPreferences({required SettingsStore store})
    // Keep the backing store private to the preference facade.
    // ignore: prefer_initializing_formals
    : _store = store;

  final SettingsStore _store;

  Future<double> loadPaneRatio() async {
    num? storedRatio;
    try {
      storedRatio = await _store.get<num>(_paneRatioKey);
    } catch (_) {
      // Startup continues while the store resets its load for a later retry.
      return _defaultPaneRatio;
    }

    if (storedRatio == null || !storedRatio.isFinite) {
      return _defaultPaneRatio;
    }

    final ratio = storedRatio.toDouble();
    return ratio.clamp(0, 1).toDouble();
  }

  Future<void> savePaneRatio(double ratio) {
    if (!ratio.isFinite) return Future.value();

    return _store.set(_paneRatioKey, ratio.clamp(0, 1).toDouble());
  }

  Future<Rect?> loadWindowBounds() async {
    late final List<num?> storedValues;
    try {
      storedValues = await Future.wait<num?>([
        _store.get<num>(_windowLeftKey),
        _store.get<num>(_windowTopKey),
        _store.get<num>(_windowWidthKey),
        _store.get<num>(_windowHeightKey),
      ]);
    } catch (_) {
      // An unreadable store must not prevent default window placement.
      return null;
    }

    if (storedValues.any((value) => value == null || !value.isFinite)) {
      return null;
    }

    final values = storedValues.map((value) => value!.toDouble()).toList();
    final width = values[2];
    final height = values[3];
    if (width <= 0 || height <= 0) return null;

    return Rect.fromLTWH(values[0], values[1], width, height);
  }

  Future<void> saveWindowBounds(Rect bounds) async {
    final values = [bounds.left, bounds.top, bounds.width, bounds.height];

    // Ignore transient invalid geometry reported during native window changes.
    if (values.any((value) => !value.isFinite) ||
        bounds.width <= 0 ||
        bounds.height <= 0) {
      return;
    }

    await _store.setAll({
      _windowLeftKey: bounds.left,
      _windowTopKey: bounds.top,
      _windowWidthKey: bounds.width,
      _windowHeightKey: bounds.height,
    });
  }
}
