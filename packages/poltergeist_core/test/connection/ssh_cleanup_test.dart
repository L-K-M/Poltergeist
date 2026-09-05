import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/src/connection/ssh_cleanup.dart';
import 'package:test/test.dart';

void main() {
  const shortTimeout = Duration(milliseconds: 100);
  const defaultBudget = Duration(seconds: 5);
  const longerTimeout = Duration(seconds: 15);

  test('a successful close completes without spending the timeout budget', () {
    fakeAsync((clock) {
      final gate = Completer<void>();
      var completed = false;
      closeSshResource(() => gate.future).then((_) => completed = true);
      clock.flushMicrotasks();
      expect(completed, isFalse);

      gate.complete();
      clock.flushMicrotasks();
      expect(completed, isTrue);
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('an in-budget close error completes cleanup without propagating', () {
    fakeAsync((clock) {
      final gate = Completer<void>();
      var completed = false;
      closeSshResource(() => gate.future).then((_) => completed = true);
      clock.flushMicrotasks();

      gate.completeError(StateError('close failed'));
      clock.flushMicrotasks();
      expect(completed, isTrue);
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('a synchronous close error cannot interrupt cleanup', () {
    fakeAsync((clock) {
      var completed = false;
      closeSshResource(
        () => throw StateError('close failed'),
      ).then((_) => completed = true);
      clock.flushMicrotasks();
      expect(completed, isTrue);
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  for (final (requested, expected) in [
    (shortTimeout, shortTimeout),
    (longerTimeout, defaultBudget),
  ]) {
    test('caller timeout $requested bounds cleanup to $expected', () {
      fakeAsync((clock) {
        final gate = Completer<void>();
        var completed = false;
        closeSshResource(
          () => gate.future,
          maxWait: requested,
        ).then((_) => completed = true);
        clock.flushMicrotasks();
        expect(completed, isFalse);

        clock.elapse(expected);
        expect(completed, isTrue);

        // A shorter caller budget must still observe eventual close errors.
        gate.completeError(StateError('late close failure'));
        clock.flushMicrotasks();
      });
    });
  }
}
