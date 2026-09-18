import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'fake_app_transfer_queue.dart';

/// The fake mirrors the real queue's conflict surface (transfer_queue
/// .dart): a cancelled item or task drops its parked conflicts with a
/// `pending: false` dismissal, and a scripted `id` without
/// `wasRestored` is a caller error — `TransferTask` mints its own id
/// otherwise, so honoring the parameter would be a silent lie.
void main() {
  late FakeAppTransferQueue queue;
  late List<TransferQueueConflictEvent> dismissals;

  setUp(() {
    queue = FakeAppTransferQueue();
    dismissals = [];
    queue.events.listen((event) {
      if (event is TransferQueueConflictEvent && !event.pending) {
        dismissals.add(event);
      }
    });
  });

  tearDown(() => queue.close());

  test('cancelItem drops the item\'s parked conflict', () async {
    final task = queue.addTask(state: TransferTaskState.running);
    final item = queue.addItem(task);
    queue.addConflict(task, item);
    expect(queue.pendingConflicts, hasLength(1));

    expect(queue.cancelItem(task.id, item.id), isTrue);
    await pumpEventQueue();

    expect(queue.pendingConflicts, isEmpty);
    expect(dismissals.single.taskId, task.id);
    expect(dismissals.single.itemId, item.id);
  });

  test('cancelTask drops every parked conflict on the task', () async {
    final task = queue.addTask(state: TransferTaskState.running);
    final itemA = queue.addItem(task, name: 'a.txt');
    final itemB = queue.addItem(task, name: 'b.txt');
    queue.addConflict(task, itemA);
    queue.addConflict(task, itemB);
    expect(queue.pendingConflicts, hasLength(2));

    queue.cancelTask(task.id);
    await pumpEventQueue();

    expect(queue.pendingConflicts, isEmpty);
    expect(
      dismissals.map((event) => event.itemId),
      containsAll(<String>[itemA.id, itemB.id]),
    );
  });

  test('a scripted id without wasRestored throws instead of no-opping',
      () {
    // TransferTask mints its own id for a live task; a scripted id the
    // fake cannot honor used to drop silently, leaving tests keyed on
    // an id no task carries.
    expect(() => queue.addTask(id: 'keyed'), throwsArgumentError);
  });
}
