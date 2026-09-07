import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_core/src/engine/connect_log_coalescer.dart';
import 'package:test/test.dart';

const _second = Duration(seconds: 1);
const _millisecond = Duration(milliseconds: 1);

/// The coalescer is engine-internal (03 §5); these tests drive it directly
/// with a fake clock, mirroring the progress coalescer suite.
void main() {
  test('pins the port budget and rounds its interval upward', () {
    expect(connectionLogFlushesPerSecond, 30);
    expect(connectionLogMaxLines, 400);
    expect(
      connectionLogFlushInterval * connectionLogFlushesPerSecond,
      greaterThanOrEqualTo(_second),
    );
    expect(
      (connectionLogFlushInterval - _millisecond) *
          connectionLogFlushesPerSecond,
      lessThan(_second),
    );
  });

  test('does not schedule empty flushes', () {
    fakeAsync((time) {
      final batches = <ConnectionLogEvent>[];
      final coalescer = ConnectLogCoalescer(batches.add);
      time.elapse(_second);

      expect(batches, isEmpty);
      expect(time.pendingTimers, isEmpty);
      coalescer.dispose();
    });
  });

  test('one batch per flush window keeps append order', () {
    fakeAsync((time) {
      final batches = <ConnectionLogEvent>[];
      final coalescer = ConnectLogCoalescer(batches.add);

      for (var i = 1; i <= 3; i++) {
        coalescer.add(ConnectLogLine(serverId: 's1', line: 'line $i'));
      }
      time.flushMicrotasks();
      expect(batches, isEmpty);

      time.elapse(connectionLogFlushInterval);
      expect(batches.single.lines, ['line 1', 'line 2', 'line 3']);

      // A quiet window sends nothing.
      time.elapse(connectionLogFlushInterval);
      expect(batches, hasLength(1));

      coalescer.dispose();
    });
  });

  test('servers batch independently', () {
    fakeAsync((time) {
      final batches = <ConnectionLogEvent>[];
      final coalescer = ConnectLogCoalescer(batches.add);

      coalescer.add(const ConnectLogLine(serverId: 's1', line: 'a'));
      coalescer.add(const ConnectLogLine(serverId: 's2', line: 'b'));
      coalescer.add(const ConnectLogLine(serverId: 's1', line: 'c'));
      time.elapse(connectionLogFlushInterval);

      expect(batches, hasLength(2));
      expect(batches.singleWhere((e) => e.serverId == 's1').lines, ['a', 'c']);
      expect(batches.singleWhere((e) => e.serverId == 's2').lines, ['b']);

      coalescer.dispose();
    });
  });

  test('one sink failure cannot discard a sibling batch', () {
    final delivered = <ConnectionLogEvent>[];
    final failure = StateError('broken sink');
    Object? surfacedError;

    runZonedGuarded(
      () => fakeAsync((time) {
        final coalescer = ConnectLogCoalescer((event) {
          if (event.serverId == 's1') throw failure;
          delivered.add(event);
        });

        coalescer.add(const ConnectLogLine(serverId: 's1', line: 'a'));
        coalescer.add(const ConnectLogLine(serverId: 's2', line: 'b'));
        time.elapse(connectionLogFlushInterval);
        coalescer.dispose();
      }),
      (error, _) => surfacedError = error,
    );

    expect(surfacedError, same(failure));
    expect(delivered.single.serverId, 's2');
    expect(delivered.single.lines, ['b']);
  });

  test('caps pending lines per server, dropping the oldest', () {
    fakeAsync((time) {
      final batches = <ConnectionLogEvent>[];
      final coalescer = ConnectLogCoalescer(batches.add);

      for (var i = 0; i < connectionLogMaxLines + 25; i++) {
        coalescer.add(ConnectLogLine(serverId: 's1', line: 'line $i'));
      }
      time.elapse(connectionLogFlushInterval);

      final lines = batches.single.lines;
      expect(lines, hasLength(connectionLogMaxLines));
      // The flood dropped the first 25 lines, never reordered the rest.
      expect(lines.first, 'line 25');
      expect(lines.last, 'line ${connectionLogMaxLines + 24}');

      coalescer.dispose();
    });
  });

  test('a reentrant producer during delivery starts the next window', () {
    fakeAsync((time) {
      final batches = <ConnectionLogEvent>[];
      late final ConnectLogCoalescer coalescer;
      coalescer = ConnectLogCoalescer((event) {
        batches.add(event);
        // A producer firing while the batch is being delivered must not
        // mutate the in-flight batch — it lands in the next window.
        if (batches.length == 1) {
          coalescer.add(const ConnectLogLine(serverId: 's1', line: 'late'));
        }
      });

      coalescer.add(const ConnectLogLine(serverId: 's1', line: 'first'));
      time.elapse(connectionLogFlushInterval);
      time.flushMicrotasks();

      expect(batches, hasLength(1));
      expect(batches.single.lines, ['first']);

      time.elapse(connectionLogFlushInterval);
      expect(batches, hasLength(2));
      expect(batches.last.lines, ['late']);

      coalescer.dispose();
    });
  });

  test('dispose drops buffered lines and ignores late appends', () {
    fakeAsync((time) {
      final batches = <ConnectionLogEvent>[];
      final coalescer = ConnectLogCoalescer(batches.add);

      coalescer.add(const ConnectLogLine(serverId: 's1', line: 'doomed'));
      coalescer.dispose();

      coalescer.add(const ConnectLogLine(serverId: 's1', line: 'late'));
      time.elapse(_second);

      expect(batches, isEmpty);
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('events are immutable snapshots of the batch', () {
    fakeAsync((time) {
      ConnectionLogEvent? captured;
      void capture(ConnectionLogEvent event) => captured = event;
      final coalescer = ConnectLogCoalescer(capture);

      coalescer.add(const ConnectLogLine(serverId: 's1', line: 'a'));
      time.elapse(connectionLogFlushInterval);

      expect(() => captured!.lines.add('x'), throwsUnsupportedError);

      coalescer.dispose();
    });
  });
}
