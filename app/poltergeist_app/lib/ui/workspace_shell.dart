import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/activity_panel_controller.dart';
import '../services/alert_center.dart';
import '../services/app_lifecycle_forwarder.dart';
import '../services/app_transfer_queue.dart';
import '../services/application_error_reporter.dart';
import '../services/bookmark_backup_service.dart';
import '../services/checkout_prompt_ledger.dart';
import '../services/checkout_session.dart';
import '../services/connection_state_bridge.dart';
import '../services/connection_status_controller.dart';
import '../services/double_click_action.dart';
import '../services/drag_out_controller.dart';
import '../services/drag_out_producer.dart' show DragOutProducer;
import '../services/editor_registry_controller.dart';
import '../services/engine_session.dart';
import '../services/external_file_opener.dart';
import '../services/in_app_quick_look.dart';
import '../services/os_drag_out.dart' show DragOutBackend, NoDragOutBackend;
import '../services/local_volumes.dart' show LocalVolumeSource;
import '../services/pane_controller.dart';
import '../services/pane_drop.dart';
import '../services/pane_file_ops.dart';
import '../services/pane_location.dart';
import '../services/pane_tabs_controller.dart';
import '../services/preview_session.dart';
import '../services/probe_settings_store.dart';
import '../services/quick_look_channel.dart';
import '../services/quit_guard.dart';
import '../services/recent_locations.dart';
import '../services/registered_command.dart';
import '../services/rsync_endpoints.dart';
import '../services/server_duplication.dart';
import '../services/session_persistence.dart';
import '../services/session_state.dart';
import '../services/settings_models.dart' show AppearanceSettingsModel;
import '../services/settings_window/settings_window_host.dart';
import '../services/settings_window/settings_window_link.dart';
import '../services/sidebar_controller.dart';
import '../services/sidebar_probe_owner.dart';
import '../services/ssh_config_import_setup.dart';
import '../services/sync_environment.dart';
import '../services/sync_plan_controller.dart';
import '../services/sync_queue_facade.dart';
import '../services/update_check_controller.dart';
import '../services/transfer_limits_controller.dart';
import '../services/uuid.dart';
import '../services/workspace_controller.dart';
import '../services/workspace_library.dart';
import '../services/workspace_state.dart';
import '../services/workspace_windows/window_host.dart' show mainWindowViewId;
import '../services/workspace_windows/workspace_window_scope.dart';
import '../services/workspace_windows/workspace_windows.dart';
import '../theme/app_theme.dart';
import 'activity/activity_commands.dart';
import 'adaptive_shell.dart';
import 'inspector/alerts_view.dart';
import 'inspector/inspector_view.dart';
import 'built_in_text_editor.dart';
import 'editor_checkout_upload.dart';
import 'compact/compact_browser.dart' show CompactPaneSeams;
import 'compact/compact_posture.dart';
import 'compact/compact_workspace.dart';
import 'import/ssh_config_import_command.dart';
import 'layout/pane_allocation.dart';
import 'local_edits_review.dart';
import 'menus/app_menu_commands.dart';
import 'menus/app_menu_host.dart';
import 'panes/drag_out_image.dart';
import 'panes/open_with_commands.dart';
import 'panes/pane_commands.dart';
import 'panes/pane_tabs_view.dart';
import 'pdf_preview.dart';
import 'preview_panel.dart';
import 'quick_look_overlay.dart';
import 'quick_open/quick_open_palette.dart';
import 'settings/app_settings_command.dart';
import 'settings/backup_settings_command.dart';
import 'settings/general_settings.dart';
import 'settings/preview_settings.dart';
import 'server_appearance.dart';
import 'server_editor.dart';
import 'server_label_scope.dart';
import 'shell/connect_dialog.dart';
import 'shell/header_activity_button.dart';
import 'shell/header_toolbar.dart';
import 'shell/macos_toolbar_band.dart';
import 'shell/shell_commands.dart';
import 'shell/shell_splitter.dart';
import 'shell/window_commands.dart';
import 'sidebar/sidebar_view.dart';
import 'sync/rsync_copy.dart';
import 'sync/sync_commands.dart';
import 'sync/sync_pair_editor.dart';
import 'sync/sync_plan_format.dart' show syncEndpointLabel;
import 'sync/sync_setup_sheet.dart';
import 'top_toast.dart';
import 'workspace/workspace_commands.dart';

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
    this.serverEditor,
    this.bookmarks,
    this.workspaces,
    this.recentLocations,
    this.connectionEngine,
    this.engineSession,
    this.transferQueue,
    this.checkoutSession,
    this.editorRegistry,
    this.externalOpener = const ExternalFileOpener(),
    this.quitGuard,
    this.conflictPolicy,
    this.initialSidebarWidth = sidebarDefaultWidth,
    this.onSidebarWidthChanged,
    this.initialInspectorWidth = inspectorDefaultWidth,
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
    this.pickDirectory,
    this.quickLook,
    this.initialPreviewThresholdBytes =
        defaultLargeDownloadThresholdBytes,
    this.onPreviewCacheCapacityChanged,
    this.onPreviewThresholdChanged,
    this.syncEnvironment,
    this.syncTasks,
    this.updateCheck,
    this.localVolumes,
    this.settingsWindow,
    this.window,
    this.probeOwner,
    this.previewThreshold,
    this.checkoutPrompts,
    this.appearance,
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

  /// The server editor's application layer (04 §4.2's management
  /// verbs): the catalog section's add/edit/duplicate/delete route
  /// through it, as do the editor's own save and test connection. Null
  /// renders the catalog read-only — the verbs hide rather than
  /// dead-end.
  final ServerEditorDelegate? serverEditor;

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

  /// The Quick Open palette's Recents source (02 §8.4): the device-local
  /// store the panes' commit hook feeds. Null keeps the palette but
  /// drops its Recents section — a store-less embedding loses only the
  /// memory, never the command surface.
  final RecentLocationsStore? recentLocations;

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

  /// The persisted region widths (D32, 10 §3.1): seeded once, clamped to
  /// their bounds, and saved once at the end of each splitter drag.
  final double initialSidebarWidth;
  final FutureOr<void> Function(double width)? onSidebarWidthChanged;
  final double initialInspectorWidth;
  final FutureOr<void> Function(double width)? onInspectorWidthChanged;

  /// The persisted throttle choices seeded onto the queue's limiters
  /// (02 §6's "persisted"); null is unlimited.
  final int? initialDownloadLimit;
  final int? initialUploadLimit;

  /// Persist sinks for the popover's writes — the limiter takes the
  /// value immediately; these land it in settings.
  final FutureOr<void> Function(int? bytesPerSecond)? onDownloadLimitChanged;
  final FutureOr<void> Function(int? bytesPerSecond)? onUploadLimitChanged;

  /// D37's per-server transfer caps, bound to the queue by the
  /// composition root; the popover beside the bandwidth limits sets their
  /// default. Null leaves that choice out of the popover.
  final TransferLimitsController? transferLimits;

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

  /// Whether the inspector starts hidden when no restored session says
  /// otherwise (10 §3). The desktop shows it; main.dart hides it on touch
  /// platforms, where it squeezes the panes on a tablet.
  final bool initialInspectorHidden;
  final FutureOr<void> Function(bool hidden)? onSidebarHiddenChanged;
  final void Function(Object error, StackTrace stackTrace)?
  onSidebarHiddenSaveError;

  /// The persisted collapsed-group keys the sidebar re-opens with
  /// (02 §4: collapse state is device-local, 04 §2.3) and their save
  /// sink, which writes one change at a time. Null leaves collapse
  /// memory in-process.
  final Set<String> initialSidebarCollapsedGroups;
  final CollapsedSectionWriter? onSidebarCollapsedGroupsChanged;

  /// The persisted sidebar row density (D33: device-local, comfortable
  /// by default) and its save sink; null keeps the choice in-process.
  final SidebarDensity initialSidebarDensity;
  final void Function(SidebarDensity density)? onSidebarDensityChanged;

  /// The persisted PINNED shortlist (D33: device-local server ids) and
  /// its save sink, which writes one change at a time; null keeps pins
  /// in-process.
  final Set<String> initialSidebarPinnedServers;
  final PinnedServerWriter? onSidebarPinnedServersChanged;

  /// 06 §5.3's preview cache — the seam the whole preview slice keys
  /// on. Null composes no [PreviewSession]: Space keeps its pre-preview
  /// fallthrough, `file.preview`/`view.togglePreview` stay disabled,
  /// and no panel or Quick Look surface mounts. Same
  /// identity-stability contract as [bookmarks].
  final PreviewCache? previewCache;

  /// The §5.3 production seam (a `QueuePreviewProducer` over the
  /// composed queue in production): null leaves the session able to
  /// preview local files and cache hits but greying out every remote
  /// Download — honest absence, never a stub.
  final PreviewProducer? previewProducer;

  /// OS drag-out's remote-file seam (00 D14's drag-out amendment):
  /// null leaves remote rows without file promises (a Linux/Windows
  /// drag of them shows the Download To… hint instead).
  final DragOutProducer? dragOutProducer;

  /// The native drag-out backend; null composes the no-op one, so a
  /// row drag that leaves the window just ends there. Read once at
  /// mount: the backend owns the channel's callback registration.
  final DragOutBackend? dragOutBackend;

  /// Download To…'s folder picker, injectable for tests; null picks
  /// `file_picker`'s native dialog on the desktop platforms (none on
  /// mobile, where the verb does not register).
  final DirectoryPicker? pickDirectory;

  /// The macOS `QLPreviewPanel` channel (06 §5.1) — injectable for
  /// tests; null binds the real method channel, which answers
  /// unavailable off-macOS and falls the verb back to the panel.
  final QuickLookChannel? quickLook;

  /// The persisted §8 large-download confirmation threshold seeding the
  /// session's live value (default 100 MiB — shared by remote previews,
  /// Quick Look productions, compare sides, and external-editor
  /// checkouts).
  final int initialPreviewThresholdBytes;

  /// The §8 settings section's persist sinks — invoked BEFORE the live
  /// value moves so a failed write leaves nothing applied. Null keeps
  /// the change session-local.
  final FutureOr<void> Function(int bytes)? onPreviewCacheCapacityChanged;
  final FutureOr<void> Function(int bytes)? onPreviewThresholdChanged;

  /// The 05 sync seams (M8): the environment plan-view sessions draw
  /// filesystems/state/journals from, and the activity-panel registry
  /// their runs report through. Null unregisters the sync commands and
  /// keeps savedSync rows at their honest notice — never a dead verb.
  final SyncEnvironment? syncEnvironment;
  final SyncQueueTasks? syncTasks;

  /// The D19 update check's session state (07 §3.10): non-null mounts
  /// the dismissible banner above the panes when a newer tag exists and
  /// registers `app.settings` (its General section hosts the opt-out).
  /// Null leaves both unwired — tests and seam-less boots stay silent.
  final UpdateCheckController? updateCheck;

  /// The sidebar's DEVICES source; null reads the host's volumes. Tests
  /// script it so a phone-posture run never lists the test machine's
  /// mounts.
  final LocalVolumeSource? localVolumes;

  /// The desktop Settings window, which the Settings, Back up and sync and
  /// Configure Editors… commands open instead of their dialogs; this shell
  /// binds its sections to it. Null keeps the dialogs — mobile, and every
  /// test that does not wire a window.
  final SettingsWindowHost? settingsWindow;

  /// The workspace window this shell fills (00 D39), or null for the
  /// single-window app. With a window the shell registers New Window and
  /// Close Window, and runs the app-wide reactions
  /// (the dirty-checkout prompt, the activity panel's reveal on new work)
  /// only while its window is the active one.
  final WorkspaceWindow? window;

  /// The reachability owner every window's sidebar reads (02 §4), shared
  /// because each owner drives the engine's one probe target set: a
  /// window's own would double the probes and, when it closed, clear the
  /// targets under the others. Null builds and owns one here.
  final SidebarProbeOwner? probeOwner;

  /// The §8 large-download threshold's live value, shared so a change in
  /// the Settings window reaches every window. Null keeps it here, seeded
  /// from [initialPreviewThresholdBytes].
  final ValueNotifier<int>? previewThreshold;

  /// The dirty-checkout prompt's guards, shared so the prompt is asked
  /// once whichever window is active. Null keeps them here.
  final CheckoutPromptLedger? checkoutPrompts;

  /// This device's theme, behind Settings → Appearance (the Settings
  /// window's Appearance tab, and the Settings dialog's section after
  /// General). Null leaves the section out.
  final AppearanceSettingsModel? appearance;

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell>
    implements WorkspaceWindowContent {
  bool _commandSessionActive = false;

  /// The latest assembled registry — the Quick Open palette reads it at
  /// open time rather than re-deriving (02 §8.4: the palette is a
  /// rendering of the registry, never a parallel list).
  List<RegisteredCommand> _commands = const [];

  /// True while a Quick Open dialog is up — the command's `run` returns
  /// immediately (the session flag must not pin the registry), so this
  /// flag is the re-entrancy guard.
  bool _quickOpenOpen = false;

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

  /// D32 §9's compact posture: its surface owns Home vs the browser and
  /// the back order. The shell reaches it from the verbs that land a
  /// location from Home and from the commands whose desktop surface
  /// (the drawer, the header filter) the compact posture replaces.
  final _compactKey = GlobalKey<CompactWorkspaceState>();

  /// Whether the current build took the compact posture.
  bool _compactPosture = false;

  /// 06 §5's preview driver: owned here so the pane's Space/Esc
  /// dispatch, the docked panel, and the Quick Look overlay share one
  /// session. Rebuilt with the workspace (it binds the focus chain —
  /// an engine swap rebinds panes); null while no
  /// [WorkspaceShell.previewCache] seam exists.
  PreviewSession? _preview;

  /// The §8 shared large-download threshold's live value — seeded once
  /// from the persisted setting and written live by the Preview &
  /// downloads section; the session reads it per gate decision. The
  /// windows share [WorkspaceShell.previewThreshold] when there is one.
  ValueNotifier<int>? _ownPreviewThreshold;
  ValueNotifier<int> get _previewThreshold =>
      widget.previewThreshold ?? _ownPreviewThreshold!;
  int get _previewThresholdBytes => _previewThreshold.value;
  set _previewThresholdBytes(int bytes) => _previewThreshold.value = bytes;

  /// Editors share the app's work: the most recent workspace continues
  /// to observe transfers and checkout changes while a document is active.
  bool get _ownsAppReactions => widget.window?.isActiveWorkspace ?? true;

  BuildContext get _promptContext => widget.window?.promptContext ?? context;

  /// The production Quick Look channel, created once so session
  /// rebuilds share the one native binding (06 §5.1).
  QuickLookChannel? _defaultQuickLook;
  QuickLookChannel get _resolvedQuickLook =>
      widget.quickLook ?? (_defaultQuickLook ??= _platformQuickLook());

  /// D32: Space is Quick Look on every desktop — the native panel on
  /// macOS, the in-window overlay on Linux and Windows. Touch platforms
  /// have no surface; Space answers on the Info tab there. Every
  /// workspace window drives the one panel (00 D39), each by its view.
  QuickLookChannel _platformQuickLook() =>
      switch (defaultTargetPlatform) {
        TargetPlatform.macOS => MethodChannelQuickLook(
          viewId: widget.window?.viewId ?? mainWindowViewId,
        ),
        TargetPlatform.linux || TargetPlatform.windows => InAppQuickLook(),
        _ => const NoopQuickLookChannel(),
      };

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
  /// The pane file verbs over the composed queue (New Folder, Delete,
  /// Duplicate — the bridged engine's queue tasks); null without a queue.
  PaneFileOps? _fileOps;
  StreamSubscription<TransferQueueEvent>? _settledRefresh;

  /// D32's alert inbox over the queue mirror, connections, checkouts,
  /// and the update check (10 §3's Alerts tab).
  late final AlertCenter _alerts;

  /// The native folder picker on the desktop platforms, none elsewhere.
  static DirectoryPicker? _platformDirectoryPicker() {
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.linux || TargetPlatform.windows =>
        (title) => FilePicker.getDirectoryPath(dialogTitle: title),
      _ => null,
    };
  }

  /// OS drag-out's Dart half: hands pane row drags that leave the
  /// window to the native session, fulfils remote promises through the
  /// queue, and reports its refusals to [_alerts].
  late final DragOutController _dragOut;

  /// The region widths (10 §3.1) and the splitter/header focus nodes.
  late double _sidebarWidth;
  late double _inspectorWidth;
  final _sidebarSplitterFocus = FocusNode(debugLabel: 'sidebar.splitter');
  final _inspectorSplitterFocus = FocusNode(debugLabel: 'inspector.splitter');
  final _headerFilterFocus = FocusNode(debugLabel: 'header.filter');

  /// The live queue seam the quit guard reads — a lookup, not a
  /// snapshot, so a didUpdateWidget rebind is always seen.
  AppTransferQueue? _quitGuardQueue() => widget.transferQueue;

  /// 06 §3.3's dirty-prompt guards: record ids already toasted (one
  /// prompt per dirty edge — an expired toast never re-fires; the
  /// persistent indicators are the §3.7 review surface's slice), and
  /// `serverId|remotePath` keys with an upload in flight, so a built-in
  /// save-and-upload racing the watcher never shows a stale prompt.
  late final CheckoutPromptLedger _checkoutPrompts =
      widget.checkoutPrompts ?? CheckoutPromptLedger();
  Set<String> get _promptedDirtyCheckouts => _checkoutPrompts.prompted;
  Set<String> get _uploadingCheckoutKeys => _checkoutPrompts.uploading;
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
    widget.settingsWindow?.attach(_settingsWindowSources());
    _sidebarWidth = widget.initialSidebarWidth.clamp(
      sidebarMinWidth,
      sidebarMaxWidth,
    );
    _inspectorWidth = widget.initialInspectorWidth.clamp(
      inspectorMinWidth,
      inspectorMaxWidth,
    );
    if (widget.previewThreshold == null) {
      _ownPreviewThreshold = ValueNotifier(widget.initialPreviewThresholdBytes);
    }
    widget.window?.attachContent(this);
    _activity = ActivityPanelController(
      queue: widget.transferQueue,
      autoClearCompleted: widget.autoClearCompletedTransfers,
      downloadLimit: widget.initialDownloadLimit,
      uploadLimit: widget.initialUploadLimit,
      persistDownloadLimit: widget.onDownloadLimitChanged,
      persistUploadLimit: widget.onUploadLimitChanged,
      transferLimits: widget.transferLimits,
      onError: ApplicationErrorReporter().report,
      // D16's anti-hiding rule made concrete: the first live task
      // re-opens the chrome — the panel's rows are the queue's only
      // window, so new work must never sit behind a hidden panel.
      // The compact posture keeps the sheet closed on new work: its
      // floating progress pill is the always-visible signal there, and a
      // half-height sheet must not cover the listing mid-flow (D32 §9).
      // With several windows it is the active one that opens: the queue
      // is the app's, and every window would otherwise pop its panel.
      onTasksArrived: () {
        if (!_compactPosture && _ownsAppReactions) {
          _workspace?.setActivityPanelHidden(false);
        }
      },
    );
    _connections = _buildConnections();
    _bindFileOps(widget.transferQueue);
    _dragOut = DragOutController(
      backend: widget.dragOutBackend ?? const NoDragOutBackend(),
      files: widget.dragOutProducer,
      queue: widget.transferQueue,
      conflictPolicy: () => widget.conflictPolicy ?? ConflictPolicy(),
      renderImage: renderDragOutImage,
    );
    _alerts = AlertCenter(
      activity: _activity,
      connections: _connections,
      checkouts: widget.checkoutSession,
      updates: widget.updateCheck,
      dragOut: _dragOut,
    );
    _sidebar = _buildSidebar();
    _probes = _buildProbes();
    _attachBookmarkBackup(widget.bookmarkBackup);
    _probes?.syncCatalog(
      widget.bookmarkBackup?.catalog?.servers ?? const [],
    );
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

  BookmarkBackupService? _backupListener;

  /// The backup service's pulse: every round lands a fresh catalog in
  /// place, so the probe owner's target set re-syncs on each notify —
  /// a Séance-side add starts probing on the round that pulls it, a
  /// tombstone stops being dialed.
  void _attachBookmarkBackup(BookmarkBackupService? service) {
    if (identical(_backupListener, service)) return;
    _backupListener?.removeListener(_onBookmarkBackupChanged);
    _backupListener = service;
    service?.addListener(_onBookmarkBackupChanged);
  }

  void _onBookmarkBackupChanged() {
    _probes?.syncCatalog(
      widget.bookmarkBackup?.catalog?.servers ?? const [],
    );
  }

  /// The command list is built in [build] — a workspace save or open
  /// must rebuild so the Workspaces submenu re-derives its rows.
  void _onWorkspacesChanged() {
    if (mounted) setState(() {});
  }

  bool _wasActiveWindow = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The Settings window binds the active window's sections (00 D39): the
    // sections are the same models in every window, but a closed window's
    // shell must not stay the one answering.
    final active = WorkspaceWindowScope.activeOf(context);
    if (widget.window != null && active && !_wasActiveWindow) {
      widget.settingsWindow?.attach(_settingsWindowSources());
    }
    _wasActiveWindow = active;
  }

  @override
  void didUpdateWidget(WorkspaceShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rebound whenever the widget is: every source is read through
    // `widget`, and a replaced seam must not leave the window on the old.
    widget.settingsWindow?.attach(_settingsWindowSources());
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
        ) ||
        oldWidget.initialSidebarDensity != widget.initialSidebarDensity ||
        !identical(
          oldWidget.onSidebarDensityChanged,
          widget.onSidebarDensityChanged,
        ) ||
        !identical(
          oldWidget.initialSidebarPinnedServers,
          widget.initialSidebarPinnedServers,
        ) ||
        !identical(
          oldWidget.onSidebarPinnedServersChanged,
          widget.onSidebarPinnedServersChanged,
        )) {
      _sidebar?.dispose();
      _sidebar = _buildSidebar();
    }
    // The probe owner keys on the engine's bridge and the settings seam.
    // A rebuilt owner re-hears the last lifecycle state so probes do not
    // silently resume while the app sits backgrounded.
    if (!identical(oldWidget.engineSession, widget.engineSession) ||
        !identical(oldWidget.probeSettings, widget.probeSettings)) {
      _disposeProbes();
      _probes = _buildProbes();
      _probes?.forwardLifecycle(_lifecycleState);
      // A settings-only seam swap leaves the sidebar (and its reload)
      // untouched, so onBookmarksChanged never re-seeds this owner —
      // sync the live favorite set here (an engine swap re-seeds via
      // the sidebar reload too; syncFavorites is a reconcile, not an
      // append, so the second seeding is a no-op).
      _probes?.syncFavorites(_sidebar?.bookmarks ?? const []);
      _probes?.syncCatalog(
        widget.bookmarkBackup?.catalog?.servers ?? const [],
      );
    }
    if (!identical(oldWidget.engineSession, widget.engineSession)) {
      // Carry the sidebar's live hidden intent across the workspace
      // rebuild: the flag lives on the workspace, so a session swap
      // would otherwise silently re-show a sidebar the user hid.
      _sidebarHiddenCarry = _workspace?.sidebarHidden;
      _workspace?.dispose();
      _workspace = null;
      _buildWorkspace();
    } else if (!identical(oldWidget.previewCache, widget.previewCache) ||
        !identical(oldWidget.previewProducer, widget.previewProducer) ||
        !identical(oldWidget.quickLook, widget.quickLook)) {
      // A preview-seam swap rebuilds the session over the SAME
      // workspace — the cache/producer/channel identities are its
      // wiring. (An engine swap already rebuilt it inside
      // [_buildWorkspace].)
      _preview?.dispose();
      _preview = _buildPreviewSession();
    }
    // The threshold's live value follows a changed seed — same
    // contract as the other persisted seeds: the settings section's
    // own writes can never arrive through here.
    if (widget.previewThreshold == null) {
      final own = _ownPreviewThreshold;
      if (own == null) {
        _ownPreviewThreshold = ValueNotifier(
          widget.initialPreviewThresholdBytes,
        );
      } else if (widget.initialPreviewThresholdBytes !=
          oldWidget.initialPreviewThresholdBytes) {
        own.value = widget.initialPreviewThresholdBytes;
      }
    }
    if (!identical(oldWidget.transferQueue, widget.transferQueue)) {
      // A later-arriving queue seam rebinds the mirror; the persisted
      // limits re-apply inside the setter.
      _activity.queue = widget.transferQueue;
      _bindFileOps(widget.transferQueue);
      _dragOut.queue = widget.transferQueue;
    }
    if (!identical(oldWidget.dragOutProducer, widget.dragOutProducer)) {
      _dragOut.files = widget.dragOutProducer;
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
    _attachBookmarkBackup(widget.bookmarkBackup);
  }

  @override
  void dispose() {
    widget.workspaces?.removeListener(_onWorkspacesChanged);
    widget.quitGuard?.unbindQueue(_quitGuardQueue);
    _attachCheckoutSession(null);
    _attachBookmarkBackup(null);
    _lifecycleForwarder?.detach();
    _disposeProbes();
    _sidebar?.dispose();
    _activity.dispose();
    _alerts.dispose();
    _dragOut.dispose();
    unawaited(_settledRefresh?.cancel());
    _sidebarSplitterFocus.dispose();
    _inspectorSplitterFocus.dispose();
    _headerFilterFocus.dispose();
    _connections?.dispose();
    _disposeWorkspace();
    switch (_defaultQuickLook) {
      case final InAppQuickLook overlay:
        overlay.dispose();
      case final MethodChannelQuickLook panel:
        panel.dispose();
    }
    _leftFocus?.dispose();
    _leftFocus = null;
    _rightFocus?.dispose();
    _rightFocus = null;
    _ownPreviewThreshold?.dispose();
    widget.window?.detachContent(this);
    super.dispose();
  }

  @override
  WorkspaceController? get workspace => _workspace;

  @override
  void claimDefaultFocus() {
    final workspace = _workspace;
    if (workspace != null && mounted) _focusPane(workspace.activePane);
  }

  /// Disposes the probe owner unless the windows share it.
  void _disposeProbes() {
    if (!identical(_probes, widget.probeOwner)) _probes?.dispose();
  }

  /// Whether a live binding other than [excluding] keeps [serverId] in the
  /// pool: in this workspace, or in another window's (00 D39). The
  /// last-binding close drops the server's pool reference, which would
  /// disconnect every window's panes on it.
  bool _serverBoundBesides(String serverId, PaneController excluding) =>
      (_workspace?.serverStillBound(serverId, excluding) ?? true) ||
      (widget.window?.serverBoundElsewhere(serverId) ?? false);

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
      density: widget.initialSidebarDensity,
      onDensityChanged: widget.onSidebarDensityChanged,
      initiallyPinned: widget.initialSidebarPinnedServers,
      onPinnedChanged: widget.onSidebarPinnedServersChanged,
      onBookmarksChanged: _onSidebarBookmarksChanged,
      onBookmarkRemoved: _forwardBookmarkRemoval,
    );
    unawaited(sidebar.reload());
    return sidebar;
  }

  SidebarProbeOwner? _buildProbes() {
    final shared = widget.probeOwner;
    if (shared != null) return shared;
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
  bool _serverConnected(String serverId) => serverConnectedNow(
    serverId,
    catalog: _connections?.servers ?? const <ConnectionServer>[],
    panes: _openPanes(),
  );

  /// Every open tab's pane, both strips.
  Iterable<PaneController> _openPanes() sync* {
    final workspace = _workspace;
    if (workspace == null) return;
    for (final strip in [workspace.left, workspace.right]) {
      for (final tab in strip.tabs) {
        yield tab.controller;
      }
    }
  }

  /// 06 §3.3's prompt surface: a copy the watcher just marked dirty
  /// queues the 12 s `"<name>" changed locally. Upload it?` toast —
  /// once per dirty edge (prompted set), never for a copy already
  /// uploading (a built-in save-and-upload racing the reconcile), never
  /// for a missing or disconnected one.
  void _scanDirtyCheckouts() {
    final session = _checkoutListener;
    // One window asks: every window hears the session (00 D39).
    if (session == null || !_ownsAppReactions) return;
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
      final promptContext = _promptContext;
      showTopToastIn(
        promptContext,
        message: AppLocalizations.of(
          promptContext,
        ).checkoutDirtyUploadPrompt(remoteBasename(current.remotePath)),
        duration: const Duration(seconds: 12),
        actionLabel: AppLocalizations.of(
          promptContext,
        ).checkoutDirtyUploadAction,
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
        final promptContext = _promptContext;
        if (!promptContext.mounted) return;
        showTopToastIn(
          promptContext,
          message: AppLocalizations.of(
            promptContext,
          ).checkoutUploadSucceeded(name),
        );
      }
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (mounted) showTopToastIn(_promptContext, message: error.toString());
    }
  }


  /// 06 §3.7's review surface: the pane banner's `Review…` and the
  /// remotePath favorite's `Local Edits…` both open the same dialog —
  /// server-scoped, so records no pane currently touches still list.
  Future<void> _showLocalEditsReview(String serverId) async {
    final session = widget.checkoutSession;
    if (session == null || !mounted) return;
    final bookmark = await widget.bookmarks?.byId(serverId);
    if (!mounted) return;
    final serverLabel = bookmark?.label ?? _serverLabel(serverId) ?? serverId;
    await showLocalEditsReview(
      context,
      session: session,
      serverId: serverId,
      serverLabel: serverLabel,
      connected: () => _serverConnected(serverId),
      connections: _connections,
      onOpen: (record) =>
          _reportedLocalEditAction(() => _openCheckoutLocalFile(record)),
      onUpload: (record) => _reportedLocalEditAction(() async {
        // Re-resolve the label per upload — a rename while the dialog
        // is open must not reach the progress/toast copy stale.
        final label =
            (await widget.bookmarks?.byId(serverId))?.label ??
            _serverLabel(serverId) ??
            serverId;
        final uploaded = await _uploadCheckout(record, label);
        if (uploaded && mounted) {
          showTopToastIn(
            context,
            message: AppLocalizations.of(
              context,
            ).checkoutUploadSucceeded(remoteBasename(record.remotePath)),
          );
        }
      }),
      onDiscard: (record) =>
          _reportedLocalEditAction(() => session.discard(record)),
      onOpenRecovered: (recovered, name) => _reportedLocalEditAction(
        () => _openRecoveredLocalFile(
          session.recoveredFile(recovered, name),
        ),
      ),
      onDiscardRecovered: (recovered, name) => _reportedLocalEditAction(
        () => session.forgetRecoveredFile(recovered, name),
      ),
    );
  }

  /// The dialog verbs' shared error posture — the same report + toast
  /// as the dirty-prompt's upload path, so a failing row action never
  /// dies silently inside the modal.
  Future<void> _reportedLocalEditAction(
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (mounted) showTopToastIn(context, message: error.toString());
    }
  }

  /// 06 §3.7's row `Open` for a managed copy: the
  /// `effectiveDefaultFor` chain — the built-in selector preflights
  /// the copy and pushes the editor route on the record's seams, the
  /// system selector OS-opens it, a configured editor launches
  /// detached on it. No fresh checkout: the record already exists.
  Future<void> _openCheckoutLocalFile(ManagedRemoteFile record) async {
    final session = widget.checkoutSession;
    if (session == null) return;
    final file = session.localFile(record);
    await _openLocalEditFile(
      file,
      registryPath: record.remotePath,
      onBuiltIn: (resolved) async {
        final bookmark = await widget.bookmarks?.byId(record.serverId);
        if (!mounted) return;
        unawaited(
          _pushEditorRoute(
            key: 'remote:${record.serverId}:${record.remotePath}',
            file: resolved,
            remotePath: record.remotePath,
            basenameOf: remoteBasename,
            onSaved: () => session.reconcile(record),
            onUpload: _editorUploader(
              session, record, bookmark?.label ?? record.serverId,
            ),
          ).catchError((Object error, StackTrace stackTrace) {
            // The fire-and-forget push would otherwise escape the row's
            // reported-lane posture as an unhandled async error.
            ApplicationErrorReporter().report(error, stackTrace);
          }),
        );
      },
    );
  }

  /// The recovered payload's `Open` — its file resolves through the
  /// same `effectiveDefaultFor` chain (the registry's extension rules
  /// still apply), with the built-in opening it in place like a local
  /// file: no record, so no remote seams.
  Future<void> _openRecoveredLocalFile(File file) =>
      _openLocalEditFile(
        file,
        registryPath: file.path,
        onBuiltIn: (resolved) async {
          if (!mounted) return;
          unawaited(
            _pushEditorRoute(
              key: 'local:${resolved.absolute.path}',
              file: resolved,
              remotePath: null,
              basenameOf: p.basename,
              onSaved: null,
              onUpload: null,
            ).catchError((Object error, StackTrace stackTrace) {
              ApplicationErrorReporter().report(error, stackTrace);
            }),
          );
        },
      );

  /// The `effectiveDefaultFor` chain shared by the review dialog's Open
  /// verbs: the built-in selector preflights the copy — an over-cap or
  /// non-UTF-8 payload re-resolves through the system default rather
  /// than dead-ending an existing local edit — the system selector
  /// OS-opens it, and a configured editor launches detached on the file
  /// (06 §4.3's no-shell rule lives inside the opener).
  Future<void> _openLocalEditFile(
    File file, {
    required String registryPath,
    required Future<void> Function(File resolved) onBuiltIn,
  }) async {
    final registry = widget.editorRegistry?.registry;
    final selected =
        registry?.effectiveDefaultFor(registryPath) ??
        EditorRegistry.systemDefaultId;
    if (selected == EditorRegistry.builtInId) {
      try {
        await loadBuiltInTextDocumentDetails(file);
      } on Object {
        // The built-in refuses over-cap/binary/non-UTF-8 — the system
        // default can still open an existing local copy, so the row's
        // Open never strands the edit.
        await widget.externalOpener.openSystemDefault(file.path);
        return;
      }
      if (!mounted) return;
      await onBuiltIn(file);
      return;
    }
    if (selected == EditorRegistry.systemDefaultId) {
      await widget.externalOpener.openSystemDefault(file.path);
      return;
    }
    final editor = registry?.byId(selected);
    if (editor == null) {
      throw StateError('The selected editor no longer exists.');
    }
    await widget.externalOpener.openWith(file.path, editor);
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
        onLocationCommitted: widget.recentLocations?.recordLocation,
        confirmClose: _confirmTabClose,
        // The cross-pane half of a remote tab's last-binding check: read
        // the workspace lazily — the strips are built before it exists.
        // Null-workspace is unreachable by close time — but if timing
        // ever shifted, "assume shared" is the fail-safe direction: it
        // detaches rather than dropping a pool reference a sibling might
        // still hold.
        serverStillShared: _serverBoundBesides,
        onError: ApplicationErrorReporter().report,
      );
      strip.reconnectRestoredTabs = widget.reconnectRestoredTabs;
      return strip;
    }

    final left = buildStrip(PaneTabsController.leftPaneId);
    final right = buildStrip(PaneTabsController.rightPaneId);
    final workspace = WorkspaceController(
      left: left,
      right: right,
      inspectorHidden: widget.initialInspectorHidden,
    );
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
      // The inspector's persisted intent (D32, 10 §3.1): only explicit
      // user toggles land here — the responsive overlay never writes it.
      // A pre-inspector document derives it from the activity flag.
      final restoredTab = InspectorTab.values
          .where((tab) => tab.name == restored.inspectorTab)
          .firstOrNull;
      if (restoredTab != null) workspace.selectInspectorTab(restoredTab);
      final inspectorHidden = restored.inspectorHidden;
      if (inspectorHidden != null) {
        workspace.setInspectorHidden(inspectorHidden);
      } else if (!restored.activityPanelHidden) {
        workspace.showInspector(InspectorTab.transfers);
      }
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
    // A window opened later has no such claim: the work is showing in
    // the window the user came from (00 D39).
    if ((widget.window?.isLaunchWindow ?? true) &&
        _activity.tasks.any((task) => !task.isTerminal)) {
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
    // 06 §5's preview driver binds the workspace's focus chain — it is
    // rebuilt with the workspace (a dispose→create swap keeps the
    // session's listeners on the live controller).
    _preview?.dispose();
    _preview = _buildPreviewSession();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final left = _leftFocus;
      final right = _rightFocus;
      if (left == null || right == null) return;
      final window = widget.window;
      if (window != null) {
        // Only the window the user is in takes focus, and only when
        // nothing in it holds focus yet; activating a window later
        // claims it then (WorkspaceWindowContent.claimDefaultFocus).
        if (!window.isActive) return;
        final scope = window.focusScope;
        final primary = FocusManager.instance.primaryFocus;
        final heldHere =
            primary != null &&
            primary != scope &&
            primary.ancestors.contains(scope);
        if (!heldHere) left.requestFocus();
        return;
      }
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
    final workspace = _workspace;
    if (workspace != null) widget.sessionPersistence?.detach(workspace);
    // The session unbinds from the workspace in its dispose — run it
    // before the workspace's own teardown so no removal lands on a
    // disposed notifier.
    _preview?.dispose();
    _preview = null;
    _workspace?.dispose();
    _workspace = null;
  }

  /// 06 §5's preview driver over the current workspace — the seam
  /// tuple (cache, producer, Quick Look channel) is its wiring; a null
  /// cache composes no session at all (Space falls through, the
  /// preview commands stay disabled).
  PreviewSession? _buildPreviewSession() {
    final cache = widget.previewCache;
    final workspace = _workspace;
    if (cache == null || workspace == null) return null;
    return PreviewSession(
      workspace: workspace,
      cache: cache,
      largeDownloadThresholdBytes: () => _previewThresholdBytes,
      producer: widget.previewProducer,
      quickLook: _resolvedQuickLook,
    );
  }

  /// The §8 "Preview & downloads" rows behind Configure Editors… — a
  /// lookup (not a snapshot) so the dialog reads the live cap and
  /// threshold at open. Null while no cache seam exists: a cache-less
  /// boot has nothing to size or clear.
  PreviewDownloadsSettings? _previewDownloadsSettings() {
    final cache = widget.previewCache;
    if (cache == null) return null;
    return PreviewDownloadsSettings(
      available: true,
      capacityBytes: cache.capacityBytes,
      thresholdBytes: _previewThresholdBytes,
      onCapacityChanged: (bytes) async {
        // Persist first — a failed write leaves the live cap
        // untouched, so the field's revert returns to truth (the
        // immediate-persist idiom).
        await widget.onPreviewCacheCapacityChanged?.call(bytes);
        cache.capacityBytes = bytes;
        unawaited(
          cache.enforce().catchError((Object error, StackTrace stack) {
            ApplicationErrorReporter().report(error, stack);
          }),
        );
      },
      onThresholdChanged: (bytes) async {
        await widget.onPreviewThresholdChanged?.call(bytes);
        _previewThresholdBytes = bytes;
      },
      onClearCache: cache.clear,
    );
  }

  /// What the Settings window shows, from the same lookups the dialogs
  /// read: the sections this boot has seams for.
  SettingsWindowSources _settingsWindowSources() => SettingsWindowSources(
    general: widget.updateCheck == null ? null : _generalSettings,
    editors: widget.editorRegistry,
    opener: widget.externalOpener,
    previewDownloads: _previewDownloadsSettings,
    backup: widget.bookmarkBackup,
    appearance: widget.appearance,
    changes: [?widget.updateCheck],
  );

  /// Opens the Settings window on [tab], when there is one to open.
  OpenSettingsWindow? get _openSettingsWindow => widget.settingsWindow?.open;

  /// The Settings → General rows behind `app.settings` — a lookup (not
  /// a snapshot) so the dialog reads the live toggle at open. The sink
  /// delegates to the controller's persist-first `setEnabled`, whose
  /// throw is what the section's revert idiom keys on.
  GeneralSettings _generalSettings() {
    final updateCheck = widget.updateCheck!;
    return GeneralSettings(
      checkForUpdates: updateCheck.enabled,
      onCheckForUpdatesChanged: updateCheck.setEnabled,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sshConfigImport = widget.sshConfigImport;
    final workspace = _workspace;
    final sidebar = _sidebar;
    final leftFocus = _leftFocus;
    final rightFocus = _rightFocus;

    final preview = _preview;
    // Hoisted so the empty-state/launcher adoption offers can run the
    // registered command itself (enablement + session rule included)
    // instead of re-invoking the dialog behind its back.
    final sshImportCommand = sshConfigImport == null
        ? null
        : buildSshConfigImportCommand(
            setup: sshConfigImport,
            enabled: () => !_commandSessionActive,
          );
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
    final commands = <RegisteredCommand>[
      if (workspace != null) buildQuickOpenCommand(open: _openQuickOpen),
      ?sshImportCommand,
      if (widget.bookmarkBackup != null)
        buildOpenSettingsBackupCommand(
          service: widget.bookmarkBackup!,
          enabled: () => !_commandSessionActive,
          openWindow: _openSettingsWindow,
        ),
      // 02 §9's `app.settings` row registers while it has a section to
      // show: D19's update-check opt-out (General's only row today) or
      // the device's theme (Appearance). A seam-less boot has neither.
      if (widget.updateCheck != null || widget.appearance != null)
        buildAppSettingsCommand(
          settings: widget.updateCheck == null ? null : _generalSettings,
          appearance: widget.appearance,
          enabled: () => !_commandSessionActive,
          openWindow: _openSettingsWindow,
        ),
      // 10 §8's platform rows: Check for Updates… in the macOS app menu,
      // Quit in the Linux/Windows File menu (macOS has AppKit's own).
      if (widget.updateCheck != null &&
          Theme.of(context).platform == TargetPlatform.macOS)
        buildCheckForUpdatesCommand(
          updates: widget.updateCheck!,
          openUrl: (url) async {
            await launchUrl(url);
          },
        ),
      if (Theme.of(context).platform
          case TargetPlatform.linux || TargetPlatform.windows)
        buildQuitCommand(requestClose: widget.window?.quitApplication),
      // 00 D39's File ▸ New Window and Close Window.
      if (widget.window case final window? when window.canOpenWindows)
        ...buildWindowCommands(window: window),
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
          sidebarIsDrawer: () => !_sidebarFits,
          focusFilter: _focusHeaderFilter,
          preview: preview,
        ),
      // 10 §5's ⌥⌘F: the sidebar's filter field, registered with it.
      if (workspace != null && sidebar != null)
        buildSidebarFilterCommand(
          sidebar: sidebar,
          workspace: workspace,
          sidebarIsDrawer: () => !_sidebarFits,
          toggleSidebarDrawer: _toggleSidebarDrawer,
        ),
      // D33's View ▸ Use Compact/Comfortable Sidebar Rows.
      if (sidebar != null) buildSidebarDensityCommand(sidebar: sidebar),
      // The rail's active-pane verbs (D21): Add Current Folder to
      // Favorites and Save to Favorites… run from the menus too.
      if (workspace != null && sidebar != null)
        ...buildSidebarVerbCommands(sidebar: sidebar, workspace: workspace),
      if (workspace != null)
        ...buildShellCommands(
          workspace: workspace,
          dropDelegate: () => dropDelegate,
          openConnect: () => unawaited(_openConnectDialog()),
          allCommands: () => _commands,
          openUrl: (url) async {
            await launchUrl(url);
          },
          fileOps: () => _fileOps,
          reportFailure: _reportCommandFailure,
          locationLabel: _paneLocationLabel,
          disconnectServer: widget.engineSession == null
              ? null
              : _disconnectServer,
          pickDirectory: widget.pickDirectory ?? _platformDirectoryPicker(),
          fullScreen: widget.window?.fullScreen,
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
          previewSettings: _previewDownloadsSettings,
          openSettingsWindow: _openSettingsWindow,
        ),
      // 05 §9's sync commands register only while every seam they
      // need exists (environment for sessions, task registry for run
      // visibility) — the same conditional-posture as the import
      // command, since a command without its seams is a dead verb.
      if (workspace != null &&
          widget.syncEnvironment != null &&
          widget.syncTasks != null)
        ...buildSyncCommands(
          workspace: workspace,
          synchronizeEnabled: () =>
              !_commandSessionActive &&
              _syncEndpointFor(workspace.left) != null &&
              _syncEndpointFor(workspace.right) != null,
          savedSyncEnabled: () =>
              !_commandSessionActive && widget.bookmarks != null,
          copyRsyncEnabled: () =>
              !_commandSessionActive &&
              _activeSyncSession?.canExportRsync == true,
          synchronizePanes: (context) => _synchronizePanes(),
          newSavedSync: (context) => _newSavedSync(),
          copyRsync: (context) => _copyRsyncCommand(context),
        ),
      // `queue.togglePause` registers unconditionally (D21): its menu
      // row stays visible-disabled while no queue seam is bound.
      ...buildActivityCommands(activity: _activity),
    ];
    // The palette reads the live list at open time — keep the latest
    // registry reachable outside build (it is rebuilt cheaply anyway).
    _commands = commands;

    // 06 §3.7's banner verb — one closure for both panes.
    void onReviewLocalEdits(String serverId) =>
        unawaited(_showLocalEditsReview(serverId));

    // Re-evaluate enablement without rebuilding the pane listings — one
    // shared listenable for the toolbar and the registry-driven menus.
    // The editor registry joins it so a picked/removed editor re-derives
    // the Open With ▸ rows on the next render.
    final enablement = Listenable.merge([
      _activity,
      if (workspace != null) ...[workspace, workspace.left, workspace.right],
      ?widget.editorRegistry,
      // file.preview's enablement keys off the live surface state too
      // (an open Quick Look / visible panel keeps the verb live).
      ?preview,
      // Save to Favorites… retires once the store carries the endpoint.
      ?sidebar,
    ]);

    final platform = Theme.of(context).platform;
    final mac = platform == TargetPlatform.macOS;
    final chrome = PoltergeistChrome.of(context);
    // D32 §3.2's last stage: below 600 dp a touch window takes the
    // compact posture (10 §9). It draws edge to edge — its app bars and
    // sheets take the system insets themselves — and its sidebar is
    // Home, not a drawer.
    final compact = compactPostureApplies(
      width: MediaQuery.sizeOf(context).width,
      platform: platform,
    );
    _compactPosture = compact;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: chrome.paneBackground,
      // The narrow-window sidebar mount (D32 §3.2): an overlay drawer
      // `view.toggleSidebar` opens once the allocation cannot fit the
      // sidebar inline. Wide windows mount the same tree inline instead.
      drawer: sidebar == null || compact
          ? null
          : Drawer(
              backgroundColor: chrome.sidebarBackground,
              // macOS: clear the toolbar band the inline column's
              // spacer clears, or the filter and first rows sit under it.
              child: ReserveMacosToolbarBand(
                child: SafeArea(child: _buildSidebarView(sshImportCommand)),
              ),
            ),
      body: SafeArea(
        left: !compact,
        top: !compact,
        right: !compact,
        bottom: !compact,
        child: ServerLabelScope(
          resolve: _serverLabel,
          child: CommandChordScope(
            commands: commands,
            child: ListenableBuilder(
              listenable: enablement,
              builder: (context, child) => AppMenuHost(
                commands: commands,
                onRun: _runCommand,
                showMenuBar: false,
                child: child!,
              ),
              child: workspace == null || leftFocus == null
                  ? const SizedBox.shrink()
                  : LayoutBuilder(
                      builder: (context, constraints) => ListenableBuilder(
                        listenable: workspace,
                        builder: (context, _) => _buildWorkspaceLayout(
                          context,
                          constraints.maxWidth,
                          mac: mac,
                          unifiedToolbar: mac,
                          workspace: workspace,
                          leftFocus: leftFocus,
                          rightFocus: rightFocus,
                          sidebar: sidebar,
                          preview: preview,
                          commands: commands,
                          enablement: enablement,
                          dropDelegate: dropDelegate,
                          onReviewLocalEdits: onReviewLocalEdits,
                          sshImportCommand: sshImportCommand,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// Whether the sidebar is inline in the current allocation (D32 §3.2)
  /// — the last layout's answer, read by the resize clamps.
  bool _sidebarInline = true;

  /// Whether the window has room for the sidebar inline, hidden or not:
  /// `view.toggleSidebar` reads it to choose between the inline intent
  /// and the drawer. [_sidebarInline] is false while the user hides the
  /// sidebar, so it would send the re-show to the drawer instead.
  bool _sidebarFits = true;

  /// The inspector's half of the same answer, read by the resize clamps.
  bool _inspectorInline = true;

  /// D32's window anatomy (10 §3): sidebar | header over (pane A | pane B
  /// | inspector), with the staged collapse evaluated on the content
  /// width — the inspector folds into an overlay first, then the sidebar
  /// into the drawer; pane B's own auto-hide stays [AdaptiveShell]'s.
  Widget _buildWorkspaceLayout(
    BuildContext context,
    double width, {
    required bool mac,
    required bool unifiedToolbar,
    required WorkspaceController workspace,
    required FocusNode leftFocus,
    required FocusNode? rightFocus,
    required SidebarController? sidebar,
    required PreviewSession? preview,
    required List<RegisteredCommand> commands,
    required Listenable enablement,
    required PaneDropDelegate? dropDelegate,
    required void Function(String serverId) onReviewLocalEdits,
    required RegisteredCommand? sshImportCommand,
  }) {
    final strings = AppLocalizations.of(context);
    final chrome = PoltergeistChrome.of(context);
    final sidebarWidth = _sidebarWidth;
    final inspectorWidth = _inspectorWidth;
    final sidebarWanted = sidebar != null && !workspace.sidebarHidden;
    _sidebarFits = width >= sidebarWidth + shellSplitterExtent + _paneRegionMin;
    final sidebarInline = sidebarWanted && _sidebarFits;
    _sidebarInline = sidebarInline;
    final inspectorWanted = !workspace.inspectorHidden;
    final usedBySidebar = sidebarInline
        ? sidebarWidth + shellSplitterExtent
        : 0.0;
    final inspectorInline =
        inspectorWanted &&
        width >=
            usedBySidebar +
                inspectorWidth +
                shellSplitterExtent +
                _paneRegionMin;
    _inspectorInline = inspectorInline;
    final inspectorOverlay = inspectorWanted && !inspectorInline;

    final inspector = InspectorView(
      workspace: workspace,
      activity: _activity,
      alerts: _alerts,
      alertActions: AlertActions(
        showTransfers: () => workspace.showInspector(InspectorTab.transfers),
        retryTask: (task) => _activity.retryTask(task.id),
        resumeRestored: _activity.resumeRestoredQueue,
        reviewHostKey: widget.engineSession == null
            ? null
            : (serverId) => unawaited(
                widget.engineSession!.reviewBlockedHostKey(serverId),
              ),
        reviewLocalEdits: widget.checkoutSession == null
            ? null
            : onReviewLocalEdits,
        openRelease: (info) => unawaited(launchUrl(info.releasesUrl)),
      ),
      preview: preview,
      pdfRenderer: pdfPreviewBuilder,
      // Every launch verb routes onto the focused ENTRY — never the
      // `preview-cache/` path (06 §5.3's open-boundary rule).
      onOpen: (pane, entry) => unawaited(pane.openEntry(entry)),
      onOpenWith: (context, pane, entry) =>
          unawaited(_chooseEditorFor(pane, entry)),
      onOpenInEditor: (pane, entry) =>
          unawaited(pane.editInBuiltInEditor(entry)),
      onReveal: _revealTransferDestination,
      onEscape: (event) => preview != null && preview.escape()
          ? KeyEventResult.handled
          : KeyEventResult.ignored,
    );
    if (_compactPosture) {
      return _buildCompactLayout(
        workspace: workspace,
        inspector: inspector,
        commands: commands,
        sshImportCommand: sshImportCommand,
        onReviewLocalEdits: onReviewLocalEdits,
      );
    }

    Widget paneTabs(PaneTabsController tabs, FocusNode focus, PaneTabsController other) =>
        PaneTabsView(
          tabs: tabs,
          workspace: workspace,
          focusNode: focus,
          preview: preview,
          onSwapFocus: () => _focusPane(other),
          onCancelRecovery: () =>
              _cancelPaneRecovery(workspace, tabs.activeTabController),
          bookmarks: widget.bookmarks,
          dropDelegate: dropDelegate,
          dragOut: _dragOut,
          checkoutSession: widget.checkoutSession,
          onReviewLocalEdits: onReviewLocalEdits,
          onSyncSaveAsFavorite: _saveSyncAsFavorite,
          onSyncEditRules: _editSyncRules,
          onImportSshConfig: sshImportCommand == null
              ? null
              : () => unawaited(_runCommand(sshImportCommand)),
          commands: commands,
          onRunCommand: _runCommand,
        );

    final panes = Stack(
      fit: StackFit.expand,
      children: [
        AdaptiveShell(
          initialPaneRatio: widget.initialPaneRatio,
          secondPaneIntent: workspace.secondPaneHidden
              ? SecondPaneIntent.hidden
              : SecondPaneIntent.shown,
          onSecondPaneVisibilityChanged: workspace.setSecondPaneLayoutShown,
          onPaneRatioChanged: widget.onPaneRatioChanged,
          onPaneRatioSaveError: widget.onPaneRatioSaveError,
          resizeLabel: strings.resizePanes,
          formatRatio: (ratio) =>
              strings.paneRatioPercent((ratio * 100).round()),
          primary: paneTabs(workspace.left, leftFocus, workspace.right),
          secondary: rightFocus == null
              ? const SizedBox.shrink()
              : paneTabs(workspace.right, rightFocus, workspace.left),
        ),
        if (preview != null)
          if (_resolvedQuickLook case final InAppQuickLook quickLook)
            QuickLookOverlay(
              controller: quickLook,
              nameFor: preview.quickLookNameFor,
              pdfRenderer: pdfPreviewBuilder,
            ),
        if (preview != null) PreviewQuickLookOverlay(session: preview),
        if (inspectorOverlay)
          PositionedDirectional(
            key: const ValueKey('inspector.overlay'),
            top: 0,
            bottom: 0,
            end: 0,
            width: inspectorWidth,
            child: Material(
              elevation: 8,
              color: chrome.inspectorBackground,
              child: inspector,
            ),
          ),
      ],
    );

    final header = ListenableBuilder(
      listenable: Listenable.merge([enablement, _alerts]),
      // The traffic lights sit in the window only while the toolbar band
      // shows; full screen hides both (MacosToolbarBandScope). Read here,
      // so a switch rebuilds the header alone.
      builder: (context, _) => HeaderToolbar(
        commands: commands,
        onRun: _runCommand,
        nativeTitlebar: unifiedToolbar,
        leadingInset:
            unifiedToolbar &&
                !sidebarInline &&
                MacosToolbarBandScope.visibleOf(context)
            ? _macTrafficLightsInset
            : 0,
        title: _HeaderTitle(workspace: workspace),
        badges: {
          kViewToggleInspectorCommandId: ToolbarBadge(
            count: _alerts.attentionCount,
            announcement: strings.alertCountSemantics(_alerts.attentionCount),
          ),
        },
        statusExtras: {
          kViewToggleActivityPanelCommandId: (context, button) =>
              HeaderActivityButton(controller: _activity, child: button),
        },
        filterField: _HeaderFilterField(
          workspace: workspace,
          focusNode: _headerFilterFocus,
        ),
        menuButton: mac
            ? null
            : AppMainMenuButton(commands: commands, onRun: _runCommand),
      ),
    );

    final main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Linux/Windows keep the native titlebar above the header; macOS
        // draws the header under the unified toolbar band, whose empty
        // space the system already drags and zooms.
        header,
        Divider(height: 1, color: chrome.separator),
        // D19's update banner lives in Alerts now (D32 §3); the pane
        // row owns the rest of the column.
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: panes),
              if (inspectorInline) ...[
                ShellSplitter(
                  key: const ValueKey('inspector.splitter'),
                  focusNode: _inspectorSplitterFocus,
                  label: strings.resizeInspector,
                  value: strings.splitterWidthPx(inspectorWidth.round()),
                  increasedValue: strings.splitterWidthPx(
                    _clampInspector(
                      inspectorWidth + shellSplitterKeyStep,
                      width,
                    ).round(),
                  ),
                  decreasedValue: strings.splitterWidthPx(
                    _clampInspector(
                      inspectorWidth - shellSplitterKeyStep,
                      width,
                    ).round(),
                  ),
                  grow: -1,
                  onResizeStart: () => _inspectorDragWidth = null,
                  onResize: (delta) => _resizeInspector(delta, width),
                  onResizeEnd: _commitInspectorWidth,
                  onReset: () {
                    setState(() => _inspectorWidth = inspectorDefaultWidth);
                    _commitInspectorWidth();
                  },
                ),
                SizedBox(
                  key: const ValueKey('inspector.region'),
                  width: inspectorWidth,
                  child: inspector,
                ),
              ],
            ],
          ),
        ),
      ],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sidebarInline) ...[
          SizedBox(
            key: const ValueKey('sidebar.region'),
            width: sidebarWidth,
            child: ColoredBox(
              color: chrome.sidebarBackground,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // macOS: the traffic lights sit over the sidebar's top
                  // band (the full-size content view under the unified
                  // toolbar, which drags natively) — Finder's layout.
                  if (unifiedToolbar) SizedBox(height: chrome.headerHeight),
                  Expanded(child: _buildSidebarView(sshImportCommand)),
                ],
              ),
            ),
          ),
          ShellSplitter(
            key: const ValueKey('sidebar.splitter'),
            focusNode: _sidebarSplitterFocus,
            nativeTitlebar: unifiedToolbar,
            label: strings.resizeSidebar,
            value: strings.splitterWidthPx(sidebarWidth.round()),
            increasedValue: strings.splitterWidthPx(
              _clampSidebar(sidebarWidth + shellSplitterKeyStep, width).round(),
            ),
            decreasedValue: strings.splitterWidthPx(
              _clampSidebar(sidebarWidth - shellSplitterKeyStep, width).round(),
            ),
            onResizeStart: () => _sidebarDragWidth = null,
            onResize: (delta) => _resizeSidebar(delta, width),
            onResizeEnd: _commitSidebarWidth,
            onReset: () {
              setState(() => _sidebarWidth = sidebarDefaultWidth);
              _commitSidebarWidth();
            },
          ),
        ],
        Expanded(child: main),
      ],
    );
  }

  /// D32 §9's compact posture over the same workspace, registry, and
  /// inspector configuration the wide layout renders — one truth, two
  /// renderings.
  Widget _buildCompactLayout({
    required WorkspaceController workspace,
    required InspectorView inspector,
    required List<RegisteredCommand> commands,
    required RegisteredCommand? sshImportCommand,
    required void Function(String serverId) onReviewLocalEdits,
  }) {
    return CompactWorkspace(
      key: _compactKey,
      workspace: workspace,
      commands: commands,
      onRunCommand: _runCommand,
      inspector: inspector,
      home: _sidebar == null
          ? null
          : _buildSidebarView(
              sshImportCommand,
              presentation: SidebarPresentation.home,
            ),
      homeDensitySwitch: _sidebar == null
          ? null
          : SidebarDensityControl(controller: _sidebar!),
      seams: CompactPaneSeams(
        onCancelRecovery: (pane) =>
            unawaited(_cancelPaneRecovery(workspace, pane)),
        bookmarks: widget.bookmarks,
        checkoutSession: widget.checkoutSession,
        onReviewLocalEdits: onReviewLocalEdits,
        onSyncSaveAsFavorite: _saveSyncAsFavorite,
        onSyncEditRules: _editSyncRules,
        onImportSshConfig: sshImportCommand == null
            ? null
            : () => unawaited(_runCommand(sshImportCommand)),
        onAddToFavorites: _sidebar == null
            ? null
            : (pane) => unawaited(_addPaneToFavorites(pane)),
      ),
    );
  }

  /// The compact browser's "Add Current Folder to Favorites": the rail's
  /// verb over the shown pane, confirmed in words because Home — where
  /// the new row appears — is a screen away.
  Future<void> _addPaneToFavorites(PaneController pane) async {
    final sidebar = _sidebar;
    final location = pane.location;
    if (sidebar == null || location == null) return;
    final result = await addLocationToFavorites(
      context,
      sidebar,
      location: location,
      remote: pane.remoteBookmark,
    );
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final message = switch (result.outcome) {
      SidebarAddOutcome.favorite => l10n.compactAddedToFavorites(result.label),
      // Already a favorite, or failed: the shared verb has said so.
      SidebarAddOutcome.alreadyFavorite || SidebarAddOutcome.failed => null,
    };
    if (message == null) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// An open that lands a location from the compact Home pushes the
  /// browser over it (D32 §9); inert on wide windows.
  void _showCompactBrowser() {
    if (_compactPosture) _compactKey.currentState?.showBrowser();
  }

  /// The unclamped width the current splitter interaction has reached
  /// (10 §3.1), reset as each one starts. A pointer delivers a drag as
  /// many small deltas: clamping each onto the displayed width would
  /// throw the overshoot away, and the drag-past-minimum hide could
  /// then only fire on one event larger than the overshoot.
  double? _sidebarDragWidth;
  double? _inspectorDragWidth;

  /// Sidebar drag/key resize (10 §3.1): clamped to its bounds and to the
  /// room the panes need; dragging well past the minimum hides it as a
  /// user hide.
  void _resizeSidebar(double delta, double windowWidth) {
    final next = (_sidebarDragWidth ?? _sidebarWidth) + delta;
    _sidebarDragWidth = next;
    if (next < sidebarMinWidth - _collapseOvershoot) {
      _sidebarDragWidth = null;
      _workspace?.setSidebarHidden(true);
      setState(() => _sidebarWidth = sidebarMinWidth);
      return;
    }
    setState(() => _sidebarWidth = _clampSidebar(next, windowWidth));
  }

  void _resizeInspector(double delta, double windowWidth) {
    final next = (_inspectorDragWidth ?? _inspectorWidth) + delta;
    _inspectorDragWidth = next;
    if (next < inspectorMinWidth - _collapseOvershoot) {
      _inspectorDragWidth = null;
      _workspace?.setInspectorHidden(true);
      setState(() => _inspectorWidth = inspectorMinWidth);
      return;
    }
    setState(() => _inspectorWidth = _clampInspector(next, windowWidth));
  }

  /// [width] held to the sidebar's bounds and its inline room.
  double _clampSidebar(double width, double windowWidth) => width.clamp(
    sidebarMinWidth,
    _inlineRoom(
      windowWidth,
      otherRegion: _inspectorInline ? _inspectorWidth : null,
    ).clamp(sidebarMinWidth, sidebarMaxWidth),
  );

  /// [width] held to the inspector's bounds and its inline room.
  double _clampInspector(double width, double windowWidth) => width.clamp(
    inspectorMinWidth,
    _inlineRoom(
      windowWidth,
      otherRegion: _sidebarInline ? _sidebarWidth : null,
    ).clamp(inspectorMinWidth, inspectorMaxWidth),
  );

  /// The widest a region can grow and stay inline (10 §3.2): the window
  /// less the [otherRegion] still inline beside it, both splitters, and
  /// the panes' floor. A drag past it would flip the region into the
  /// drawer or overlay under the pointer and unmount its splitter before
  /// the width could persist.
  double _inlineRoom(double windowWidth, {required double? otherRegion}) =>
      windowWidth -
      (otherRegion == null ? 0 : otherRegion + shellSplitterExtent) -
      shellSplitterExtent -
      _paneRegionMin;

  void _commitSidebarWidth() =>
      _persist(widget.onSidebarWidthChanged, _sidebarWidth);

  void _commitInspectorWidth() =>
      _persist(widget.onInspectorWidthChanged, _inspectorWidth);

  /// Persists a width once at the interaction boundary — never per drag
  /// pixel — reporting (never throwing) a failed write.
  void _persist(FutureOr<void> Function(double)? save, double value) {
    if (save == null) return;
    try {
      final result = save(value);
      if (result is Future<void>) {
        unawaited(
          result.catchError((Object error, StackTrace stack) {
            ApplicationErrorReporter().report(error, stack);
          }),
        );
      }
    } on Object catch (error, stack) {
      ApplicationErrorReporter().report(error, stack);
    }
  }

  /// Binds the file verbs and the settled-task refresh to [queue].
  /// Remote panes have no directory watch (03 §7.5), so a finished
  /// transfer or delete would otherwise leave the destination listing
  /// stale: any visible pane showing a settled task's destination folder
  /// (or, for deletes, the deleted items' folder) refreshes.
  void _bindFileOps(AppTransferQueue? queue) {
    unawaited(_settledRefresh?.cancel());
    _settledRefresh = null;
    _fileOps = queue == null ? null : PaneFileOps(queue);
    if (queue == null) return;
    _settledRefresh = queue.events.listen((event) {
      if (event is! TransferQueueTaskEvent) return;
      if (event.state != TransferTaskState.completed &&
          event.state != TransferTaskState.failed &&
          event.state != TransferTaskState.cancelled) {
        return;
      }
      final task = queue.tasks.where((t) => t.id == event.taskId).firstOrNull;
      if (task == null) return;
      _refreshPanesShowing(task);
    });
  }

  void _refreshPanesShowing(TransferTask task) {
    final workspace = _workspace;
    if (workspace == null) return;
    final touched = <(FsLocation, String)>{
      (task.destination, task.destinationDir),
      if (task.operation == TransferOperation.delete ||
          task.operation == TransferOperation.move)
        for (final root in task.rootPaths) (task.source, paneParentPath(root)),
    };
    for (final strip in [workspace.left, workspace.right]) {
      final pane = strip.activeTab?.controller;
      final location = pane?.location;
      if (pane == null || location is! RemotePaneLocation) continue;
      final endpoint = fsLocationForLocation(location);
      if (touched.any((t) => t.$1 == endpoint && t.$2 == location.path)) {
        pane.refresh();
      }
    }
  }

  /// A command's failure as a top toast (02 §10): typed filesystem
  /// errors carry sanitized messages; anything else reports and shows
  /// the generic line.
  void _reportCommandFailure(Object error) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final message = switch (error) {
      RemoteFileException(:final message) => message,
      TrashException(:final message) => message,
      _ => l10n.paneErrorOther,
    };
    if (error is! RemoteFileException && error is! TrashException) {
      ApplicationErrorReporter().report(error, StackTrace.current);
    }
    showTopToastIn(context, message: message);
  }

  /// The place a delete dialog names: the server's own name for a remote
  /// pane, "This computer" for a local one.
  String _paneLocationLabel(PaneController pane) {
    final l10n = AppLocalizations.of(context);
    final location = pane.location;
    if (location is RemotePaneLocation) {
      return _serverLabel(location.serverId) ??
          pane.remoteBookmark?.label ??
          location.serverId;
    }
    return l10n.activityTaskRouteLocal;
  }

  /// ⌘F (D32 §4): the header's filter field takes focus.
  void _focusHeaderFilter() {
    if (_compactPosture) {
      // The compact browser's app-bar field is the filter there.
      _compactKey.currentState?.openFilter();
      return;
    }
    _headerFilterFocus.requestFocus();
  }

  /// The id → name resolver behind [ServerLabelScope]: favorites and
  /// connection rows first, then the shared-account catalog.
  String? _serverLabel(String serverId) {
    for (final server in _connections?.servers ?? const <ConnectionServer>[]) {
      if (server.serverId == serverId) return server.label;
    }
    for (final server
        in widget.bookmarkBackup?.catalog?.servers ?? const <ServerConfig>[]) {
      if (server.id == serverId) return server.label;
    }
    // A Quick Connect session is in neither list: its only record is
    // the ad-hoc bookmark bound on the tab that opened it.
    for (final pane in _openPanes()) {
      final bookmark = pane.remoteBookmark;
      if (bookmark != null && bookmark.id == serverId) return bookmark.label;
    }
    return null;
  }

  /// ⌘K's Connect dialog (D32 §4): Quick Connect over a fresh tab in the
  /// active pane — the same seam the pane launcher uses.
  Future<void> _openConnectDialog() async {
    final workspace = _workspace;
    if (workspace == null) return;
    await showConnectDialog(
      context,
      servers: _connectChoices(),
      onConnect: (bookmark, initialPath) {
        final tab = workspace.activePane.newTab(
          target: NewTabTarget.launcher,
        );
        unawaited(
          tab.controller.connectRemote(bookmark, initialPath: initialPath),
        );
        _showCompactBrowser();
      },
    );
  }

  /// The Connect dialog's one-click servers (D32 §4): the rail's servers —
  /// saved remote favorites and the shared-account catalog — used most
  /// recently first, each opening a new tab exactly as the sidebar's
  /// new-tab open does.
  List<ConnectServerChoice> _connectChoices() {
    String endpoint(String user, String host, int port) {
      final address = port == 22 ? host : '$host:$port';
      return user.isEmpty ? address : '$user@$address';
    }

    final choices = <ConnectServerChoice>[
      for (final bookmark in _sidebar?.bookmarks ?? const <Bookmark>[])
        if (bookmark.kind == BookmarkKind.remotePath)
          ConnectServerChoice(
            id: bookmark.id,
            label: bookmark.label,
            detail: switch (bookmark.server?.identity) {
              final identity? => endpoint(
                identity.username,
                identity.host,
                identity.port,
              ),
              null => bookmark.remotePath ?? '',
            },
            mark: ServerBadge.glyph(
              tint: ServerTint(named: bookmark.color),
              icon: bookmark.icon,
              size: 18,
            ),
            open: () => _openFavorite(bookmark, SidebarOpenAction.newTab),
          ),
      for (final server
          in widget.bookmarkBackup?.catalog?.servers ??
              const <ServerConfig>[])
        ConnectServerChoice(
          id: server.id,
          label: server.label,
          detail: endpoint(server.username, server.host, server.port),
          mark: ServerBadge(
            tint: ServerTint.of(server),
            mark: server.mark,
            size: 18,
          ),
          open: () => _openCatalogServer(server, SidebarOpenAction.newTab),
        ),
    ];
    return orderConnectChoices(choices, [
      for (final recent
          in widget.recentLocations?.entries ?? const <RecentLocation>[])
        ?recent.serverId,
    ]);
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
    _showCompactBrowser();
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
    if (_compactPosture) {
      // No listing takes focus there: the chords flip the shown pane.
      workspace.setActivePane(pane);
      return;
    }
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
      } on CheckoutLimitException catch (error) {
        if (mounted) _toastRefusalWithRouter(error, pane, entry);
        return;
      }
      if (!mounted) {
        unawaited(session.discard(record));
        return;
      }
      try {
        // The explicit built-in choice refuses with the §1 reason and
        // the Open With ▸ router — never a silent system hand-off (06
        // §4.2): preflight the fetched copy so a binary/non-UTF-8 file
        // declines the same way the over-cap checkout does.
        await loadBuiltInTextDocumentDetails(
          session.localFile(record),
        );
      } on CheckoutLimitException catch (error) {
        if (mounted) {
          _toastRefusalWithRouter(error, pane, entry);
        } else {
          unawaited(session.discard(record));
        }
        return;
      } on BuiltInEditorException catch (error) {
        if (mounted) {
          _toastRefusalWithRouter(error, pane, entry);
        } else {
          unawaited(session.discard(record));
        }
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
          onUpload: _editorUploader(session, record, bookmark.label),
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
        onUpload: _editorUploader(session, record, bookmark.label),
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
    return uploadEditorCheckout(
      context: widget.window?.promptContext ?? context,
      session: session,
      prompts: _checkoutPrompts,
      copy: copy,
      serverLabel: serverLabel,
    );
  }

  Future<bool> Function(BuildContext) _editorUploader(
    CheckoutSession session,
    ManagedRemoteFile copy,
    String serverLabel,
  ) {
    // Capture app-owned state now: the editor outlives this shell.
    final prompts = _checkoutPrompts;
    return (editorContext) => uploadEditorCheckout(
      context: editorContext,
      session: session,
      prompts: prompts,
      copy: copy,
      serverLabel: serverLabel,
    );
  }

  /// Opens a desktop editor window, or the mobile full-window route.
  /// Reopening a document focuses its live editor.
  /// On mobile, focuses the live
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
    required Future<bool> Function(BuildContext)? onUpload,
  }) async {
    final window = widget.window;
    if (window != null && window.canOpenWindows) {
      await window.openEditor(
        key: key,
        title: basenameOf(remotePath ?? file.path),
        builder: (editorWindow) => ValueListenableBuilder<bool>(
          valueListenable: editorWindow.editorQuitPending,
          builder: (editorContext, quitPending, _) => BuiltInTextEditorScreen(
            quitPending: quitPending,
            file: file,
            remotePath: remotePath,
            onSaved: onSaved,
            onUpload: onUpload == null ? null : () => onUpload(editorContext),
            onCloseRequested: editorWindow.close,
            onQuitRequested: editorWindow.quitApplication,
            onNewWindowRequested: editorWindow.openWindow,
            onCloseGuardChanged: editorWindow.setEditorCloseGuard,
            showToast: (toastContext, message) =>
                showTopToastIn(toastContext, message: message),
            monoFontFallback: poltergeistMonoFontFamilies,
            basenameOf: basenameOf,
          ),
        ),
      );
      return;
    }
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
        onUpload: onUpload == null ? null : () => onUpload(routeContext),
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
      if (_serverBoundBesides(serverId, pane)) {
        await pane.cancelPendingBind();
      } else {
        await pane.cancelRecovery(
          serverStillUnshared: () => !_serverBoundBesides(serverId, pane),
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
  Widget _buildSidebarView(
    RegisteredCommand? sshImportCommand, {
    SidebarPresentation presentation = SidebarPresentation.rail,
  }) {
    final session = widget.engineSession;
    final backup = widget.bookmarkBackup;
    final queue = widget.transferQueue;
    // The rail's Connect, Settings, and Sync-setup affordances run the
    // registered commands (D21) — the same enablement and one-shot
    // session rule as their menu rows; an unregistered one hides.
    VoidCallback? runCommand(String id) {
      for (final command in _commands) {
        if (command.id == id) return () => unawaited(_runCommand(command));
      }
      return null;
    }

    return SidebarView(
      controller: _sidebar!,
      presentation: presentation,
      // D22's adoption offer in the empty-servers state routes through
      // the registered command: the same enablement and one-shot
      // session rule apply as the menu row.
      onImportSshConfig: sshImportCommand == null
          ? null
          : () => unawaited(_runCommand(sshImportCommand)),
      connections: _connections,
      probes: _probes,
      // D32 §5: the active pane marks the selection pill and feeds "Add
      // Current Folder"; its tabs carry the Quick Connect sessions.
      workspace: _workspace,
      volumes: widget.localVolumes ?? SystemLocalVolumes.host,
      // Stateless and cheap, like the panes' own delegate in build.
      dropDelegate: queue == null
          ? null
          : PaneDropDelegate(
              queue: queue,
              conflictPolicy: widget.conflictPolicy,
            ),
      onQuickConnect: runCommand(kConnectQuickConnectCommandId),
      onOpenSettings: runCommand(kAppSettingsCommandId),
      onOpenSyncSettings: runCommand(kOpenSettingsBackupCommandId),
      onOpenFavorite: _workspace == null ? null : _openFavorite,
      onUpdateWorkspace: _workspace == null || widget.workspaces == null
          ? null
          : (bookmark) => unawaited(_updateWorkspaceFavorite(bookmark)),
      // 06 §3.7's review entry: the dialog needs the checkout session —
      // without it the row's menu offers no dead-end verb.
      onLocalEdits: widget.checkoutSession == null
          ? null
          : (bookmark) => unawaited(_showLocalEditsReview(bookmark.id)),
      onDisconnect: session == null
          ? null
          : (server) => unawaited(_disconnectServer(server.serverId)),
      // The blocked-review affordance exists only where a composition
      // can start a connect: the session's engine raises the pool's
      // changed-key review at the attempt (D18).
      onReviewBlocked: session == null
          ? null
          : (server) =>
                unawaited(session.reviewBlockedHostKey(server.serverId)),
      // 04 §4.2's catalog surface: the service owns the pulled
      // serverConfig materialization and the round status; its
      // notifications repaint the rail (the catalog mutates in place,
      // so the view reads the status at build, never a stale copy).
      catalog: backup?.catalog,
      catalogListenable: backup,
      syncStatus: backup == null
          ? null
          : () => SidebarSyncStatus(
              enrolled: backup.account != null,
              syncing: backup.syncing,
              lastSyncAt: backup.lastSyncAt,
              error: backup.lastSyncError,
            ),
      onSyncNow: backup == null ? null : () => unawaited(_syncNow()),
      onOpenCatalogServer: _workspace == null ? null : _openCatalogServer,
      // 04 §4.2's management verbs: all four ride the editor seam, so
      // they gate together on it — a null delegate leaves the catalog
      // read-only rather than offering dead ends.
      onAddCatalogServer: widget.serverEditor == null
          ? null
          : () => unawaited(_editCatalogServer(null)),
      onEditCatalogServer: widget.serverEditor == null
          ? null
          : (server) => unawaited(_editCatalogServer(server)),
      onDuplicateCatalogServer: widget.serverEditor == null
          ? null
          : (server) => unawaited(_duplicateCatalogServer(server)),
      onDeleteCatalogServer: widget.serverEditor == null
          ? null
          : (server) => unawaited(_deleteCatalogServer(server)),
    );
  }

  /// The catalog section's add/edit entry: the shared editor dialog over
  /// the app's delegate — a null [server] is the editor's add path.
  /// Null-safe on purpose: the duplicate toast's action outlives the
  /// build that gated the verbs, and the shell may have been rebuilt
  /// read-only (no editor) by the time it is tapped.
  Future<void> _editCatalogServer(ServerConfig? server) async {
    final editor = widget.serverEditor;
    if (editor == null) return;
    await showServerEditor(context, editor, server);
  }

  /// Copy a catalog server, then offer the editor — upstream's flow
  /// (server_list_pane._duplicateServer @ 035b0d8): duplicating is
  /// almost always the first half of "…and change one thing", and the
  /// toast's action is a shorter route back than finding the new row.
  Future<void> _duplicateCatalogServer(ServerConfig server) async {
    final backups = widget.bookmarkBackup;
    if (backups == null) return;
    final l10n = AppLocalizations.of(context);
    final ServerConfig copy;
    try {
      copy = await backups.duplicateServer(server);
    } on SourceServerChanged catch (error) {
      // Verbatim, as upstream: the message is written as a whole
      // sentence for this toast.
      if (mounted) {
        showTopToastIn(context, message: '$error');
      } else {
        ApplicationErrorReporter().report(error, StackTrace.current);
      }
      return;
    } catch (error, stackTrace) {
      // The vault throws when the OS keyring is locked — say so rather
      // than leaving the menu looking like it did nothing.
      ApplicationErrorReporter().report(error, stackTrace);
      if (mounted) {
        showTopToastIn(
          context,
          message: l10n.sidebarCatalogDuplicateFailed(
            server.label,
            '$error',
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    showTopToastIn(
      context,
      message: l10n.sidebarCatalogDuplicated(copy.label),
      actionLabel: l10n.sidebarCatalogDuplicatedEdit,
      onAction: () {
        if (mounted) unawaited(_editCatalogServer(copy));
      },
    );
  }

  /// The catalog row's delete: upstream's confirmation (live managed
  /// edits counted into the body), the live panes dropped first —
  /// upstream's `closeAllTabsForServer` analog — then the service's
  /// tombstoned delete.
  Future<void> _deleteCatalogServer(ServerConfig server) async {
    final backups = widget.bookmarkBackup;
    if (backups == null) return;
    final l10n = AppLocalizations.of(context);
    final session = widget.checkoutSession;
    final edits = (session?.copiesFor(server.id).length ?? 0) +
        (session?.displacedFor(server.id).length ?? 0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.sidebarCatalogDeleteTitle(server.label)),
        content: Text(
          edits == 0
              ? l10n.sidebarCatalogDeleteBody
              : l10n.sidebarCatalogDeleteBodyEdits(edits),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.sidebarCatalogDeleteCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.sidebarCatalogDeleteConfirm),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.engineSession?.paneLanes.disconnectServer(server.id);
      await backups.deleteServer(server);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
    }
  }

  /// The "Sync now" round: the service serializes concurrent calls
  /// itself (`syncing` early-returns); a failed round reports through
  /// the reporter and leaves its description on the button's tooltip.
  Future<void> _syncNow() async {
    try {
      await widget.bookmarkBackup?.backUpNow();
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
    }
  }

  /// A catalog row's activation: the pulled [ServerConfig] becomes a
  /// `serverConfigId`-referencing remotePath bookmark — the same shape a
  /// synced favorite carries — and rides [_openFavorite]'s pane
  /// resolution, which resolves the id back through the catalog at
  /// connect time. The server's own id keys the binding, so a catalog
  /// open and a referencing favorite share one pool entry.
  void _openCatalogServer(ServerConfig server, SidebarOpenAction action) {
    _openFavorite(_catalogOpenBookmark(server), action);
  }

  /// The transient bookmark a catalog open binds through: never
  /// persisted — the catalog is the truth; this only carries the
  /// reference and the display fields the pane chrome reads.
  Bookmark _catalogOpenBookmark(ServerConfig server) => Bookmark(
    id: server.id,
    kind: BookmarkKind.remotePath,
    label: server.label,
    color: server.color,
    icon: server.icon,
    server: BookmarkServerRef(serverConfigId: server.id),
    sortKey: '',
    createdAt: DateTime.fromMillisecondsSinceEpoch(server.createdAt),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(server.updatedAt),
  );

  /// A favorite activation resolved against the panes (02 §4):
  /// localFolder and remotePath bind the resolved pane's tab per the
  /// modifier vocabulary (plain = preferred-pane rules, ⌘/Ctrl = new
  /// tab in the plain-click pane, ⌥/Alt = the pane a plain click would
  /// not have used). A workspace favorite opens per §3 — the guarded
  /// both-pane replacement, shared with the menu command. A savedSync
  /// decodes back into its pair and opens the 05 plan view in the
  /// resolved pane.
  void _openFavorite(Bookmark bookmark, SidebarOpenAction action) {
    final workspace = _workspace;
    if (workspace == null) return;
    switch (bookmark.kind) {
      case BookmarkKind.workspace:
        unawaited(_openWorkspaceFavorite(bookmark));
        _showCompactBrowser();
        return;
      case BookmarkKind.savedSync:
        unawaited(
          _openSavedSyncFavorite(
            bookmark,
            _favoriteTargetPane(workspace, bookmark, action),
          ),
        );
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
    _showCompactBrowser();
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
        // A shared-account `serverConfigId` ref resolves through the
        // pulled catalog (04 §4.2): the pulled config carries fields an
        // embedded identity cannot express — jumpHostId above all. An id
        // the catalog cannot answer fails honestly before the dial; an
        // embedded identity beside it is the older-record fallback.
        ServerConfig? resolved;
        final ref = bookmark.server;
        if (ref?.serverConfigId != null) {
          resolved = _serverConfigById(ref!.serverConfigId!);
          if (resolved == null && ref.identity == null) {
            ApplicationErrorReporter().report(
              StateError(
                'sidebar.open: serverConfigId ${ref.serverConfigId} '
                'resolves to no pulled server',
              ),
              StackTrace.current,
            );
            return;
          }
        }
        unawaited(
          controller
              .connectRemote(bookmark, resolvedConfig: resolved)
              .catchError(
                (Object error, StackTrace stackTrace) =>
                    ApplicationErrorReporter().report(error, stackTrace),
              ),
        );
      case BookmarkKind.workspace || BookmarkKind.savedSync:
        break; // answered above — the switch is exhaustive.
    }
  }

  /// ── Quick Open (02 §8.4) ─────────────────────────────────────────

  /// `app.quickOpen`'s invocation: opens the centered palette over the
  /// live registry, favorites, and recents. The dialog future is NOT
  /// awaited — `_runCommand`'s one-shot session would otherwise pin
  /// every app command's `enabled` for the palette's whole lifetime.
  void _openQuickOpen() {
    if (_quickOpenOpen || _workspace == null) return;
    _quickOpenOpen = true;
    unawaited(
      showQuickOpenPalette(
        context,
        commands: _commands,
        favorites: _sidebar?.bookmarks ?? const [],
        recents: widget.recentLocations?.entries ?? const [],
        resolveRecentBookmark: _resolveRecentBookmark,
        onCommand: (command) => unawaited(_runCommand(command)),
        onFavorite: (bookmark, action) =>
            _openFavorite(bookmark, _sidebarAction(action)),
        onRecent: _openRecentLocation,
        localHome: (widget.localVolumes ?? SystemLocalVolumes.host)
            .homeDirectory,
      ).whenComplete(() => _quickOpenOpen = false),
    );
  }

  /// The palette's Enter family mapped onto §4's sidebar vocabulary:
  /// ⌥ = the other pane, ⌘/Ctrl = a new tab.
  SidebarOpenAction _sidebarAction(QuickOpenAction action) => switch (action) {
    QuickOpenAction.plain => SidebarOpenAction.plain,
    QuickOpenAction.newTab => SidebarOpenAction.newTab,
    QuickOpenAction.otherPane => SidebarOpenAction.oppositePane,
  };

  /// A remote recent's live bookmark: the sidebar's favorites by id,
  /// so an edited favorite opens under its CURRENT credentials. Null
  /// leaves the palette to the row's stored snapshot.
  Bookmark? _resolveRecentBookmark(RecentLocation recent) {
    for (final bookmark in _sidebar?.bookmarks ?? const <Bookmark>[]) {
      if (bookmark.id == recent.serverId) return bookmark;
    }
    return null;
  }

  /// Opens a Recents row (02 §8.4: "a Recent location opens like a
  /// favorite") — same pane/tab resolution minus `preferredPane`, which
  /// a recent does not carry: plain lands on the active pane.
  void _openRecentLocation(RecentLocation recent, QuickOpenAction action) {
    final workspace = _workspace;
    if (workspace == null) return;
    // Resolve before any state change: an unopenable remote must not
    // switch the active pane or strand a fresh launcher tab.
    final bookmark = recent.isRemote
        ? _resolveRecentBookmark(recent) ?? recent.remoteBookmark
        : null;
    if (recent.isRemote && bookmark == null) {
      return; // the row renders disabled instead
    }
    final active = workspace.activePane;
    final strip = _shownPane(
      workspace,
      action == QuickOpenAction.otherPane
          ? (identical(active, workspace.left)
                ? workspace.right
                : workspace.left)
          : active,
    );
    workspace.setActivePane(strip);
    _showCompactBrowser();
    final tab = action == QuickOpenAction.newTab || strip.activeTab == null
        ? strip.newTab(target: NewTabTarget.launcher)
        : strip.activeTab!;
    final controller = tab.controller;
    if (!recent.isRemote) {
      unawaited(
        controller
            .openLocalAt(recent.path)
            .catchError(
              (Object error, StackTrace stackTrace) =>
                  ApplicationErrorReporter().report(error, stackTrace),
            ),
      );
      return;
    }
    unawaited(
      controller
          .connectRemote(bookmark!, initialPath: recent.path)
          .catchError(
            (Object error, StackTrace stackTrace) =>
                ApplicationErrorReporter().report(error, stackTrace),
          ),
    );
  }

  /// ── Sync pair openings (05 §9) ───────────────────────────────────
  ///
  /// All three entry points — `sync.synchronizePanes` (⌥⌘Y), the
  /// sidebar's savedSync row, and `sync.newSavedSync` — build or decode
  /// the SyncPair and show it in the Sync sheet (D32 §7). The sheet's
  /// Simulate/Synchronize land on the same path: mint a
  /// SyncPlanController bound to the shared environment and the
  /// activity-panel task registry, and open its transient plan tab on
  /// the resolved pane.

  /// A pane's live location as a sync endpoint (the ad-hoc pair's
  /// legs): local paths map straight across; remote locations need
  /// the bound bookmark's server ref — the RemoteEndpoint shape 04
  /// §2.1 names. Launcher/unbound panes yield null, which disables
  /// `sync.synchronizePanes` rather than dead-ending the command.
  SyncEndpoint? _syncEndpointFor(PaneTabsController strip) {
    final controller = strip.activeTab?.controller;
    if (controller == null) return null;
    return switch (controller.location) {
      LocalPaneLocation(:final path) => LocalEndpoint(path),
      RemotePaneLocation(:final path) =>
        switch (controller.remoteBookmark?.server) {
          final BookmarkServerRef ref =>
            RemoteEndpoint(server: ref, path: path),
          _ => null,
        },
      _ => null,
    };
  }

  /// The focused strip's sync-plan session, when its active tab is
  /// one — `sync.copyRsyncCommand` acts on this tab (05 §2.1: the
  /// exporter is reachable only from the plan view).
  SyncPlanController? get _activeSyncSession =>
      _workspace?.activePane.activeTab?.syncSession;

  /// Shared-mode catalog lookup for the export seam: a `serverConfigId`
  /// resolves through the pulled Séance catalog; absent catalog or id
  /// leaves the ref unresolved so the command disables rather than
  /// emitting a wrong host.
  ServerConfig? _serverConfigById(String id) =>
      widget.bookmarkBackup?.catalog?.byId(id);

  /// `sync.copyRsyncCommand` (05 §2.1): the active plan's export to
  /// the clipboard — the action-bar button and this menu row share the
  /// one verb in rsync_copy.dart.
  Future<void> _copyRsyncCommand(BuildContext context) async {
    final session = _activeSyncSession;
    if (session == null) return;
    await copyRsyncCommand(context, session);
  }

  /// The ad-hoc pair's display name — one label per leg so the tab
  /// reads as a direction, like §7's header does.
  String _syncPairLabel(
    AppLocalizations l10n,
    SyncEndpoint left,
    SyncEndpoint right,
  ) =>
      l10n.syncPairLabel(
        syncEndpointLabel(left, shortenRemotePath: true),
        syncEndpointLabel(right, shortenRemotePath: true),
      );

  /// `sync.synchronizePanes` (05 §9, D32 §7): the ad-hoc pair from
  /// both panes' live locations, shown in the Sync sheet first — the
  /// FOCUSED pane is the source. Never persisted unless the sheet's
  /// Save as Favorite runs, so its state keys on the canonical pair id
  /// alone (§9's ad-hoc rule).
  Future<void> _synchronizePanes() async {
    final pair = _paneSyncPair(name: null);
    if (pair == null) return;
    await _showSyncSheet(SyncSheetMode.adHoc, pair);
  }

  /// Both panes as a pair, direction pointing away from the focused
  /// pane; null while either pane has no syncable location. [name]
  /// null uses the ad-hoc "left ⇄ right" label.
  SyncPair? _paneSyncPair({required String? name}) {
    final workspace = _workspace;
    if (workspace == null) return null;
    final left = _syncEndpointFor(workspace.left);
    final right = _syncEndpointFor(workspace.right);
    if (left == null || right == null) return null;
    final rightFocused = identical(workspace.activePane, workspace.right);
    return SyncPair(
      id: uuidV4(),
      name: name ?? _syncPairLabel(AppLocalizations.of(context), left, right),
      left: left,
      right: right,
      rules: SyncRuleSet(
        direction: rightFocused
            ? SyncDirection.rightToLeft
            : SyncDirection.leftToRight,
      ),
    );
  }

  /// The savedSync favorite's open (05 §9, D32 §7): decode the spec
  /// back into its SyncPair — a spec-less row is a malformed favorite,
  /// reported rather than silently ignored — and show it in the Sync
  /// sheet, whose verbs open the plan view on the resolved pane.
  Future<void> _openSavedSyncFavorite(
    Bookmark bookmark,
    PaneTabsController strip,
  ) async {
    final pair = syncPairFromBookmark(bookmark);
    if (pair == null) {
      ApplicationErrorReporter().report(
        StateError('sidebar.open: savedSync ${bookmark.id} has no spec'),
        StackTrace.current,
      );
      return;
    }
    await _showSyncSheet(SyncSheetMode.saved, pair, strip: strip);
  }

  /// `sync.newSavedSync` (05 §9, D32 §7): the Sync sheet in its
  /// new-favorite mode, prefilled from the panes when both are bound.
  /// Every verb but Cancel persists the favorite first.
  Future<void> _newSavedSync() async {
    if (widget.bookmarks == null) return;
    await _showSyncSheet(SyncSheetMode.newSaved, _paneSyncPair(name: ''));
  }

  /// The Sync sheet's one entry (D32 §7): gathers what it renders (the
  /// server choices for Advanced…, the stored pair state for the plan
  /// sentence), then acts on the verb it closed with. The sheet never
  /// scans — Simulate and Synchronize open the plan tab exactly as the
  /// pre-D32 entries did, Synchronize with its auto-run intent.
  Future<void> _showSyncSheet(
    SyncSheetMode mode,
    SyncPair? initial, {
    PaneTabsController? strip,
  }) async {
    final environment = widget.syncEnvironment;
    if (environment == null) return;
    final store = widget.bookmarks;
    final servers = store == null
        ? const <Bookmark>[]
        : await _syncServerChoices(store);
    final pairState = initial == null
        ? null
        : await _storedSyncPairState(environment, initial);
    if (!mounted) return;
    final result = await showSyncSetupSheet(
      context,
      mode: mode,
      initial: initial,
      pairState: pairState,
      servers: servers,
      endpointAvailable: environment.endpointAvailable,
      rsyncEndpoints: (pair) =>
          resolveRsyncEndpoints(pair, serverConfig: _serverConfigById),
      onSaveFavorite: store == null ? null : _saveSyncPairFromSheet,
      serverFor: (ref) => switch (ref.serverConfigId) {
        final String id => _serverConfigById(id),
        null => null,
      },
    );
    if (result == null || !mounted) return;
    if (mode == SyncSheetMode.newSaved) {
      if (!await _saveSyncPairFromSheet(result.pair)) return;
      if (result.action == SyncSheetAction.save || !mounted) return;
    }
    await _openSyncPlan(
      result.pair,
      caseOverrides: result.caseOverrides,
      strip: strip,
      intent: result.action == SyncSheetAction.synchronize
          ? SyncPlanIntent.synchronize
          : SyncPlanIntent.review,
    );
  }

  /// The sheet's pre-scan read of the pair's stored state — a store
  /// fault reports and leaves the sentence without the clock flags
  /// rather than blocking the sheet.
  Future<SyncPairState?> _storedSyncPairState(
    SyncEnvironment environment,
    SyncPair pair,
  ) async {
    try {
      return await loadStoredSyncPairState(environment.states, pair);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      return null;
    }
  }

  /// Persists a sheet pair as its savedSync favorite and confirms with
  /// the saved toast; a store fault reports, surfaces the honest
  /// notice, and answers false so the sheet stays unsaved.
  Future<bool> _saveSyncPairFromSheet(SyncPair pair) async {
    try {
      await _persistSyncPair(pair);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (mounted) {
        _showSidebarNotice(AppLocalizations.of(context).sidebarActionFailed);
      }
      return false;
    }
    if (mounted) {
      showTopToastIn(
        context,
        message: AppLocalizations.of(context).syncSavedFavoriteToast(pair.name),
      );
    }
    return true;
  }

  /// The plan view's Save as Favorite (05 §7): persists the open
  /// pair as a savedSync bookmark — an existing favorite with the
  /// pair's id keeps its group, sort key, and creation stamp (the
  /// re-save is an update, never a second row).
  Future<void> _saveSyncAsFavorite(SyncPlanController session) async {
    final store = widget.bookmarks;
    if (store == null) return;
    try {
      await _persistSyncPair(session.pair);
      if (!mounted) return;
      showTopToastIn(
        context,
        message: AppLocalizations.of(
          context,
        ).syncSavedFavoriteToast(session.pair.name),
      );
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (!mounted) return;
      _showSidebarNotice(AppLocalizations.of(context).sidebarActionFailed);
    }
  }

  /// Upserts [pair] as its savedSync bookmark (04 §2.1: the bookmark
  /// id IS the pair id). Preserves group/sortKey/createdAt across
  /// re-saves; a fresh pair appends ungrouped.
  Future<void> _persistSyncPair(SyncPair pair) async {
    final store = widget.bookmarks!;
    final existing = await store.byId(pair.id);
    final now = DateTime.now();
    final bookmark = bookmarkFromSyncPair(
      pair,
      group: existing?.group,
      sortKey: existing?.sortKey ?? await store.sortKeyForInsert(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await store.save(bookmark);
  }

  /// The remote bookmarks the pair editor's endpoint pickers offer —
  /// every stored remotePath row carrying a server reference (an
  /// embedded identity or config id both resolve to a RemoteEndpoint).
  Future<List<Bookmark>> _syncServerChoices(BookmarkStore store) async {
    try {
      return [
        for (final bookmark in await store.load())
          if (bookmark.kind == BookmarkKind.remotePath &&
              bookmark.server != null)
            bookmark,
      ];
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      return const [];
    }
  }

  /// The plan view's rules edit (05 §7's options affordance): the
  /// same pair editor, seeded from the live pair. Saving updates the
  /// session (rules + case overrides → rescan) and re-saves the
  /// bookmark when the pair is a persisted favorite.
  Future<void> _editSyncRules(SyncPlanController session) async {
    final store = widget.bookmarks;
    final servers = store == null
        ? const <Bookmark>[]
        : await _syncServerChoices(store);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<SyncPairEditorResult>(
      context: context,
      builder: (_) => SyncPairEditorDialog(
        initial: session.pair,
        // The live session's answers seed the case fields — an
        // unrelated save must not reset them to "auto".
        initialCaseOverrides: SyncCaseOverrides(
          left: session.pairState.caseSensitiveOverrideLeft,
          right: session.pairState.caseSensitiveOverrideRight,
        ),
        servers: servers,
        saveLabel: l10n.syncEditorSaveAndRescan,
      ),
    );
    if (result == null || !mounted) return;
    await session.updatePairDefinition(
      result.pair,
      caseOverrides: result.caseOverrides,
    );
    final existing = store == null ? null : await store.byId(result.pair.id);
    if (existing?.kind == BookmarkKind.savedSync) {
      try {
        await _persistSyncPair(result.pair);
      } on Object catch (error, stackTrace) {
        ApplicationErrorReporter().report(error, stackTrace);
      }
    }
  }

  /// Every sync open lands here: one SyncPlanController per tab on
  /// the resolved strip (default the active pane), deviceId resolved
  /// once for the session's run-id prefixes. [intent] is the sheet's
  /// verb — Synchronize auto-runs a creates-only plan (D32 §7).
  Future<void> _openSyncPlan(
    SyncPair pair, {
    SyncCaseOverrides? caseOverrides,
    PaneTabsController? strip,
    SyncPlanIntent intent = SyncPlanIntent.review,
  }) async {
    final environment = widget.syncEnvironment;
    final syncTasks = widget.syncTasks;
    if (_workspace == null || environment == null || syncTasks == null) {
      return;
    }
    final deviceId = await environment.deviceId();
    // The await lets a workspace swap dispose the shell's workspace
    // mid-flight — re-resolve, never open on a stale strip.
    if (!mounted) return;
    final workspace = _workspace;
    if (workspace == null) return;
    final target = strip ?? workspace.activePane;
    target.openSyncPlanTab(
      SyncPlanController(
        pair: pair,
        environment: environment,
        syncTasks: syncTasks,
        deviceId: deviceId,
        caseOverrides: caseOverrides,
        intent: intent,
        // 05 §2.1's export seam: shared-mode `serverConfigId` refs
        // resolve through the pulled Séance catalog; embedded
        // identities resolve directly (rsync_endpoints.dart).
        rsyncEndpoints: (p) => resolveRsyncEndpoints(
          p,
          serverConfig: _serverConfigById,
        ),
      ),
    );
    workspace.setActivePane(target);
    _showCompactBrowser();
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

  /// The Connections row's Disconnect (02 §4), and Server ▸ Disconnect
  /// for the active tab's server: drops the pool's reference for the
  /// server through the pane lanes — the same seam a pane's recovery
  /// banner cancels through.
  Future<void> _disconnectServer(String serverId) async {
    try {
      await widget.engineSession?.paneLanes.disconnectServer(serverId);
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
    if (_compactPosture) {
      // The compact posture's sidebar is Home (D32 §9).
      _compactKey.currentState?.showHome();
      return;
    }
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

/// Leading room for the macOS traffic lights when the header reaches the
/// window's leading edge (sidebar hidden or in the drawer).
const _macTrafficLightsInset = 76.0;

/// How far past a region's minimum a drag must go before it hides the
/// region (10 §3.1): a deliberate fling, never an accidental nudge.
const _collapseOvershoot = 48.0;

/// The panes' floor the sidebar and inspector yield to (10 §3.2): two
/// minimum panes and their splitter.
const _paneRegionMin = 2 * minPaneWidth + paneSplitterExtent;

/// Sidebar width bounds (10 §3.1).
const sidebarDefaultWidth = 232.0;
const sidebarMinWidth = 180.0;
const sidebarMaxWidth = 360.0;

/// The header's title block (10 §4): the active pane's location — the
/// folder or server name with the server dot, and `user@host` under it
/// for remotes only. The full path is a tooltip (remote:
/// `user@host:path`), never a second line (10 §2).
class _HeaderTitle extends StatelessWidget {
  const _HeaderTitle({required this.workspace});

  final WorkspaceController workspace;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final tab = workspace.activePane.activeTab;
    final controller = tab?.controller;
    final title = tab == null ? l10n.headerTitleEmpty : paneTabTitle(tab, l10n);
    final location = controller?.location;
    final bookmark = controller?.remoteBookmark;
    final identity = bookmark?.server?.identity;
    final subtitle = bookmark == null
        ? null
        : identity != null
        ? '${identity.username}@${identity.host}'
        : bookmark.label;
    final path = switch (location) {
      null => null,
      final loc when identity != null =>
        '${identity.username}@${identity.host}:${loc.path}',
      final loc when bookmark != null => '${bookmark.label}:${loc.path}',
      final loc => loc.path,
    };
    final block = Semantics(
      header: true,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  title,
                  key: const ValueKey('header.title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (bookmark != null && controller != null) ...[
                const SizedBox(width: 4),
                PaneConnectionDot(controller: controller),
              ],
            ],
          ),
          if (subtitle != null)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: chrome.secondaryText,
              ),
            ),
        ],
      ),
    );
    return path == null ? block : Tooltip(message: path, child: block);
  }
}

/// D32 §4's filter field: filters the active pane's listing as the user
/// types (the pane's own strip no longer opens for ⌘F), shows `12 of
/// 348` while a query is active, and Esc clears it back to the listing.
class _HeaderFilterField extends StatefulWidget {
  const _HeaderFilterField({required this.workspace, required this.focusNode});

  final WorkspaceController workspace;
  final FocusNode focusNode;

  @override
  State<_HeaderFilterField> createState() => _HeaderFilterFieldState();
}

class _HeaderFilterFieldState extends State<_HeaderFilterField> {
  final _text = TextEditingController();
  PaneController? _bound;

  @override
  void initState() {
    super.initState();
    widget.workspace.addListener(_rebind);
    _rebind();
  }

  @override
  void didUpdateWidget(covariant _HeaderFilterField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspace, widget.workspace)) {
      oldWidget.workspace.removeListener(_rebind);
      widget.workspace.addListener(_rebind);
      _rebind();
    }
  }

  /// Follows the active pane's active tab: the field always shows the
  /// query the focused listing is filtered by.
  void _rebind() {
    final next = widget.workspace.activeTabController;
    if (identical(next, _bound)) {
      _syncText();
      return;
    }
    _bound?.removeListener(_syncText);
    _bound = next;
    _bound?.addListener(_syncText);
    _syncText();
  }

  void _syncText() {
    final query = _bound?.filterQuery ?? '';
    if (_text.text != query) {
      _text.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.workspace.removeListener(_rebind);
    _bound?.removeListener(_syncText);
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final pane = _bound;
    final active = pane != null && pane.filterActive;
    return SizedBox(
      height: 28,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            pane?.clearFilter();
            _text.clear();
            widget.focusNode.unfocus();
          },
        },
        child: TextField(
          key: const ValueKey('header.filter'),
          controller: _text,
          focusNode: widget.focusNode,
          enabled: pane != null && pane.acceptsFilterQuery,
          style: theme.textTheme.bodyMedium,
          textAlignVertical: TextAlignVertical.center,
          onChanged: (value) => pane?.setFilterQuery(value),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: chrome.capsuleFill,
            hintText: l10n.headerFilterHint,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            prefixIcon: Icon(Icons.search, size: 16, color: chrome.secondaryText),
            prefixIconConstraints: const BoxConstraints(minWidth: 28),
            suffixIcon: active
                ? Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: Center(
                      widthFactor: 1,
                      child: Text(
                        l10n.paneFilterCount(
                          pane.entries.length,
                          pane.unfilteredCount,
                        ),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: chrome.secondaryText,
                        ),
                      ),
                    ),
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }
}
