import 'dart:async' show FutureOr;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:macos_window_utils/widgets/titlebar_safe_area.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show ConflictPolicy;

import 'l10n/app_localizations.dart';
import 'services/app_transfer_queue.dart';
import 'services/bookmark_store.dart';
import 'services/connection_state_bridge.dart';
import 'services/content_size_reporter.dart';
import 'services/double_click_action.dart';
import 'services/engine_session.dart';
import 'services/pane_tabs_controller.dart' show NewTabTarget;
import 'services/quit_guard.dart';
import 'services/session_persistence.dart';
import 'services/session_state.dart';
import 'services/ssh_config_import_setup.dart';
import 'services/workspace_library.dart';
import 'theme/app_theme.dart';
import 'ui/adaptive_shell.dart';
import 'ui/workspace_shell.dart';

class PoltergeistApp extends StatefulWidget {
  const PoltergeistApp({
    super.key,
    this.initialPaneRatio = 0.5,
    this.newTabTarget = NewTabTarget.duplicate,
    this.doubleClickAction = DoubleClickAction.open,
    this.reconnectRestoredTabs = true,
    this.restoredSession,
    this.sessionPersistence,
    this.onPaneRatioChanged,
    this.onPaneRatioSaveError,
    this.onContentSizeChanged,
    this.navigatorKey,
    this.scaffoldMessengerKey,
    this.sshConfigImport,
    this.bookmarks,
    this.workspaces,
    this.connectionEngine,
    this.engineSession,
    this.transferQueue,
    this.quitGuard,
    this.conflictPolicy,
    this.initialActivityPanelHeight = 200,
    this.onActivityPanelHeightChanged,
    this.onActivityPanelHeightSaveError,
    this.initialDownloadLimit,
    this.initialUploadLimit,
    this.onDownloadLimitChanged,
    this.onUploadLimitChanged,
    this.autoClearCompletedTransfers = true,
  });

  final double initialPaneRatio;

  /// The persisted "New tabs open" preference (02 §2.1), loaded at
  /// startup and seeded onto each pane's tab strip.
  final NewTabTarget newTabTarget;

  /// The persisted "Double-click action" preference (02 §2.6), loaded
  /// at startup and seeded onto each pane's tab strip.
  final DoubleClickAction doubleClickAction;

  /// The persisted "Reconnect restored tabs automatically" setting
  /// (02 §3), loaded at startup and seeded onto each pane's tab strip.
  final bool reconnectRestoredTabs;

  /// The persisted session document (02 §3's launch restoration);
  /// null boots the default two-pane layout.
  final SessionState? restoredSession;

  /// 02 §3's session writer: flushed inside `onExitRequested` — the
  /// app-quit safe point — while its notify-driven writes cover every
  /// other commit point. Null leaves session persistence unwired.
  final SessionPersistence? sessionPersistence;

  final PaneRatioSaver? onPaneRatioChanged;
  final void Function(Object, StackTrace)? onPaneRatioSaveError;
  final ValueChanged<Size>? onContentSizeChanged;

  /// The D22 ssh_config import wiring (service, bookmark store, config
  /// path). Null leaves the import command unregistered; `main.dart`
  /// supplies it from the app-support directory.
  final SshConfigImportSetup? sshConfigImport;

  /// The persisted bookmark store behind the Connections surface (03 §6's
  /// `BookmarkStore` seam). Null leaves that command unregistered.
  final BookmarkRepository? bookmarks;

  /// The saved-workspace list behind `workspace.save` and the
  /// "Workspaces" submenu (02 §3). Null leaves those commands
  /// unregistered; `main.dart` supplies it from the app-support settings
  /// store.
  final WorkspaceLibrary? workspaces;

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

  /// The transfer queue behind the activity panel (02 §6, D16). Null
  /// until the engine-host transfer slice binds one — the panel mounts
  /// empty chrome rather than simulating activity.
  final AppTransferQueue? transferQueue;

  /// 07 §3.5's quit gate: consulted by the intercepted window close and
  /// by `onExitRequested` (the macOS/OS quit path), so quitting with
  /// live transfers warns and the journal flushes before either teardown
  /// is allowed. Null leaves both paths unguarded.
  final QuitGuard? quitGuard;

  /// The persisted conflict matrix (02 §5.2) the pane drop targets
  /// resolve per task at enqueue time; null applies the spec defaults.
  /// Loaded at startup once the settings slice owns the matrix.
  final ConflictPolicy? conflictPolicy;

