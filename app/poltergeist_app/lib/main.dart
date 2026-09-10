import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'app.dart';
import 'services/app_preferences.dart';
import 'services/application_error_reporter.dart';
import 'services/bookmark_store.dart';
import 'services/desktop_window_lifecycle.dart';
import 'services/probe_settings_store.dart';
import 'services/settings_store.dart';
import 'services/ssh_config_file_source.dart';
import 'services/ssh_config_import_setup.dart';
import 'services/uuid.dart';

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
  // Both facades write settings.json through this one instance;
  // SettingsStore serializes every write internally (its write tail) and
  // persists the full in-memory snapshot atomically, so probe-servers
  // writes can never interleave with pane-ratio saves.
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
      sshConfigImport: _sshConfigImport(
        supportDirectory.path,
        errorReporter.report,
      ),
      onPaneRatioChanged: preferences.savePaneRatio,
      onPaneRatioSaveError: errorReporter.report,
      onContentSizeChanged: (size) {
        errorReporter.observe(windowLifecycle.calibrateMinimumSize(size));
      },
    ),
  );
  await errorReporter.guard(windowLifecycle.show);
}

/// The D22 import wiring: `~/.ssh/config` read read-only, imported rows
/// persisted to `bookmarks.json` beside settings. Returns null when no
/// home directory can be determined — the command stays unregistered
/// rather than reading a bogus path.
SshConfigImportSetup? _sshConfigImport(
  String supportPath,
  void Function(Object, StackTrace) onError,
) {
  // Recover the real home when a macOS sandbox points HOME at the app
  // container (the ported `expandHomePath` rule): `~/.ssh` means the
  // user's keys, never the container's.
  final home = expandHomePath(
    '~',
    environment: Platform.environment,
    isMacOS: Platform.isMacOS,
  );
  if (home == '~') return null;

  return SshConfigImportSetup(
    service: SshConfigImportService(
      homeDirectory: home,
      source: const LocalSshConfigFileSource(),
      mintId: uuidV4,
    ),
    bookmarks: FileBookmarkStore(
      path: '$supportPath${Platform.pathSeparator}bookmarks.json',
      onError: onError,
    ),
    // ssh_config paths are POSIX-shaped: the core import service
    // normalizes on `/` (its include base is `.ssh/`), so these literal
    // separators are deliberate. Windows import awaits that path
    // handling, not `Platform.pathSeparator` here.
    configPath: '$home/.ssh/config',
  );
}
