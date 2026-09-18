import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/app_preferences.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/settings_store.dart';

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_preferences_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('accepts integer-valued persisted geometry and pane ratio', () async {
    await settingsFile.writeAsString(
      '{"layout.paneRatio":1,"window.left":80,"window.top":60,'
      '"window.width":1180,"window.height":760}',
    );
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    expect(await preferences.loadPaneRatio(), 1);
    expect(
      await preferences.loadWindowBounds(),
      const Rect.fromLTWH(80, 60, 1180, 760),
    );
  });

  test('uses the default pane ratio while settings recover', () async {
    await settingsFile.writeAsBytes([0xff]);
    final errors = <Object>[];
    final preferences = AppPreferences(
      store: SettingsStore(
        path: settingsFile.path,
        onError: (error, _) => errors.add(error),
      ),
    );

    expect(await preferences.loadPaneRatio(), 0.5);
    expect(errors, hasLength(1));

    await settingsFile.writeAsString('{"layout.paneRatio":0.7}');

    expect(await preferences.loadPaneRatio(), 0.7);
  });

  test('uses default window placement while settings recover', () async {
    final blockedParent = File(p.join(temporaryDirectory.path, 'blocked'));
    await blockedParent.writeAsString('not a directory');
    final preferences = AppPreferences(
      store: SettingsStore(
        path: p.join(blockedParent.path, 'settings.json'),
      ),
    );

    expect(await preferences.loadWindowBounds(), isNull);
  });

  test('persists every Double-click action value and reads it back',
      () async {
    for (final action in DoubleClickAction.values) {
      final preferences = AppPreferences(
        store: SettingsStore(path: settingsFile.path),
      );
      await preferences.saveDoubleClickAction(action);
      expect(await preferences.loadDoubleClickAction(), action);
    }
  });

  test('the restored-tab reconnect setting defaults ON and persists',
      () async {
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    expect(await preferences.loadReconnectRestoredTabs(), isTrue);

    await preferences.saveReconnectRestoredTabs(false);
    expect(await preferences.loadReconnectRestoredTabs(), isFalse);

    // A non-bool stored value reads as the spec default, not a failure.
    // SettingsStore caches after first load, so a fresh store observes
    // the externally written file.
    await settingsFile.writeAsString(
      '{"tabs.reconnectRestored":"yes"}',
    );
    final reloaded = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );
    expect(await reloaded.loadReconnectRestoredTabs(), isTrue);
  });

  test('the Double-click action defaults to Open and falls back on an '
      'unknown stored value', () async {
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    expect(
      await preferences.loadDoubleClickAction(),
      DoubleClickAction.open,
    );

    await settingsFile.writeAsString(
      '{"panes.doubleClickAction":"teleport"}',
    );
    expect(
      await preferences.loadDoubleClickAction(),
      DoubleClickAction.open,
    );
  });

  test('a non-finite persisted transfer limit decodes as unlimited',
      () async {
    // jsonDecode saturates an over-range literal to Infinity, and
    // toInt() throws on it outside the get's try — a corrupt settings
    // file must not crash the loader (the panel-height loader already
    // guards the same way).
    await settingsFile.writeAsString(
      '{"transfer.downloadLimitBytesPerSecond":1e999}',
    );
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    expect(await preferences.loadDownloadLimit(), isNull);
  });

  test('does not persist invalid window bounds', () async {
    const invalidBounds = <({String name, Rect bounds})>[
      (
        name: 'non-finite origin',
        bounds: Rect.fromLTWH(double.nan, 60, 1180, 760),
      ),
      (
        name: 'non-finite size',
        bounds: Rect.fromLTWH(80, 60, double.infinity, 760),
      ),
      (name: 'zero width', bounds: Rect.fromLTWH(80, 60, 0, 760)),
      (name: 'negative height', bounds: Rect.fromLTWH(80, 60, 1180, -1)),
    ];

    for (final fixture in invalidBounds) {
      final fixtureFile = File(p.join(temporaryDirectory.path, fixture.name));
      final preferences = AppPreferences(
        store: SettingsStore(path: fixtureFile.path),
      );

      await expectLater(
        preferences.saveWindowBounds(fixture.bounds),
        completes,
        reason: fixture.name,
      );
      expect(fixtureFile.existsSync(), isFalse, reason: fixture.name);
    }
  });
}
