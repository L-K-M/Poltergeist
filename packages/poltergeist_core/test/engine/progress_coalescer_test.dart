import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_core/src/engine/progress_coalescer.dart';
import 'package:test/test.dart';

const _second = Duration(seconds: 1);
const _millisecond = Duration(milliseconds: 1);
const _microsecond = Duration(microseconds: 1);

void main() {
  test('pins the port budget and rounds its interval upward', () {
    expect(progressFlushesPerSecond, 30);
    expect(progressItemsPerFlushCap, 64);
    expect(
      progressFlushInterval * progressFlushesPerSecond,
      greaterThanOrEqualTo(_second),
    );
    expect(
      (progressFlushInterval - _millisecond) * progressFlushesPerSecond,
      lessThan(_second),
    );
  });

  test('does not schedule empty flushes', () {
    fakeAsync((time) {
      final batches = <TransferProgressBatchEvent>[];
      final coalescer = ProgressCoalescer(batches.add);
      time.elapse(_second);

      expect(batches, isEmpty);
      expect(time.pendingTimers, isEmpty);
      coalescer.dispose();
    });
  });

  test('retains latest counters, including resets and unknown totals', () {
    fakeAsync((time) {
      final batches = <TransferProgressBatchEvent>[];
      final coalescer = ProgressCoalescer(batches.add);
      coalescer.add(_sample('task', 'item', 100));
      const latest = TransferProgressEvent(
        taskId: 'task',
        itemId: 'item',
        transferred: 2,
        total: null,
        taskTransferredBytes: 12,
        taskTotalBytes: null,
      );
      coalescer.add(latest);

      time.elapse(progressFlushInterval - _microsecond);
      expect(batches, isEmpty);
      time.elapse(_microsecond);
      expect(batches.single.items, [same(latest)]);
      expect(time.pendingTimers, isEmpty);
      coalescer.dispose();
    });
  });

  test(
    'keeps task and item identities separate without delimiter collisions',
    () {
      fakeAsync((time) {
        final batches = <TransferProgressBatchEvent>[];
        final coalescer = ProgressCoalescer(batches.add);
        final samples = [
          _sample('a', 'b:c', 1),
          _sample('a:b', 'c', 2),
          _sample('other', 'c', 3),
          _sample('other', 'd', 4),
        ];
        samples.forEach(coalescer.add);
        time.elapse(progressFlushInterval);

        expect(batches.single.items, samples);
        coalescer.dispose();
      });
    },
  );

  test('bounds a rotating flood across many tasks, not just each task', () {
    fakeAsync((time) {
      final batches = <TransferProgressBatchEvent>[];
      final coalescer = ProgressCoalescer(batches.add);
      const eventCount = 10000;
      for (var index = 0; index < eventCount; index++) {
        coalescer.add(_sample('task-$index', 'item-$index', index));
      }

      expect(time.pendingTimers, hasLength(1));
      time.elapse(progressFlushInterval);
      expect(batches, hasLength(1));
      expect(batches.single.items, hasLength(progressItemsPerFlushCap));
      expect(
        batches.single.items.first.transferred,
        eventCount - progressItemsPerFlushCap,
      );
      expect(batches.single.items.last.transferred, eventCount - 1);
      coalescer.dispose();
    });
  });

  test('refresh protects an item from oldest-event eviction', () {
    fakeAsync((time) {
      final batches = <TransferProgressBatchEvent>[];
      final coalescer = ProgressCoalescer(batches.add);
      for (var index = 0; index < progressItemsPerFlushCap; index++) {
        coalescer.add(_sample('task', 'item-$index', index));
      }
      coalescer.add(_sample('task', 'item-0', 1000));
      coalescer.add(_sample('task', 'overflow', 1001));
      time.elapse(progressFlushInterval);

      final items = batches.single.items;
      expect(items.map((item) => item.itemId), isNot(contains('item-1')));
      expect(items[items.length - 2].itemId, 'item-0');
      expect(items[items.length - 2].transferred, 1000);
      expect(items.last.itemId, 'overflow');
      coalescer.dispose();
    });
  });

  test('staggered tasks share a window without extending its deadline', () {
    fakeAsync((time) {
      final batches = <TransferProgressBatchEvent>[];
      final coalescer = ProgressCoalescer(batches.add);
      coalescer.add(_sample('first', 'item', 1));
      time.elapse(progressFlushInterval - _microsecond);
      coalescer.add(_sample('second', 'item', 2));

      expect(time.pendingTimers, hasLength(1));
      time.elapse(_microsecond);
      expect(batches.single.items.map((item) => item.taskId), [
        'first',
        'second',
      ]);
      coalescer.dispose();
    });
  });

  test('continuous multi-task flood stays within every rolling second', () {
    fakeAsync((time) {
      final emissions = <Duration>[];
      final coalescer = ProgressCoalescer((_) => emissions.add(time.elapsed));
      const step = Duration(milliseconds: 1);
      const sampleCount = 10000;
      for (var index = 0; index < sampleCount; index++) {
        coalescer.add(_sample('task-${index % 100}', 'item', index));
        time.elapse(step);
      }
      time.elapse(progressFlushInterval);

      expect(
        emissions.length,
        greaterThan(200),
        reason: 'Dropping all progress must not satisfy the cap.',
      );
      for (var index = 0; index < emissions.length; index++) {
        if (index > 0) {
          expect(
            emissions[index] - emissions[index - 1],
            greaterThanOrEqualTo(progressFlushInterval),
          );
        }
        final end = emissions[index] + _second;
        expect(
          emissions.skip(index).takeWhile((time) => time < end).length,
          lessThanOrEqualTo(progressFlushesPerSecond),
        );
      }
      coalescer.dispose();
    });
  });

  test('VM timer truncation cannot exceed the rolling-second budget', () {
    fakeAsync((time) {
      final emissions = <Duration>[];
      late ProgressCoalescer coalescer;
      runZoned(
        () {
          coalescer = ProgressCoalescer((_) {
            emissions.add(time.elapsed);
            coalescer.add(_sample('task', 'item', emissions.length));
          });
          coalescer.add(_sample('task', 'item', 0));
          time.elapse(_second * 2);
          coalescer.dispose();
        },
        zoneSpecification: ZoneSpecification(
          // vm/lib/timer_patch.dart truncates Duration to whole milliseconds.
          createTimer: (self, parent, zone, duration, callback) =>
              parent.createTimer(
                zone,
                Duration(milliseconds: duration.inMilliseconds),
                callback,
              ),
        ),
      );

      expect(emissions.length, greaterThan(progressFlushesPerSecond));
      final end = emissions.first + _second;
      expect(
        emissions.takeWhile((instant) => instant < end).length,
        lessThanOrEqualTo(progressFlushesPerSecond),
      );
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('discarding one task preserves sibling progress and its deadline', () {
    fakeAsync((time) {
      final batches = <TransferProgressBatchEvent>[];
      final coalescer = ProgressCoalescer(batches.add);
      coalescer.add(_sample('finished', 'item', 1));
      coalescer.add(_sample('active', 'item', 2));
      time.elapse(progressFlushInterval - _microsecond);
      coalescer.discardTask('finished');
      coalescer.discardTask('unknown');
      time.elapse(_microsecond);

      expect(batches.single.items.single.taskId, 'active');
      coalescer.dispose();
    });
  });

  test(
    'item completion discards only its counters and preserves the deadline',
    () {
      fakeAsync((time) {
        final batches = <TransferProgressBatchEvent>[];
        final coalescer = ProgressCoalescer(batches.add);
        coalescer.add(_sample('task', 'finished', 1));
        coalescer.add(_sample('task', 'active', 2));
        coalescer.add(_sample('sibling', 'finished', 3));
        time.elapse(progressFlushInterval - _microsecond);
        coalescer.discardItem('task', 'finished');
        coalescer.discardItem('task', 'unknown');
        time.elapse(_microsecond);

        expect(batches.single.items.map((item) => (item.taskId, item.itemId)), [
          ('task', 'active'),
          ('sibling', 'finished'),
        ]);
        coalescer.dispose();
      });
    },
  );

  test('discarding the last item cancels the timer', () {
    fakeAsync((time) {
      final batches = <TransferProgressBatchEvent>[];
      final coalescer = ProgressCoalescer(batches.add);
      coalescer.add(_sample('task', 'finished', 1));
      coalescer.discardItem('task', 'finished');
      expect(time.pendingTimers, isEmpty);
      time.elapse(_second);
      expect(batches, isEmpty);
      coalescer.dispose();
    });
  });

  test('discarding all pending progress cancels the timer', () {
    fakeAsync((time) {
      final batches = <TransferProgressBatchEvent>[];
      final coalescer = ProgressCoalescer(batches.add);
      coalescer.add(_sample('finished', 'item', 1));
      coalescer.discardTask('finished');
      expect(time.pendingTimers, isEmpty);
      time.elapse(_second);
      expect(batches, isEmpty);

      coalescer.add(_sample('new', 'item', 2));
      time.elapse(progressFlushInterval);
      expect(batches.single.items.single.taskId, 'new');
      coalescer.dispose();
    });
  });

  test('dispose drops pending progress and ignores late callbacks', () {
    fakeAsync((time) {
      final batches = <TransferProgressBatchEvent>[];
      final coalescer = ProgressCoalescer(batches.add);
      coalescer.add(_sample('task', 'item', 1));
      coalescer.dispose();
      coalescer.dispose();
      coalescer.add(_sample('task', 'late', 2));
      coalescer.discardTask('task');
      time.elapse(_second);

      expect(batches, isEmpty);
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('reentrant progress starts a fresh bounded window', () {
    fakeAsync((time) {
      final batches = <TransferProgressBatchEvent>[];
      late ProgressCoalescer coalescer;
      coalescer = ProgressCoalescer((batch) {
        batches.add(batch);
        if (batches.length == 1) coalescer.add(_sample('task', 'item', 2));
      });
      coalescer.add(_sample('task', 'item', 1));
      time.elapse(progressFlushInterval);
      expect(batches.single.items.single.transferred, 1);
      time.elapse(progressFlushInterval - _microsecond);
      expect(batches, hasLength(1));
      time.elapse(_microsecond);
      expect(batches.last.items.single.transferred, 2);
      expect(time.pendingTimers, isEmpty);
      coalescer.dispose();
    });
  });
}

TransferProgressEvent _sample(String taskId, String itemId, int transferred) =>
    TransferProgressEvent(
      taskId: taskId,
      itemId: itemId,
      transferred: transferred,
      total: 10000,
      taskTransferredBytes: transferred + 20000,
      taskTotalBytes: 100000,
    );
