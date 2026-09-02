import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/app_preferences.dart';
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
}
