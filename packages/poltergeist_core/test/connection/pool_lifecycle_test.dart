import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Matcher get _disconnected => throwsA(
  isA<RemoteFileException>().having(
    (error) => error.kind,
    'kind',
    RemoteFileErrorKind.disconnected,
  ),
);

void main() {
  late PoolHarness harness;

  setUp(() {
    harness = PoolHarness()
      ..addServer('s1')
      ..addServer('s2');
  });
  tearDown(() async {
    await harness.manager.disconnectServer('s1');
    await harness.manager.disconnectServer('s2');
  });

  test(
    'disconnect rejects a browse binding completing home resolution',
    () async {
      await harness.manager.openBrowseChannel('s2', paneTabId: 'keep');
      final transport = harness.opener.transports.single;
      final gate = transport.canonicalizeGate = Completer<void>();
      final opening = harness.manager.openBrowseChannel('s1', paneTabId: 'tab');
      final outcome = expectLater(opening, _disconnected);
      await _flush();
      expect(transport.channels, hasLength(2));

      await harness.manager.disconnectServer('s1');
      gate.complete();
      await outcome;
      expect(harness.openChannels, hasLength(1));
      expect(await harness.manager.connectedServerIds(), {'s2'});
    },
  );

  test(
    'disconnect rejects an in-flight transfer acquisition on a shared pool',
    () async {
      await harness.manager.openBrowseChannel('s2', paneTabId: 'keep');
      final transport = harness.opener.transports.single;
      final gate = transport.openGate = Completer<void>();
      final opening = harness.manager.leaseTransferChannel('s1');
      final outcome = expectLater(opening, _disconnected);
      await _flush();
      expect(transport.channels, hasLength(2));

      await harness.manager.disconnectServer('s1');
      gate.complete();
      await outcome;
      expect(harness.openChannels, hasLength(1));
      expect(await harness.manager.connectedServerIds(), {'s2'});
    },
  );

  test(
    'a cancelled resolver cannot replace a newer server reference',
    () async {
      final gate = harness.resolveGate = Completer<void>();
      final stale = harness.manager.openBrowseChannel('s1', paneTabId: 'old');
      final outcome = expectLater(stale, _disconnected);
      await harness.manager.disconnectServer('s1');

      harness.resolveGate = null;
      final current = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'current',
      );
      gate.complete();
      await outcome;
      await _flush();

      expect(harness.opener.calls, hasLength(1));
      expect(await harness.manager.connectedServerIds(), {'s1'});
      expect(harness.openChannels.single.fs, same(current.fs));
    },
  );

  test('a new session does not join a disconnected first connect', () async {
    final gate = Completer<bool>();
    var prompts = 0;
    harness.onHostKey = (_) async => ++prompts == 1 ? gate.future : true;
    final stale = harness.manager.openBrowseChannel('s1', paneTabId: 'old');
    final outcome = expectLater(stale, _disconnected);
    await _flush();
    await harness.manager.disconnectServer('s1');

    final current = harness.manager.openBrowseChannel('s1', paneTabId: 'new');
    current.ignore();
    await _flush();
    final connectCount = harness.opener.calls.length;
    gate.complete(true);
    await outcome;
    await current;

    expect(connectCount, 2);
    expect(await harness.manager.connectedServerIds(), {'s1'});
    expect(harness.openChannels, hasLength(1));
  });

  test(
    'an in-flight browse acquisition holds pane-lifetime teardown',
    () async {
      final keeper = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'keep',
      );
      final transport = harness.opener.transports.single;
      final gate = transport.canonicalizeGate = Completer<void>();
      final opening = harness.manager.openBrowseChannel('s1', paneTabId: 'new');
      opening.ignore();
      await _flush();
      await keeper.close();
      final closedDuringOpen = transport.closed;
      gate.complete();
      final current = await opening;

      expect(closedDuringOpen, isFalse);
      expect(harness.openChannels.single.fs, same(current.fs));
    },
  );

  test(
    'channel cleanup cannot replace a disconnected acquisition error',
    () async {
      await harness.manager.openBrowseChannel('s2', paneTabId: 'keep');
      final transport = harness.opener.transports.single;
      final gate = transport.openGate = Completer<void>();
      final opening = harness.manager.leaseTransferChannel('s1');
      final outcome = expectLater(opening, _disconnected);
      await _flush();
      transport.channels.last.closeFailure = StateError('channel cleanup');

      await harness.manager.disconnectServer('s1');
      gate.complete();
      try {
        await outcome;
      } finally {
        transport.channels.last.closeFailure = null;
      }
    },
  );

  test(
    'pool cleanup cannot replace a disconnected acquisition error',
    () async {
      final keeper = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'keep',
      );
      final transport = harness.opener.transports.single;
      final gate = transport.canonicalizeGate = Completer<void>();
      final opening = harness.manager.openBrowseChannel('s1', paneTabId: 'new');
      final outcome = expectLater(opening, _disconnected);
      await _flush();
      await keeper.close();

      // Death invalidates the open; failing cleanup must preserve that cause.
      transport.closed = true;
      transport.closeFailure = StateError('transport cleanup');
      gate.complete();
      await outcome;
    },
  );
}
