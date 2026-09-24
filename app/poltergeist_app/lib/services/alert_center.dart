import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'activity_panel_controller.dart';
import 'checkout_session.dart';
import 'connection_status_controller.dart';
import 'update_check_controller.dart';

/// How loudly an alert asks for attention (D32 §3's Alerts tab).
enum AlertSeverity { error, warning, info }

/// One thing that needs the user — D32's Alerts tab rows (10 §2's
/// "things that need you live in Alerts"). Each variant carries the
/// live source object, never a copied snapshot of its text: the view
/// localizes at render time and the source stays the one truth.
sealed class AppAlert {
  const AppAlert();

  /// Stable identity for session dismissal and list keys.
  String get key;

  AlertSeverity get severity;
}

/// A transfer task that ended failed (D16: failures must never hide).
final class TransferFailedAlert extends AppAlert {
  const TransferFailedAlert(this.task);

  final TransferTask task;

  @override
  String get key => 'task:${task.id}';

  @override
  AlertSeverity get severity => AlertSeverity.error;
}

/// Conflicts parked on the queue, waiting for a decision (02 §5.2).
final class ConflictsPendingAlert extends AppAlert {
  const ConflictsPendingAlert(this.count);

  final int count;

  @override
  String get key => 'conflicts';

  @override
  AlertSeverity get severity => AlertSeverity.warning;
}

/// Journaled work a relaunch restored behind the forced queue pause.
final class RestoredQueueAlert extends AppAlert {
  const RestoredQueueAlert(this.count);

  final int count;

  @override
  String get key => 'restored';

  @override
  AlertSeverity get severity => AlertSeverity.info;
}

/// A server whose connection failed, lost a pane binding, or is blocked
/// on a changed host key (D18: never auto-repinned).
final class ConnectionAlert extends AppAlert {
  const ConnectionAlert(this.server);

  final ConnectionServer server;

  bool get blocked => server.status?.state == ServerConnectionState.blocked;

  /// The engine's sanitized one-liner: the block reason, the connect
  /// failure, or the pane binding's recovery failure.
  String? get detail => server.status?.detail ?? server.paneFailure?.message;

  @override
  String get key => 'server:${server.serverId}';

  @override
  AlertSeverity get severity =>
      blocked ? AlertSeverity.error : AlertSeverity.warning;
}

/// Managed checkouts holding edits that never uploaded (06 §3.7).
final class LocalEditsAlert extends AppAlert {
  const LocalEditsAlert({required this.serverId, required this.count});

  final String serverId;
  final int count;

  @override
  String get key => 'edits:$serverId';

  @override
  AlertSeverity get severity => AlertSeverity.warning;
}

/// A newer release exists (D19's link-only update check).
final class UpdateAvailableAlert extends AppAlert {
  const UpdateAvailableAlert(this.info);

  final UpdateInfo info;

  @override
  String get key => 'update:${info.latestVersion}';

  @override
  AlertSeverity get severity => AlertSeverity.info;
}

/// D32's alert inbox: a derived, always-current view over the sources
/// that already own each truth — the queue mirror, the connection
/// status notifier, the checkout session, and the update check. It
/// stores nothing but the session's dismissals, so an alert disappears
/// the moment its cause resolves (a retried task, a clean upload, a
/// reconnect) and can never go stale.
class AlertCenter extends ChangeNotifier {
  AlertCenter({
    required ActivityPanelController activity,
    ConnectionStatusController? connections,
    CheckoutSession? checkouts,
    UpdateCheckController? updates,
  }) : _activity = activity,
       _connections = connections,
       _checkouts = checkouts,
       _updates = updates {
    _sources = Listenable.merge([
      activity,
      ?connections,
      ?checkouts,
      ?updates,
    ])..addListener(_changed);
  }

  final ActivityPanelController _activity;
  final ConnectionStatusController? _connections;
  final CheckoutSession? _checkouts;
  final UpdateCheckController? _updates;
  late final Listenable _sources;
  final _dismissed = <String>{};
  List<AppAlert>? _cache;

  void _changed() {
    _cache = null;
    notifyListeners();
  }

  /// Every live, undismissed alert: errors first, then warnings, then
  /// info — within a severity, source order.
  List<AppAlert> get alerts => _cache ??= _derive();

  /// The badge count on the Alerts tab and the inspector toggle: every
  /// undismissed alert — an info row (an update, a paused restored
  /// queue) is still something the user has not seen, and a badge that
  /// skipped it would bury it in a tab nobody opens.
  int get attentionCount => alerts.length;

  /// Hides [alert] for this session. An update alert also dismisses the
  /// check's own banner state so the two surfaces agree.
  void dismiss(AppAlert alert) {
    if (alert is UpdateAvailableAlert) _updates?.dismiss();
    if (_dismissed.add(alert.key)) _changed();
  }

  List<AppAlert> _derive() {
    final result = <AppAlert>[];
    for (final task in _activity.tasks) {
      if (task.state == TransferTaskState.failed) {
        result.add(TransferFailedAlert(task));
      }
    }
    final conflicts = _activity.pendingConflicts.length;
    if (conflicts > 0) result.add(ConflictsPendingAlert(conflicts));
    final restored = _activity.restoredTasks.length;
    if (restored > 0 && _activity.queuePaused) {
      result.add(RestoredQueueAlert(restored));
    }
    final connections = _connections;
    if (connections != null) {
      for (final server in connections.servers) {
        final state = server.status?.state;
        final failed =
            state == ServerConnectionState.blocked ||
            server.paneFailure != null ||
            (state == ServerConnectionState.disconnected &&
                server.status?.detail != null);
        if (failed) result.add(ConnectionAlert(server));
      }
    }
    final checkouts = _checkouts;
    if (checkouts != null) {
      final counts = <String, int>{};
      for (final record in checkouts.records) {
        if (record.dirty || record.missing) {
          counts.update(record.serverId, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      for (final MapEntry(:key, :value) in counts.entries) {
        result.add(LocalEditsAlert(serverId: key, count: value));
      }
    }
    final update = _updates?.update;
    if (update != null) result.add(UpdateAvailableAlert(update));

    final visible = [
      for (final alert in result)
        if (!_dismissed.contains(alert.key)) alert,
    ];
    // Stable sort by severity keeps source order inside each band.
    final ordered = <AppAlert>[
      for (final severity in AlertSeverity.values)
        for (final alert in visible)
          if (alert.severity == severity) alert,
    ];
    return List.unmodifiable(ordered);
  }

  @override
  void dispose() {
    _sources.removeListener(_changed);
    super.dispose();
  }
}
