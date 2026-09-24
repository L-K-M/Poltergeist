import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/alert_center.dart';
import '../../theme/app_theme.dart';
import '../activity/activity_format.dart';
import '../server_label_scope.dart';

/// The verbs an alert row offers, bound by the shell (the Alerts tab
/// owns no behavior — every action routes to the surface that already
/// owns it: the queue, the host-key review, the edits review, the
/// release page).
class AlertActions {
  const AlertActions({
    required this.showTransfers,
    required this.retryTask,
    required this.resumeRestored,
    this.reviewHostKey,
    this.reviewLocalEdits,
    this.openRelease,
  });

  final VoidCallback showTransfers;
  final void Function(TransferTask task) retryTask;
  final VoidCallback resumeRestored;
  final void Function(String serverId)? reviewHostKey;
  final void Function(String serverId)? reviewLocalEdits;
  final void Function(UpdateInfo info)? openRelease;
}

/// D32's Alerts tab (10 §3): every live thing that needs the user, most
/// severe first, each with the one action that resolves it and a
/// dismiss. Empty is a calm "All clear", never a blank panel (02 §2.7).
class AlertsView extends StatelessWidget {
  const AlertsView({super.key, required this.center, required this.actions});

  final AlertCenter center;
  final AlertActions actions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chrome = PoltergeistChrome.of(context);
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        final alerts = center.alerts;
        if (alerts.isEmpty) {
          return Center(
            key: const ValueKey('alerts.empty'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 32,
                  color: chrome.secondaryText,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.alertsEmpty,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: chrome.secondaryText),
                ),
              ],
            ),
          );
        }
        return ListView.separated(
          key: const ValueKey('alerts.list'),
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: alerts.length,
          separatorBuilder: (_, _) =>
              Divider(height: 1, indent: 40, color: chrome.separator),
          itemBuilder: (context, index) => _AlertRow(
            alert: alerts[index],
            actions: actions,
            onDismiss: () => center.dismiss(alerts[index]),
          ),
        );
      },
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({
    required this.alert,
    required this.actions,
    required this.onDismiss,
  });

  final AppAlert alert;
  final AlertActions actions;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final labelOf = ServerLabelScope.maybeOf(context);
    String serverName(String id) => labelOf?.call(id) ?? id;

    final (IconData icon, Color color) = switch (alert.severity) {
      AlertSeverity.error => (Icons.error_outline, theme.colorScheme.error),
      AlertSeverity.warning => (
        Icons.warning_amber_outlined,
        theme.colorScheme.tertiary,
      ),
      AlertSeverity.info => (Icons.info_outline, theme.colorScheme.primary),
    };

    final (String title, String? detail, List<(String, VoidCallback)> verbs) =
        switch (alert) {
          TransferFailedAlert(:final task) => (
            l10n.alertTransferFailed(transferTaskTitle(task, l10n)),
            task.items
                .map((item) => item.error)
                .whereType<String>()
                .firstOrNull,
            [
              (l10n.alertActionRetry, () => actions.retryTask(task)),
              (l10n.alertActionShow, actions.showTransfers),
            ],
          ),
          ConflictsPendingAlert(:final count) => (
            l10n.alertConflictsPending(count),
            null,
            [(l10n.alertActionResolve, actions.showTransfers)],
          ),
          RestoredQueueAlert(:final count) => (
            l10n.alertRestoredQueue(count),
            null,
            [
              (l10n.activityRestoredResume, actions.resumeRestored),
              (l10n.alertActionShow, actions.showTransfers),
            ],
          ),
          ConnectionAlert(:final server, :final blocked) => (
            blocked
                ? l10n.alertHostKeyChanged(server.label)
                : l10n.alertConnectionFailed(server.label),
            (alert as ConnectionAlert).detail,
            [
              if (blocked && actions.reviewHostKey != null)
                (
                  l10n.alertActionReview,
                  () => actions.reviewHostKey!(server.serverId),
                ),
            ],
          ),
          LocalEditsAlert(:final serverId, :final count) => (
            l10n.alertLocalEdits(count, serverName(serverId)),
            null,
            [
              if (actions.reviewLocalEdits != null)
                (
                  l10n.alertActionReview,
                  () => actions.reviewLocalEdits!(serverId),
                ),
            ],
          ),
          UpdateAvailableAlert(:final info) => (
            l10n.alertUpdateAvailable(info.latestVersion),
            null,
            [
              if (actions.openRelease != null)
                (l10n.alertActionViewRelease, () => actions.openRelease!(info)),
            ],
          ),
        };

    return Padding(
      key: ValueKey('alert.${alert.key}'),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 6, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: chrome.secondaryText,
                    ),
                  ),
                ],
                if (verbs.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    children: [
                      for (final (label, run) in verbs)
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 28),
                          ),
                          onPressed: run,
                          child: Text(label),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            key: ValueKey('alert.${alert.key}.dismiss'),
            tooltip: l10n.alertActionDismiss,
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: onDismiss,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
