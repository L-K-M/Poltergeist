import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:macos_window_utils/widgets/titlebar_safe_area.dart';

import 'l10n/app_localizations.dart';
import 'services/bookmark_store.dart';
import 'services/connection_state_bridge.dart';
import 'services/content_size_reporter.dart';
import 'services/engine_session.dart';
import 'services/probe_settings_store.dart';
import 'services/sftp_demo_controller.dart';
import 'services/ssh_config_import_setup.dart';
import 'theme/app_theme.dart';
import 'ui/adaptive_shell.dart';
import 'ui/workspace_shell.dart';

class PoltergeistApp extends StatefulWidget {
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
    this.engineSession,
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
  /// fake, production spawns the real engine isolate. Ignored whenever an
  /// [engineSession] exists — the demo then reuses that engine, so a
  /// second one never spawns in one process.
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

  /// The engine's connection-state lanes for the Connections surface. A
  /// test seam only: an [engineSession] supplies its own lanes, and no
  /// production path passes both.
  final ConnectionStateBridge? connectionEngine;

  /// The app's long-lived production engine (startup composition, not
  /// debug-gated): its lanes feed the Connections surface, its prompt
  /// coordinator answers dialogs from any production surface, and its
  /// shutdown rides app exit. Null leaves the app running engine-less —
  /// every surface reads "no engine" instead of failing to boot.
  final EngineSession? engineSession;

  /// The prompt coordinator and other dialog owners show through this key;
  /// null keeps the default navigator. The session's coordinator and the
  /// [MaterialApp] must share one key: dialogs render on this navigator.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Root snack-bar surface for transient notices (vault-save failures).
  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  @override
  State<PoltergeistApp> createState() => _PoltergeistAppState();
}

/// The exit hook's flush budget: long enough for a real disk write,
/// short enough that a wedged one cannot stall the exit decision.
const _exitFlushTimeout = Duration(seconds: 2);

class _PoltergeistAppState extends State<PoltergeistApp> {
  AppLifecycleListener? _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _attachSessionLifecycle();
  }

  @override
  void didUpdateWidget(PoltergeistApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.engineSession, widget.engineSession)) {
      // The outgoing session's engine must not outlive its replacement
      // unnoticed: forward the exit state before re-attaching.
      oldWidget.engineSession?.forwardLifecycle(AppLifecycleState.detached);
      _attachSessionLifecycle();
    }
  }

  /// Engine lifetime follows the app's: `detached` is the last state a
  /// desktop process sees (the window is gone), so the session shuts the
  /// engine down there — best-effort orderly teardown before process
  /// exit. `onExitRequested` covers the window-close path where `detached`
  /// may never be delivered to Dart before the process is torn down; both
  /// routes land on the same idempotent shutdown.
  void _attachSessionLifecycle() {
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    final session = widget.engineSession;
    if (session == null) return;
    _lifecycleListener = AppLifecycleListener(
      onStateChange: session.forwardLifecycle,
      // The framework awaits this future before exiting — the only exit
      // hook with a wait semantic, so the pending mirror writes flush
      // before the process is allowed to die. The session's shutdown
      // itself is triggered fire-and-forget (idempotent), keeping the
      // exit decision independent of teardown-path futures.
      onExitRequested: () async {
        // Flush what is already queued before stopping the engine: the
        // tails snapshot at call time, so writes racing the shutdown
        // trigger still land first. Best-effort and bounded — the
        // framework awaits this future, so neither a failed nor a wedged
        // flush may block the exit.
        try {
          await session
              .flushWrites()
              .timeout(_exitFlushTimeout);
        } on Object catch (error, stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stackTrace),
          );
        }
        session.forwardLifecycle(AppLifecycleState.detached);
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    // Deliberately no shutdown here: the tree never unmounts in
    // production (engine lifetime rides app exit), and driving async
    // shutdown from widget dispose deadlocks the test binding's
    // teardown zone — tests own their session teardown explicitly.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: widget.navigatorKey,
      scaffoldMessengerKey: widget.scaffoldMessengerKey,
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
    final bool demoEnabled = widget.debugDemoEnabled && kDebugMode;
    assert(
      demoEnabled || widget.sftpDemoEngineFactory == null,
      'sftpDemoEngineFactory was provided but debugDemoEnabled is off; '
      'the factory will be silently ignored.',
    );
    assert(
      !demoEnabled || widget.probeSettings != null,
      'debugDemoEnabled requires probeSettings: the demo session\'s '
      'probe wiring must persist.',
    );
    assert(
      widget.connectionEngine == null || widget.engineSession == null,
      'connectionEngine is a test seam; engineSession supplies its own '
      'lanes. Provide one, not both.',
    );
    final workspace = WorkspaceShell(
      initialPaneRatio: widget.initialPaneRatio,
      onPaneRatioChanged: widget.onPaneRatioChanged,
      onPaneRatioSaveError: widget.onPaneRatioSaveError,
      debugDemoEnabled: demoEnabled,
      // Forward the seam only where the gated surface can consume it;
      // release/profile builds never see a spawnable engine factory.
      sftpDemoEngineFactory: demoEnabled ? widget.sftpDemoEngineFactory : null,
      probeSettings: demoEnabled ? widget.probeSettings : null,
      sshConfigImport: widget.sshConfigImport,
      bookmarks: widget.bookmarks,
      connectionEngine: widget.connectionEngine,
      engineSession: widget.engineSession,
    );
    final callback = widget.onContentSizeChanged;
    if (callback == null) return workspace;

    // The desktop minimum includes native chrome around this content box.
    return ContentSizeReporter(onSize: callback, child: workspace);
  }
}
