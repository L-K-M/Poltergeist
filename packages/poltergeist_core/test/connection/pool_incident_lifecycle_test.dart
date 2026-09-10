import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

// The trust-incident lifecycle (owner decision 2026-09-09T19:52Z, options
// 1a/2a/3a): a presented key returning to the pinned one lifts a declined
// block, declined incidents persist across restarts, and deleting a
// bookmark cascades deletion of its incident records.

const _originalKey = 'SHA256:original';
const _changedKey = 'SHA256:changed';
const _hostKeyType = 'ssh-ed25519';
const _policy = PoolPolicy(
  maxTransports: 2,
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 3,
);

Future<PoolHarness> _harness(
  List<String> fingerprints, {
  required IncidentStore store,
  List<String> serverIds = const ['s1', 's2'],
}) async {
  final harness = PoolHarness(
    policy: _policy,
    opener: FakeTransportOpener(presentedFingerprints: fingerprints),
    incidentStore: store,
  );
  for (final id in serverIds) {
    harness.addServer(id);
  }
  addTearDown(() async {
    for (final id in serverIds) {
      await harness.manager.disconnectServer(id);
    }
  });
  // Pre-pin the original key, as an earlier session would have.
  final config = harness.servers[serverIds.first]!;
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

/// Blocks the pool without a user review: the growth attempt presents the
/// changed key with prompting disabled, so the block lands and the
/// declined-key prompt never runs (the pool_trust_test pattern).
Future<void> _declineViaGrowth(PoolHarness harness) async {
  await harness.manager.openBrowseChannel('s1', paneTabId: 'one');
  await harness.manager.openBrowseChannel('s2', paneTabId: 'two');
  await harness.manager.leaseTransferChannel('s1');
  await expectLater(
    harness.manager.leaseTransferChannel('s1'),
    throwsA(isA<RemoteFileException>()),
  );
}

Matcher _blockedError() => isA<RemoteFileException>().having(
  (error) => error.message,
  'message',
  contains('blocked'),
);

/// Waits until the store's records satisfy [check]. The manager's
/// persistence writes are unawaited by design, so store assertions poll
/// briefly instead of racing them. [load] must return a fresh read: a
/// file-backed store caches its first load, so the caller supplies a new
/// instance per poll.
Future<void> _eventuallyRecords(
  Future<List<IncidentRecord>> Function() load,
  bool Function(List<IncidentRecord> records) check,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!check(await load())) {
    if (DateTime.now().isAfter(deadline)) {
      fail('The incident store never reached the expected state.');
    }
    await pumpEventQueue(times: 2);
  }
}

