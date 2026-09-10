import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/application_error_reporter.dart';
import '../services/bookmark_store.dart';
import '../services/connection_state_bridge.dart';
import '../services/connection_status_controller.dart';
import '../services/engine_session.dart';
import '../services/probe_settings_store.dart';
import '../services/registered_command.dart';
import '../services/sftp_demo_controller.dart';
import '../services/ssh_config_import_setup.dart';
import 'adaptive_shell.dart';
import 'connections/connections_command.dart';
import 'demo/sftp_demo_view.dart';
import 'import/ssh_config_import_command.dart';

/// Provides the M1 chrome and placeholder pane content. Renders every
/// registered command (D21): the Connections surface and the D22 ssh_config
/// import entry when wired, plus — in debug builds only (app.dart ANDs the
/// flag with kDebugMode) — the M2 demo command (07 §3.3's debug-only listing
/// surface; throwaway, M3 replaces it).
class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({
    super.key,
    this.initialPaneRatio = 0.5,
    this.onPaneRatioChanged,
    this.onPaneRatioSaveError,
    this.debugDemoEnabled = kDebugMode,
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
  final bool debugDemoEnabled;
  final SftpDemoEngineFactory? sftpDemoEngineFactory;
  final ProbeSettings? probeSettings;

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
  /// exists (the startup-wiring slice spawns one), which leaves every
  /// listed server without live truth rather than guessing at it.
  /// Same identity-stability contract as [bookmarks].
  final ConnectionStateBridge? connectionEngine;

  /// The app's long-lived production engine session (startup
  /// composition): its lanes feed the Connections surface, its coordinator
  /// answers prompts from any production surface, its review seam leads a
  /// blocked row to the changed-key dialog, and the debug demo reuses its
  /// engine — never a second spawn. Null leaves those unwired (tests and
  /// alternate boot paths).
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

  @override
  void initState() {
    super.initState();
    _connections = _buildConnections();
  }

  @override
  void didUpdateWidget(WorkspaceShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The composition root supplies the store once but may supply the
    // engine later (the startup-wiring flow mounts the shell before any
    // engine exists); a replacement of either must not leave the surface
    // listing the previous store's bookmarks or a dead engine seam.
    if (identical(oldWidget.bookmarks, widget.bookmarks) &&
        identical(oldWidget.connectionEngine, widget.connectionEngine) &&
        identical(oldWidget.engineSession, widget.engineSession)) {
      return;
    }

    _connections?.dispose();
    _connections = _buildConnections();
  }

  /// 03 §6's app-wide `ConnectionStatus`, or null where the composition root
  /// supplied no store and the surface therefore stays unregistered.
  ///
  /// The controller's own default error reporter routes to
  /// `FlutterError.reportError` — the same default sink main.dart's
  /// app-wide reporter uses — so failures surface without a wired sink.
  ConnectionStatusController? _buildConnections() {
    final bookmarks = widget.bookmarks;
    if (bookmarks == null) return null;

    return ConnectionStatusController(
      bookmarks: bookmarks,
      // A session's lanes are the production engine's own; an injected
      // seam (tests) stands in only where no session exists.
      bridge: widget.engineSession?.connectionLanes ?? widget.connectionEngine,
    );
  }

  @override
  void dispose() {
    _connections?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;

    // Every user action is a registered command (D21); the toolbar
    // renders registered commands, it never hard-codes a button.
    // The probe wiring must persist: the composition root supplies the
    // store-backed settings whenever the demo surface is enabled. The
    // assert trips in debug; release builds gate the command instead of
    // crashing on a misconfigured shell.
    final probeSettings = widget.probeSettings;
    assert(!widget.debugDemoEnabled || probeSettings != null);
    final sshConfigImport = widget.sshConfigImport;
    final connections = _connections;
    final session = widget.engineSession;
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
        ),
      if (sshConfigImport != null)
        buildSshConfigImportCommand(
          setup: sshConfigImport,
          enabled: () => !_commandSessionActive,
        ),
      if (widget.debugDemoEnabled && probeSettings != null)
        buildSftpDemoCommand(
          // One engine per process: the session's engine overrides any
          // factory while it lives; without a session the demo owns its
          // spawn (the pre-session posture, still used by tests).
          spawnEngine:
              session?.demoEngineFactory ??
              widget.sftpDemoEngineFactory ??
              spawnSftpDemoEngine,
          engineOwnership: session == null
              ? SftpDemoEngineOwnership.sessionOwned
              : SftpDemoEngineOwnership.shared,
          sharedPrompts: session?.prompts,
          probeSettings: probeSettings,
          enabled: () => !_commandSessionActive,
        ),
    ];

    return Scaffold(
      body: SafeArea(
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
                primary: _EmptyPane(
                  title: strings.paneAName,
                  prompt: strings.emptyPanePrompt,
                ),
                secondary: _EmptyPane(
                  title: strings.paneBName,
                  prompt: strings.emptyPanePrompt,
                ),
              ),
            ),
            Divider(height: 1, color: colors.outlineVariant),
            _StatusBar(label: strings.readyStatus),
          ],
        ),
      ),
    );
  }

  /// Runs one registered command. Escaping failures are reported — the
  /// toolbar's onPressed discards the returned future, so an unhandled
  /// error here would surface only as a zone complaint.
  Future<void> _runCommand(RegisteredCommand command) async {
    // The command's own enabled() predicate is the authority: it flips
    // synchronously, so a second tap in the same frame (before the
    // disabled rebuild lands) is still refused, and a future command
    // with its own lifecycle is never blocked by this one's session.
    // Contract: run() stays pending for the command's whole session (the
    // demo awaits its route's pop), so the flag tracks the session.
    if (!command.enabled()) return;
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

class _EmptyPane extends StatelessWidget {
  const _EmptyPane({required this.title, required this.prompt});

  final String title;
  final String prompt;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return ColoredBox(
      color: colors.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 34,
            alignment: AlignmentDirectional.centerStart,
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 12),
            color: colors.surfaceContainerLow,
            child: Text(title, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(
            child: Center(
              child: Text(
                prompt,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
          ),
        ],
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
