import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'services/app_preferences.dart';
import 'services/application_error_reporter.dart';
import 'services/desktop_window_lifecycle.dart';
import 'services/probe_settings_store.dart';
import 'services/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final supportDirectory = await getApplicationSupportDirectory();
  final settingsPath =
      '${supportDirectory.path}${Platform.pathSeparator}settings.json';
  final errorReporter = ApplicationErrorReporter();
  final settingsStore = SettingsStore(
    path: settingsPath,
    onError: errorReporter.report,
  );
  final preferences = AppPreferences(store: settingsStore);
  final probeSettings = ProbeSettingsStore(store: settingsStore);
  final paneRatio = await preferences.loadPaneRatio();
  final windowLifecycle = DesktopWindowLifecycle(
    preferences,
    onError: errorReporter.report,
  );
  await errorReporter.guard(windowLifecycle.prepare);

  runApp(
    PoltergeistApp(
      initialPaneRatio: paneRatio,
      // The debug-only demo surface is an explicit opt-in at the boot
      // site; tests and alternate paths stay opted out by default.
      debugDemoEnabled: kDebugMode,
      probeSettings: probeSettings,
      onPaneRatioChanged: preferences.savePaneRatio,
      onPaneRatioSaveError: errorReporter.report,
      onContentSizeChanged: (size) {
        errorReporter.observe(windowLifecycle.calibrateMinimumSize(size));
      },
    ),
  );
  await errorReporter.guard(windowLifecycle.show);
}
