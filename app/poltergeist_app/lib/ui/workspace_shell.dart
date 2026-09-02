import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'adaptive_shell.dart';

/// Provides the M1 chrome and placeholder pane content.
class WorkspaceShell extends StatelessWidget {
  const WorkspaceShell({
    super.key,
    this.initialPaneRatio = 0.5,
    this.onPaneRatioChanged,
    this.onPaneRatioSaveError,
  });

  final double initialPaneRatio;
  final PaneRatioSaver? onPaneRatioChanged;
  final void Function(Object, StackTrace)? onPaneRatioSaveError;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _Toolbar(title: strings.appTitle),
            Divider(height: 1, color: colors.outlineVariant),
            Expanded(
              child: AdaptiveShell(
                initialPaneRatio: initialPaneRatio,
                onPaneRatioChanged: onPaneRatioChanged,
                onPaneRatioSaveError: onPaneRatioSaveError,
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
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
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
