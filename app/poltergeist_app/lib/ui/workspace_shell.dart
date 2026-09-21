import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/activity_panel_controller.dart';
import '../services/app_lifecycle_forwarder.dart';
import '../services/app_preferences.dart' show minActivityPanelHeight;
import '../services/app_transfer_queue.dart';
import '../services/application_error_reporter.dart';
import '../services/bookmark_backup_service.dart';
import '../services/checkout_session.dart';
import '../services/connection_state_bridge.dart';
import '../services/connection_status_controller.dart';
import '../services/double_click_action.dart';
import '../services/editor_registry_controller.dart';
import '../services/engine_session.dart';
import '../services/external_file_opener.dart';
import '../services/pane_controller.dart';
import '../services/pane_drop.dart';
import '../services/pane_tabs_controller.dart';
import '../services/probe_settings_store.dart';
import '../services/quit_guard.dart';
import '../services/registered_command.dart';
import '../services/session_persistence.dart';
import '../services/session_state.dart';
import '../services/sidebar_controller.dart';
import '../services/sidebar_probe_owner.dart';
import '../services/ssh_config_import_setup.dart';
import '../services/sync_browsing_controller.dart';
import '../services/workspace_controller.dart';
import '../services/workspace_library.dart';
import '../services/workspace_state.dart';
import '../theme/app_theme.dart' show poltergeistMonoFontFamilies;
import 'activity/activity_commands.dart';
import 'activity/activity_format.dart';
import 'activity/activity_panel.dart';
import 'adaptive_shell.dart';
import 'built_in_text_editor.dart';
import 'import/ssh_config_import_command.dart';
import 'layout/pane_allocation.dart';
import 'menus/app_menu_host.dart';
import 'panes/open_with_commands.dart';
import 'panes/pane_commands.dart';
import 'panes/pane_format.dart' show paneUnevaluated;
import 'panes/pane_tabs_view.dart';
import 'panes/sync_browse_chip.dart';
import 'settings/backup_settings_command.dart';
import 'sidebar/sidebar_view.dart';
import 'top_toast.dart';
import 'workspace/workspace_commands.dart';

/// The inline sidebar's width (02 §1: default 240, min 200, max 320 —
/// the sidebar↔panes splitter and its persisted width land with the
/// layout-splitter slice; a fixed default keeps this slice honest).
const _sidebarWidth = 240.0;

