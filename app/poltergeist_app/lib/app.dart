import 'dart:async' show FutureOr;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
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
import 'services/app_session_lifecycle.dart';
import 'services/app_transfer_queue.dart';
import 'services/bookmark_backup_service.dart';
import 'services/checkout_prompt_ledger.dart';
import 'services/checkout_session.dart';
import 'services/connection_state_bridge.dart';
import 'services/content_size_reporter.dart';
import 'services/double_click_action.dart';
import 'services/drag_out_producer.dart' show DragOutProducer;
import 'services/editor_registry_controller.dart';
import 'services/engine_session.dart';
import 'services/os_drag_out.dart' show DragOutBackend;
import 'services/pane_tabs_controller.dart' show NewTabTarget;
import 'services/probe_settings_store.dart' show ProbeSettings;
import 'services/quick_look_channel.dart' show QuickLookChannel;
import 'services/quit_guard.dart';
import 'services/recent_locations.dart';
import 'services/session_persistence.dart';
import 'services/session_state.dart';
import 'services/settings_models.dart' show AppearanceSettingsModel;
import 'services/settings_window/settings_window_host.dart';
import 'services/sidebar_controller.dart'
    show CollapsedSectionWriter, PinnedServerWriter, SidebarDensity;
import 'services/sidebar_probe_owner.dart';
import 'services/ssh_config_import_setup.dart';
import 'services/sync_environment.dart';
import 'services/sync_queue_facade.dart';
import 'services/transfer_limits_controller.dart';
import 'services/update_check_controller.dart';
import 'services/workspace_library.dart';
import 'services/workspace_windows/workspace_windows.dart';
import 'theme/app_appearance.dart';
import 'theme/app_theme.dart';
import 'ui/adaptive_shell.dart';
import 'ui/inspector/inspector_view.dart' show inspectorDefaultWidth;
import 'ui/server_editor.dart' show ServerEditorDelegate;
import 'ui/shell/macos_toolbar_band.dart';
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
    this.transferLimits,
    this.autoClearCompletedTransfers = true,
    this.probeSettings,
    this.initialSidebarHidden = false,
    this.initialInspectorHidden = false,
    this.onSidebarHiddenChanged,
    this.onSidebarHiddenSaveError,
    this.initialSidebarCollapsedGroups = const {},
    this.onSidebarCollapsedGroupsChanged,
    this.initialSidebarDensity = SidebarDensity.comfortable,
    this.onSidebarDensityChanged,
    this.initialSidebarPinnedServers = const {},
    this.onSidebarPinnedServersChanged,
    this.previewCache,
    this.previewProducer,
    this.dragOutProducer,
    this.dragOutBackend,
    this.quickLook,
    this.initialPreviewThresholdBytes =
        defaultLargeDownloadThresholdBytes,
    this.onPreviewCacheCapacityChanged,
    this.onPreviewThresholdChanged,
    this.syncEnvironment,
    this.syncTasks,
    this.updateCheck,
    this.settingsWindow,
    this.toolbarBand,
    this.window,
    this.probeOwner,
    this.previewThreshold,
    this.checkoutPrompts,
    this.appearance,
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

  /// D37's per-server transfer caps, already bound to the queue; the
  /// Activity panel's popover sets their default.
  final TransferLimitsController? transferLimits;

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

  /// The inspector's seed with no restored session (see
  /// [WorkspaceShell.initialInspectorHidden]).
  final bool initialInspectorHidden;
  final FutureOr<void> Function(bool hidden)? onSidebarHiddenChanged;
  final void Function(Object error, StackTrace stackTrace)?
  onSidebarHiddenSaveError;

  /// The persisted collapsed-group keys and their save sink (02 §4's
  /// device-local expansion state).
  final Set<String> initialSidebarCollapsedGroups;
  final CollapsedSectionWriter? onSidebarCollapsedGroupsChanged;

  /// The persisted sidebar row density and its save sink (D33).
  final SidebarDensity initialSidebarDensity;
  final void Function(SidebarDensity density)? onSidebarDensityChanged;

  /// The persisted PINNED shortlist and its save sink (D33).
  final Set<String> initialSidebarPinnedServers;
  final PinnedServerWriter? onSidebarPinnedServersChanged;

  /// 06 §5.3's preview cache behind the whole preview slice — null
  /// composes no preview session (Space falls through, the preview
  /// commands stay disabled). `main.dart` supplies the app-support
  /// `preview-cache/` store seeded with the persisted cap.
  final PreviewCache? previewCache;

  /// The §5.3 remote-production seam — a `QueuePreviewProducer` over
  /// the composed queue in production (D14); null leaves remote
  /// previews promptless-disabled while local ones still render.
  final PreviewProducer? previewProducer;

  /// OS drag-out's remote-file seam (00 D14's drag-out amendment): a
  /// `QueueDragOutProducer` over the same produce hook in production;
  /// null leaves remote rows without file promises.
  final DragOutProducer? dragOutProducer;

  /// The native drag-out session (`poltergeist/dragout`); null
  /// composes none, so a row drag that leaves the window just ends.
  final DragOutBackend? dragOutBackend;

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

  /// The desktop Settings window (see [WorkspaceShell.settingsWindow]).
  final SettingsWindowHost? settingsWindow;

  /// Whether the macOS toolbar band is showing (`MacosToolbarBandChannel`
  /// in production): false in full screen, where the layout drops the
  /// band's reservation and the traffic-light inset. Null keeps the
  /// windowed layout.
  final ValueListenable<bool>? toolbarBand;

  /// The workspace window this app renders (00 D39), or null for the
  /// single-window app. A window's app takes its navigator and messenger
  /// from the window and leaves the app lifecycle to the windows root,
  /// which owns the one listener for every window.
  final WorkspaceWindow? window;

  /// App-wide state the windows share (see the same fields on
  /// [WorkspaceShell]): borrowed, so a closing window's shell never
  /// disposes them; null lets a single-window shell own its own.
  final SidebarProbeOwner? probeOwner;
  final ValueNotifier<int>? previewThreshold;
  final CheckoutPromptLedger? checkoutPrompts;

  /// This device's theme: what the app is drawn in, and the model behind
  /// Settings → Appearance. Null draws the default theme and leaves the
  /// section out.
  final AppearanceSettingsModel? appearance;

  /// The prompt coordinator and other dialog owners show through this key;
  /// null keeps the default navigator. The session's coordinator and the
  /// [MaterialApp] must share one key: dialogs render on this navigator.
  /// With [window] set, the MaterialApp takes the window's own key and
  /// this is the windows' proxy, which answers for the active window's.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Root snack-bar surface for transient notices (vault-save failures).
  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  @override
  State<PoltergeistApp> createState() => _PoltergeistAppState();
}

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

  /// The app's lifecycle listener (`attachAppSessionLifecycle`), unless
  /// this app is one window of several, whose root owns it.
  void _attachSessionLifecycle() {
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    if (widget.window != null) return;
    _lifecycleListener = attachAppSessionLifecycle(
      session: widget.engineSession,
      persistence: widget.sessionPersistence,
      quitGuard: widget.quitGuard,
      checkouts: widget.checkoutSession,
      recentLocations: widget.recentLocations,
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
    // Built once here, outside the theme's builder, which then only swaps
    // the MaterialApp's themes: the workspace keeps its state through a
    // re-theme, and is not rebuilt for one.
    final home = ClaimMacosToolbarBand(child: _buildWorkspace());
    final appearance = widget.appearance;
    if (appearance == null) return _app(AppAppearance.initial, home);
    // Rebuilt for a theme change and nothing else: the appearance moves
    // only when Settings → Appearance writes.
    return ValueListenableBuilder<AppAppearance>(
      valueListenable: appearance,
      builder: (context, value, _) => _app(value, home),
    );
  }

  Widget _app(AppAppearance appearance, Widget home) {
    final themes = poltergeistThemesFor(appearance);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: widget.window?.navigatorKey ?? widget.navigatorKey,
      scaffoldMessengerKey:
          widget.window?.scaffoldMessengerKey ?? widget.scaffoldMessengerKey,
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      theme: themes.theme,
      darkTheme: themes.darkTheme,
      themeMode: themes.themeMode,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      // macOS: every route, dialog, and root-overlay toast keeps its
      // controls below the unified toolbar band, which claims clicks
      // for window drag...
      builder: (context, child) {
        final reserved = ReserveMacosToolbarBand(child: child!);
        final band = widget.toolbarBand;
        if (band == null) return reserved;
        return MacosToolbarBandScope(band: band, child: reserved);
      },
      // ...except the shell, which draws under the transparent titlebar
      // (the full-size content view), passes its header controls
      // through, and insets itself for the traffic lights, leaving no
      // blank titlebar band above the header (D32).
      home: home,
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
      transferLimits: widget.transferLimits,
      autoClearCompletedTransfers: widget.autoClearCompletedTransfers,
      probeSettings: widget.probeSettings,
      initialSidebarHidden: widget.initialSidebarHidden,
      initialInspectorHidden: widget.initialInspectorHidden,
      onSidebarHiddenChanged: widget.onSidebarHiddenChanged,
      onSidebarHiddenSaveError: widget.onSidebarHiddenSaveError,
      initialSidebarCollapsedGroups: widget.initialSidebarCollapsedGroups,
      onSidebarCollapsedGroupsChanged:
          widget.onSidebarCollapsedGroupsChanged,
      initialSidebarDensity: widget.initialSidebarDensity,
      onSidebarDensityChanged: widget.onSidebarDensityChanged,
      initialSidebarPinnedServers: widget.initialSidebarPinnedServers,
      onSidebarPinnedServersChanged: widget.onSidebarPinnedServersChanged,
      previewCache: widget.previewCache,
      previewProducer: widget.previewProducer,
      dragOutProducer: widget.dragOutProducer,
      dragOutBackend: widget.dragOutBackend,
      quickLook: widget.quickLook,
      initialPreviewThresholdBytes: widget.initialPreviewThresholdBytes,
      onPreviewCacheCapacityChanged:
          widget.onPreviewCacheCapacityChanged,
      onPreviewThresholdChanged: widget.onPreviewThresholdChanged,
      syncEnvironment: widget.syncEnvironment,
      syncTasks: widget.syncTasks,
      updateCheck: widget.updateCheck,
      settingsWindow: widget.settingsWindow,
      window: widget.window,
      probeOwner: widget.probeOwner,
      previewThreshold: widget.previewThreshold,
      checkoutPrompts: widget.checkoutPrompts,
      appearance: widget.appearance,
    );
    final callback = widget.onContentSizeChanged;
    if (callback == null) return workspace;

    // The desktop minimum includes native chrome around this content box.
    return ContentSizeReporter(onSize: callback, child: workspace);
  }
}
