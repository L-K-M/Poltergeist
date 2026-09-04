import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _singleTransferPolicy = PoolPolicy(
  maxTransports: 1,
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 2,
);

void main() {
  test('a released lease cannot release the next borrower', () async {
    final harness = PoolHarness(policy: _singleTransferPolicy)..addServer('s1');
    addTearDown(() => harness.manager.disconnectServer('s1'));
    await harness.manager.openBrowseChannel('s1', paneTabId: 'keep');

    final old = await harness.manager.leaseTransferChannel('s1');
    await old.release();
    final current = await harness.manager.leaseTransferChannel('s1');
    expect(current.fs, same(old.fs));

    TransferChannelLease? granted;
    final pending = harness.manager.leaseTransferChannel('s1');
    unawaited(pending.then<void>((lease) => granted = lease, onError: (_) {}));
    await Future<void>.delayed(Duration.zero);
    expect(granted, isNull);

    // A delayed finally block from the old borrower must not free this lease.
    await old.release();
    await Future<void>.delayed(Duration.zero);
    expect(granted, isNull);

    await current.release();
    await (await pending).release();
  });

  test(
    'an old pane view cannot close a replacement after disconnect',
    () async {
      final harness = PoolHarness()..addServer('s1');
      addTearDown(() => harness.manager.disconnectServer('s1'));
      final old = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'tab',
      );
      await harness.manager.disconnectServer('s1');
      final current = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'tab',
      );

      await old.close();
      expect(harness.openChannels, hasLength(1));
      expect(await harness.manager.connectedServerIds(), {'s1'});
      expect(
        (await harness.manager.openBrowseChannel('s1', paneTabId: 'tab')).fs,
        same(current.fs),
      );
    },
  );

  test(
    'a closed shared binding cannot close its rebind to the same channel',
    () async {
      final harness = PoolHarness(
        policy: const PoolPolicy(
          maxTransports: 1,
          maxTransferChannelsPerTransport: 1,
          maxChannelsPerTransport: 1,
        ),
      )..addServer('s1');
      addTearDown(() => harness.manager.disconnectServer('s1'));
      final keeper = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'keep',
      );
      final old = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'tab',
      );
      await old.close();
      final current = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'tab',
      );
      expect(current.fs, same(old.fs));

      // Handle identity alone is insufficient: this is a new binding to it.
      await old.close();
      await keeper.close();
      expect(harness.openChannels, hasLength(1));
      await current.close();
      expect(harness.openChannels, isEmpty);
    },
  );

  test('concurrent opens of one tab share one binding lifetime', () async {
    final harness = PoolHarness()..addServer('s1');
    addTearDown(() => harness.manager.disconnectServer('s1'));
    await harness.manager.openBrowseChannel('s1', paneTabId: 'keep');
    final views = await Future.wait([
      harness.manager.openBrowseChannel('s1', paneTabId: 'tab'),
      harness.manager.openBrowseChannel('s1', paneTabId: 'tab'),
    ]);
    expect(views.first.fs, same(views.last.fs));

    await views.first.close();
    await harness.manager.openBrowseChannel('s1', paneTabId: 'tab');
    await views.last.close();
    expect(harness.openChannels, hasLength(2));
  });
}
