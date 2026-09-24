import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/activity_panel_controller.dart';
import 'package:poltergeist_app/services/alert_center.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';

void main() {
  late FakeAppTransferQueue queue;
  late ActivityPanelController activity;
  late AlertCenter center;

  setUp(() {
    queue = FakeAppTransferQueue();
    activity = ActivityPanelController(queue: queue);
    center = AlertCenter(activity: activity);
  });

  tearDown(() {
    center.dispose();
    activity.dispose();
  });

  test('a calm queue raises nothing', () {
    queue.addTask(state: TransferTaskState.running);
    expect(center.alerts, isEmpty);
    expect(center.attentionCount, 0);
  });

  test('a failed task becomes an error alert and badges', () async {
    final task = queue.addTask(state: TransferTaskState.failed);
    await Future<void>.delayed(Duration.zero);
    expect(center.alerts, hasLength(1));
    final alert = center.alerts.single as TransferFailedAlert;
    expect(alert.task.id, task.id);
    expect(alert.severity, AlertSeverity.error);
    expect(center.attentionCount, 1);
  });

  test('an alert disappears when its cause resolves', () async {
    final task = queue.addTask(state: TransferTaskState.failed);
    await Future<void>.delayed(Duration.zero);
    expect(center.alerts, isNotEmpty);
    task.state = TransferTaskState.running;
    queue.emitRefresh();
    await Future<void>.delayed(Duration.zero);
    expect(center.alerts, isEmpty);
  });

  test('dismissal hides an alert for the session', () async {
    queue.addTask(state: TransferTaskState.failed);
    await Future<void>.delayed(Duration.zero);
    var notified = 0;
    center.addListener(() => notified++);
    center.dismiss(center.alerts.single);
    expect(center.alerts, isEmpty);
    expect(notified, 1);
  });

  test('errors sort ahead of info alerts', () async {
    queue.addTask(state: TransferTaskState.paused, wasRestored: true, id: 'r1');
    queue.pauseQueue();
    queue.addTask(state: TransferTaskState.failed);
    await Future<void>.delayed(Duration.zero);
    final severities = [for (final a in center.alerts) a.severity];
    expect(severities.first, AlertSeverity.error);
  });
}
