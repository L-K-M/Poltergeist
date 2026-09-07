import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _firstDelay = Duration(seconds: 1);
const _secondDelay = Duration(seconds: 2);
const _denied = RemoteFileException(
  kind: RemoteFileErrorKind.permissionDenied,
  operation: 'canonicalize',
  path: '.',
  message: 'Home inaccessible.',
);
const _disconnected = RemoteFileException(
  kind: RemoteFileErrorKind.disconnected,
  operation: 'canonicalize',
  path: '.',
  message: 'Transport disconnected.',
);

void main() {
  test(
    'late home failure from a dead transport preserves the recovering pane',
    () {
      fakeAsync((time) {
        final h = PoolHarness()..addServer('s1');
        final pane = browsePane(time, h, 'a');
        final handshake = h.opener.connectGate = Completer<void>();
        h.opener.transports.single.die();
        time.flushMicrotasks();
        time.elapse(_firstDelay);
        time.flushMicrotasks();

        // The home lookup fails after its transport dies, while the pane
        // still belongs to the same recovery cycle.
        final replacement = h.opener.transports.last;
        final home = replacement.canonicalizeGate = Completer<void>();
        h.opener.connectGate = null;
        handshake.complete();
        time.flushMicrotasks();
        replacement.die();
        time.flushMicrotasks();
        home.completeError(_denied);
        time.flushMicrotasks();

        time.elapse(_secondDelay);
        time.flushMicrotasks();
        expect(pane.fs, same(h.opener.transports.last.channels.single.fs));
        expect(browsePane(time, h, 'a'), same(pane));
        expect(h.recoveryFailures, isEmpty);
        completeWithoutTimers(time, pane.close());
        expect(time.pendingTimers, isEmpty);
      });
    },
  );

  test('disconnected home error retires transport before done arrives', () {
    fakeAsync((time) {
      final h = PoolHarness()..addServer('s1');
      final pane = browsePane(time, h, 'a');
      final handshake = h.opener.connectGate = Completer<void>();
      h.opener.transports.single.die();
      time.flushMicrotasks();
      time.elapse(_firstDelay);
      time.flushMicrotasks();

      final replacement = h.opener.transports.last;
      final home = replacement.canonicalizeGate = Completer<void>();
      h.opener.connectGate = null;
      handshake.complete();
      time.flushMicrotasks();

      // VFS failure can precede the done notification. Recovery must
      // retire the closed transport rather than wait for that notification.
      replacement.closed = true;
      home.completeError(_disconnected);
      time.flushMicrotasks();
      expect(replacement.closeCompleted, isTrue);

      time.elapse(_secondDelay);
      time.flushMicrotasks();
      expect(pane.fs, same(h.opener.transports.last.channels.single.fs));
      expect(browsePane(time, h, 'a'), same(pane));
      expect(h.recoveryFailures, isEmpty);
      completeWithoutTimers(time, pane.close());
      expect(time.pendingTimers, isEmpty);
    });
  });

  test(
    'late home denial retires a closed transport and rebinds both panes',
    () {
      fakeAsync((time) {
        final h = PoolHarness()..addServer('s1');
        final first = browsePane(time, h, 'a');
        final second = browsePane(time, h, 'b');
        final home = Completer<void>();
        var openedHomes = 0;

        // Let one pane rebind before its sibling's home lookup waits.
        h.opener.transportFsBuilder = (path) => StubRemoteFileSystem(
          path,
          canonicalizeGate: ++openedHomes == 2 ? home : null,
        );
        h.opener.transports.single.die();
        time.flushMicrotasks();
        time.elapse(_firstDelay);
        time.flushMicrotasks();
        final replacement = h.opener.transports.last;
        expect(first.fs, same(replacement.channels.first.fs));

        replacement.closed = true;
        home.completeError(_denied);
        time.flushMicrotasks();
        time.elapse(_secondDelay);
        time.flushMicrotasks();

        final recovered = h.opener.transports.last;
        expect(first.fs, same(recovered.channels.first.fs));
        expect(second.fs, same(recovered.channels.last.fs));
        expect(replacement.closeCompleted, isTrue);
        expect(h.recoveryFailures, isEmpty);
        completeWithoutTimers(time, first.close());
        completeWithoutTimers(time, second.close());
        expect(time.pendingTimers, isEmpty);
      });
    },
  );
}
