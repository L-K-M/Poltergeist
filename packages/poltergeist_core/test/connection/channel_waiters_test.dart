import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _singleChannel = PoolPolicy(
  maxTransports: 1,
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 1,
);

final _unsupported = isA<RemoteFileException>().having(
  (error) => error.kind,
  'kind',
  RemoteFileErrorKind.unsupported,
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
      expect(errors, everyElement(_unsupported));
      expect(await harness.manager.connectedServerIds(), isEmpty);
    },
  );

  test('stranded transfer requests fail with the typed SFTP error', () async {
    final harness = PoolHarness(
      policy: _singleChannel,
      opener: FakeTransportOpener(transportOpenLimit: 0),
    )..addServer('s1');
    addTearDown(() => harness.manager.disconnectServer('s1'));

    await expectLater(
      harness.manager.leaseTransferChannel('s1'),
      throwsA(_unsupported),
    );
    expect(await harness.manager.connectedServerIds(), isEmpty);
  });

  test('a stranded pool reconnects once the server permits SFTP', () async {
    final opener = FakeTransportOpener(transportOpenLimit: 0);
    final harness = PoolHarness(policy: _singleChannel, opener: opener)
      ..addServer('s1');
    addTearDown(() => harness.manager.disconnectServer('s1'));

    await expectLater(
      harness.manager.openBrowseChannel('s1', paneTabId: 'refused'),
      throwsA(_unsupported),
    );
    expect(opener.transports.single.closed, isTrue);

    // The server enables SFTP; the next request must use a fresh transport.
    opener.transportOpenLimit = null;
    final recovered = await harness.manager.openBrowseChannel(
      's1',
      paneTabId: 'recovered',
    );
    expect(opener.transports, hasLength(2));
    expect(harness.openChannels.single.fs, same(recovered.fs));
    expect(await harness.manager.connectedServerIds(), {'s1'});
  });

  test('successful opens clear obsolete SFTP failure classification', () async {
    final harness = PoolHarness(
      policy: const PoolPolicy(maxTransports: 1),
      opener: FakeTransportOpener(
        authKind: AuthKind.keyboardInteractive,
        transportOpenLimit: 1,
      ),
    )..addServer('s1');
    addTearDown(() => harness.manager.disconnectServer('s1'));
    await harness.manager.openBrowseChannel('s1', paneTabId: 'first');
    await harness.manager.openBrowseChannel('s1', paneTabId: 'refused-share');

    // The server frees its channel slot; a later open succeeds.
    final transport = harness.opener.transports.single;
    await transport.channels.single.close();
    await harness.manager.openBrowseChannel('s1', paneTabId: 'recovered');
    expect(harness.openChannels, hasLength(1));

    // Death lands after the first-connect check, before slot selection.
    // Interactive auth prevents silent growth from hiding the disconnect.
    final opening = harness.manager.leaseTransferChannel('s1');
    scheduleMicrotask(() => transport.closed = true);
    await expectLater(
      opening,
      throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.disconnected,
        ),
      ),
    );
    expect(harness.opener.calls, hasLength(1));
  });

  test('stranded teardown forgets errors before the next connect', () async {
    final harness = PoolHarness(
      policy: _singleChannel,
      opener: FakeTransportOpener(
        authKind: AuthKind.keyboardInteractive,
        transportOpenLimit: 0,
      ),
    )..addServer('s1');
    addTearDown(() => harness.manager.disconnectServer('s1'));
    await expectLater(
      harness.manager.leaseTransferChannel('s1'),
      throwsA(_unsupported),
    );

    // The next SSH connection dies before SFTP opens. Its error must not
    // come from the previous, already-detached connection's SFTP refusal.
    final gate = harness.opener.connectGate = Completer<void>();
    final outcome = expectLater(
      harness.manager.leaseTransferChannel('s1'),
      throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.disconnected,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    harness.opener.transports.last.closed = true;
    gate.complete();
    await outcome;
    expect(harness.opener.calls, hasLength(2));
  });

  test(
    'a release pump fails waiters when replacement SFTP is refused',
    () async {
      final opener = FakeTransportOpener();
      final harness = PoolHarness(policy: _singleChannel, opener: opener)
        ..addServer('s1')
        ..addServer('s2');
      addTearDown(() async {
        await harness.manager.disconnectServer('s1');
        await harness.manager.disconnectServer('s2');
      });
      final pane = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'held',
      );
      final errors = <Object>[];
      unawaited(
        harness.manager
            .leaseTransferChannel('s2')
            .then<void>(
              (_) => fail('unexpected transfer lease'),
              onError: errors.add,
            ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty);

      // The held connection dies; its replacement refuses every SFTP open.
      opener.transports.single.closed = true;
      opener.transportOpenLimit = 0;
      await pane.close();
      await Future<void>.delayed(Duration.zero);

      expect(errors, hasLength(1));
      expect(errors.single, _unsupported);
      expect(await harness.manager.connectedServerIds(), isEmpty);
    },
  );

  test(
    'a release pump tries every available transport before failing',
    () async {
      final harness =
          PoolHarness(
              policy: const PoolPolicy(
                maxTransports: 2,
                maxTransferChannelsPerTransport: 1,
                maxChannelsPerTransport: 1,
              ),
            )
            ..addServer('s1')
            ..addServer('s2');
      addTearDown(() async {
        await harness.manager.disconnectServer('s1');
        await harness.manager.disconnectServer('s2');
      });
      final first = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'one',
      );
      final second = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'two',
      );
      TransferChannelLease? granted;
      final errors = <Object>[];
      unawaited(
        harness.manager
            .leaseTransferChannel('s2')
            .then<void>((value) => granted = value, onError: errors.add),
      );
      await Future<void>.delayed(Duration.zero);
      expect(granted, isNull);

      harness.opener.transports.first.openFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'open SFTP',
        message: 'The first transport refuses SFTP.',
      );
      await Future.wait([first.close(), second.close()]);
      await Future<void>.delayed(Duration.zero);

      expect(errors, isEmpty);
      expect(granted, isNotNull);
      expect(
        granted!.fs,
        same(harness.opener.transports.last.channels.last.fs),
      );
      await granted!.release();
    },
  );

  test('a dead refusal cannot classify a surviving pool disconnect', () async {
    final opener = FakeTransportOpener();
    final harness =
        PoolHarness(
            opener: opener,
            policy: const PoolPolicy(
              maxTransports: 2,
              maxTransferChannelsPerTransport: 1,
              maxChannelsPerTransport: 1,
            ),
          )
          ..addServer('s1')
          ..addServer('s2');
    addTearDown(() async {
      await harness.manager.disconnectServer('s1');
      await harness.manager.disconnectServer('s2');
    });
    final first = await harness.manager.openBrowseChannel(
      's1',
      paneTabId: 'one',
    );
    final second = await harness.manager.openBrowseChannel(
      's1',
      paneTabId: 'two',
    );
    final errors = <Object>[];
    unawaited(
      harness.manager
          .leaseTransferChannel('s2')
          .then<void>(
            (_) => fail('unexpected transfer lease'),
            onError: errors.add,
          ),
    );
    await Future<void>.delayed(Duration.zero);
    opener.transports.first.openFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.unsupported,
      operation: 'open SFTP',
      message: 'The first transport refuses SFTP.',
    );
    await first.close();
    expect(errors, isEmpty);

    // Let the refusing transport die without a successful new SFTP open.
    // A fresh auth challenge caps growth; the second transport stays usable.
    opener.transports.first.closed = true;
    opener.connectFailure = const AuthChallengeRequiredError(
      'Interaction required.',
    );
    final shared = await harness.manager.openBrowseChannel(
      's2',
      paneTabId: 'evict',
    );
    expect(shared.fs, same(second.fs));
    await shared.close();

    opener.transports.last.closed = true;
    await second.close();
    await Future<void>.delayed(Duration.zero);
    expect(errors, hasLength(1));
    expect(
      errors.single,
      isA<RemoteFileException>().having(
        (error) => error.kind,
        'kind',
        RemoteFileErrorKind.disconnected,
      ),
    );
  });
}
