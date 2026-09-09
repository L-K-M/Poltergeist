import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:macos_window_utils/widgets/titlebar_safe_area.dart';

import 'l10n/app_localizations.dart';
import 'services/content_size_reporter.dart';
import 'services/sftp_demo_controller.dart';
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
    final workspace = WorkspaceShell(
      initialPaneRatio: initialPaneRatio,
      onPaneRatioChanged: onPaneRatioChanged,
      onPaneRatioSaveError: onPaneRatioSaveError,
      debugDemoEnabled: demoEnabled,
      // Forward the seam only where the gated surface can consume it;
      // release/profile builds never see a spawnable engine factory.
      sftpDemoEngineFactory: demoEnabled ? sftpDemoEngineFactory : null,
    );
    final callback = onContentSizeChanged;
    if (callback == null) return workspace;

    // The desktop minimum includes native chrome around this content box.
    return ContentSizeReporter(onSize: callback, child: workspace);
  }
}
