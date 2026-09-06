import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _originalKey = 'SHA256:original';
const _changedKey = 'SHA256:changed';
const _hostKeyType = 'ssh-ed25519';
const _primaryServerId = 's1';
const _siblingServerId = 's2';
const _policy = PoolPolicy(
  maxTransports: 2,
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 3,
);

enum _GrowthRace { oldKey, authChallenge, delayedKey, interactiveRetry }

Future<PoolHarness> _harness(List<String> fingerprints) async {
  final harness =
      PoolHarness(
          policy: _policy,
          opener: FakeTransportOpener(presentedFingerprints: fingerprints),
        )
        ..addServer(_primaryServerId)
        ..addServer(_siblingServerId);
  addTearDown(() => _disconnectAll(harness));
  final config = harness.servers[_primaryServerId]!;
  await harness.store.put(
    HostKey(
      host: config.host,
      port: config.port,
      type: _hostKeyType,
      fingerprintSha256: _originalKey,
      pinnedAt: 0,
    ),
  );
  return harness;
}

Future<void> _disconnectAll(PoolHarness harness) async {
  await harness.manager.disconnectServer(_primaryServerId);
  await harness.manager.disconnectServer(_siblingServerId);
}

Future<void> _blockViaGrowth(PoolHarness harness) async {
  await harness.manager.openBrowseChannel(_primaryServerId, paneTabId: 'one');
  await harness.manager.openBrowseChannel(_siblingServerId, paneTabId: 'two');
  await harness.manager.leaseTransferChannel(_primaryServerId);
  await expectLater(
    harness.manager.leaseTransferChannel(_primaryServerId),
    throwsA(isA<RemoteFileException>()),
  );
  for (final id in [_primaryServerId, _siblingServerId]) {
    expect(
      await harness.manager.watchServer(id).first,
      ServerConnectionState.blocked,
    );
  }
}

