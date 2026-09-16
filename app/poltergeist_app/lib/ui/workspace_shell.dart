import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/application_error_reporter.dart';
import '../services/bookmark_store.dart';
import '../services/connection_state_bridge.dart';
import '../services/connection_status_controller.dart';
import '../services/double_click_action.dart';
import '../services/engine_session.dart';
import '../services/pane_controller.dart';
import '../services/pane_tabs_controller.dart';
import '../services/registered_command.dart';
import '../services/session_persistence.dart';
import '../services/session_state.dart';
import '../services/ssh_config_import_setup.dart';
import '../services/sync_browsing_controller.dart';
import '../services/workspace_controller.dart';
import '../services/workspace_library.dart';
import 'adaptive_shell.dart';
import 'connections/connections_command.dart';
import 'import/ssh_config_import_command.dart';
import 'layout/pane_allocation.dart';
import 'menus/app_menu_host.dart';
import 'panes/pane_commands.dart';
import 'panes/pane_tabs_view.dart';
import 'panes/sync_browse_chip.dart';
import 'workspace/workspace_commands.dart';

/// The production two-pane shell (02 §1, foundation slice): toolbar over
/// the registered commands (D21), the pane pair in the M1 adaptive shell
/// with its persisted splitter ratio, and the status bar. The M2 interim
/// Connections surface stays (M5 owns its removal) and becomes the remote
/// entry point for panes — each row opens its bookmark in the active pane.
/// The M2 debug demo surface is retired: the panes supersede its flow.
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
    this.bookmarks,
    this.workspaces,
    this.connectionEngine,
    this.engineSession,
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

  /// The persisted bookmark store the Connections surface lists (03 §6's
  /// `BookmarkStore` seam). Null leaves that command unregistered.
  ///
  /// Callers must pass a stable instance across rebuilds: the shell keys
  /// its controller lifecycle on seam identity, so a fresh wrapper per
  /// rebuild would churn watches and drop the loaded list.
  final BookmarkRepository? bookmarks;

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

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  bool _commandSessionActive = false;

  /// 03 §6's app-wide `ConnectionStatus`: one per window root, owned here so
  /// its watches die with the shell. M5's sidebar composition consumes the
  /// same instance instead of a second watcher.
  ConnectionStatusController? _connections;

  /// The pane pair and active pane (03 §6's WorkspaceController, foundation
  /// slice) plus the per-pane listing focus nodes (02 §8.2). Rebuilt when
  /// the engine session identity changes; the panes rebind their initial
  /// location with the new lanes.
  WorkspaceController? _workspace;
  FocusNode? _leftFocus;
  FocusNode? _rightFocus;

  @override
  void initState() {
    super.initState();
    // Focus nodes are session-independent: a session rebind replaces
    // only the pane controllers, so focus (and its pane activation)
    // survives the swap instead of dropping to the root scope and being
    // re-claimed by the left pane.
    _leftFocus = FocusNode(debugLabel: 'pane.left.listing');
    _rightFocus = FocusNode(debugLabel: 'pane.right.listing');
    _connections = _buildConnections();
    _buildWorkspace();
    widget.workspaces?.addListener(_onWorkspacesChanged);
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
    if (!identical(oldWidget.engineSession, widget.engineSession)) {
      _workspace?.dispose();
      _workspace = null;
      _buildWorkspace();
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
  }

  @override
  void dispose() {
    widget.workspaces?.removeListener(_onWorkspacesChanged);
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

    return ConnectionStatusController(
      bookmarks: bookmarks,
      bridge: widget.engineSession?.connectionLanes ?? widget.connectionEngine,
    );
  }

  /// Whether the launch session document was already consumed: it seeds
  /// exactly one workspace build — an engine-session rebind later must
  /// not replay launch state over the session the user has since built.
  bool _sessionRestoreConsumed = false;

  void _buildWorkspace() {
    final lanes = widget.engineSession?.paneLanes;
    PaneTabsController buildStrip(String paneId) {
      final strip = PaneTabsController(
        paneId: paneId,
        lanes: lanes,
        newTabTarget: widget.newTabTarget,
        doubleClickAction: widget.doubleClickAction,
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
      if (restored.activePaneId == PaneTabsController.rightPaneId) {
        // Refused while pane B is hidden — the workspace's own rule
        // parks commands on the survivor (02 §3).
        workspace.setActivePane(right);
      }
    } else {
      left.newTab(target: NewTabTarget.home);
      right.newTab(target: NewTabTarget.home);
    }
    // The change listener attaches only after the initial state
    // settles: a launch-time visibility flip is restoration, not a
    // user-driven hide edge — the synchronous notify inside
    // setSecondPaneHidden would otherwise fire _onWorkspaceChanged's
    // focus handoff before the first frame. Seed the tracker from the
    // settled state, never a hardcoded shown.
    workspace.addListener(_onWorkspaceChanged);
    _secondPaneWasShown = workspace.secondPaneShown;
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
    final connections = _connections;
    final session = widget.engineSession;
    final workspace = _workspace;
    final leftFocus = _leftFocus;
    final rightFocus = _rightFocus;

    final commands = <RegisteredCommand>[
      if (connections != null)
        buildConnectionsCommand(
          controller: connections,
          enabled: () => !_commandSessionActive,
          // The blocked-review affordance exists only where a composition
          // can start a connect: the session's engine raises the pool's
          // changed-key review at the attempt (D18).
          onReviewBlocked: session == null
              ? null
              : (server) => unawaited(
                  session.reviewBlockedHostKey(server.serverId),
                ),
          // The pane entry point (07 §3.4's M3 window: the interim list
          // stays until M5): opening binds the ACTIVE pane to the row's
          // bookmark path.
          onOpenInPane: session == null || workspace == null
              ? null
              : (server) => unawaited(_openBookmarkInActivePane(server)),
        ),
      if (sshConfigImport != null)
        buildSshConfigImportCommand(
          setup: sshConfigImport,
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
        ),
    ];

    // Re-evaluate enablement without rebuilding the pane listings — one
    // shared listenable for the toolbar and the registry-driven menus.
    final enablement = Listenable.merge([
      if (workspace != null) ...[
        workspace,
        workspace.left,
        workspace.right,
      ],
    ]);

    return Scaffold(
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
                        builder: (context, _) => AdaptiveShell(
                          initialPaneRatio: widget.initialPaneRatio,
                          secondPaneIntent: workspace.secondPaneHidden
                              ? SecondPaneIntent.hidden
                              : SecondPaneIntent.shown,
                          onSecondPaneVisibilityChanged:
                              workspace.setSecondPaneLayoutShown,
                          onPaneRatioChanged: widget.onPaneRatioChanged,
                          onPaneRatioSaveError: widget.onPaneRatioSaveError,
                          resizeLabel: strings.resizePanes,
                          formatRatio: (ratio) =>
                              strings.paneRatioPercent((ratio * 100).round()),
                          primary: PaneTabsView(
                            tabs: workspace.left,
                            workspace: workspace,
                            focusNode: leftFocus,
                            onSwapFocus: () => _focusPane(workspace.right),
                            onCancelRecovery: () => _cancelPaneRecovery(
                              workspace,
                              workspace.left.activeTabController,
                            ),
                            bookmarks: widget.bookmarks,
                          ),
                          secondary: rightFocus == null
                              ? const SizedBox.shrink()
                              : PaneTabsView(
                                  tabs: workspace.right,
                                  workspace: workspace,
                                  focusNode: rightFocus,
                                  onSwapFocus: () => _focusPane(workspace.left),
                                  onCancelRecovery: () => _cancelPaneRecovery(
                                    workspace,
                                    workspace.right.activeTabController,
                                  ),
                                  bookmarks: widget.bookmarks,
                                ),
                        ),
                      ),
              ),
              Divider(height: 1, color: colors.outlineVariant),
              _StatusBar(
                label: strings.readyStatus,
                syncLink: workspace?.syncBrowsing,
              ),
            ],
          ),
          ),
        ),
      ),
    );
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

  /// Resolves the row's bookmark and binds the active pane to it. The
  /// pane's own connect flow owns prompts and errors; failures surface in
  /// the pane, not here.
  Future<void> _openBookmarkInActivePane(ConnectionServer server) async {
    final store = widget.bookmarks;
    if (store == null) return;
    try {
      final bookmarks = await store.load();
      if (!mounted) return;
      // Re-resolve after the await: a session swap may have disposed the
      // captured workspace while the store read was in flight (09 §3.1's
      // recheck idiom — `mounted` alone does not cover it).
      final pane = _workspace?.activePane;
      if (pane == null) return;
      for (final bookmark in bookmarks) {
        if (bookmark.id == server.serverId) {
          // The row binds the pane's ACTIVE tab — a launcher pane grows
          // a tab for it rather than silently opening behind the strip.
          final tab =
              pane.activeTab ?? pane.newTab(target: NewTabTarget.launcher);
          await tab.controller.connectRemote(bookmark);
          return;
        }
      }
      // The row outlived its backing bookmark (deleted between render
      // and tap) — a silent dead tap would read as a broken button.
      ApplicationErrorReporter().report(
        StateError('openInPane: no bookmark for ${server.serverId}'),
        StackTrace.current,
      );
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
    }
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

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.label, this.syncLink});

  final String label;

  /// The workspace's Sync Browsing link (02 §7): while enabled the
  /// status bar carries the same chip the path bars do — the amber
  /// link-broken variant while suspended.
  final SyncBrowsingController? syncLink;

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
          ],
        ),
      ),
    );
  }
}
