import 'dart:ui' show Color, Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/activity_panel_controller.dart';
import 'package:poltergeist_app/services/alert_center.dart';
import 'package:poltergeist_app/services/drag_out_controller.dart';
import 'package:poltergeist_app/services/os_drag_out.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';
import '../support/fake_drag_out.dart';

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

  test('a dismissed alert returns when its cause recurs', () async {
    // D16: failures must never hide. Dismissing covers the failure the
    // user saw; a retry that fails again is a new one.
    final task = queue.addTask(state: TransferTaskState.failed);
    await Future<void>.delayed(Duration.zero);
    center.dismiss(center.alerts.single);
    expect(center.attentionCount, 0);

    task.state = TransferTaskState.running;
    queue.emitRefresh();
    await Future<void>.delayed(Duration.zero);
    expect(center.alerts, isEmpty);

    task.state = TransferTaskState.failed;
    queue.emitRefresh();
    await Future<void>.delayed(Duration.zero);
    expect(center.alerts.single, isA<TransferFailedAlert>());
    expect(center.attentionCount, 1);
  });

  test('a dismissal holds while its cause persists', () async {
    final task = queue.addTask(state: TransferTaskState.failed);
    await Future<void>.delayed(Duration.zero);
    center.dismiss(center.alerts.single);

    // Unrelated queue churn leaves the same failure dismissed.
    queue.addTask(state: TransferTaskState.running);
    queue.emitRefresh();
    await Future<void>.delayed(Duration.zero);
    expect(task.state, TransferTaskState.failed);
    expect(center.alerts, isEmpty);
  });

  test('errors sort ahead of info alerts', () async {
    queue.addTask(state: TransferTaskState.paused, wasRestored: true, id: 'r1');
    queue.pauseQueue();
    queue.addTask(state: TransferTaskState.failed);
    await Future<void>.delayed(Duration.zero);
    final severities = [for (final a in center.alerts) a.severity];
    expect(severities.first, AlertSeverity.error);
  });

  test('a refused drag-out raises an alert until dismissed', () async {
    final backend = FakeDragOutBackend(
      support: DragOutSupport.localFilesAndPromises,
    );
    final dragOut = DragOutController(
      backend: backend,
      files: FakeDragOutProducer(),
      queue: queue,
      dropStagingDirectory: '/tmp/Drops',
    );
    addTearDown(dragOut.dispose);
    final withDragOut = AlertCenter(activity: activity, dragOut: dragOut);
    addTearDown(withDragOut.dispose);
    queue.pauseQueue();
    await dragOut.handOff(
      PaneEntryDrag(
        source: const ServerFsLocation('srv-1'),
        rootPaths: const ['/srv/site'],
        entries: const [
          RemoteFileEntry(
            path: '/srv/site',
            name: 'site',
            type: RemoteFileType.directory,
          ),
        ],
      ),
      position: Offset.zero,
      style: DragOutImageStyle(
        palette: const DragOutImagePalette(
          background: Color(0xFFFFFFFF),
          foreground: Color(0xFF000000),
          badge: Color(0xFF0000FF),
          onBadge: Color(0xFFFFFFFF),
        ),
        devicePixelRatio: 1,
        itemCountLabel: (count) => '$count',
      ),
    );
    await expectLater(
      dragOut.fulfilPromise(
        DragOutPromiseRequest(
          sessionId: backend.requests.single.sessionId,
          promiseId: 'p1',
          destinationPath: '/Users/me/Desktop/site',
        ),
      ),
      throwsA(isA<DragOutPromiseException>()),
    );
    final alert = withDragOut.alerts.single as DragOutAlert;
    expect(alert.notice.kind, DragOutNoticeKind.paused);
    expect(alert.notice.itemName, 'site');
    expect(alert.severity, AlertSeverity.warning);
    withDragOut.dismiss(alert);
    expect(withDragOut.alerts, isEmpty);
  });
}