void main() {
  test('a transfer request cannot prompt or clear a blocked pool', () async {
    final harness = await _harness([_originalKey, _changedKey]);
    await _blockViaGrowth(harness);
    var prompts = 0;
    harness.onHostKey = (_) async {
      prompts++;
      return true;
    };
    final connectCount = harness.opener.calls.length;

    await expectLater(
      harness.manager.leaseTransferChannel(_siblingServerId),
      throwsA(isA<RemoteFileException>()),
    );
    expect(prompts, 0);
    expect(harness.opener.calls, hasLength(connectCount));
    expect(harness.store.pins.values.single.fingerprintSha256, _originalKey);
  });

  test(
    'a trusted key reappearing cannot silently clear a hard block',
    () async {
      final harness = await _harness([_originalKey, _changedKey, _originalKey]);
      await _blockViaGrowth(harness);

      await expectLater(
        harness.manager.openBrowseChannel(_primaryServerId, paneTabId: 'retry'),
        throwsA(isA<RemoteFileException>()),
      );
      expect(
        await harness.manager.watchServer(_primaryServerId).first,
        ServerConnectionState.blocked,
      );
      expect(await harness.manager.connectedServerIds(), isEmpty);
      expect(harness.openChannels, isEmpty);
    },
  );

  test('the pool is blocked while a changed-key review is pending', () async {
    final harness = await _harness([_changedKey]);
    final entered = Completer<void>();
    final decision = Completer<bool>();
    harness.onHostKey = (_) {
      entered.complete();
      return decision.future;
    };
    final opening = harness.manager.openBrowseChannel(
      _primaryServerId,
      paneTabId: 'tab',
    );
    final outcome = expectLater(opening, throwsA(isA<RemoteFileException>()));
    await entered.future;
    final state = await harness.manager.watchServer(_primaryServerId).first;
    decision.complete(false);
    await outcome;

    expect(state, ServerConnectionState.blocked);
    expect(harness.store.pins.values.single.fingerprintSha256, _originalKey);
  });

  test('changed-key approval survives a subsequent auth failure', () async {
    final harness = await _harness([_changedKey]);
    const failure = RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied,
      operation: 'connect',
      message: 'Authentication failed after host-key approval.',
    );
    harness.opener.connectFailure = failure;
    var prompts = 0;
    harness.onHostKey = (_) async {
      prompts++;
      return true;
    };
    Object? firstFailure;
    await harness.manager
        .openBrowseChannel(_primaryServerId, paneTabId: 'auth-fails')
        .then<void>(
          (_) => fail('unexpected authenticated connection'),
          onError: (Object error) {
            firstFailure = error;
          },
        );
    expect(harness.store.pins.values.single.fingerprintSha256, _changedKey);

    // TOFU pinned the approved key; retries must not need another verdict.
    harness.opener.connectFailure = null;
    await harness.manager.openBrowseChannel(
      _primaryServerId,
      paneTabId: 'retry',
    );
    expect(firstFailure, same(failure));
    expect(prompts, 1);
    expect(
      await harness.manager.watchServer(_primaryServerId).first,
      ServerConnectionState.connected,
    );
  });

  test(
    'a trust incident survives pool retirement when the original key returns',
    () async {
      final harness = await _harness([_originalKey, _changedKey, _originalKey]);
      await _blockViaGrowth(harness);
      await _disconnectAll(harness);

      await expectLater(
        harness.manager.openBrowseChannel(
          _primaryServerId,
          paneTabId: 'returned',
        ),
        throwsA(isA<RemoteFileException>()),
      );
      expect(
        await harness.manager.watchServer(_primaryServerId).first,
        ServerConnectionState.blocked,
      );
      expect(harness.store.pins.values.single.fingerprintSha256, _originalKey);
      expect(await harness.manager.connectedServerIds(), isEmpty);
      expect(harness.openChannels, isEmpty);
    },
  );

  test(
    'workers cannot review an incident inherited by a replacement pool',
    () async {
      final harness = await _harness([_originalKey, _changedKey]);
      await _blockViaGrowth(harness);
      await _disconnectAll(harness);
      var prompts = 0;
      harness.onHostKey = (_) async {
        prompts++;
        return true;
      };
      final connectCount = harness.opener.calls.length;

      await expectLater(
        harness.manager.leaseTransferChannel(_primaryServerId),
        throwsA(isA<RemoteFileException>()),
      );
      expect(prompts, 0);
      expect(harness.opener.calls, hasLength(connectCount));
      expect(harness.store.pins.values.single.fingerprintSha256, _originalKey);
    },
  );

  test(
    'current approval clears an inherited incident across later sessions',
    () async {
      final harness = await _harness([_originalKey, _changedKey]);
      await _blockViaGrowth(harness);
      await _disconnectAll(harness);
      var prompts = 0;
      harness.onHostKey = (_) async {
        prompts++;
        return true;
      };

      await harness.manager.openBrowseChannel(
        _primaryServerId,
        paneTabId: 'review',
      );
      expect(harness.store.pins.values.single.fingerprintSha256, _changedKey);
      await _disconnectAll(harness);
      final lease = await harness.manager.leaseTransferChannel(
        _primaryServerId,
      );
      expect(prompts, 1);
      expect(await harness.manager.connectedServerIds(), {_primaryServerId});
      await lease.release();
    },
  );

  test(
    'a retired approval cannot pin or clear a replacement incident',
    () async {
      final harness = await _harness([_changedKey]);
      final entered = Completer<void>();
      final decision = Completer<bool>();
      var prompts = 0;
      harness.onHostKey = (_) {
        prompts++;
        if (prompts != 1) return Future.value(false);
        entered.complete();
        return decision.future;
      };
      Object? retiredError;
      final retired = harness.manager
          .openBrowseChannel(_primaryServerId, paneTabId: 'retired')
          .then<void>(
            (_) => fail('retired connection succeeded'),
            onError: (Object error) {
              retiredError = error;
            },
          );
      await entered.future;
      await _disconnectAll(harness);

      // Same fingerprints, different incident: equality is not authority.
      await expectLater(
        harness.manager.openBrowseChannel(
          _primaryServerId,
          paneTabId: 'replacement',
        ),
        throwsA(isA<RemoteFileException>()),
      );
      decision.complete(true);
      await retired;

      expect(harness.store.pins.values.single.fingerprintSha256, _originalKey);
      expect(
        retiredError,
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.disconnected,
        ),
      );
      expect(
        await harness.manager.watchServer(_primaryServerId).first,
        ServerConnectionState.blocked,
      );
      expect(await harness.manager.connectedServerIds(), isEmpty);
    },
  );

  test(
    'a fresh transfer first connect may still request trust review',
    () async {
      final harness = await _harness([_changedKey]);
      var prompts = 0;
      harness.onHostKey = (_) async {
        prompts++;
        return false;
      };

      await expectLater(
        harness.manager.leaseTransferChannel(_primaryServerId),
        throwsA(isA<RemoteFileException>()),
      );
      expect(prompts, 1);
      expect(harness.opener.calls.single.prompting, ConnectPrompting.enabled);
      expect(
        await harness.manager.watchServer(_primaryServerId).first,
        ServerConnectionState.blocked,
      );
    },
  );

  test(
    'live watchers retain an inherited block during review and teardown',
    () async {
      final harness = await _harness([_originalKey, _changedKey]);
      await _blockViaGrowth(harness);
      await _disconnectAll(harness);
      final states = <ServerConnectionState>[];
      final subscription = harness.manager
          .watchServer(_primaryServerId)
          .listen(states.add);
      addTearDown(subscription.cancel);
      final entered = Completer<void>();
      final decision = Completer<bool>();
      harness.onHostKey = (_) {
        entered.complete();
        return decision.future;
      };
      final outcome = expectLater(
        harness.manager.openBrowseChannel(
          _primaryServerId,
          paneTabId: 'review',
        ),
        throwsA(isA<RemoteFileException>()),
      );
      await entered.future;
      await Future<void>.delayed(Duration.zero);
      final pendingState = states.last;
      decision.complete(false);
      await outcome;
      await Future<void>.delayed(Duration.zero);

      expect(pendingState, ServerConnectionState.blocked);
      expect(states.first, ServerConnectionState.disconnected);
      expect(states.skip(1), everyElement(ServerConnectionState.blocked));
    },
  );

  test(
    'removing a pin cannot permit first-use approval of a hard block',
    () async {
      final harness = await _harness([_originalKey, _changedKey]);
      await _blockViaGrowth(harness);
      harness.store.pins.clear();
      var prompts = 0;
      harness.onHostKey = (_) async {
        prompts++;
        return true;
      };

      await expectLater(
        harness.manager.openBrowseChannel(
          _primaryServerId,
          paneTabId: 'no-pin',
        ),
        throwsA(isA<RemoteFileException>()),
      );
      expect([prompts, harness.store.pins.length], [0, 0]);
      expect(
        await harness.manager.watchServer(_primaryServerId).first,
        ServerConnectionState.blocked,
      );
    },
  );

  for (final race in _GrowthRace.values) {
    test(
      'late growth ${race.name} respects the replacement connection',
      () async {
        final retryKey = race == _GrowthRace.interactiveRetry
            ? _originalKey
            : _changedKey;
        final growthKey = race == _GrowthRace.delayedKey
            ? _changedKey
            : _originalKey;
        final harness = await _harness([_originalKey, growthKey, retryKey]);
        await harness.manager.openBrowseChannel(
          _primaryServerId,
          paneTabId: 'one',
        );
        await harness.manager.openBrowseChannel(
          _siblingServerId,
          paneTabId: 'two',
        );
        final original = harness.opener.transports.single;
        final channelGate = Completer<void>();
        original.openGate = channelGate;
        PaneChannel? third;
        final errors = <Object>[];
        final browsing = harness.manager
            .openBrowseChannel(_primaryServerId, paneTabId: 'three')
            .then<void>((channel) {
              third = channel;
            }, onError: errors.add);
        await Future<void>.delayed(Duration.zero);
        final gate = Completer<void>();
        if (race == _GrowthRace.delayedKey) {
          harness.opener.growthVerificationGate = gate;
        } else {
          harness.opener.growthGate = gate;
        }
        TransferChannelLease? granted;
        final pending = harness.manager
            .leaseTransferChannel(_primaryServerId)
            .then<void>((lease) {
              granted = lease;
            }, onError: errors.add);
        await Future<void>.delayed(Duration.zero);
        final growthCall = harness.opener.calls.singleWhere(
          (call) => call.prompting == ConnectPrompting.disabled,
        );

        // Evict the dead slot while its growth replacement is still in flight.
        original.closed = true;
        channelGate.completeError(
          const RemoteFileException(
            kind: RemoteFileErrorKind.disconnected,
            operation: 'open SFTP',
            message: 'The original transport disconnected mid-open.',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        if (race == _GrowthRace.interactiveRetry) {
          harness.opener.authKind = AuthKind.keyboardInteractive;
        }

        // Retry establishes current trust/auth while the old result is parked.
        final approved = await harness.manager.openBrowseChannel(
          _siblingServerId,
          paneTabId: 'new-key',
        );
        final currentTransport = harness.opener.calls.last.transport;
        expect(harness.store.pins.values.single.fingerprintSha256, retryKey);
        if (race == _GrowthRace.authChallenge) {
          harness.opener.connectFailure = const AuthChallengeRequiredError(
            'An obsolete growth attempt requires interaction.',
          );
        }
        gate.complete();
        await Future.wait([browsing, pending]);
        final oldHandshakeClosed = growthCall.transport?.closed ?? true;
        final liveAfterGrowth = harness.opener.transports
            .where((transport) => !transport.closed)
            .toList();
        harness.opener.connectFailure = null;

        // The stale result must neither supply a slot nor change the current cap.
        TransferChannelLease? additional;
        final callsBeforeProbe = harness.opener.calls.length;
        final probe = harness.manager
            .leaseTransferChannel(_primaryServerId)
            .then<void>((lease) {
              additional = lease;
            }, onError: errors.add);
        await Future<void>.delayed(Duration.zero);
        final probeGrew = harness.opener.calls.length > callsBeforeProbe;
        await third?.close();
        await approved.close();
        await granted?.release();
        await probe;
        await additional?.release();

        expect(errors, isEmpty);
        expect(oldHandshakeClosed, isTrue);
        expect(liveAfterGrowth, [currentTransport]);
        expect(probeGrew, race != _GrowthRace.interactiveRetry);
      },
    );
  }
}