void main() {
  test('the pinned key returning clears the block and its records', () async {
    final store = InMemoryIncidentStore();
    final harness = await _harness([
      _originalKey,
      _changedKey,
      _originalKey,
    ], store: store);
    await _declineViaGrowth(harness);
    await _eventuallyRecords(
      () => store.load(),
      (records) => records.isNotEmpty,
    );
    var prompts = 0;
    harness.onHostKey = (_) async {
      prompts++;
      return true;
    };

    // 1a: presented == pinned lifts the declined block — no new verdict,
    // no prompt, no pin write.
    final pane = await harness.manager.openBrowseChannel(
      's1',
      paneTabId: 'back',
    );
    expect(prompts, 0);
    expect(harness.store.pins.values.single.fingerprintSha256, _originalKey);
    // Both bookmarks reference the shared pool: once the block lifts, the
    // live transport serves both.
    expect(await harness.manager.connectedServerIds(), {'s1', 's2'});
    await _eventuallyRecords(() => store.load(), (records) => records.isEmpty);
    await pane.close();
  });

  test('a declined incident survives a manager restart', () async {
    final store = InMemoryIncidentStore();
    final first = await _harness([_originalKey, _changedKey], store: store);
    await _declineViaGrowth(first);
    await _eventuallyRecords(
      () => store.load(),
      (records) => records.length == 2,
    );

    // Restart: fresh manager and pin store, same incident store. The
    // server still presents the changed key.
    final restarted = await _harness([_changedKey], store: store);
    await expectLater(
      restarted.manager.leaseTransferChannel('s1'),
      throwsA(_blockedError()),
    );
    // Nothing was dialed, so the block must have come from the persisted
    // records — a worker never prompts or connects on an inherited block.
    expect(restarted.opener.calls, isEmpty);

    // Review still works after the restart: approval clears the block and
    // deletes its persisted records.
    var prompts = 0;
    restarted.onHostKey = (_) async {
      prompts++;
      return true;
    };
    final pane = await restarted.manager.openBrowseChannel(
      's1',
      paneTabId: 'review',
    );
    expect(prompts, 1);
    expect(restarted.store.pins.values.single.fingerprintSha256, _changedKey);
    await _eventuallyRecords(() => store.load(), (records) => records.isEmpty);
    await pane.close();
  });

  test(
    'a declined incident survives a real store round-trip on disk',
    () async {
      final dir = await Directory.systemTemp.createTemp('incident-lifecycle-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } on Object {
          // Best-effort test cleanup.
        }
      });
      final path = '${dir.path}/incidents.json';

      final first = await _harness([
        _originalKey,
        _changedKey,
      ], store: FileIncidentStore(File(path)));
      await _declineViaGrowth(first);
      await _eventuallyRecords(
        () => FileIncidentStore(File(path)).load(),
        (records) => records.length == 2,
      );

      final restarted = await _harness([
        _changedKey,
      ], store: FileIncidentStore(File(path)));
      await expectLater(
        restarted.manager.leaseTransferChannel('s1'),
        throwsA(_blockedError()),
      );
      expect(restarted.opener.calls, isEmpty);
    },
  );

  test(
    'removing the last bookmark of a blocked endpoint clears the block',
    () async {
      final store = InMemoryIncidentStore();
      final harness = await _harness([
        _originalKey,
        _changedKey,
        _originalKey,
      ], store: store);
      await _declineViaGrowth(harness);
      await _eventuallyRecords(
        () => store.load(),
        (records) => records.length == 2,
      );

      // Identity rule for a shared server: the block is per-endpoint and
      // survives while any referencing bookmark still carries its record —
      // removing one bookmark only withdraws that bookmark's stake.
      await harness.manager.removeBookmark('s1');
      await _eventuallyRecords(
        () => store.load(),
        (records) => records.length == 1 && records.single.serverId == 's2',
      );
      await expectLater(
        harness.manager.leaseTransferChannel('s2'),
        throwsA(_blockedError()),
      );

      // Last bookmark out: its incident goes with it (3a), and a fresh
      // bookmark id at the same endpoint starts without any inherited block.
      await harness.manager.removeBookmark('s2');
      await _eventuallyRecords(
        () => store.load(),
        (records) => records.isEmpty,
      );
      harness.addServer('s3');
      var prompts = 0;
      harness.onHostKey = (_) async {
        prompts++;
        return true;
      };
      final pane = await harness.manager.openBrowseChannel(
        's3',
        paneTabId: 'fresh',
      );
      expect(prompts, 0);
      expect(harness.store.pins.values.single.fingerprintSha256, _originalKey);
      await pane.close();
    },
  );

  test(
    'a persisted block survives until its last owning bookmark leaves',
    () async {
      final store = InMemoryIncidentStore();
      final first = await _harness([_originalKey, _changedKey], store: store);
      await _declineViaGrowth(first);
      await _eventuallyRecords(
        () => store.load(),
        (records) => records.length == 2,
      );

      final restarted = await _harness([
        _originalKey,
        _changedKey,
      ], store: store);
      await expectLater(
        restarted.manager.leaseTransferChannel('s1'),
        throwsA(_blockedError()),
      );

      // s2 never connects in this session; its record is an orphan that the
      // removal still clears — but the block survives while s1's stake holds.
      await restarted.manager.removeBookmark('s2');
      await _eventuallyRecords(
        () => store.load(),
        (records) => records.length == 1 && records.single.serverId == 's1',
      );
      await expectLater(
        restarted.manager.leaseTransferChannel('s1'),
        throwsA(_blockedError()),
      );

      await restarted.manager.removeBookmark('s1');
      await _eventuallyRecords(
        () => store.load(),
        (records) => records.isEmpty,
      );

      // Same manager, fresh id: the endpoint connects without a block.
      restarted.addServer('s3');
      var prompts = 0;
      restarted.onHostKey = (_) async {
        prompts++;
        return true;
      };
      final pane = await restarted.manager.openBrowseChannel(
        's3',
        paneTabId: 'fresh',
      );
      expect(prompts, 0);
      await pane.close();
    },
  );
}
