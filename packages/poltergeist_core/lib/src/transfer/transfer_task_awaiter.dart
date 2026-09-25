import 'dart:async';

import 'transfer_queue.dart' show TransferQueueEvent;
import 'transfer_task.dart';

/// Waits for an ordinary queue task to settle: the awaitable shape a
/// caller outside the queue needs when a journaled task, not a produce
/// hop, answers its request (00 D14's drag-out amendment: a folder
/// promise is fulfilled by a normal recursive download, and the OS
/// completion handler fires when that task ends).
///
/// Observes [events] for [taskId] and re-reads the [tasks] snapshot on
/// each one, so it works over the concrete queue and the app's
/// `AppTransferQueue` seam alike. Completes with the task once it is
/// terminal (completed, failed, or cancelled), or with null when the
/// task is not listed when the wait starts (a queue removes only
/// terminal rows, so a listed task always settles first), or when the
/// event stream closes on an unsettled task: nothing else would ever
/// complete the wait. A task that already settled before the call
/// resolves on the first check, like `QueuePreviewProducer`'s re-check
/// after registration.
Future<TransferTask?> awaitTransferTaskTerminal({
  required Stream<TransferQueueEvent> events,
  required List<TransferTask> Function() tasks,
  required String taskId,
}) {
  TransferTask? lookup() {
    for (final task in tasks()) {
      if (task.id == taskId) return task;
    }
    return null;
  }

  final completer = Completer<TransferTask?>();
  late final StreamSubscription<TransferQueueEvent> subscription;

  void check() {
    if (completer.isCompleted) return;
    final task = lookup();
    if (task != null && !task.isTerminal) return;
    completer.complete(task);
    unawaited(subscription.cancel());
  }

  // Subscribe before the first check: a terminal event that fires in
  // between is then observed rather than lost.
  subscription = events.listen(
    (event) {
      if (event.taskId == taskId) check();
    },
    onDone: () {
      if (completer.isCompleted) return;
      final task = lookup();
      completer.complete(task != null && task.isTerminal ? task : null);
    },
  );
  check();
  return completer.future;
}
