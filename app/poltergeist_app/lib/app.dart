import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:macos_window_utils/widgets/titlebar_safe_area.dart';

import 'l10n/app_localizations.dart';
import 'services/bookmark_store.dart';
import 'services/connection_state_bridge.dart';
import 'services/content_size_reporter.dart';
import 'services/probe_settings_store.dart';
import 'services/sftp_demo_controller.dart';
import 'services/ssh_config_import_setup.dart';
import 'theme/app_theme.dart';
import 'ui/adaptive_shell.dart';
import 'ui/workspace_shell.dart';

class PoltergeistApp extends StatelessWidget {
  const PoltergeistApp({
    super.key,
    this.initialPaneRatio = 0.5,
    this.onPaneRatioChanged,
    this.onPaneRatioSaveError,
    this.onContentSizeChanged,
    this.navigatorKey,
    this.scaffoldMessengerKey,
    this.debugDemoEnabled = false,
    this.sftpDemoEngineFactory,
    this.probeSettings,
    this.sshConfigImport,
    this.bookmarks,
    this.connectionEngine,
  });

  final double initialPaneRatio;
  final PaneRatioSaver? onPaneRatioChanged;
  final void Function(Object, StackTrace)? onPaneRatioSaveError;
  final ValueChanged<Size>? onContentSizeChanged;

  /// Gating flag for the debug-only SFTP demo surface (07 §3.3). Defaults
  /// off so tests and alternate boot paths opt in explicitly; the debug
  /// entrypoint (main.dart) passes kDebugMode. The flag can only disable
  /// the demo in debug builds, never enable it in release: _buildWorkspace
  /// ANDs it with kDebugMode, which is false there.
  final bool debugDemoEnabled;

  /// Engine factory behind the demo surface; tests inject a scripted
  /// fake, production spawns the real engine isolate.
  final SftpDemoEngineFactory? sftpDemoEngineFactory;

  /// Persisted probe settings behind the demo surface's probe wiring.
  final ProbeSettings? probeSettings;

  /// The D22 ssh_config import wiring (service, bookmark store, config
  /// path). Null leaves the import command unregistered; `main.dart`
  /// supplies it from the app-support directory.
  final SshConfigImportSetup? sshConfigImport;

  /// The persisted bookmark store behind the Connections surface (03 §6's
  /// `BookmarkStore` seam). Null leaves that command unregistered.
  final BookmarkRepository? bookmarks;

  /// The engine's connection-state lanes for the Connections surface. Null
  /// while no production engine exists: the startup-wiring slice owns the
  /// spawn, which must seed host-key pins and trust incidents together
  /// (STATUS item 6, audit finding A).
  final ConnectionStateBridge? connectionEngine;

  /// The prompt coordinator and other dialog owners show through this key;
  /// null keeps the default navigator.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Root snack-bar surface for transient notices (vault-save failures).
  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      theme: buildPoltergeistTheme(Brightness.light),
      darkTheme: buildPoltergeistTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: TitlebarSafeArea(child: _buildWorkspace()),
    );
  }

  Widget _buildWorkspace() {
    // Runtime-gated only: the demo code stays linked into release
    // binaries until M3 deletes this surface wholesale.
    final bool demoEnabled = debugDemoEnabled && kDebugMode;
    assert(
      demoEnabled || sftpDemoEngineFactory == null,
      'sftpDemoEngineFactory was provided but debugDemoEnabled is off; '
      'the factory will be silently ignored.',
    );
    assert(
      !demoEnabled || probeSettings != null,
      'debugDemoEnabled requires probeSettings: the demo session\'s '
      'probe wiring must persist.',
    );
    final workspace = WorkspaceShell(
      initialPaneRatio: initialPaneRatio,
      onPaneRatioChanged: onPaneRatioChanged,
      onPaneRatioSaveError: onPaneRatioSaveError,
      debugDemoEnabled: demoEnabled,
      // Forward the seam only where the gated surface can consume it;
      // release/profile builds never see a spawnable engine factory.
      sftpDemoEngineFactory: demoEnabled ? sftpDemoEngineFactory : null,
      probeSettings: demoEnabled ? probeSettings : null,
      sshConfigImport: sshConfigImport,
      bookmarks: bookmarks,
      connectionEngine: connectionEngine,
    );
    final callback = onContentSizeChanged;
    if (callback == null) return workspace;

    // The desktop minimum includes native chrome around this content box.
    return ContentSizeReporter(onSize: callback, child: workspace);
  }
}
