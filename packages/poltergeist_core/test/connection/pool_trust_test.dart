import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _originalKey = 'SHA256:original';
const _changedKey = 'SHA256:changed';
const _policy = PoolPolicy(
  maxTransports: 2,
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 3,
);

Future<PoolHarness> _harness(List<String> fingerprints) async {
  final harness =
      PoolHarness(
          policy: _policy,
          opener: FakeTransportOpener(presentedFingerprints: fingerprints),
        )
        ..addServer('s1')
        ..addServer('s2');
  addTearDown(() async {
    await harness.manager.disconnectServer('s1');
    await harness.manager.disconnectServer('s2');
  });
  await harness.store.put(
    const HostKey(
      host: 'example.com',
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: _originalKey,
      pinnedAt: 0,
    ),
  );
  return harness;
}

Future<void> _blockViaGrowth(PoolHarness harness) async {
  await harness.manager.openBrowseChannel('s1', paneTabId: 'one');
  await harness.manager.openBrowseChannel('s2', paneTabId: 'two');
  await harness.manager.leaseTransferChannel('s1');
  await expectLater(
    harness.manager.leaseTransferChannel('s1'),
    throwsA(isA<RemoteFileException>()),
  );
  for (final id in ['s1', 's2']) {
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
      harness.manager.leaseTransferChannel('s2'),
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
        harness.manager.openBrowseChannel('s1', paneTabId: 'retry'),
        throwsA(isA<RemoteFileException>()),
      );
      expect(
        await harness.manager.watchServer('s1').first,
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
    final opening = harness.manager.openBrowseChannel('s1', paneTabId: 'tab');
    final outcome = expectLater(opening, throwsA(isA<RemoteFileException>()));
    await entered.future;
    final state = await harness.manager.watchServer('s1').first;
    decision.complete(false);
    await outcome;

    expect(state, ServerConnectionState.blocked);
    expect(harness.store.pins.values.single.fingerprintSha256, _originalKey);
  });
}
