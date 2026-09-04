import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _singleChannel = PoolPolicy(
  maxTransports: 1,
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 1,
);

void main() {
  test('first browse binding wakes concurrent browse waiters', () async {
    final harness = PoolHarness(policy: _singleChannel)..addServer('s1');
    addTearDown(() => harness.manager.disconnectServer('s1'));
    final first = harness.manager.openBrowseChannel('s1', paneTabId: 'first');
    PaneChannel? granted;
    final waiting = harness.manager.openBrowseChannel(
      's1',
      paneTabId: 'waiting',
    );
    unawaited(waiting.then<void>((value) => granted = value, onError: (_) {}));

    final initial = await first;
    await Future<void>.delayed(Duration.zero);
    expect(granted, isNotNull);
    expect(granted!.fs, same(initial.fs));
  });

  test('a transfer waiter cannot strand a queued browse share', () async {
    final harness = PoolHarness(policy: _singleChannel)..addServer('s1');
    addTearDown(() => harness.manager.disconnectServer('s1'));
    final first = harness.manager.openBrowseChannel('s1', paneTabId: 'first');
    final transfer = harness.manager.leaseTransferChannel('s1');
    transfer.ignore();
    PaneChannel? granted;
    final waiting = harness.manager.openBrowseChannel(
      's1',
      paneTabId: 'waiting',
    );
    unawaited(waiting.then<void>((value) => granted = value, onError: (_) {}));

    final initial = await first;
    await Future<void>.delayed(Duration.zero);
    expect(granted, isNotNull);
    expect(granted!.fs, same(initial.fs));
  });

  test(
    'SFTP refusal fails every request when no channel can make progress',
    () async {
      final harness = PoolHarness(
        policy: _singleChannel,
        opener: FakeTransportOpener(transportOpenLimit: 0),
      )..addServer('s1');
      addTearDown(() => harness.manager.disconnectServer('s1'));
      final errors = <Object>[];
      for (final tab in ['first', 'waiting']) {
        unawaited(
          harness.manager
              .openBrowseChannel('s1', paneTabId: tab)
              .then<void>(
                (_) => fail('unexpected SFTP channel'),
                onError: errors.add,
              ),
        );
      }

      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(2));
      expect(
        errors,
        everyElement(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.unsupported,
          ),
        ),
      );
      expect(await harness.manager.connectedServerIds(), isEmpty);
    },
  );
}
