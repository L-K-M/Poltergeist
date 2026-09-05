import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _primaryServer = 'primary';
const _siblingServer = 'sibling';

enum _ChannelKind { browse, transfer }

enum _ConnectOutcome { connected, rejected }

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

Future<void> _join(PoolHarness harness, _ChannelKind kind) async {
  switch (kind) {
    case _ChannelKind.browse:
      await harness.manager.openBrowseChannel(_siblingServer, paneTabId: 'tab');
    case _ChannelKind.transfer:
      await harness.manager.leaseTransferChannel(_siblingServer);
  }
}

List<ServerConnectionState> _watch(PoolHarness harness, String serverId) {
  final states = <ServerConnectionState>[];
  final subscription = harness.manager.watchServer(serverId).listen(states.add);
  addTearDown(subscription.cancel);
  return states;
}

void main() {
  late PoolHarness harness;

  setUp(() {
    harness = PoolHarness()
      ..addServer(_primaryServer)
      ..addServer(_siblingServer);
  });
  tearDown(() async {
    await harness.manager.disconnectServer(_siblingServer);
    await harness.manager.disconnectServer(_primaryServer);
  });

  for (final kind in _ChannelKind.values) {
    test(
      '${kind.name} join publishes connected to an existing watcher',
      () async {
        await harness.manager.openBrowseChannel(
          _primaryServer,
          paneTabId: 'keep',
        );
        final primaryStates = _watch(harness, _primaryServer);
        final siblingStates = _watch(harness, _siblingServer);
        await _flushEvents();
        expect(siblingStates, [ServerConnectionState.disconnected]);

        await _join(harness, kind);
        await _flushEvents();

        expect(siblingStates, [
          ServerConnectionState.disconnected,
          ServerConnectionState.connected,
        ]);
        expect(primaryStates, [ServerConnectionState.connected]);
        expect(await harness.manager.connectedServerIds(), {
          _primaryServer,
          _siblingServer,
        });

        // A retained subscription must see a fresh join after disconnect too.
        await harness.manager.disconnectServer(_siblingServer);
        await _join(harness, kind);
        await _flushEvents();

        expect(siblingStates, [
          ServerConnectionState.disconnected,
          ServerConnectionState.connected,
          ServerConnectionState.disconnected,
          ServerConnectionState.connected,
        ]);
        expect(primaryStates, [ServerConnectionState.connected]);
        expect(harness.opener.calls, hasLength(1));
      },
    );
  }

  for (final outcome in _ConnectOutcome.values) {
    test(
      'a join during first connect receives connecting then ${outcome.name}',
      () async {
        final gate = Completer<void>();
        // Hold the first-use prompt so rejection can fail an in-flight join.
        harness.onHostKey = (_) async {
          await gate.future;
          return outcome == _ConnectOutcome.connected;
        };
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final primaryStates = _watch(harness, _primaryServer);
        final primary = harness.manager.openBrowseChannel(
          _primaryServer,
          paneTabId: 'keep',
        );
        primary.ignore();
        await _flushEvents();
        expect(harness.opener.calls, hasLength(1));

        final siblingStates = _watch(harness, _siblingServer);
        final sibling = _join(harness, _ChannelKind.browse);
        sibling.ignore();
        await _flushEvents();

        expect(siblingStates, [
          ServerConnectionState.disconnected,
          ServerConnectionState.connecting,
        ]);
        gate.complete();
        switch (outcome) {
          case _ConnectOutcome.connected:
            await primary;
            await sibling;
          case _ConnectOutcome.rejected:
            final rejected = throwsA(isA<SshConnectException>());
            await expectLater(primary, rejected);
            await expectLater(sibling, rejected);
        }
        await _flushEvents();

        final expected = [
          ServerConnectionState.disconnected,
          ServerConnectionState.connecting,
          outcome == _ConnectOutcome.connected
              ? ServerConnectionState.connected
              : ServerConnectionState.disconnected,
        ];
        expect(primaryStates, expected);
        expect(siblingStates, expected);
        expect(harness.opener.calls, hasLength(1));
      },
    );
  }

  test(
    'a transfer joining a blocked pool publishes blocked without prompting',
    () async {
      const originalKey = 'SHA256:original';
      const changedKey = 'SHA256:changed';
      harness =
          PoolHarness(
              opener: FakeTransportOpener(
                presentedFingerprints: [originalKey, changedKey],
              ),
            )
            ..addServer(_primaryServer)
            ..addServer(_siblingServer);
      await harness.manager.openBrowseChannel(
        _primaryServer,
        paneTabId: 'keep',
      );
      for (
        var i = 0;
        i < const PoolPolicy().maxTransferChannelsPerTransport;
        i++
      ) {
        await harness.manager.leaseTransferChannel(_primaryServer);
      }
      final blocked = throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.other,
        ),
      );
      await expectLater(
        harness.manager.leaseTransferChannel(_primaryServer),
        blocked,
      );

      final siblingStates = _watch(harness, _siblingServer);
      var prompts = 0;
      harness.onHostKey = (_) async {
        prompts++;
        return true;
      };
      await expectLater(_join(harness, _ChannelKind.transfer), blocked);
      await _flushEvents();

      expect(siblingStates, [
        ServerConnectionState.disconnected,
        ServerConnectionState.blocked,
      ]);
      expect(prompts, 0);
      expect(harness.opener.calls, hasLength(2));

      // Disconnect ends this subscription's block without approving the key.
      await harness.manager.disconnectServer(_siblingServer);
      await _flushEvents();
      expect(siblingStates, [
        ServerConnectionState.disconnected,
        ServerConnectionState.blocked,
        ServerConnectionState.disconnected,
      ]);
      expect(
        await harness.manager.watchServer(_primaryServer).first,
        ServerConnectionState.blocked,
      );
    },
  );
}