/// The production two-pane shell (02 §1): toolbar over the registered
/// commands (D21), the global sidebar of 02 §4 inline at stage 0 and in
/// the overlay drawer below it, the pane pair in the M1 adaptive shell
/// with its persisted splitter ratio, and the status bar. The M2
/// interim Connections surface is gone — the sidebar's fixed
/// Connections section and the favorites list are the remote entry
/// points, each row opening in the pane 02 §4's rules resolve.
class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({
    super.key,
    this.initialPaneRatio = 0.5,
    this.newTabTarget = NewTabTarget.duplicate,
    this.doubleClickAction = DoubleClickAction.open,
    this.reconnectRestoredTabs = true,
    this.restoredSession,
    this.sessionPersistence,
    this.onPaneRatioChanged,
    this.onPaneRatioSaveError,
    this.sshConfigImport,
    this.bookmarkBackup,
    this.bookmarks,
    this.workspaces,
    this.connectionEngine,
    this.engineSession,
    this.transferQueue,
    this.checkoutSession,
    this.editorRegistry,
    this.externalOpener = const ExternalFileOpener(),
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
    this.probeSettings,
    this.initialSidebarHidden = false,
    this.onSidebarHiddenChanged,
    this.onSidebarHiddenSaveError,
    this.initialSidebarCollapsedGroups = const {},
    this.onSidebarCollapsedGroupsChanged,
  });

  final double initialPaneRatio;

  /// The persisted "New tabs open" preference (02 §2.1) seeding each
  /// strip's live [PaneTabsController.newTabTarget] — read at every
  /// `tab.new`; the settings slice writes the field (and persists it)
  /// after construction.
  final NewTabTarget newTabTarget;

  /// The persisted "Double-click action" preference (02 §2.6) seeding
  /// each strip's live [PaneTabsController.doubleClickAction] — read at
  /// every file open; the settings slice writes the field (and persists
  /// it) after construction.
  final DoubleClickAction doubleClickAction;

  /// The persisted "Reconnect restored tabs automatically" setting
  /// (02 §3) seeding each strip's live
  /// [PaneTabsController.reconnectRestoredTabs] — read when a
  /// session-restored remote tab activates.
  final bool reconnectRestoredTabs;

  /// The persisted session document (02 §3's launch restoration);
  /// consumed on the FIRST workspace build only — an engine-session
  /// rebind later rebuilds the strips fresh rather than replaying the
  /// launch document over live state. Null boots the default two-tab
  /// layout.
  final SessionState? restoredSession;

  /// 02 §3's safe-point writer: attached to the live workspace so tab
  /// open/close/switch, navigation commits, and the pane toggle land on
  /// disk; null leaves session persistence unwired (test surfaces).
  /// Same identity-stability contract as [bookmarks].
  final SessionPersistence? sessionPersistence;

  final PaneRatioSaver? onPaneRatioChanged;
  final void Function(Object, StackTrace)? onPaneRatioSaveError;

  /// The D22 ssh_config import wiring; null leaves the command
  /// unregistered (tests and alternate boot paths stay opted out).
  final SshConfigImportSetup? sshConfigImport;

  /// The 04 §3.3 backup service behind `open-settings-backup` (M6).
  /// Null leaves the command unregistered — tests and engine-less boots
  /// opt out.
  final BookmarkBackupService? bookmarkBackup;

  /// The persisted bookmark store behind the sidebar's favorites and
  /// Connections sections (03 §6's `BookmarkStore` seam). Null unmounts
  /// the sidebar entirely — there is no remote entry point without it.
  ///
  /// Callers must pass a stable instance across rebuilds: the shell keys
  /// its controller lifecycles on seam identity, so a fresh wrapper per
  /// rebuild would churn watches and drop the loaded lists.
  final BookmarkStore? bookmarks;

  /// The saved-workspace list behind `workspace.save` and the
  /// "Workspaces" submenu (02 §3, M3 slice). Null leaves those commands
  /// unregistered (tests and alternate boot paths stay opted out). Same
  /// identity-stability contract as [bookmarks]: the shell subscribes
  /// once per seam instance so a save or open re-derives the submenu.
  final WorkspaceLibrary? workspaces;

  /// The engine's connection-state lanes; null while no production engine
  /// exists, which leaves every listed server without live truth rather
  /// than guessing at it. Same identity-stability contract as
  /// [bookmarks].
  final ConnectionStateBridge? connectionEngine;

  /// The app's long-lived production engine session (startup
  /// composition): its lanes feed the Connections surface, its pane lanes
  /// drive both panes, its coordinator answers prompts from any surface,
  /// and its review seam leads a blocked row to the changed-key dialog.
  /// Null leaves those unwired (tests and alternate boot paths).
  final EngineSession? engineSession;

  /// The transfer queue behind the activity panel (02 §6, D16): the
  /// app-facing seam, never the concrete core queue. Null mounts the
  /// panel chrome empty — production wiring lands with the engine-host
  /// transfer slice; the panel's verbs stay reachable-but-disabled, and
  /// `queue.togglePause` still registers (D21).
  final AppTransferQueue? transferQueue;

  /// The managed-checkout session (06 §3, M7) — the seam the future
  /// editor surfaces (built-in editor, external-editor saves, the
  /// §3.7 recovered-edit review) will consume. Nothing renders it yet;
  /// the shell carries it so those surfaces bind the same instance
  /// without re-plumbing composition. Null leaves checkout verbs
  /// unwired (queue-less boots compose no session). Same
  /// identity-stability contract as [bookmarks].
  final CheckoutSession? checkoutSession;

  /// The external-editor registry owner (06 §4.1): feeds the Open With ▸
  /// submenu's compatible rows, the Open verb's `effectiveDefaultFor`
  /// resolution, and the `Other…` pick's persistence. Null leaves the
  /// registry surface unwired — the submenu still offers the reserved
  /// selectors and the pick registers nothing.
  final EditorRegistryController? editorRegistry;

  /// The launch seam (06 §4.3): channel/executable launches behind the
  /// injectable opener — tests script it so no editor process spawns.
  final ExternalFileOpener externalOpener;

  /// 07 §3.5's quit gate: the shell binds its live [transferQueue]
  /// lookup onto the guard so the intercepted close can warn and flush
  /// the journal — the queue stays behind the app services layer
  /// (widgets never name the engine's queue).
  final QuitGuard? quitGuard;

  /// The persisted conflict matrix (02 §5.2) the pane drop targets
  /// resolve per task at enqueue time; null applies the spec defaults
  /// (ask on every bucket). The settings writer lands with the
  /// settings slice — until then the default keeps the ask-park flow.
  final ConflictPolicy? conflictPolicy;

  /// The activity panel's persisted pixel height (02 §1's third
  /// splitter): default 200, floor 120, capped at half the window in
  /// the splitter's resize path.
  final double initialActivityPanelHeight;
  final PaneRatioSaver? onActivityPanelHeightChanged;
  final void Function(Object, StackTrace)? onActivityPanelHeightSaveError;

  /// The persisted throttle choices seeded onto the queue's limiters
  /// (02 §6's "persisted"); null is unlimited.
  final int? initialDownloadLimit;
  final int? initialUploadLimit;

  /// Persist sinks for the popover's writes — the limiter takes the
  /// value immediately; these land it in settings.
  final FutureOr<void> Function(int? bytesPerSecond)? onDownloadLimitChanged;
  final FutureOr<void> Function(int? bytesPerSecond)? onUploadLimitChanged;

  /// 02 §6's "auto-remove on success" setting (default on).
  final bool autoClearCompletedTransfers;

  /// The device-local probe-settings seam behind the sidebar's
  /// reachability owner (02 §4): supplies the per-favorite facts the
  /// probe policy reads and writes. Null leaves every server-backed
  /// favorite at honest `unknown` — no probe wiring at all (tests,
  /// alternate boot paths). Same identity-stability contract as
  /// [bookmarks].
  final ProbeSettings? probeSettings;

  /// The persisted sidebar-visibility intent (02 §1's persistence
  /// list): only an explicit `view.toggleSidebar` on the desktop stage
  /// writes it — the stage-1 drawer collapse recomputes from window
  /// width and never lands here.
  final bool initialSidebarHidden;
  final FutureOr<void> Function(bool hidden)? onSidebarHiddenChanged;
  final void Function(Object error, StackTrace stackTrace)?
  onSidebarHiddenSaveError;

  /// The persisted collapsed-group keys the sidebar re-opens with
  /// (02 §4: collapse state is device-local, 04 §2.3) and their save
  /// sink — null leaves collapse memory in-process.
  final Set<String> initialSidebarCollapsedGroups;
  final void Function(Set<String> keys)? onSidebarCollapsedGroupsChanged;

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  bool _commandSessionActive = false;

  /// 03 §6's app-wide `ConnectionStatus`: one per window root, owned here so
  /// its watches die with the shell. The sidebar's Connections section and
  /// the favorite badges' live-truth half both consume this instance (02 §4:
  /// pool state, never probe state, on the Connections rows).
  ConnectionStatusController? _connections;

  /// 02 §4's sidebar controllers: the favorites sections plus collapse and
  /// store-routed mutations ([_sidebar]), and the reachability owner behind
  /// the favorite badge dots ([_probes]). Both rebuild on seam swaps like
  /// [_connections].
  SidebarController? _sidebar;
  SidebarProbeOwner? _probes;

  /// The lifecycle forwarder feeding [_probes] (02 §4's foreground
  /// gating): owned by the shell so probe activity dies with the window.
  /// The engine session gets its own forwarding in the app composition —
  /// this lane serves the probe owner only.
  AppLifecycleForwarder? _lifecycleForwarder;
  AppLifecycleState? _lifecycleState;

  /// The shell's Scaffold: `view.toggleSidebar` opens its drawer below
  /// the stage-0 boundary (02 §1's stage-1 collapse).
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// The pane pair and active pane (03 §6's WorkspaceController, foundation
  /// slice) plus the per-pane listing focus nodes (02 §8.2). Rebuilt when
  /// the engine session identity changes; the panes rebind their initial
  /// location with the new lanes.
  WorkspaceController? _workspace;
  FocusNode? _leftFocus;
  FocusNode? _rightFocus;

  /// The activity panel's state owner (02 §6): session-independent —
  /// a workspace rebuild rebinds panes, not the queue mirror — so it
  /// lives on the shell state, not inside [_buildWorkspace].
  late final ActivityPanelController _activity;
  late final FocusNode _activitySplitterFocus;
  double _activityPanelHeight = 0;

  /// The live queue seam the quit guard reads — a lookup, not a
  /// snapshot, so a didUpdateWidget rebind is always seen.
  AppTransferQueue? _quitGuardQueue() => widget.transferQueue;

  /// 06 §3.3's dirty-prompt guards: record ids already toasted (one
  /// prompt per dirty edge — an expired toast never re-fires; the
  /// persistent indicators are the §3.7 review surface's slice), and
  /// `serverId|remotePath` keys with an upload in flight, so a built-in
  /// save-and-upload racing the watcher never shows a stale prompt.
  final _promptedDirtyCheckouts = <String>{};
  final _uploadingCheckoutKeys = <String>{};
  CheckoutSession? _checkoutListener;

  static String _checkoutKey(ManagedRemoteFile record) =>
      '${record.serverId}|${record.remotePath}';

  @override
  void initState() {
    super.initState();
    // Focus nodes are session-independent: a session rebind replaces
    // only the pane controllers, so focus (and its pane activation)
    // survives the swap instead of dropping to the root scope and being
    // re-claimed by the left pane.
    _leftFocus = FocusNode(debugLabel: 'pane.left.listing');
    _rightFocus = FocusNode(debugLabel: 'pane.right.listing');
    _activitySplitterFocus = FocusNode(debugLabel: 'activity.panel.splitter');
    _activityPanelHeight = widget.initialActivityPanelHeight;
    _activity = ActivityPanelController(
      queue: widget.transferQueue,
      autoClearCompleted: widget.autoClearCompletedTransfers,
      downloadLimit: widget.initialDownloadLimit,
      uploadLimit: widget.initialUploadLimit,
      persistDownloadLimit: widget.onDownloadLimitChanged,
      persistUploadLimit: widget.onUploadLimitChanged,
      onError: ApplicationErrorReporter().report,
      // D16's anti-hiding rule made concrete: the first live task
      // re-opens the chrome — the panel's rows are the queue's only
      // window, so new work must never sit behind a hidden panel.
      onTasksArrived: () => _workspace?.setActivityPanelHidden(false),
    );
    _connections = _buildConnections();
    _sidebar = _buildSidebar();
    _probes = _buildProbes();
    _attachLifecycle();
    _buildWorkspace();
    widget.workspaces?.addListener(_onWorkspacesChanged);
    widget.quitGuard?.bindQueue(_quitGuardQueue);
    _attachCheckoutSession(widget.checkoutSession);
  }

  /// The §3.3 watcher's app-side surface: the session re-publishes on
  /// every record change and the scan raises the upload prompt for
  /// copies an external editor just marked dirty.
  void _attachCheckoutSession(CheckoutSession? session) {
    if (identical(_checkoutListener, session)) return;
    _checkoutListener?.removeListener(_scanDirtyCheckouts);
    _checkoutListener = session;
    session?.addListener(_scanDirtyCheckouts);
  }

  /// The command list is built in [build] — a workspace save or open
  /// must rebuild so the Workspaces submenu re-derives its rows.
  void _onWorkspacesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(WorkspaceShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The composition root supplies the store once but may supply the
    // engine later (the startup-wiring flow mounts the shell before any
    // engine exists); a replacement of any seam must not leave the
    // surface listing the previous store's bookmarks or a dead engine
    // lane — the session's lanes feed this surface too.
    if (!identical(oldWidget.bookmarks, widget.bookmarks) ||
        !identical(oldWidget.connectionEngine, widget.connectionEngine) ||
        !identical(oldWidget.engineSession, widget.engineSession)) {
      _connections?.dispose();
      _connections = _buildConnections();
    }
    // The sidebar controller keys on the store, the engine session, and
    // the collapse seams: a store swap must not leave the list reading
    // the previous store (the same posture as [_connections]), and a
    // session swap re-runs the reload that re-seeds the rebuilt probe
    // owner's favorite set.
    if (!identical(oldWidget.bookmarks, widget.bookmarks) ||
        !identical(oldWidget.engineSession, widget.engineSession) ||
        !identical(
          oldWidget.initialSidebarCollapsedGroups,
          widget.initialSidebarCollapsedGroups,
        ) ||
        !identical(
          oldWidget.onSidebarCollapsedGroupsChanged,
          widget.onSidebarCollapsedGroupsChanged,
        )) {
      _sidebar?.dispose();
      _sidebar = _buildSidebar();
    }
    // The probe owner keys on the engine's bridge and the settings seam.
    // A rebuilt owner re-hears the last lifecycle state so probes do not
    // silently resume while the app sits backgrounded.
    if (!identical(oldWidget.engineSession, widget.engineSession) ||
        !identical(oldWidget.probeSettings, widget.probeSettings)) {
      _probes?.dispose();
      _probes = _buildProbes();
      _probes?.forwardLifecycle(_lifecycleState);
      // A settings-only seam swap leaves the sidebar (and its reload)
      // untouched, so onBookmarksChanged never re-seeds this owner —
      // sync the live favorite set here (an engine swap re-seeds via
      // the sidebar reload too; syncFavorites is a reconcile, not an
      // append, so the second seeding is a no-op).
      _probes?.syncFavorites(_sidebar?.bookmarks ?? const []);
    }
    if (!identical(oldWidget.engineSession, widget.engineSession)) {
      // Carry the sidebar's live hidden intent across the workspace
      // rebuild: the flag lives on the workspace, so a session swap
      // would otherwise silently re-show a sidebar the user hid.
      _sidebarHiddenCarry = _workspace?.sidebarHidden;
      _workspace?.dispose();
      _workspace = null;
      _buildWorkspace();
    }
    if (!identical(oldWidget.transferQueue, widget.transferQueue)) {
      // A later-arriving queue seam rebinds the mirror; the persisted
      // limits re-apply inside the setter.
      _activity.queue = widget.transferQueue;
    }
    // The settings slice writes the strips' live newTabTarget directly;
    // this sync only covers a parent rebuild with a changed seed, which
    // can never clobber the settings writer — it fires solely on an
    // actual widget-parameter change.
    if (widget.newTabTarget != oldWidget.newTabTarget) {
      _workspace?.left.newTabTarget = widget.newTabTarget;
      _workspace?.right.newTabTarget = widget.newTabTarget;
    }
    // Same contract for the file-open preference: a changed seed syncs
    // both strips' live value without clobbering the settings writer.
    if (widget.doubleClickAction != oldWidget.doubleClickAction) {
      _workspace?.left.doubleClickAction = widget.doubleClickAction;
      _workspace?.right.doubleClickAction = widget.doubleClickAction;
    }
    // And for the restored-tab reconnect setting (02 §3).
    if (widget.reconnectRestoredTabs != oldWidget.reconnectRestoredTabs) {
      _workspace?.left.reconnectRestoredTabs = widget.reconnectRestoredTabs;
      _workspace?.right.reconnectRestoredTabs = widget.reconnectRestoredTabs;
    }
    if (!identical(oldWidget.workspaces, widget.workspaces)) {
      oldWidget.workspaces?.removeListener(_onWorkspacesChanged);
      widget.workspaces?.addListener(_onWorkspacesChanged);
    }
    if (!identical(oldWidget.quitGuard, widget.quitGuard)) {
      oldWidget.quitGuard?.unbindQueue(_quitGuardQueue);
      widget.quitGuard?.bindQueue(_quitGuardQueue);
    }
    _attachCheckoutSession(widget.checkoutSession);
  }

  @override
  void dispose() {
    widget.workspaces?.removeListener(_onWorkspacesChanged);
    widget.quitGuard?.unbindQueue(_quitGuardQueue);
    _attachCheckoutSession(null);
    _lifecycleForwarder?.detach();
    _probes?.dispose();
    _sidebar?.dispose();
    _activity.dispose();
    _activitySplitterFocus.dispose();
    _connections?.dispose();
    _disposeWorkspace();
    _leftFocus?.dispose();
    _leftFocus = null;
    _rightFocus?.dispose();
    _rightFocus = null;
    super.dispose();
  }

  ConnectionStatusController? _buildConnections() {
    assert(
      widget.engineSession == null || widget.connectionEngine == null,
      'connectionEngine is ignored when engineSession is provided',
    );
    final bookmarks = widget.bookmarks;
    if (bookmarks == null) return null;

    final controller = ConnectionStatusController(
      bookmarks: bookmarks,
      bridge: widget.engineSession?.connectionLanes ?? widget.connectionEngine,
    );
    // A `connected` status is the device-local fact that makes a
    // sync-origin favorite probe-eligible (02 §4) — forward every one
    // the pool reports; the owner dedupes per (id, endpoint).
    controller.addListener(_onConnectionsChanged);
    unawaited(controller.loadServers());
    return controller;
  }

  SidebarController? _buildSidebar() {
    final store = widget.bookmarks;
    if (store == null) return null;
    final sidebar = SidebarController(
      store: store,
      initiallyCollapsed: widget.initialSidebarCollapsedGroups,
      onCollapsedChanged: widget.onSidebarCollapsedGroupsChanged,
      onBookmarksChanged: _onSidebarBookmarksChanged,
      onBookmarkRemoved: _forwardBookmarkRemoval,
    );
    unawaited(sidebar.reload());
    return sidebar;
  }

  SidebarProbeOwner? _buildProbes() {
    final bridge = widget.engineSession?.probeLanes;
    final settings = widget.probeSettings;
    if (bridge == null || settings == null) return null;
    return SidebarProbeOwner(bridge: bridge, settings: settings);
  }

  /// 02 §4's foreground gating: probes pause in background and resume on
  /// return. The engine session gets the same state through the app
  /// composition's own listener — this lane feeds only [_probes].
  void _attachLifecycle() {
    _lifecycleForwarder = AppLifecycleForwarder(
      onState: (state) {
        _lifecycleState = state;
        _probes?.forwardLifecycle(state);
      },
    )..attach();
  }

  /// One store truth feeding both sidebar surfaces (02 §4): a local
  /// mutation reloads the connections list (a deleted favorite leaves
  /// the pool rows) and re-syncs the probe set with the store's sections.
  void _onSidebarBookmarksChanged() {
    unawaited(_connections?.loadServers());
    _probes?.syncFavorites(_sidebar?.bookmarks ?? const []);
  }

  /// The favorite-delete cascade after the store remove landed (03 §6's
  /// ordering: the record is gone first — the engine cascade is designed
  /// never to be retried). The probe owner drops its device-local record
  /// in the same breath.
  void _forwardBookmarkRemoval(String serverId) {
    _probes?.noteRemoved(serverId);
    final session = widget.engineSession;
    if (session == null) return;
    unawaited(
      session.removeBookmark(serverId).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        ApplicationErrorReporter().report(error, stackTrace);
      }),
    );
  }

  /// Forwards every `connected` pool state to the probe owner (02 §4's
  /// opt-in rule for sync-origin favorites — a successful connect from
  /// this device is the only fact that enables their probing).
  void _onConnectionsChanged() {
    final probes = _probes;
    if (probes != null) {
      for (final server
          in _connections?.servers ?? const <ConnectionServer>[]) {
        if (server.status?.state == ServerConnectionState.connected) {
          probes.noteConnected(
            server.serverId,
            host: server.host,
            port: server.port,
          );
        }
      }
    }
    // A reconnect also re-arms the dirty-prompt scan: a copy marked
    // dirty while its server was down is promptable the moment the
    // upload could actually run (§3.3's "disabled while disconnected").
    _scanDirtyCheckouts();
  }

  /// Whether [serverId] currently reports a live connection — the
  /// dirty-prompt's connected gate (a disconnected server cannot upload,
  /// so prompting would dead-end into a raw connection error).
  bool _serverConnected(String serverId) {
    for (final server in _connections?.servers ?? const <ConnectionServer>[]) {
      if (server.serverId == serverId) {
        return server.status?.state == ServerConnectionState.connected;
      }
    }
    return false;
  }

  /// 06 §3.3's prompt surface: a copy the watcher just marked dirty
  /// queues the 12 s `"<name>" changed locally. Upload it?` toast —
  /// once per dirty edge (prompted set), never for a copy already
  /// uploading (a built-in save-and-upload racing the reconcile), never
  /// for a missing or disconnected one.
  void _scanDirtyCheckouts() {
    final session = _checkoutListener;
    if (session == null) return;
    final dirtyIds = {
      for (final record in session.records)
        if (record.dirty) record.id,
    };
    _promptedDirtyCheckouts.removeWhere((id) => !dirtyIds.contains(id));
    for (final record in session.records) {
      if (!record.dirty ||
          record.missing ||
          _promptedDirtyCheckouts.contains(record.id) ||
          _uploadingCheckoutKeys.contains(_checkoutKey(record)) ||
          !_serverConnected(record.serverId)) {
        continue;
      }
      _promptedDirtyCheckouts.add(record.id);
      _queueDirtyPrompt(session, record);
      // One toast per notification — the next change event surfaces the
      // next dirty copy (Séance's files_pane behavior, kept).
      return;
    }
  }

  void _queueDirtyPrompt(CheckoutSession session, ManagedRemoteFile record) {
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      if (!mounted) return;
      // Re-check right before showing: a save-and-upload from the
      // built-in editor may already have uploaded (or be uploading) this
      // copy, and a stale "Upload it?" prompt would read as a
      // confirmation request.
      ManagedRemoteFile? current;
      for (final candidate in session.records) {
        if (candidate.id == record.id) current = candidate;
      }
      if (current == null ||
          !current.dirty ||
          current.missing ||
          _uploadingCheckoutKeys.contains(_checkoutKey(current)) ||
          !_serverConnected(current.serverId)) {
        _promptedDirtyCheckouts.remove(record.id);
        return;
      }
      showTopToastIn(
        context,
        message: AppLocalizations.of(
          context,
        ).checkoutDirtyUploadPrompt(remoteBasename(current.remotePath)),
        duration: const Duration(seconds: 12),
        actionLabel: AppLocalizations.of(context).checkoutDirtyUploadAction,
        onAction: () => unawaited(_uploadDirtyCheckout(current!)),
      );
    });
    // A post-frame callback alone does not schedule the frame it waits
    // on: the dirty edge arrives off a filesystem watcher, i.e. exactly
    // when nothing else is painting, so an idle window would hold the
    // prompt hostage until some unrelated repaint. Schedule explicitly.
    binding.scheduleFrame();
  }

  /// The toast's Upload action: the §3.4 CAS-guarded upload through the
  /// same escalation as the built-in editor — a typed conflict asks,
  /// every other failure reports and toasts.
  Future<void> _uploadDirtyCheckout(ManagedRemoteFile record) async {
    final name = remoteBasename(record.remotePath);
    try {
      final bookmark = await widget.bookmarks?.byId(record.serverId);
      if (!mounted) return;
      final uploaded = await _uploadCheckout(
        record,
        bookmark?.label ?? record.serverId,
      );
      if (uploaded && mounted) {
        showTopToastIn(
          context,
          message: AppLocalizations.of(context).checkoutUploadSucceeded(name),
        );
      }
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (mounted) showTopToastIn(context, message: error.toString());
    }
  }

  /// Whether the launch session document was already consumed: it seeds
  /// exactly one workspace build — an engine-session rebind later must
  /// not replay launch state over the session the user has since built.
  bool _sessionRestoreConsumed = false;

  /// The sidebar's live hidden intent, stashed across a workspace rebuild
  /// (the flag lives on the workspace; a session swap must not silently
  /// re-show a sidebar the user hid). Consumed by the next
  /// [_buildWorkspace].
  bool? _sidebarHiddenCarry;

  /// Last reported sidebar-hidden state — a flip edge is what persists,
  /// so unrelated workspace notifies must not re-run the save.
  bool _sidebarWasHidden = false;

  void _buildWorkspace() {
    final lanes = widget.engineSession?.paneLanes;
    PaneTabsController buildStrip(String paneId) {
      final strip = PaneTabsController(
        paneId: paneId,
        lanes: lanes,
        newTabTarget: widget.newTabTarget,
        doubleClickAction: widget.doubleClickAction,
        // 06 §4.2: the built-in editor's open route — wired on every
        // strip so `file.editBuiltIn` and the "Double-click action:
        // Edit in Poltergeist" preference resolve the same way. The
        // external seam covers the remote Open verb's registry
        // resolution and every Open With ▸ choice.
        builtInEditorOpen: _openBuiltInEditor,
        externalEditorOpen: _openWithExternal,
        confirmClose: _confirmTabClose,
        // The cross-pane half of a remote tab's last-binding check: read
        // the workspace lazily — the strips are built before it exists.
        serverStillShared: (serverId, excluding) =>
            // Null-workspace is unreachable by close time — but if timing
            // ever shifted, "assume shared" is the fail-safe direction:
            // it detaches rather than dropping a pool reference a sibling
            // might still hold.
            _workspace?.serverStillBound(serverId, excluding) ?? true,
        onError: ApplicationErrorReporter().report,
      );
      strip.reconnectRestoredTabs = widget.reconnectRestoredTabs;
      return strip;
    }

    final left = buildStrip(PaneTabsController.leftPaneId);
    final right = buildStrip(PaneTabsController.rightPaneId);
    final workspace = WorkspaceController(left: left, right: right);
    _workspace = workspace;
    widget.sessionPersistence?.attach(workspace);

    // 02 §3's launch restoration wins over the default seed exactly
    // once: the persisted document seeds both strips (a pane that saved
    // zero tabs stays on its launcher — restoration never auto-opens),
    // the pane toggle's user intent, and the active pane. With no
    // document, each pane opens one tab on the local home — explicit
    // `home` because the startup tab has no duplicate source and a
    // launcher's first surface is still a browsing location. The "New
    // tabs open" preference governs ⌘T only (02 §2.1). With no engine
    // the tab stays unbound and renders the no-engine state.
    final restored = _sessionRestoreConsumed ? null : widget.restoredSession;
    _sessionRestoreConsumed = true;
    if (restored != null) {
      for (final pane in restored.panes) {
        final strip = switch (pane.paneId) {
          PaneTabsController.leftPaneId => left,
          PaneTabsController.rightPaneId => right,
          _ => null,
        };
        strip?.restoreSession(pane);
      }
      workspace.setSecondPaneHidden(restored.secondPaneHidden);
      // The panel's persisted intent (02 §1): only explicit user
      // toggles land here — auto-hide never writes this flag.
      workspace.setActivityPanelHidden(restored.activityPanelHidden);
      if (restored.activePaneId == PaneTabsController.rightPaneId) {
        // Refused while pane B is hidden — the workspace's own rule
        // parks commands on the survivor (02 §3).
        workspace.setActivePane(right);
      }
    } else {
      left.newTab(target: NewTabTarget.home);
      right.newTab(target: NewTabTarget.home);
    }
    // D16's anti-hiding rule covers the boot case too: a queue already
    // holding live tasks when the workspace mounts — the restored
    // journal's survivors, parked behind the forced pause — is work the
    // user has not seen this session, and the panel's rows are its only
    // window. The arrival edge cannot reach them: binding a queue with
    // live tasks initializes _hadLiveTasks, so no arrival ever fires
    // for them. The seed deliberately wins over a restored session's
    // hidden flag — saved chrome intent yields to un-acknowledged work.
    if (_activity.tasks.any((task) => !task.isTerminal)) {
      workspace.setActivityPanelHidden(false);
    }
    // The sidebar's persisted visibility intent (02 §1): seeded once
    // from launch state, carried live across a workspace rebuild — and
    // seeded BEFORE the change listener attaches, like the pane flags,
    // so the seed notify can never masquerade as a user toggle.
    workspace.setSidebarHidden(
      _sidebarHiddenCarry ?? widget.initialSidebarHidden,
    );
    _sidebarHiddenCarry = null;
    // The change listener attaches only after the initial state
    // settles: a launch-time visibility flip is restoration, not a
    // user-driven hide edge — the synchronous notify inside
    // setSecondPaneHidden would otherwise fire _onWorkspaceChanged's
    // focus handoff before the first frame. Seed the tracker from the
    // settled state, never a hardcoded shown.
    workspace.addListener(_onWorkspaceChanged);
    _secondPaneWasShown = workspace.secondPaneShown;
    _sidebarWasHidden = workspace.sidebarHidden;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final left = _leftFocus;
      final right = _rightFocus;
      if (left == null || right == null) return;
      // Claim initial focus only when nothing else holds it: a session
      // rebind mid-interaction must not yank focus from a toolbar
      // control or field back to the left listing.
      final primary = FocusManager.instance.primaryFocus;
      final focusElsewhere =
          primary != null && primary != FocusManager.instance.rootScope;
      if (!focusElsewhere) {
        left.requestFocus();
      }
    });
  }

  void _disposeWorkspace() {
    // The writer outlives the shell (the app owns it) — detach so a
    // rebuild's notify storm cannot write a torn-down workspace's doc.
    widget.sessionPersistence?.detach();
    _workspace?.dispose();
    _workspace = null;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;

    final sshConfigImport = widget.sshConfigImport;
    final workspace = _workspace;
    final sidebar = _sidebar;
    final leftFocus = _leftFocus;
    final rightFocus = _rightFocus;

    final commands = <RegisteredCommand>[
      if (sshConfigImport != null)
        buildSshConfigImportCommand(
          setup: sshConfigImport,
          enabled: () => !_commandSessionActive,
        ),
      if (widget.bookmarkBackup != null)
        buildOpenSettingsBackupCommand(
          service: widget.bookmarkBackup!,
          enabled: () => !_commandSessionActive,
        ),
      if (workspace != null && widget.workspaces != null)
        ...buildWorkspaceCommands(
          workspace: workspace,
          library: widget.workspaces!,
          enabled: () => !_commandSessionActive,
        ),
      if (workspace != null && leftFocus != null && rightFocus != null)
        ...buildPaneCommands(
          workspace: workspace,
          focusLeft: () => _focusPane(workspace.left),
          focusRight: () => _focusPane(workspace.right),
          swapFocus: () => _focusPane(workspace.swapFocus()),
          sidebarAvailable: () => _sidebar != null,
          toggleSidebarDrawer: _toggleSidebarDrawer,
        ),
      // `open-with-external` registers whenever a workspace exists
      // (D21): the Open With ▸ submenu renders disabled rows while no
      // file is selected.
      if (workspace != null)
        buildOpenWithCommand(
          workspace: workspace,
          registry: widget.editorRegistry,
          externalOpener: widget.externalOpener,
          openWith: (pane, entry, editorId) =>
              _openWithExternal(pane, entry, editorId),
          pickAndOpen: _pickAndOpenExternal,
        ),
      // `queue.togglePause` registers unconditionally (D21): its menu
      // row stays visible-disabled while no queue seam is bound.
      ...buildActivityCommands(activity: _activity),
    ];

    // The drop enqueue seam (02 §5.1, D14): exists only while a queue
    // is bound — without one there is nowhere a drop could land, so
    // rows stay undraggable and every target refuses. Cheap and
    // stateless, so it rebuilds per build like the command list.
    final transferQueue = widget.transferQueue;
    final dropDelegate = transferQueue == null
        ? null
        : PaneDropDelegate(
            queue: transferQueue,
            conflictPolicy: widget.conflictPolicy,
          );

    // Re-evaluate enablement without rebuilding the pane listings — one
    // shared listenable for the toolbar and the registry-driven menus.
    // The editor registry joins it so a picked/removed editor re-derives
    // the Open With ▸ rows on the next render.
    final enablement = Listenable.merge([
      _activity,
      if (workspace != null) ...[workspace, workspace.left, workspace.right],
      ?widget.editorRegistry,
    ]);

    return Scaffold(
      key: _scaffoldKey,
      // The stage-1/2 sidebar mount (02 §1's staged collapse): an
      // overlay drawer `view.toggleSidebar` opens. At stage 0 the same
      // tree mounts inline instead — the drawer stays attached so the
      // stage boundary is the only difference.
      drawer: sidebar == null
          ? null
          : Drawer(child: SafeArea(child: _buildSidebarView())),
      body: SafeArea(
        child: CommandChordScope(
          commands: commands,
          child: ListenableBuilder(
            listenable: enablement,
            builder: (context, child) => AppMenuHost(
              commands: commands,
              onRun: _runCommand,
              child: child!,
            ),
            child: Column(
              children: [
                ListenableBuilder(
                  listenable: enablement,
                  builder: (context, child) => _Toolbar(
                    title: strings.appTitle,
                    commands: commands,
                    onRun: _runCommand,
                  ),
                ),
                Divider(height: 1, color: colors.outlineVariant),
                Expanded(
                  // `view.toggleSecondPane` and the Sync Browsing link
                  // state ride the workspace listenable — a hide/show or
                  // a suspension must re-lay-out the panes without a
                  // parent rebuild.
                  child: workspace == null || leftFocus == null
                      ? const SizedBox.shrink()
                      : ListenableBuilder(
                          listenable: workspace,
                          builder: (context, _) => Row(
                            children: [
                              // The stage-0 inline sidebar (02 §1/§4):
                              // mounted at desktop width unless the user
                              // hid the region — below the boundary the
                              // Scaffold's drawer carries the same tree.
                              if (sidebar != null &&
                                  !workspace.sidebarHidden &&
                                  MediaQuery.sizeOf(context).width >=
                                      desktopStageBoundary) ...[
                                SizedBox(
                                  key: const ValueKey('sidebar.region'),
                                  width: _sidebarWidth,
                                  child: _buildSidebarView(),
                                ),
                                VerticalDivider(
                                  width: 1,
                                  color: colors.outlineVariant,
                                ),
                              ],
                              Expanded(
                                child: AdaptiveShell(
                                  initialPaneRatio: widget.initialPaneRatio,
                                  secondPaneIntent: workspace.secondPaneHidden
                                      ? SecondPaneIntent.hidden
                                      : SecondPaneIntent.shown,
                                  onSecondPaneVisibilityChanged:
                                      workspace.setSecondPaneLayoutShown,
                                  onPaneRatioChanged: widget.onPaneRatioChanged,
                                  onPaneRatioSaveError:
                                      widget.onPaneRatioSaveError,
                                  resizeLabel: strings.resizePanes,
                                  formatRatio: (ratio) => strings
                                      .paneRatioPercent((ratio * 100).round()),
                                  primary: PaneTabsView(
                                    tabs: workspace.left,
                                    workspace: workspace,
                                    focusNode: leftFocus,
                                    onSwapFocus: () =>
                                        _focusPane(workspace.right),
                                    onCancelRecovery: () => _cancelPaneRecovery(
                                      workspace,
                                      workspace.left.activeTabController,
                                    ),
                                    bookmarks: widget.bookmarks,
                                    dropDelegate: dropDelegate,
                                  ),
                                  secondary: rightFocus == null
                                      ? const SizedBox.shrink()
                                      : PaneTabsView(
                                          tabs: workspace.right,
                                          workspace: workspace,
                                          focusNode: rightFocus,
                                          onSwapFocus: () =>
                                              _focusPane(workspace.left),
                                          onCancelRecovery: () =>
                                              _cancelPaneRecovery(
                                                workspace,
                                                workspace
                                                    .right
                                                    .activeTabController,
                                              ),
                                          bookmarks: widget.bookmarks,
                                          dropDelegate: dropDelegate,
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
                // The activity panel's persisted intent rides the
                // workspace listenable (02 §1: user-shown, never
                // auto-hidden) — unmounted entirely while hidden.
                if (workspace != null)
                  ListenableBuilder(
                    listenable: workspace,
                    builder: (context, _) {
                      if (workspace.activityPanelHidden) {
                        return const SizedBox.shrink();
                      }
                      return _ActivitySection(
                        controller: _activity,
                        height: _activityPanelHeight,
                        splitterFocus: _activitySplitterFocus,
                        onResize: _resizeActivityPanel,
                        onResizeEnd: _commitActivityPanelHeight,
                        onClose: () => workspace.setActivityPanelHidden(true),
                        onReveal: _revealTransferDestination,
                      );
                    },
                  ),
                Divider(height: 1, color: colors.outlineVariant),
                _StatusBar(
                  label: strings.readyStatus,
                  syncLink: workspace?.syncBrowsing,
                  activity: _activity,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The activity splitter's drag/key resize: pixel deltas grow the
  /// panel upward, clamped to 02 §1's bounds (floor 120, cap half the
  /// window — MediaQuery height is the window's content box, the honest
  /// ceiling available here).
  void _resizeActivityPanel(double delta) {
    final halfWindow = MediaQuery.sizeOf(context).height / 2;
    // clamp() throws when lower > upper, so keep the ceiling at least
    // the floor for windows shorter than 2 * minActivityPanelHeight.
    final max = halfWindow < minActivityPanelHeight
        ? minActivityPanelHeight
        : halfWindow;
    setState(() {
      _activityPanelHeight = (_activityPanelHeight + delta).clamp(
        minActivityPanelHeight,
        max,
      );
    });
  }

  /// Persist once at the interaction boundary, not per drag pixel —
  /// the same posture as the pane ratio's save.
  void _commitActivityPanelHeight() {
    final save = widget.onActivityPanelHeightChanged;
    if (save == null) return;
    final report = widget.onActivityPanelHeightSaveError;
    try {
      final result = save(_activityPanelHeight);
      if (result is Future<void>) {
        unawaited(
          result.catchError((Object error, StackTrace stack) {
            report?.call(error, stack);
          }),
        );
      }
    } on Object catch (error, stack) {
      report?.call(error, stack);
    }
  }

  /// Reveal-in-pane (02 §6): opens the task's destination directory on
  /// the active pane — `openLocalAt` for a local destination, a
  /// bookmark-resolved `connectRemote` (initialPath = the destination)
  /// for a server side. A missing bookmark reports rather than
  /// dead-ends the tap.
  void _revealTransferDestination(TransferTask task) {
    final workspace = _workspace;
    final pane = workspace?.activeTabController;
    if (pane == null) return;
    switch (task.destination) {
      case LocalFsLocation():
        unawaited(pane.openLocalAt(task.destinationDir));
      case ServerFsLocation(:final serverId):
        unawaited(
          _revealRemoteDestination(pane, serverId, task.destinationDir),
        );
    }
  }

  Future<void> _revealRemoteDestination(
    PaneController pane,
    String serverId,
    String path,
  ) async {
    final store = widget.bookmarks;
    if (store == null) return;
    try {
      final bookmarks = await store.load();
      for (final bookmark in bookmarks) {
        if (bookmark.id == serverId) {
          await pane.connectRemote(bookmark, initialPath: path);
          return;
        }
      }
      ApplicationErrorReporter().report(
        StateError('revealInPane: no bookmark for $serverId'),
        StackTrace.current,
      );
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
    }
  }

  /// Moves keyboard focus to [pane]'s listing node. A focus request
  /// aimed at the hidden pane lands on the survivor instead (02 §3): the
  /// hidden strip is unmounted, and a detached node would otherwise
  /// latch a stale request that fires on re-show.
  void _focusPane(PaneTabsController pane) {
    final workspace = _workspace;
    if (workspace == null) return;
    final target =
        identical(pane, workspace.right) && !workspace.secondPaneShown
        ? workspace.left
        : pane;
    (identical(target, workspace.left) ? _leftFocus : _rightFocus)
        ?.requestFocus();
  }

  /// Last reported second-pane visibility: the shown → hidden
  /// transition is what moves focus, so unrelated workspace notifies
  /// must not re-run the handoff.
  bool _secondPaneWasShown = true;

  /// 02 §3's hidden-pane rule made concrete: when pane B leaves the
  /// screen its tabs take no keyboard focus. On the user toggle the
  /// notify lands before the unmount, so primary focus can still sit on
  /// any node in the disappearing half — the listing node itself, one
  /// of its fields, a tab chip, the strip's buttons, or the splitter
  /// (which unmounts with the second pane). On the stage-2 auto-hide
  /// the strip is already gone and a detached primary focus reads
  /// null. All of those move focus to the survivor; focus sitting on an
  /// unrelated, still-mounted control is left alone.
  void _onWorkspaceChanged() {
    final workspace = _workspace;
    if (workspace == null) return;
    _persistSidebarHiddenIfChanged(workspace);
    final shown = workspace.secondPaneShown;
    final becameHidden = _secondPaneWasShown && !shown;
    _secondPaneWasShown = shown;
    if (!becameHidden) return;
    final left = _leftFocus;
    if (left == null) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || _focusInsideDisappearingPanes(primary)) {
      left.requestFocus();
    }
  }

  /// Persists the sidebar's explicit visibility intent on the flip edge
  /// (02 §1's persistence list: user toggles only — the stage-1 drawer
  /// collapse never lands here). The same once-at-the-boundary posture
  /// as the activity panel's height save.
  void _persistSidebarHiddenIfChanged(WorkspaceController workspace) {
    final hidden = workspace.sidebarHidden;
    if (hidden == _sidebarWasHidden) return;
    _sidebarWasHidden = hidden;
    final save = widget.onSidebarHiddenChanged;
    if (save == null) return;
    final report = widget.onSidebarHiddenSaveError;
    try {
      final result = save(hidden);
      if (result is Future<void>) {
        unawaited(
          result.catchError((Object error, StackTrace stackTrace) {
            report?.call(error, stackTrace);
          }),
        );
      }
    } on Object catch (error, stackTrace) {
      report?.call(error, stackTrace);
    }
  }

  /// True when [node]'s widget lives inside the secondary-pane subtree
  /// or on the splitter — both unmount when pane B hides, so a node
  /// anywhere under either keyed widget is leaving the screen. The
  /// strip's own focusables (tab chips, the new-tab button) are
  /// siblings of the listing's Focus, not its descendants, so
  /// [FocusNode.hasFocus] alone cannot see them.
  bool _focusInsideDisappearingPanes(FocusNode node) {
    final context = node.context;
    if (context == null) return false;
    var inside = false;
    context.visitAncestorElements((element) {
      if (element.widget.key == AdaptiveShell.secondaryPaneKey ||
          element.widget.key == AdaptiveShell.splitterKey) {
        inside = true;
        return false;
      }
      return true;
    });
    return inside;
  }

  /// The tab-close confirmation presenter wired onto each strip's
  /// [PaneTabsController.confirmClose]: the ONLY shape the guarded close
  /// accepts (the confirmation lives inside the state operation, so no
  /// close route — chord, chip, or middle-click — can skip it). Answers
  /// false when the dialog cannot be answered.
  Future<bool> _confirmTabClose(
    PaneTab tab,
    List<TabCloseTrigger> triggers,
  ) async {
    if (!mounted) return false;
    final l10n = AppLocalizations.of(context);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // The trigger bullet list grows with the registry — scrollable
        // keeps a long localization plus several triggers inside short
        // windows instead of overflowing the column.
        scrollable: true,
        title: Text(l10n.tabCloseConfirmTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.tabCloseConfirmBody(paneTabTitle(tab, l10n))),
            const SizedBox(height: 8),
            for (final trigger in triggers)
              Text('• ${tabCloseTriggerLabel(l10n, trigger)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.tabCloseConfirmCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.tabCloseConfirmClose),
          ),
        ],
      ),
    );
    return accepted ?? false;
  }

  /// Live editor routes by §3.1 session key —
  /// `remote:<serverId>:<remotePath>` for managed checkouts,
  /// `local:<canonical path>` for plain files: one live built-in editor
  /// per key, so a second open focuses the existing route instead of
  /// stacking a duplicate editor on shared state (06 §3.1).
  final _editorRoutes = <String, Route<void>>{};

  /// The strip's `builtInEditorOpen` seam (06 §4.2): resolves the target
  /// — a plain local file opens directly (a symlink resolves once at
  /// open, §2.1 step 2); a remote file rides the managed checkout under
  /// the 4 MiB cap — then pushes (or focuses) the editor route. Open-time
  /// failures report and toast the typed message, so the §1 refusal
  /// strings surface verbatim.
  Future<void> _openBuiltInEditor(
    PaneController pane,
    RemoteFileEntry entry,
  ) async {
    final bookmark = pane.remoteBookmark;
    try {
      if (bookmark == null) {
        // A plain local file is edited in place — never through a
        // checkout (06 §4.2): Poltergeist is its file manager, not its
        // custodian.
        final file = await resolveBuiltInEditorTarget(File(entry.path));
        if (!mounted) return;
        unawaited(
          _pushEditorRoute(
            key: 'local:${file.absolute.path}',
            file: file,
            remotePath: null,
            basenameOf: p.basename,
            onSaved: null,
            onUpload: null,
          ),
        );
        return;
      }
      final session = widget.checkoutSession;
      if (session == null) {
        // Wiring defect, not a user fault: a remote open without the
        // checkout session cannot honestly become a local-file open.
        ApplicationErrorReporter().report(
          StateError('remote edit reached without a checkout session'),
          StackTrace.current,
        );
        if (mounted) {
          showTopToastIn(
            context,
            message: AppLocalizations.of(context).editorCheckoutUnavailable,
          );
        }
        return;
      }
      final ManagedRemoteFile record;
      try {
        record = await session.checkout(
          serverId: bookmark.id,
          entry: entry,
          maximumBytes: builtInEditorMaximumBytes,
        );
        if (!mounted) {
          unawaited(session.discard(record));
          return;
        }
        // The explicit built-in choice refuses with the §1 reason and
        // the Open With ▸ router — never a silent system hand-off (06
        // §4.2): preflight the fetched copy so a binary/non-UTF-8 file
        // declines the same way the over-cap checkout does.
        await loadBuiltInTextDocumentDetails(
          session.localFile(record),
        );
      } on CheckoutLimitException catch (error) {
        if (mounted) _toastRefusalWithRouter(error, pane, entry);
        return;
      } on BuiltInEditorException catch (error) {
        if (mounted) _toastRefusalWithRouter(error, pane, entry);
        return;
      }
      if (!mounted) {
        unawaited(session.discard(record));
        return;
      }
      unawaited(
        _pushEditorRoute(
          key: 'remote:${record.serverId}:${record.remotePath}',
          file: session.localFile(record),
          remotePath: record.remotePath,
          basenameOf: remoteBasename,
          onSaved: () => session.reconcile(record),
          onUpload: () => _uploadCheckout(record, bookmark.label),
        ),
      );
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (mounted) showTopToastIn(context, message: error.toString());
    }
  }

  /// The strip's `externalEditorOpen` seam (06 §4.2): a null [editorId]
  /// is the remote Open verb resolving the registry's
  /// `effectiveDefaultFor`; a concrete id — a configured editor or a
  /// `poltergeist.*` reserved selector — is an explicit Open With ▸
  /// choice. Local files never check out (Poltergeist is their file
  /// manager, not their custodian); remote files always do — the
  /// checkout is what makes the watch → prompt → conflict-guarded
  /// upload round-trip possible.
  Future<void> _openWithExternal(
    PaneController pane,
    RemoteFileEntry entry,
    String? editorId,
  ) async {
    try {
      if (pane.remoteBookmark == null) {
        await _openLocalEntryWith(pane, entry, editorId);
        return;
      }
      if (editorId == null) {
        await _openRemoteEntryDefault(pane, entry);
        return;
      }
      await _openRemoteEntryWith(pane, entry, editorId);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (mounted) showTopToastIn(context, message: error.toString());
    }
  }

  /// The local rows of §4.2's table: the built-in selector rides the
  /// same in-place open as `file.editBuiltIn`, the system selector the
  /// pane's OS-default open, and a configured editor launches detached
  /// on the file directly — never a checkout.
  Future<void> _openLocalEntryWith(
    PaneController pane,
    RemoteFileEntry entry,
    String? editorId,
  ) async {
    final id = editorId ?? EditorRegistry.systemDefaultId;
    if (id == EditorRegistry.builtInId) {
      await _openBuiltInEditor(pane, entry);
      return;
    }
    if (id == EditorRegistry.systemDefaultId) {
      await pane.openInSystemDefaultApp(entry);
      return;
    }
    final registry = widget.editorRegistry?.registry;
    if (registry == null) {
      throw StateError(
        'open-with reached without a configured editor registry',
      );
    }
    final editor = registry.byId(id);
    if (editor == null) {
      throw StateError('The selected editor no longer exists.');
    }
    await widget.externalOpener.openWith(entry.path, editor);
  }

  /// An explicit remote choice (Open With ▸): the built-in selector is
  /// the capped built-in row (a refusal surfaces, never falls back —
  /// the user named the editor); every other selector takes an uncapped
  /// checkout, then launches on the managed copy.
  Future<void> _openRemoteEntryWith(
    PaneController pane,
    RemoteFileEntry entry,
    String editorId,
  ) async {
    if (editorId == EditorRegistry.builtInId) {
      await _openBuiltInEditor(pane, entry);
      return;
    }
    final session = widget.checkoutSession;
    final bookmark = pane.remoteBookmark;
    if (session == null || bookmark == null) {
      // Wiring defect, not a user fault — same report as the built-in
      // path's missing session.
      ApplicationErrorReporter().report(
        StateError('remote open-with reached without a checkout session'),
        StackTrace.current,
      );
      if (mounted) {
        showTopToastIn(
          context,
          message: AppLocalizations.of(context).editorCheckoutUnavailable,
        );
      }
      return;
    }
    final record = await session.checkout(serverId: bookmark.id, entry: entry);
    if (!mounted) {
      // The checkout finished after the shell went away — nothing can
      // edit the copy, so release it rather than leaking a managed dir.
      unawaited(session.discard(record));
      return;
    }
    await _launchCheckout(session, record, editorId);
  }

  /// Launches [editorId] on a checked-out copy: the system selector
  /// OS-opens the file, a configured editor launches detached (06
  /// §4.3's no-shell rule lives inside the opener). A launch that never
  /// happens discards the checkout — no editor means no edits to watch.
  Future<void> _launchCheckout(
    CheckoutSession session,
    ManagedRemoteFile record,
    String editorId,
  ) async {
    final file = session.localFile(record);
    if (editorId == EditorRegistry.systemDefaultId) {
      try {
        await widget.externalOpener.openSystemDefault(file.path);
      } catch (_) {
        unawaited(session.discard(record));
        rethrow;
      }
      return;
    }
    final registry = widget.editorRegistry?.registry;
    if (registry == null) {
      unawaited(session.discard(record));
      throw StateError(
        'open-with reached without a configured editor registry',
      );
    }
    final editor = registry.byId(editorId);
    if (editor == null) {
      unawaited(session.discard(record));
      throw StateError('The selected editor no longer exists.');
    }
    try {
      await widget.externalOpener.openWith(file.path, editor);
    } catch (_) {
      unawaited(session.discard(record));
      rethrow;
    }
  }

  /// The remote Open verb (06 §4.2's first row): `effectiveDefaultFor`
  /// resolves the target, then the built-in chain — capped checkout,
  /// refused early on a KNOWN over-cap size with the §1 router (never
  /// an auto-download of what the refusal just declined), re-resolved
  /// through the system default only when download already began (the
  /// unknown-size stream abort) or the fetched copy fails the editor's
  /// own checks (non-UTF-8, binary).
  Future<void> _openRemoteEntryDefault(
    PaneController pane,
    RemoteFileEntry entry,
  ) async {
    final selected =
        widget.editorRegistry?.registry.effectiveDefaultFor(entry.path) ??
        EditorRegistry.systemDefaultId;
    if (selected != EditorRegistry.builtInId) {
      await _openRemoteEntryWith(pane, entry, selected);
      return;
    }
    final session = widget.checkoutSession;
    final bookmark = pane.remoteBookmark;
    if (session == null || bookmark == null) {
      ApplicationErrorReporter().report(
        StateError('remote open reached without a checkout session'),
        StackTrace.current,
      );
      if (mounted) {
        showTopToastIn(
          context,
          message: AppLocalizations.of(context).editorCheckoutUnavailable,
        );
      }
      return;
    }
    final ManagedRemoteFile record;
    try {
      record = await session.checkout(
        serverId: bookmark.id,
        entry: entry,
        maximumBytes: builtInEditorMaximumBytes,
      );
    } on CheckoutLimitException catch (error) {
      if (!mounted) return;
      if (entry.size != null && entry.size! > builtInEditorMaximumBytes) {
        // The known-size early refusal: router, never fallback — §4.2.
        _toastRefusalWithRouter(error, pane, entry);
        return;
      }
      // The unknown-size stream abort (or a listing that understated):
      // bandwidth was already being spent — re-resolve through the
      // uncapped system-default chain.
      await _openRemoteEntryWith(pane, entry, EditorRegistry.systemDefaultId);
      return;
    }
    if (!mounted) {
      unawaited(session.discard(record));
      return;
    }
    final file = session.localFile(record);
    try {
      await loadBuiltInTextDocumentDetails(
        file,
        maximumBytes: builtInEditorMaximumBytes,
      );
    } on BuiltInEditorException {
      // A fetched copy that fails the editor's own checks (non-UTF-8,
      // binary) re-resolves to the OS default on the checkout file —
      // §4.2: a default-resolution chain never dead-ends in a built-in
      // refusal.
      if (!mounted) {
        unawaited(session.discard(record));
        return;
      }
      await widget.externalOpener.openSystemDefault(file.path);
      return;
    } on CheckoutLimitException {
      // The checkout already held a complete copy over the cap —
      // §4.2's "a complete local copy already exists" case takes the
      // same system-default fallback (nothing new downloaded).
      if (!mounted) {
        unawaited(session.discard(record));
        return;
      }
      await widget.externalOpener.openSystemDefault(file.path);
      return;
    }
    if (!mounted) {
      unawaited(session.discard(record));
      return;
    }
    unawaited(
      _pushEditorRoute(
        key: 'remote:${record.serverId}:${record.remotePath}',
        file: file,
        remotePath: record.remotePath,
        basenameOf: remoteBasename,
        onSaved: () => session.reconcile(record),
        onUpload: () => _uploadCheckout(record, bookmark.label),
      ),
    );
  }

  /// §1's refusal-is-a-router: the built-in refusal toasts verbatim with
  /// an `Open With` action opening the chooser — the next step the
  /// refusal names.
  void _toastRefusalWithRouter(
    Object error,
    PaneController pane,
    RemoteFileEntry entry,
  ) {
    showTopToastIn(
      context,
      message: error.toString(),
      duration: const Duration(seconds: 12),
      actionLabel: AppLocalizations.of(context).fileOpenWithLabel,
      onAction: () => unawaited(_chooseEditorFor(pane, entry)),
    );
  }

  /// The chooser behind the refusal router and the command's non-menu
  /// invocation: the same rows the Open With ▸ submenu renders.
  Future<void> _chooseEditorFor(
    PaneController pane,
    RemoteFileEntry entry,
  ) async {
    if (!mounted) return;
    final selected = await showOpenWithChooser(
      context,
      registry: widget.editorRegistry?.registry,
      path: entry.path,
    );
    if (selected == null || !mounted) return;
    if (selected == kOpenWithOtherChoice) {
      await _pickAndOpenExternal(context, pane, entry);
      return;
    }
    await _openWithExternal(pane, entry, selected);
  }

  /// The `Other…` flow (06 §4.1): pick an application, register it (the
  /// menu grows the row), then — when the entry has an extension — the
  /// remember-choice prompt decides whether the pick binds that
  /// extension or opens once. Cancel anywhere aborts without a launch.
  Future<void> _pickAndOpenExternal(
    BuildContext context,
    PaneController pane,
    RemoteFileEntry entry,
  ) async {
    try {
      final picked = await widget.externalOpener.pickEditor(
        dialogTitle: AppLocalizations.of(context).editorPickDialogTitle,
      );
      if (picked == null || !context.mounted) return;
      await widget.editorRegistry?.register(picked);
      if (!context.mounted) return;
      final extension = _extensionBindingKey(entry.path);
      if (extension == null) {
        await _openWithExternal(pane, entry, picked.id);
        return;
      }
      final remember = await showRememberEditorChoice(
        context,
        name: remoteBasename(entry.path),
        editor: picked.displayName,
        extension: extension,
      );
      if (remember == null || !context.mounted) return;
      if (remember) {
        await widget.editorRegistry?.setExtensionDefault(
          extension,
          picked.id,
        );
        if (!context.mounted) return;
      }
      await _openWithExternal(pane, entry, picked.id);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (context.mounted) {
        showTopToastIn(context, message: error.toString());
      }
    }
  }

  /// The basename's last suffix as a binding key (`.zshrc` and `name.`
  /// have none): normalized the way the registry normalizes — lowercase,
  /// no dot — so the stored key always matches a lookup.
  static String? _extensionBindingKey(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1).toLowerCase();
  }

  /// The editor's `onUpload` — and the dirty-toast's `Upload` action —
  /// for a managed checkout (06 §3.4): the CAS-guarded upload,
  /// escalating ONLY a typed `conflict` to the overwrite dialog — every
  /// other kind rethrows to the caller's error toast. Cancelling
  /// returns false, which the screen toasts as "Saved locally; not
  /// uploaded." The in-flight key set suppresses the §3.3 dirty prompt
  /// while an upload runs.
  Future<bool> _uploadCheckout(
    ManagedRemoteFile copy,
    String serverLabel,
  ) async {
    final session = widget.checkoutSession;
    if (session == null) {
      // Wiring defect, not a user fault — mirror the open-time report so
      // this isn't misreported as a deliberate "Saved locally; not
      // uploaded."
      ApplicationErrorReporter().report(
        StateError('remote edit upload reached without a checkout session'),
        StackTrace.current,
      );
      return false;
    }
    // Keyed on (serverId, remotePath), not the record's id: a reconcile
    // mid-upload can swap in a record with a fresh id, and an id-keyed
    // guard would miss a second call on the swapped record. Only the
    // call that inserted the key removes it — an overlapping second
    // upload must not clear the first's suppression.
    final key = _checkoutKey(copy);
    final ownsKey = _uploadingCheckoutKeys.add(key);
    try {
      return await session.uploadLocalCopy(copy);
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.conflict || !mounted) rethrow;
      final overwrite = await _confirmRemoteOverwrite(copy, serverLabel);
      if (!overwrite) return false;
      return session.uploadLocalCopy(copy, overwriteRemoteChanges: true);
    } finally {
      if (ownsKey) _uploadingCheckoutKeys.remove(key);
    }
  }

  /// 06 §3.4's escalation dialog (02 §10's verb rules — safe default
  /// first): "Remote file changed" … `Cancel` (default) ·
  /// `Overwrite Remote Version`. The neutral "(or was deleted)" copy
  /// matches the typed conflict message — a deleted target has no newer
  /// version to overwrite. [serverLabel] names the server the remote
  /// path lives on (the bookmark's label, or its id as the fallback).
  Future<bool> _confirmRemoteOverwrite(
    ManagedRemoteFile copy,
    String serverLabel,
  ) async {
    if (!mounted) return false;
    final l10n = AppLocalizations.of(context);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.editorConflictTitle),
        content: Text(
          l10n.editorConflictBody(
            remoteBasename(copy.remotePath),
            serverLabel,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.editorConflictCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.editorConflictOverwrite),
          ),
        ],
      ),
    );
    return accepted ?? false;
  }

  /// Pushes the full-window editor route (06 §2.3), or focuses the live
  /// one when [key]'s editor is already on the stack — §3.1's
  /// one-editor-per-key rule: two editors on one checkout (or one local
  /// path) would share a file and baseline, so the second open surfaces
  /// the first instead of arming its save-conflict refusal.
  Future<void> _pushEditorRoute({
    required String key,
    required File file,
    required String? remotePath,
    required String Function(String) basenameOf,
    required Future<void> Function()? onSaved,
    required Future<bool> Function()? onUpload,
  }) async {
    final existing = _editorRoutes[key];
    if (existing != null && existing.isActive) {
      final navigator = Navigator.of(context);
      // Reveal by popping the covering routes one at a time so each
      // editor's PopScope guard runs — popUntil would force-pop and
      // silently drop unsaved changes. maybePop reports true even for
      // a vetoed pop, so progress is judged by the guarded route
      // actually leaving the top, never by the return value.
      var unobserved = 0;
      while (!existing.isCurrent) {
        if (!mounted) return;
        Route<void>? guarded;
        for (final route in _editorRoutes.values) {
          if (route.isActive && route.isCurrent) {
            guarded = route;
            break;
          }
        }
        if (!await navigator.maybePop()) return;
        if (guarded == null) {
          // The covering route isn't a tracked editor — its fate is
          // invisible here, and one that vetoes would spin this loop
          // forever. Bound the unobserved pops instead of churning.
          if (++unobserved >= 4) return;
          continue;
        }
        unobserved = 0;
        // A vetoed editor keeps its route and raises the discard
        // dialog above it; wait for that choice. Discard kills the
        // route and the reveal continues; Keep editing leaves it
        // current and ends the reveal.
        while (guarded.isActive && !guarded.isCurrent) {
          await SchedulerBinding.instance.endOfFrame;
          if (!mounted) return;
        }
        if (guarded.isActive) return;
      }
      return;
    }
    late final MaterialPageRoute<void> route;
    route = MaterialPageRoute<void>(
      builder: (routeContext) => BuiltInTextEditorScreen(
        file: file,
        remotePath: remotePath,
        onSaved: onSaved,
        onUpload: onUpload,
        showToast: (toastContext, message) =>
            showTopToastIn(toastContext, message: message),
        monoFontFallback: poltergeistMonoFontFamilies,
        basenameOf: basenameOf,
      ),
    );
    _editorRoutes[key] = route;
    unawaited(
      route.popped.then((_) {
        if (identical(_editorRoutes[key], route)) {
          _editorRoutes.remove(key);
        }
      }),
    );
    unawaited(Navigator.of(context).push(route));
  }

  /// The banner's cancel, sibling-aware (02 §2.7 in a two-pane, tabbed
  /// world): the engine keys pool references by serverId, so a plain
  /// disconnect would kill every tab and pane browsing the same server.
  /// Detach only the cancelling tab when the server is shared; drop the
  /// reference — and with it the pool's recovery — when this tab is its
  /// last user. The alone decision is re-checked after the detach's
  /// awaited release: another tab may bind the server while that release
  /// is in flight, and its fresh reference must not be dropped out from
  /// under it.
  Future<void> _cancelPaneRecovery(
    WorkspaceController workspace,
    PaneController? pane,
  ) async {
    // Keyed on the pending binding: the post-first-cancel state holds a
    // live remote channel with no location.
    final serverId = pane?.remoteBookmark?.id;
    if (pane == null || serverId == null) return;
    try {
      if (workspace.serverStillBound(serverId, pane)) {
        await pane.cancelPendingBind();
      } else {
        await pane.cancelRecovery(
          serverStillUnshared: () =>
              !workspace.serverStillBound(serverId, pane),
        );
      }
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
    }
  }

  /// The sidebar surface shared by the inline region (stage 0) and the
  /// overlay drawer (stage 1/2): one tree, two mounts — a favorite open
  /// inside the drawer resolves the panes the same way an inline click
  /// does.
  Widget _buildSidebarView() {
    final session = widget.engineSession;
    return SidebarView(
      controller: _sidebar!,
      connections: _connections,
      probes: _probes,
      onOpenFavorite: _workspace == null ? null : _openFavorite,
      onUpdateWorkspace: _workspace == null || widget.workspaces == null
          ? null
          : (bookmark) => unawaited(_updateWorkspaceFavorite(bookmark)),
      // The blocked-review affordance exists only where a composition
      // can start a connect: the session's engine raises the pool's
      // changed-key review at the attempt (D18).
      onOpenConnection: session == null || _workspace == null
          ? null
          : (server) => unawaited(_openConnectionInOtherPane(server)),
      onDisconnect: session == null
          ? null
          : (server) => unawaited(_disconnectServer(server)),
      onReviewBlocked: session == null
          ? null
          : (server) =>
                unawaited(session.reviewBlockedHostKey(server.serverId)),
    );
  }

  /// A favorite activation resolved against the panes (02 §4):
  /// localFolder and remotePath bind the resolved pane's tab per the
  /// modifier vocabulary (plain = preferred-pane rules, ⌘/Ctrl = new
  /// tab in the plain-click pane, ⌥/Alt = the pane a plain click would
  /// not have used). A workspace favorite opens per §3 — the guarded
  /// both-pane replacement, shared with the menu command. The
  /// saved-sync kind answers with the honest not-yet notice — its open
  /// verb lands with the 05 sync preview — never a dead row.
  void _openFavorite(Bookmark bookmark, SidebarOpenAction action) {
    final workspace = _workspace;
    if (workspace == null) return;
    final l10n = AppLocalizations.of(context);
    switch (bookmark.kind) {
      case BookmarkKind.workspace:
        unawaited(_openWorkspaceFavorite(bookmark));
        return;
      case BookmarkKind.savedSync:
        _showSidebarNotice(l10n.sidebarSyncLater);
        return;
      case BookmarkKind.localFolder || BookmarkKind.remotePath:
        break;
    }
    // Validate before mutating: a malformed favorite must not leave a
    // pane switch and a stranded launcher tab behind the error report.
    if (bookmark.kind == BookmarkKind.localFolder &&
        bookmark.localPath == null) {
      ApplicationErrorReporter().report(
        StateError('sidebar.open: localFolder ${bookmark.id} has no path'),
        StackTrace.current,
      );
      return;
    }
    final strip = _favoriteTargetPane(workspace, bookmark, action);
    workspace.setActivePane(strip);
    // Plain clicks replace the resolved pane's active tab — a launcher
    // pane grows one for the open; the new-tab action always grows one.
    final tab = action == SidebarOpenAction.newTab || strip.activeTab == null
        ? strip.newTab(target: NewTabTarget.launcher)
        : strip.activeTab!;
    final controller = tab.controller;
    switch (bookmark.kind) {
      case BookmarkKind.localFolder:
        unawaited(
          controller
              .openLocalAt(bookmark.localPath!)
              .catchError(
                (Object error, StackTrace stackTrace) =>
                    ApplicationErrorReporter().report(error, stackTrace),
              ),
        );
      case BookmarkKind.remotePath:
        unawaited(
          controller
              .connectRemote(bookmark)
              .catchError(
                (Object error, StackTrace stackTrace) =>
                    ApplicationErrorReporter().report(error, stackTrace),
              ),
        );
      case BookmarkKind.workspace || BookmarkKind.savedSync:
        break; // answered above — the switch is exhaustive.
    }
  }

  /// The workspace favorite's open (02 §3): the detail doc's exact
  /// tab-set snapshot when this device holds one, else the bookmark's
  /// own left/right endpoints — the synced shape's reduced form for a
  /// workspace captured elsewhere. Either way it lands through the same
  /// guarded both-pane replacement the menu command runs, Undo toast
  /// included.
  Future<void> _openWorkspaceFavorite(Bookmark bookmark) async {
    final workspace = _workspace;
    if (workspace == null) return;
    final library = widget.workspaces;
    final saved =
        library?.workspaces
            .where((record) => record.id == bookmark.id)
            .firstOrNull ??
        SavedWorkspace(
          id: bookmark.id,
          label: bookmark.label,
          savedAt: bookmark.createdAt,
          lastOpenedAt: null,
          snapshot: workspaceSnapshotFromBookmark(bookmark),
        );
    try {
      await openWorkspaceBookmark(
        context,
        workspace: workspace,
        library: library,
        saved: saved,
      );
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      // A failed open must not read as a dead row — same honest notice
      // the update verb surfaces on a store fault.
      if (mounted) {
        _showSidebarNotice(AppLocalizations.of(context).sidebarActionFailed);
      }
    }
  }

  /// The workspace row's "Update Workspace" verb: re-captures both
  /// panes over the existing favorite — one bookmark = one workspace,
  /// an update, never a duplicate. The saved toast mirrors the menu
  /// save's; a store fault reports and surfaces the honest notice.
  Future<void> _updateWorkspaceFavorite(Bookmark bookmark) async {
    final workspace = _workspace;
    final library = widget.workspaces;
    if (workspace == null || library == null) return;
    final l10n = AppLocalizations.of(context);
    try {
      final saved = await library.recapture(
        bookmark.id,
        workspace.captureWorkspace(),
      );
      if (!mounted || saved == null) return;
      showTopToastIn(context, message: l10n.workspaceSavedToast(saved.label));
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (!mounted) return;
      _showSidebarNotice(l10n.sidebarActionFailed);
    }
  }

  /// The pane a favorite open lands on (02 §4): `preferredPane` picks
  /// the plain-click side (`either` = the active pane); the ⌥/Alt
  /// action flips to the other side of that same resolution.
  PaneTabsController _favoriteTargetPane(
    WorkspaceController workspace,
    Bookmark bookmark,
    SidebarOpenAction action,
  ) {
    final plain = switch (bookmark.preferredPane) {
      PreferredPane.left => workspace.left,
      PreferredPane.right => workspace.right,
      PreferredPane.either => workspace.activePane,
    };
    final target = action == SidebarOpenAction.oppositePane
        ? (identical(plain, workspace.left) ? workspace.right : workspace.left)
        : plain;
    return _shownPane(workspace, target);
  }

  /// 02 §4's unhide rule applied to a resolved target: a user-hidden
  /// pane B un-hides for the open (its preserved tab state intact); a
  /// stage-2 layout-hidden pane B cannot show at all, so the open falls
  /// to the visible pane instead.
  PaneTabsController _shownPane(
    WorkspaceController workspace,
    PaneTabsController target,
  ) {
    if (!identical(target, workspace.right) || workspace.secondPaneShown) {
      return target;
    }
    if (workspace.secondPaneHidden) {
      workspace.setSecondPaneHidden(false);
      if (workspace.secondPaneShown) return workspace.right;
    }
    return workspace.left;
  }

  /// The Connections row's "Open in other pane" (02 §4): resolves the
  /// row's bookmark and binds the pane opposite the active one — the
  /// same unhide/stage-2 fallback rules as a favorite's modifier click.
  Future<void> _openConnectionInOtherPane(ConnectionServer server) async {
    final store = widget.bookmarks;
    if (store == null) return;
    try {
      final bookmark = await store.byId(server.serverId);
      if (!mounted) return;
      // Re-resolve after the await: a session swap may have disposed the
      // captured workspace while the store read was in flight (09 §3.1's
      // recheck idiom — `mounted` alone does not cover it).
      final workspace = _workspace;
      if (workspace == null) return;
      if (bookmark == null) {
        // The row outlived its backing bookmark (deleted between render
        // and tap) — a silent dead tap would read as a broken button.
        ApplicationErrorReporter().report(
          StateError('sidebar.connOpen: no bookmark for ${server.serverId}'),
          StackTrace.current,
        );
        return;
      }
      final strip = _shownPane(
        workspace,
        identical(workspace.activePane, workspace.left)
            ? workspace.right
            : workspace.left,
      );
      workspace.setActivePane(strip);
      final tab =
          strip.activeTab ?? strip.newTab(target: NewTabTarget.launcher);
      await tab.controller.connectRemote(bookmark);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
    }
  }

  /// The Connections row's Disconnect (02 §4): drops the pool's
  /// reference for the server through the pane lanes — the same seam a
  /// pane's recovery banner cancels through.
  Future<void> _disconnectServer(ConnectionServer server) async {
    try {
      await widget.engineSession?.paneLanes.disconnectServer(server.serverId);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
    }
  }

  /// The narrow-stage half of `view.toggleSidebar` (02 §1's stage
  /// table): the shell's own Scaffold owns the overlay drawer, and a
  /// command-run context sits ABOVE that Scaffold — `Scaffold.maybeOf`
  /// from it would never find the drawer, so the lookup goes through
  /// the key.
  void _toggleSidebarDrawer() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null || !scaffold.hasDrawer) return;
    if (scaffold.isDrawerOpen) {
      scaffold.closeDrawer();
    } else {
      scaffold.openDrawer();
    }
  }

  /// 02 §10's transient notice for the deferred open verbs — a SnackBar
  /// on the shell's messenger, informational like the pane's notice
  /// strip (the strip lives inside a pane; a workspace/saved-sync row
  /// opens no pane to strip into).
  void _showSidebarNotice(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Runs one registered command. Escaping failures are reported — the
  /// toolbar's onPressed discards the returned future, so an unhandled
  /// error here would surface only as a zone complaint.
  Future<void> _runCommand(RegisteredCommand command) async {
    // The command's own enabled() predicate is the authority: it flips
    // synchronously, so a second tap in the same frame (before the
    // disabled rebuild lands) is still refused, and a future command
    // with its own lifecycle is never blocked by this one's session.
    if (!command.enabled()) return;
    if (command.scope == CommandScope.pane ||
        command.scope == CommandScope.selection) {
      // Pane commands act immediately on the active pane; they open no
      // session, so the one-at-a-time guard does not apply to them.
      try {
        await command.run(context);
      } on Object catch (error, stackTrace) {
        ApplicationErrorReporter().report(error, stackTrace);
      }
      return;
    }
    setState(() => _commandSessionActive = true);
    try {
      await command.run(context);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
    } finally {
      if (mounted) setState(() => _commandSessionActive = false);
    }
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.title,
    required this.commands,
    required this.onRun,
  });

  final String title;
  final List<RegisteredCommand> commands;
  final Future<void> Function(RegisteredCommand command) onRun;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(
              Icons.drive_file_move_outline,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const Spacer(),
            for (final command in commands)
              Flexible(
                child: TextButton(
                  key: ValueKey('command.${command.id}'),
                  onPressed: command.enabled() ? () => onRun(command) : null,
                  // Compact density: every registered command stays on
                  // the strip, so a growing registry shares the width —
                  // the label's Flexible ellipsis is what lets a button
                  // shrink below its natural size instead of overflowing.
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The icon rides in a Flexible too: a growing
                      // registry squeezes a button below icon width, and
                      // a rigid 18px box would overflow its slot.
                      Flexible(
                        child: Icon(
                          command.icon ?? Icons.bug_report_outlined,
                          size: 18,
                        ),
                      ),
                      // The gap rides inside the Flexible so a squeezed
                      // button can collapse to the icon alone instead of
                      // overflowing at icon + spacing width.
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsetsDirectional.only(start: 4),
                          child: Text(
                            command.label(l10n),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The activity panel + its top splitter — one mounted unit gated on
/// the workspace's persisted visibility intent.
class _ActivitySection extends StatelessWidget {
  const _ActivitySection({
    required this.controller,
    required this.height,
    required this.splitterFocus,
    required this.onResize,
    required this.onResizeEnd,
    required this.onClose,
    required this.onReveal,
  });

  final ActivityPanelController controller;
  final double height;
  final FocusNode splitterFocus;
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;
  final VoidCallback onClose;
  final void Function(TransferTask task)? onReveal;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ActivityHeightSplitter(
          key: const ValueKey('activity.splitter'),
          focusNode: splitterFocus,
          label: l10n.resizeActivityPanel,
          value: l10n.activityPanelHeightPx(height.round()),
          increasedValue: l10n.activityPanelHeightPx(height.round() + 16),
          decreasedValue: l10n.activityPanelHeightPx(height.round() - 16),
          onResize: onResize,
          onResizeEnd: onResizeEnd,
        ),
        SizedBox(
          height: height,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => ActivityPanel(
              key: const ValueKey('activity.panel'),
              controller: controller,
              onClose: onClose,
              onReveal: onReveal,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.label, this.syncLink, this.activity});

  final String label;

  /// The workspace's Sync Browsing link (02 §7): while enabled the
  /// status bar carries the same chip the path bars do — the amber
  /// link-broken variant while suspended.
  final SyncBrowsingController? syncLink;

  /// The transfer queue's mirror (02 §6/§1): a live task count + rate
  /// chip, and the bandwidth-limit chip while either direction is
  /// capped. The status bar is never the queue's only representation —
  /// the panel's rows are — these chips are the always-on summary.
  final ActivityPanelController? activity;

  @override
  Widget build(BuildContext context) {
    final link = syncLink;
    return SizedBox(
      height: 24,
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 10),
        child: Row(
          children: [
            // Both children ride Flexible — the named-cause line can
            // exceed a narrow status row's width, and an unbounded chip
            // would overflow it the way the toolbar did.
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            if (link != null)
              Flexible(
                child: ListenableBuilder(
                  listenable: link,
                  builder: (context, _) {
                    if (!link.enabled) return const SizedBox.shrink();
                    return Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(start: 10),
                        child: SyncBrowseChip(
                          key: const ValueKey('statusbar.syncChip'),
                          link: link,
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (activity != null)
              Flexible(
                child: ListenableBuilder(
                  listenable: activity!,
                  builder: (context, _) =>
                      _TransferChips(controller: activity!),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The status bar's transfer summary (02 §1/§6): a rate+count chip while
/// any task is live, plus the bandwidth chip while a direction is
/// capped. Both chips are summaries only — per-item truth stays on the
/// panel's rows (D16).
class _TransferChips extends StatelessWidget {
  const _TransferChips({required this.controller});

  final ActivityPanelController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final platform = Theme.of(context).platform;
    final live = controller.tasks.where((task) => !task.isTerminal).length;
    final down = controller.downloadLimit;
    final up = controller.uploadLimit;
    final rate = controller.aggregateRate;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (live > 0)
            Flexible(
              child: Text(
                key: const ValueKey('statusbar.transferChip'),
                l10n.statusTransferChip(
                  rate > 0
                      ? formatTransferRate(rate, platform: platform)
                      : paneUnevaluated,
                  live,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          if (down != null || up != null)
            Flexible(
              child: Padding(
                padding: EdgeInsetsDirectional.only(start: live > 0 ? 10 : 0),
                child: Text(
                  key: const ValueKey('statusbar.limitChip'),
                  l10n.statusLimitChip(
                    down == null
                        ? l10n.activityBandwidthUnlimited
                        : formatTransferLimit(down, platform: platform),
                    up == null
                        ? l10n.activityBandwidthUnlimited
                        : formatTransferLimit(up, platform: platform),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
