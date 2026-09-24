import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/dock_progress.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';

final class _RecordingSurface implements DockProgressSurface {
  final progress = <double?>[];
  final badges = <String?>[];

  @override
  Future<void> setProgress(double? fraction) async => progress.add(fraction);

  @override
  Future<void> setBadge(String? label) async => badges.add(label);
}

void main() {
  test('idle clears the Dock indicator once, then stays quiet', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final surface = _RecordingSurface();
      DockProgressReporter(queue: queue, surface: surface);
      async.elapse(const Duration(seconds: 1));
      expect(surface.progress, [null]);
      expect(surface.badges, [null]);
      queue.emitRefresh();
      async.elapse(const Duration(seconds: 1));
      expect(surface.progress, [null], reason: 'unchanged state, no call');
    });
  });

  test('live tasks publish aggregate byte progress and a count badge', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final surface = _RecordingSurface();
      DockProgressReporter(queue: queue, surface: surface);
      queue.addTask(
        state: TransferTaskState.running,
        transferredBytes: 25,
        totalBytes: 100,
      );
      queue.addTask(
        state: TransferTaskState.running,
        transferredBytes: 25,
        totalBytes: 100,
      );
      async.elapse(const Duration(seconds: 1));
      expect(surface.progress.last, closeTo(0.25, 1e-9));
      expect(surface.badges.last, '2');
    });
  });

  test('bursts of queue events coalesce into one update per interval', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final surface = _RecordingSurface();
      DockProgressReporter(queue: queue, surface: surface);
      async.elapse(const Duration(seconds: 1));
      final task = queue.addTask(
        state: TransferTaskState.running,
        totalBytes: 100,
      );
      for (var i = 1; i <= 50; i++) {
        task.transferredBytes = i;
        queue.emitRefresh();
      }
      async.elapse(const Duration(milliseconds: 600));
      // One idle clear, then a single coalesced progress publish.
      expect(surface.progress, hasLength(2));
      expect(surface.progress.last, closeTo(0.5, 1e-9));
    });
  });

  test('a finished queue clears the indicator again', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final surface = _RecordingSurface();
      DockProgressReporter(queue: queue, surface: surface);
      final task = queue.addTask(
        state: TransferTaskState.running,
        transferredBytes: 10,
        totalBytes: 100,
      );
      async.elapse(const Duration(seconds: 1));
      task.state = TransferTaskState.completed;
      queue.emitRefresh();
      async.elapse(const Duration(seconds: 1));
      expect(surface.progress.last, isNull);
      expect(surface.badges.last, isNull);
    });
  });
}
