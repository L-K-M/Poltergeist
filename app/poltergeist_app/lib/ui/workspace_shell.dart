import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/application_error_reporter.dart';
import '../services/registered_command.dart';
import '../services/sftp_demo_controller.dart';
import 'adaptive_shell.dart';
import 'demo/sftp_demo_view.dart';

/// Provides the M1 chrome and placeholder pane content. In debug builds
/// (and only there — app.dart ANDs the flag with kDebugMode) it also
/// registers and renders the M2 demo commands (07 §3.3's debug-only
/// listing surface; throwaway, M3 replaces it).
class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({
    super.key,
    this.initialPaneRatio = 0.5,
    this.onPaneRatioChanged,
    this.onPaneRatioSaveError,
    this.debugDemoEnabled = kDebugMode,
    this.sftpDemoEngineFactory,
  });

  final double initialPaneRatio;
  final PaneRatioSaver? onPaneRatioChanged;
  final void Function(Object, StackTrace)? onPaneRatioSaveError;
  final bool debugDemoEnabled;
  final SftpDemoEngineFactory? sftpDemoEngineFactory;

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  bool _demoSessionActive = false;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;

    // Every user action is a registered command (D21); the toolbar
    // renders registered commands, it never hard-codes a button.
    final commands = <RegisteredCommand>[
      if (widget.debugDemoEnabled)
        buildSftpDemoCommand(
          spawnEngine: widget.sftpDemoEngineFactory ?? spawnSftpDemoEngine,
          enabled: () => !_demoSessionActive,
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

  /// Runs one registered command; the demo command's session flag keeps
  /// the entry disabled while its route is open. Escaping failures are
  /// reported — the toolbar's onPressed discards the returned future, so
  /// an unhandled error here would surface only as a zone complaint.
  Future<void> _runCommand(RegisteredCommand command) async {
    setState(() => _demoSessionActive = true);
    try {
      await command.run(context);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
    } finally {
      if (mounted) setState(() => _demoSessionActive = false);
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
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            for (final command in commands)
              TextButton.icon(
                key: ValueKey('command.${command.id}'),
                onPressed: command.enabled() ? () => onRun(command) : null,
                icon: const Icon(Icons.bug_report_outlined, size: 18),
                label: Text(command.label(l10n)),
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
