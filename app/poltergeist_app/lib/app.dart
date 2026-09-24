import 'dart:async' show FutureOr, unawaited;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show
        BookmarkStore,
        ConflictPolicy,
        PreviewCache,
        PreviewProducer,
        defaultLargeDownloadThresholdBytes;

import 'l10n/app_localizations.dart';
import 'services/app_transfer_queue.dart';
import 'services/bookmark_backup_service.dart';
import 'services/checkout_session.dart';
import 'services/connection_state_bridge.dart';
import 'services/content_size_reporter.dart';
import 'services/double_click_action.dart';
import 'services/editor_registry_controller.dart';
import 'services/engine_session.dart';
import 'services/pane_tabs_controller.dart' show NewTabTarget;
import 'services/probe_settings_store.dart' show ProbeSettings;
import 'services/quick_look_channel.dart' show QuickLookChannel;
import 'services/quit_guard.dart';
import 'services/recent_locations.dart';
import 'services/session_persistence.dart';
import 'services/session_state.dart';
import 'services/ssh_config_import_setup.dart';
import 'services/sync_environment.dart';
import 'services/sync_queue_facade.dart';
import 'services/update_check_controller.dart';
import 'services/workspace_library.dart';
import 'theme/app_theme.dart';
import 'ui/adaptive_shell.dart';
import 'ui/inspector/inspector_view.dart' show inspectorDefaultWidth;
import 'ui/server_editor.dart' show ServerEditorDelegate;
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
    this.bookmarkBackup,
    this.serverEditor,
    this.bookmarks,
    this.workspaces,
    this.recentLocations,
    this.connectionEngine,
    this.engineSession,
    this.transferQueue,
    this.checkoutSession,
    this.editorRegistry,
    this.quitGuard,
    this.conflictPolicy,
    this.initialSidebarWidth,
    this.onSidebarWidthChanged,
    this.initialInspectorWidth,
    this.onInspectorWidthChanged,
    this.initialDownloadLimit,
    this.initialUploadLimit,
    this.onDownloadLimitChanged,
    this.onUploadLimitChanged,
    this.autoClearCompletedTransfers = true,
    this.probeSettings,
    this.initialSidebarHidden = false,
    this.onSidebarHiddenChanged,
    this.onSidebarHiddenSaveError,
    this.initialSidebarCollapsedGroups = const {},
    this.onSidebarCollapsedGroupsChanged,
    this.previewCache,
    this.previewProducer,
    this.quickLook,
    this.initialPreviewThresholdBytes =
        defaultLargeDownloadThresholdBytes,
    this.onPreviewCacheCapacityChanged,
    this.onPreviewThresholdChanged,
    this.syncEnvironment,
    this.syncTasks,
    this.updateCheck,
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

  /// The 04 §3.3 backup service behind Settings → Backup (M6). Null
  /// leaves `open-settings-backup` unregistered; `main.dart` supplies
  /// it from the app-support stores and the OS keystore.
  final BookmarkBackupService? bookmarkBackup;

  /// The server editor's application layer (04 §4.2's management
  /// verbs): add/edit on the catalog rows and the editor's own saves
  /// and test-connection route through it. Null renders the catalog
  /// read-only — the management verbs hide rather than dead-end.
  final ServerEditorDelegate? serverEditor;

  /// The persisted bookmark store behind the sidebar's favorites list
  /// (03 §6's `BookmarkStore` seam). Null unmounts the sidebar — and
  /// with it the remote entry point — so production always wires it.
  final BookmarkStore? bookmarks;

  /// The saved-workspace list behind `workspace.save` and the
  /// "Workspaces" submenu (02 §3). Null leaves those commands
  /// unregistered; `main.dart` supplies it from the app-support settings
  /// store.
  final WorkspaceLibrary? workspaces;

  /// Quick Open's Recents source (02 §8.4): the device-local store the
  /// panes' location-commit hook feeds, flushed at the app-quit safe
  /// point. Null drops the palette's Recents section only.
  final RecentLocationsStore? recentLocations;

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

  /// The managed-checkout session (06 §3, M7): the future editor UI's
  /// service seam — durable store, watch/reconcile, and the explicit
  /// upload-on-save verb routed through the composed queue. Its resume
  /// reconcile rides this app's lifecycle listener. Null leaves the
  /// checkout surface absent (queue-less boots compose no session).
  final CheckoutSession? checkoutSession;

  /// The external-editor registry owner (06 §4.1): the Open With ▸
  /// submenu's source of configured editors and the persisted home of
  /// user choices. Null leaves the registry surface unwired (tests and
  /// settings-less boots).
  final EditorRegistryController? editorRegistry;

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
  /// D32's persisted region widths (10 §3.1); null boots the defaults.
  final double? initialSidebarWidth;
  final FutureOr<void> Function(double width)? onSidebarWidthChanged;
  final double? initialInspectorWidth;
  final FutureOr<void> Function(double width)? onInspectorWidthChanged;

  /// The persisted throttle limits seeded onto the queue's limiters.
  final int? initialDownloadLimit;
  final int? initialUploadLimit;
  final FutureOr<void> Function(int? bytesPerSecond)?
  onDownloadLimitChanged;
  final FutureOr<void> Function(int? bytesPerSecond)? onUploadLimitChanged;

  /// 02 §6's "auto-remove on success" setting (default on).
  final bool autoClearCompletedTransfers;

  /// The device-local probe-settings seam behind the sidebar's
  /// reachability owner (02 §4). Null leaves every favorite dot at
  /// honest unknown — `main.dart` supplies the settings.json-backed
  /// store.
  final ProbeSettings? probeSettings;

  /// The persisted sidebar-visibility intent and its save sinks
  /// (02 §1; see [WorkspaceShell.initialSidebarHidden]).
  final bool initialSidebarHidden;
  final FutureOr<void> Function(bool hidden)? onSidebarHiddenChanged;
  final void Function(Object error, StackTrace stackTrace)?
  onSidebarHiddenSaveError;

  /// The persisted collapsed-group keys and their save sink (02 §4's
  /// device-local expansion state).
  final Set<String> initialSidebarCollapsedGroups;
  final void Function(Set<String> keys)? onSidebarCollapsedGroupsChanged;

  /// 06 §5.3's preview cache behind the whole preview slice — null
  /// composes no preview session (Space falls through, the preview
  /// commands stay disabled). `main.dart` supplies the app-support
  /// `preview-cache/` store seeded with the persisted cap.
  final PreviewCache? previewCache;

  /// The §5.3 remote-production seam — a `QueuePreviewProducer` over
  /// the composed queue in production (D14); null leaves remote
  /// previews promptless-disabled while local ones still render.
  final PreviewProducer? previewProducer;

  /// The macOS Quick Look channel seam (06 §5.1) — injectable for
  /// tests; null binds the real method channel.
  final QuickLookChannel? quickLook;

  /// The persisted §8 large-download threshold (default 100 MiB) and
  /// the §8 settings section's persist sinks.
  final int initialPreviewThresholdBytes;
  final FutureOr<void> Function(int bytes)? onPreviewCacheCapacityChanged;
  final FutureOr<void> Function(int bytes)? onPreviewThresholdChanged;

  /// The 05 sync seams (M8): the environment plan-view sessions draw
  /// filesystems/state/journals from, and the activity-panel registry
  /// their runs report through. Both come from `main.dart`'s
  /// composition; null unregisters the sync commands.
  final SyncEnvironment? syncEnvironment;
  final SyncQueueTasks? syncTasks;

  /// The D19 update check's session state (07 §3.10): non-null mounts
  /// the link-only banner when a newer release exists and registers
  /// `app.settings` for the opt-out toggle. Null leaves both unwired.
  final UpdateCheckController? updateCheck;

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
    final engineSwapped =
        !identical(oldWidget.engineSession, widget.engineSession);
    if (engineSwapped ||
        !identical(oldWidget.quitGuard, widget.quitGuard) ||
        !identical(
          oldWidget.sessionPersistence,
          widget.sessionPersistence,
        )) {
      // The outgoing session's engine must not outlive its replacement
      // unnoticed — forward the exit state before re-attaching, but only
      // when the engine itself is swapped; a guard/persistence rebind
      // keeps the same session alive.
      if (engineSwapped) {
        oldWidget.engineSession?.forwardLifecycle(AppLifecycleState.detached);
      }
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
    final checkouts = widget.checkoutSession;
    if (session == null &&
        persistence == null &&
        quitGuard == null &&
        checkouts == null) {
      return;
    }
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        session?.forwardLifecycle(state);
        // 06 §3.3's reconcile-on-resume: every foreground transition
        // rehashes the managed checkouts and repairs degraded
        // snapshots — the designed fallback when a watcher missed
        // events while the app sat backgrounded.
        if (state == AppLifecycleState.resumed && checkouts != null) {
          unawaited(
            checkouts.reconcileOnResume().catchError((
              Object error,
              StackTrace stackTrace,
            ) {
              FlutterError.reportError(
                FlutterErrorDetails(exception: error, stack: stackTrace),
              );
            }),
          );
        }
      },
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
            // 02 §8.4's recents share the safe point: a debounced write
            // still pending at quit must land before the window dies.
            if (widget.recentLocations != null) widget.recentLocations!.flush(),
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
      // D32: the shell draws under the transparent macOS titlebar (the
      // full-size content view) and insets itself for the traffic
      // lights — no blank titlebar band above the header.
      home: _buildWorkspace(),
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
      bookmarkBackup: widget.bookmarkBackup,
      serverEditor: widget.serverEditor,
      bookmarks: widget.bookmarks,
      workspaces: widget.workspaces,
      recentLocations: widget.recentLocations,
      connectionEngine: widget.connectionEngine,
      engineSession: widget.engineSession,
      transferQueue: widget.transferQueue,
      checkoutSession: widget.checkoutSession,
      editorRegistry: widget.editorRegistry,
      quitGuard: widget.quitGuard,
      conflictPolicy: widget.conflictPolicy,
      initialSidebarWidth: widget.initialSidebarWidth ?? sidebarDefaultWidth,
      onSidebarWidthChanged: widget.onSidebarWidthChanged,
      initialInspectorWidth:
          widget.initialInspectorWidth ?? inspectorDefaultWidth,
      onInspectorWidthChanged: widget.onInspectorWidthChanged,
      initialDownloadLimit: widget.initialDownloadLimit,
      initialUploadLimit: widget.initialUploadLimit,
      onDownloadLimitChanged: widget.onDownloadLimitChanged,
      onUploadLimitChanged: widget.onUploadLimitChanged,
      autoClearCompletedTransfers: widget.autoClearCompletedTransfers,
      probeSettings: widget.probeSettings,
      initialSidebarHidden: widget.initialSidebarHidden,
      onSidebarHiddenChanged: widget.onSidebarHiddenChanged,
      onSidebarHiddenSaveError: widget.onSidebarHiddenSaveError,
      initialSidebarCollapsedGroups: widget.initialSidebarCollapsedGroups,
      onSidebarCollapsedGroupsChanged:
          widget.onSidebarCollapsedGroupsChanged,
      previewCache: widget.previewCache,
      previewProducer: widget.previewProducer,
      quickLook: widget.quickLook,
      initialPreviewThresholdBytes: widget.initialPreviewThresholdBytes,
      onPreviewCacheCapacityChanged:
          widget.onPreviewCacheCapacityChanged,
      onPreviewThresholdChanged: widget.onPreviewThresholdChanged,
      syncEnvironment: widget.syncEnvironment,
      syncTasks: widget.syncTasks,
      updateCheck: widget.updateCheck,
    );
    final callback = widget.onContentSizeChanged;
    if (callback == null) return workspace;

    // The desktop minimum includes native chrome around this content box.
    return ContentSizeReporter(onSize: callback, child: workspace);
  }
}
