import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/application_error_reporter.dart';
import '../services/bookmark_store.dart';
import '../services/connection_state_bridge.dart';
import '../services/connection_status_controller.dart';
import '../services/engine_session.dart';
import '../services/pane_controller.dart';
import '../services/pane_location.dart';
import '../services/registered_command.dart';
import '../services/ssh_config_import_setup.dart';
import '../services/workspace_controller.dart';
import 'adaptive_shell.dart';
import 'connections/connections_command.dart';
import 'import/ssh_config_import_command.dart';
import 'panes/pane_commands.dart';
import 'panes/pane_view.dart';

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
    this.onPaneRatioChanged,
    this.onPaneRatioSaveError,
    this.sshConfigImport,
    this.bookmarks,
    this.connectionEngine,
    this.engineSession,
  });

  final double initialPaneRatio;
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
    _connections = _buildConnections();
    _buildWorkspace();
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
      _disposeWorkspace();
      _buildWorkspace();
    }
  }

  @override
  void dispose() {
    _connections?.dispose();
    _disposeWorkspace();
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

  void _buildWorkspace() {
    final lanes = widget.engineSession?.paneLanes;
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    _workspace = WorkspaceController(left: left, right: right);
    _leftFocus = FocusNode(debugLabel: 'pane.left.listing');
    _rightFocus = FocusNode(debugLabel: 'pane.right.listing');

    // The initial binding: both panes browse the local home through the
    // engine's local channel (03 §5's seam; one engine, no second spawn).
    // Keyboard starts on the left pane's listing.
    if (lanes != null) {
      unawaited(left.openLocalHome());
      unawaited(right.openLocalHome());
    }
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
    _workspace?.dispose();
    _workspace = null;
    _leftFocus?.dispose();
    _leftFocus = null;
    _rightFocus?.dispose();
    _rightFocus = null;
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
      if (workspace != null && leftFocus != null && rightFocus != null)
        ...buildPaneCommands(
          workspace: workspace,
          focusLeft: () => _focusPane(leftFocus),
          focusRight: () => _focusPane(rightFocus),
          swapFocus: () => _focusPane(
            identical(workspace.activePane, workspace.left)
                ? rightFocus
                : leftFocus,
          ),
        ),
    ];

    return Scaffold(
      body: SafeArea(
        child: CommandChordScope(
          commands: commands,
          child: Column(
            children: [
              _Toolbar(
                title: strings.appTitle,
                commands: commands,
                onRun: _runCommand,
              ),
              Divider(height: 1, color: colors.outlineVariant),
              Expanded(
                child: AdaptiveShell(
                  initialPaneRatio: widget.initialPaneRatio,
                  onPaneRatioChanged: widget.onPaneRatioChanged,
                  onPaneRatioSaveError: widget.onPaneRatioSaveError,
                  resizeLabel: strings.resizePanes,
                  formatRatio: (ratio) =>
                      strings.paneRatioPercent((ratio * 100).round()),
                  primary: workspace == null || leftFocus == null
                      ? const SizedBox.shrink()
                      : PaneView(
                          controller: workspace.left,
                          workspace: workspace,
                          focusNode: leftFocus,
                          onSwapFocus: () => _focusPane(rightFocus),
                          onCancelRecovery: () =>
                              _cancelPaneRecovery(workspace, workspace.left),
                        ),
                  secondary: workspace == null || rightFocus == null
                      ? const SizedBox.shrink()
                      : PaneView(
                          controller: workspace.right,
                          workspace: workspace,
                          focusNode: rightFocus,
                          onSwapFocus: () => _focusPane(leftFocus),
                          onCancelRecovery: () =>
                              _cancelPaneRecovery(workspace, workspace.right),
                        ),
                ),
              ),
              Divider(height: 1, color: colors.outlineVariant),
              _StatusBar(label: strings.readyStatus),
            ],
          ),
        ),
      ),
    );
  }

  void _focusPane(FocusNode? node) {
    node?.requestFocus();
  }

  /// The banner's cancel, sibling-aware (02 §2.7 in a two-pane world):
  /// the engine keys pool references by serverId, so a plain disconnect
  /// would kill a sibling pane browsing the same server. Detach only the
  /// cancelling pane when the server is shared; drop the reference — and
  /// with it the pool's recovery — when this pane is its last user.
  Future<void> _cancelPaneRecovery(
    WorkspaceController workspace,
    PaneController pane,
  ) async {
    final location = pane.location;
    if (location is! RemotePaneLocation) return;
    final sibling = identical(pane, workspace.left)
        ? workspace.right
        : workspace.left;
    final siblingLocation = sibling.location;
    final siblingShares =
        siblingLocation is RemotePaneLocation &&
        siblingLocation.serverId == location.serverId;
    try {
      if (siblingShares) {
        await pane.detachRemote();
      } else {
        await pane.cancelRecovery();
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
          await pane.connectRemote(bookmark);
          return;
        }
      }
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
                child: TextButton.icon(
                  key: ValueKey('command.${command.id}'),
                  onPressed: command.enabled() ? () => onRun(command) : null,
                  icon: Icon(
                    command.icon ?? Icons.bug_report_outlined,
                    size: 18,
                  ),
                  label: Text(
                    command.label(l10n),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
  const _StatusBar({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 10),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(label, style: Theme.of(context).textTheme.labelSmall),
        ),
      ),
    );
  }
}
