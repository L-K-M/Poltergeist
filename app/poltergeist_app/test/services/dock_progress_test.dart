import 'dart:async';

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

final class _ThrowingSurface implements DockProgressSurface {
  var calls = 0;

  @override
  Future<void> setProgress(double? fraction) async {
    calls++;
    throw StateError('no taskbar');
  }

  @override
  Future<void> setBadge(String? label) async {}
}

void main() {
  test('an idle start never touches the platform surface', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final surface = _RecordingSurface();
      DockProgressReporter(
        queue: queue,
        surface: surface,
        surfaceReady: Future.value(),
      );
      async.elapse(const Duration(seconds: 1));
      queue.emitRefresh();
      async.elapse(const Duration(seconds: 1));
      expect(surface.progress, isEmpty, reason: 'nothing to show or clear');
      expect(surface.badges, isEmpty);
    });
  });

  test('nothing reaches the surface before the window is ready', () {
    // On Windows, window_manager's setProgressBar dereferences a
    // taskbar list created only by waitUntilReadyToShow; a publish
    // before that is a native crash no try/catch can stop.
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final surface = _RecordingSurface();
      final ready = Completer<void>();
      DockProgressReporter(
        queue: queue,
        surface: surface,
        surfaceReady: ready.future,
      );
      queue.addTask(
        state: TransferTaskState.running,
        transferredBytes: 25,
        totalBytes: 100,
      );
      async.elapse(const Duration(seconds: 5));
      expect(surface.progress, isEmpty);
      expect(surface.badges, isEmpty);

      ready.complete();
      async.elapse(const Duration(seconds: 1));
      expect(surface.progress, [closeTo(0.25, 1e-9)]);
      expect(surface.badges, ['1']);
    });
  });

  test('a window that never becomes ready keeps the surface untouched', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final surface = _RecordingSurface();
      DockProgressReporter(
        queue: queue,
        surface: surface,
        surfaceReady: Completer<void>().future,
      );
      queue.addTask(state: TransferTaskState.running, totalBytes: 100);
      async.elapse(const Duration(minutes: 1));
      expect(surface.progress, isEmpty);
    });
  });

  test('surface failures stay inside the reporter', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final surface = _ThrowingSurface();
      DockProgressReporter(
        queue: queue,
        surface: surface,
        surfaceReady: Future.value(),
      );
      final task = queue.addTask(
        state: TransferTaskState.running,
        totalBytes: 100,
      );
      async.elapse(const Duration(seconds: 1));
      task.transferredBytes = 50;
      queue.emitRefresh();
      async.elapse(const Duration(seconds: 1));
      expect(surface.calls, 2, reason: 'a failure does not stop reporting');
    });
  });

  test('live tasks publish aggregate byte progress and a count badge', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final surface = _RecordingSurface();
      DockProgressReporter(
        queue: queue,
        surface: surface,
        surfaceReady: Future.value(),
      );
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
      DockProgressReporter(
        queue: queue,
        surface: surface,
        surfaceReady: Future.value(),
      );
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
      // No idle clear, then a single coalesced progress publish.
      expect(surface.progress, hasLength(1));
      expect(surface.progress.last, closeTo(0.5, 1e-9));
    });
  });

  test('a finished queue clears the indicator again', () {
    fakeAsync((async) {
      final queue = FakeAppTransferQueue();
      final surface = _RecordingSurface();
      DockProgressReporter(
        queue: queue,
        surface: surface,
        surfaceReady: Future.value(),
      );
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