  /// The activity panel's persisted pixel height (02 §1).
  final double initialActivityPanelHeight;
  final PaneRatioSaver? onActivityPanelHeightChanged;
  final void Function(Object, StackTrace)? onActivityPanelHeightSaveError;

  /// The persisted throttle limits seeded onto the queue's limiters.
  final int? initialDownloadLimit;
  final int? initialUploadLimit;
  final FutureOr<void> Function(int? bytesPerSecond)?
  onDownloadLimitChanged;
  final FutureOr<void> Function(int? bytesPerSecond)? onUploadLimitChanged;

  /// 02 §6's "auto-remove on success" setting (default on).
  final bool autoClearCompletedTransfers;

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
    if (!identical(oldWidget.engineSession, widget.engineSession) ||
        !identical(oldWidget.quitGuard, widget.quitGuard) ||
        !identical(
          oldWidget.sessionPersistence,
          widget.sessionPersistence,
        )) {
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
    final persistence = widget.sessionPersistence;
    final quitGuard = widget.quitGuard;
    if (session == null && persistence == null && quitGuard == null) {
      return;
    }
    _lifecycleListener = AppLifecycleListener(
      onStateChange:
          session?.forwardLifecycle ?? (_) {},
      // The framework awaits this future before exiting — the only exit
      // hook with a wait semantic, so the pending mirror writes flush
      // before the process is allowed to die. The session's shutdown
      // itself is triggered fire-and-forget (idempotent), keeping the
      // exit decision independent of teardown-path futures.
      onExitRequested: () async {
        // The quit guard rides this path too: a platform quit (⌘Q, OS
        // termination) never reaches the window's close callback, so
        // without this the journal could exit unflushed and un-warned.
        // A veto cancels the exit — the same answer the intercepted
        // close gets, sharing one in-flight decision.
        if (quitGuard != null && !await quitGuard.confirmClose()) {
          return AppExitResponse.cancel;
        }
        // Flush what is already queued before stopping the engine: the
        // tails snapshot at call time, so writes racing the shutdown
        // trigger still land first. The session document (02 §3's
        // app-quit safe point) flushes in the same bounded wait. Both
        // are best-effort — the framework awaits this future, so
        // neither a failed nor a wedged flush may block the exit.
        try {
          await Future.wait<void>([
            if (session != null) session.flushWrites(),
            if (persistence != null) persistence.flush(),
          ]).timeout(_exitFlushTimeout);
        } on Object catch (error, stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stackTrace),
          );
        }
        session?.forwardLifecycle(AppLifecycleState.detached);
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
    assert(
      widget.connectionEngine == null || widget.engineSession == null,
      'connectionEngine is a test seam; engineSession supplies its own '
      'lanes. Provide one, not both.',
    );
    final workspace = WorkspaceShell(
      initialPaneRatio: widget.initialPaneRatio,
      newTabTarget: widget.newTabTarget,
      doubleClickAction: widget.doubleClickAction,
      reconnectRestoredTabs: widget.reconnectRestoredTabs,
      restoredSession: widget.restoredSession,
      sessionPersistence: widget.sessionPersistence,
      onPaneRatioChanged: widget.onPaneRatioChanged,
      onPaneRatioSaveError: widget.onPaneRatioSaveError,
      sshConfigImport: widget.sshConfigImport,
      bookmarks: widget.bookmarks,
      workspaces: widget.workspaces,
      connectionEngine: widget.connectionEngine,
      engineSession: widget.engineSession,
      transferQueue: widget.transferQueue,
      quitGuard: widget.quitGuard,
      conflictPolicy: widget.conflictPolicy,
      initialActivityPanelHeight: widget.initialActivityPanelHeight,
      onActivityPanelHeightChanged: widget.onActivityPanelHeightChanged,
      onActivityPanelHeightSaveError:
          widget.onActivityPanelHeightSaveError,
      initialDownloadLimit: widget.initialDownloadLimit,
      initialUploadLimit: widget.initialUploadLimit,
      onDownloadLimitChanged: widget.onDownloadLimitChanged,
      onUploadLimitChanged: widget.onUploadLimitChanged,
      autoClearCompletedTransfers: widget.autoClearCompletedTransfers,
    );
    final callback = widget.onContentSizeChanged;
    if (callback == null) return workspace;

    // The desktop minimum includes native chrome around this content box.
    return ContentSizeReporter(onSize: callback, child: workspace);
  }
}
