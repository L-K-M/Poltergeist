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
        completeWithoutTimers(time, pane.close());
        expect(time.pendingTimers, isEmpty);
      });
    },
  );
}
