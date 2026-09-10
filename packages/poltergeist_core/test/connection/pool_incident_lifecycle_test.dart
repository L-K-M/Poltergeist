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
const _thirdKey = 'SHA256:third';
const _hostKeyType = 'ssh-ed25519';
const _watchClosureTimeout = Duration(seconds: 5);
const _policy = PoolPolicy(
  maxTransports: 2,
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 3,
);

Future<PoolHarness> _harness(
  List<String> fingerprints, {
  required IncidentStore store,
  List<String> serverIds = const ['s1', 's2'],
  String? pinnedFingerprint = _originalKey,
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
  // Pre-pin the original key, as an earlier session would have. Null models
  // a pin store that lost the endpoint's pin — audit finding A's premise.
  if (pinnedFingerprint == null) return harness;
  final config = harness.servers[serverIds.first]!;
  await harness.store.put(
    HostKey(
      host: config.host,
      port: config.port,
      type: _hostKeyType,
      fingerprintSha256: pinnedFingerprint,
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
Future<void> _eventually<T>(
  Future<T> Function() load,
  bool Function(T value) check,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  T? latest;
  while (!check(latest = await load())) {
    if (DateTime.now().isAfter(deadline)) {
      fail('The store never reached the expected state; last value: $latest');
    }
    await pumpEventQueue(times: 2);
  }
}

IncidentRecord _record({
  String serverId = 's1',
  String host = 'example.com',
  int port = 22,
  String? pinned = _originalKey,
}) => IncidentRecord(
  serverId: serverId,
  host: host,
  port: port,
  username: 'test',
  presentedFingerprintSha256: _changedKey,
  pinnedFingerprintSha256: pinned,
);

/// A store whose load parks on [gate] and returns the pre-gate snapshot —
/// the shape of a file-backed load racing a removal's delete.
final class _GatedIncidentStore implements IncidentStore {
  final Map<String, IncidentRecord> records;
  final gate = Completer<void>();

  _GatedIncidentStore({required List<IncidentRecord> records})
    : records = {for (final record in records) record.serverId: record};

  @override
  Future<List<IncidentRecord>> load() async {
    final snapshot = List.of(records.values);
    await gate.future;
    return snapshot;
  }

  @override
  Future<void> put(IncidentRecord record) async {
    records[record.serverId] = record;
  }

  @override
  Future<void> removeFor(String serverId, PoolKey endpoint) async {
    final stored = records[serverId];
    if (stored != null && stored.poolKey == endpoint) records.remove(serverId);
  }

  @override
  Future<void> removeAllFor(String serverId) async {
    records.remove(serverId);
  }
}

/// Every mutation fails — the observer hook's fixture.
final class _ThrowingIncidentStore implements IncidentStore {
  @override
  Future<List<IncidentRecord>> load() async => const [];

  @override
  Future<void> put(IncidentRecord record) async {
    throw const FileSystemException('Simulated incident write failure.');
  }

  @override
  Future<void> removeFor(String serverId, PoolKey endpoint) async {
    throw const FileSystemException('Simulated incident delete failure.');
  }

  @override
  Future<void> removeAllFor(String serverId) async {
    throw const FileSystemException('Simulated incident delete failure.');
  }
}

/// Loads and stores normally but fails every delete — the fixture for the
/// load-time drop whose cleanup is best-effort.
final class _DeleteFailingIncidentStore implements IncidentStore {
  final IncidentStore _inner;

  _DeleteFailingIncidentStore(this._inner);

  @override
  Future<List<IncidentRecord>> load() => _inner.load();

  @override
  Future<void> put(IncidentRecord record) => _inner.put(record);

  @override
  Future<void> removeFor(String serverId, PoolKey endpoint) async {
    throw const FileSystemException('Simulated incident delete failure.');
  }

  @override
  Future<void> removeAllFor(String serverId) async {
    throw const FileSystemException('Simulated incident delete failure.');
  }
}

/// A manager whose teardown throws. No production path does today — every
/// cleanup await on that route runs through `closeSshResource`'s ignore
/// mode — so the cascade's exception safety (audit finding F) is pinned by
/// overriding the only await `removeBookmark` makes before it.
final class _FailingTeardownManager extends PooledConnectionManager {
  _FailingTeardownManager({
    required super.resolveServer,
    required super.resolveCredentials,
    required super.tofu,
    required super.onHostKey,
    required super.openTransport,
    super.incidentStore,
    super.policy,
  });

  @override
  Future<void> disconnectServer(String serverId) async {
    throw StateError('simulated teardown failure');
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
    await _eventually(() => store.load(), (records) => records.isNotEmpty);
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
    await _eventually(() => store.load(), (records) => records.isEmpty);
    await pane.close();
  });

  test('a declined incident survives a manager restart', () async {
    final store = InMemoryIncidentStore();
    final first = await _harness([_originalKey, _changedKey], store: store);
    await _declineViaGrowth(first);
    await _eventually(() => store.load(), (records) => records.length == 2);

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
    await _eventually(() => store.load(), (records) => records.isEmpty);
    await pane.close();
  });

  test('a restored block lifts when the pinned key returns', () async {
    final store = InMemoryIncidentStore();
    await store.put(_record(serverId: 's1'));

    // Item 6's coupling: the record and its pin are restored together, so
    // the inherited block keeps both of D18's escapes — explicit review,
    // and 1a's restored-key match.
    final harness = await _harness([_originalKey], store: store);
    await expectLater(
      harness.manager.leaseTransferChannel('s1'),
      throwsA(_blockedError()),
    );
    // Nothing was dialed: the block came from the restored record.
    expect(harness.opener.calls, isEmpty);

    var prompts = 0;
    harness.onHostKey = (_) async {
      prompts++;
      return true;
    };
    final pane = await harness.manager.openBrowseChannel(
      's1',
      paneTabId: 'back',
    );
    expect(prompts, 0);
    expect(harness.store.pins.values.single.fingerprintSha256, _originalKey);
    await _eventually(() => store.load(), (records) => records.isEmpty);
    await pane.close();
  });

  test(
    'a restored record with no pin is skipped but never deleted',
    () async {
      final store = InMemoryIncidentStore();
      await store.put(_record(serverId: 's1'));

      // Audit finding A: the record survived a restart but its pin did not.
      // Restoring that block leaves it with no escape — every connect
      // verifies firstUse, which a blocked pool refuses to prompt for, and
      // 1a has no pin to match — so the load skips it and lets the endpoint
      // re-detect. It does NOT delete it: "no pin" is also what a pin store
      // that failed to load reads as, and erasing the user's persisted
      // declines over a transient read is irreversible.
      final harness = await _harness(
        [_changedKey],
        store: store,
        pinnedFingerprint: null,
      );
      final verdicts = <HostKeyVerdict>[];
      harness.onHostKey = (decision) async {
        verdicts.add(decision.verdict);
        return true;
      };

      final pane = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'review',
      );
      expect(verdicts, [HostKeyVerdict.firstUse]);
      expect(harness.store.pins.values.single.fingerprintSha256, _changedKey);
      expect(await store.load(), [_record(serverId: 's1')]);
      await pane.close();
    },
  );

  test('a pin at another endpoint does not restore a record', () async {
    final store = InMemoryIncidentStore();
    await store.put(_record(serverId: 's1'));

    final harness = await _harness(
      [_changedKey],
      store: store,
      pinnedFingerprint: null,
    );
    // The record's own fingerprint, pinned at a DIFFERENT endpoint (a cloned
    // machine, a shared jump host). Only the pin at the record's endpoint can
    // review or lift its block, so a fingerprint found elsewhere in the store
    // must not restore it.
    await harness.store.put(
      HostKey(
        host: 'other.example',
        port: 2222,
        type: _hostKeyType,
        fingerprintSha256: _originalKey,
        pinnedAt: 0,
      ),
    );
    final verdicts = <HostKeyVerdict>[];
    harness.onHostKey = (decision) async {
      verdicts.add(decision.verdict);
      return true;
    };

    final pane = await harness.manager.openBrowseChannel(
      's1',
      paneTabId: 'review',
    );
    expect(verdicts, [HostKeyVerdict.firstUse]);
    // Skipped, not deleted: the record's own endpoint has no pin, which is
    // also what a pin store that failed to load reads as.
    expect(await store.load(), [_record(serverId: 's1')]);
    await pane.close();
  });

  test(
    'a restored record whose pin moved on is dropped and re-detected',
    () async {
      final store = InMemoryIncidentStore();
      await store.put(_record(serverId: 's1'));
      // A record with no pinned half can never name the current pin either.
      await store.put(_record(serverId: 's2', pinned: null));

      final harness = await _harness(
        [_changedKey],
        store: store,
        pinnedFingerprint: _thirdKey,
      );
      final verdicts = <HostKeyVerdict>[];
      harness.onHostKey = (decision) async {
        verdicts.add(decision.verdict);
        return true;
      };

      // The stored block names a pin the store no longer holds: its detail
      // would be wrong, and 1a would lift it on a key the record never
      // named. Re-detection against the real pin decides instead — the
      // endpoint comes up unblocked, so even a worker reaches the review.
      final lease = await harness.manager.leaseTransferChannel('s1');
      expect(verdicts, [HostKeyVerdict.changed]);
      expect(harness.store.pins.values.single.fingerprintSha256, _changedKey);
      await _eventually(() => store.load(), (records) => records.isEmpty);
      await lease.release();
    },
  );

  test('a stale record whose delete fails still loads unblocked', () async {
    final inner = InMemoryIncidentStore();
    await inner.put(_record(serverId: 's1'));
    final harness = await _harness(
      [_changedKey],
      store: _DeleteFailingIncidentStore(inner),
      pinnedFingerprint: _thirdKey,
    );
    var prompts = 0;
    harness.onHostKey = (_) async {
      prompts++;
      return true;
    };

    // The endpoint is pinned, just to another key, so the record is stale
    // and its delete is attempted. A worker never prompts, so a lease that
    // connects at all proves the block was not restored; the failed delete
    // reaches only the observer.
    final lease = await harness.manager.leaseTransferChannel('s1');
    expect(prompts, 1);
    expect(harness.incidentStoreErrors, isNotEmpty);
    await lease.release();
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
      await _eventually(
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
      await _eventually(() => store.load(), (records) => records.length == 2);

      // Identity rule for a shared server: the block is per-endpoint and
      // survives while any referencing bookmark still carries its record —
      // removing one bookmark only withdraws that bookmark's stake.
      await harness.manager.removeBookmark('s1');
      await _eventually(
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
      await _eventually(() => store.load(), (records) => records.isEmpty);
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
      await _eventually(() => store.load(), (records) => records.length == 2);

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
      await _eventually(
        () => store.load(),
        (records) => records.length == 1 && records.single.serverId == 's1',
      );
      await expectLater(
        restarted.manager.leaseTransferChannel('s1'),
        throwsA(_blockedError()),
      );

      await restarted.manager.removeBookmark('s1');
      await _eventually(() => store.load(), (records) => records.isEmpty);

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

  test(
    'a removal racing the lazy store load leaves no phantom owner',
    () async {
      final store = _GatedIncidentStore(
        records: [
          _record(serverId: 's1'),
          _record(serverId: 's2'),
        ],
      );
      final harness = PoolHarness(
        policy: _policy,
        opener: FakeTransportOpener(presentedFingerprints: [_changedKey]),
        incidentStore: store,
      )..addServer('s1');
      addTearDown(() async {
        for (final id in harness.servers.keys.toList()) {
          await harness.manager.disconnectServer(id);
        }
      });
      final config = harness.servers['s1']!;
      await harness.store.put(
        HostKey(
          host: config.host,
          port: config.port,
          type: _hostKeyType,
          fingerprintSha256: _originalKey,
          pinnedAt: 0,
        ),
      );
      harness.onHostKey = (_) async => false;

      // A reference resolution parks inside the store load while a removal
      // for the same bookmark runs; the load's snapshot predates the delete
      // (the file-store race shape).
      final opening = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
      final removal = harness.manager.removeBookmark('s2');
      store.gate.complete();
      await expectLater(opening, throwsA(_blockedError()));
      await removal;

      // The last live bookmark leaves: with the phantom owner the block
      // would survive s1's removal, and the fresh id's worker would throw
      // blocked instead of connecting.
      await harness.manager.removeBookmark('s1');
      harness.addServer('s3');
      var prompts = 0;
      harness.onHostKey = (_) async {
        prompts++;
        return true;
      };
      final lease = await harness.manager.leaseTransferChannel('s3');
      expect(prompts, 1);
      await lease.release();
    },
  );

  test(
    'a removal during an in-flight connect leaves no state behind',
    () async {
      final store = InMemoryIncidentStore();
      final harness = await _harness([
        _originalKey,
        _changedKey,
      ], store: store);
      harness.credentialGate = Completer<void>();

      // The first connect parks inside credential resolution while the
      // bookmark is deleted. The pool's reference and pending identity are
      // gone before the resolution returns, so the late completion must not
      // dial, re-register state, or persist a record for a deleted id.
      final opening = harness.manager.openBrowseChannel('s1', paneTabId: 'a');
      await pumpEventQueue();
      final states = harness.manager.watchServer('s1').toList();

      await harness.manager.removeBookmark('s1');
      harness.credentialGate!.complete();

      await expectLater(opening, throwsA(isA<RemoteFileException>()));
      final observed = await states.timeout(_watchClosureTimeout);
      expect(
        observed.last,
        const ServerStatus(ServerConnectionState.disconnected),
      );
      expect(harness.opener.calls, isEmpty);
      expect(await store.load(), isEmpty);
    },
  );

  test(
    'store failures reach the observer without affecting the block',
    () async {
      final store = _ThrowingIncidentStore();
      final harness = await _harness([_originalKey, _changedKey], store: store);
      await _declineViaGrowth(harness);
      await _eventually(
        () async => harness.incidentStoreErrors,
        (errors) => errors.isNotEmpty,
      );

      // The live block is untouched by the failed persistence.
      await expectLater(
        harness.manager.leaseTransferChannel('s1'),
        throwsA(_blockedError()),
      );
    },
  );

  test(
    'lifting a block spares a re-pointed bookmark\'s newer record',
    () async {
      final store = InMemoryIncidentStore();
      final harness = await _harness([
        _originalKey,
        _changedKey,
        _originalKey,
      ], store: store);
      await _declineViaGrowth(harness);
      await _eventually(() => store.load(), (records) => records.length == 2);

      // The bookmark s1 was re-pointed to another endpoint and declined
      // there: the store now holds the NEW endpoint's block under s1
      // (single-record-per-serverId stores upsert).
      await store.put(
        _record(serverId: 's1', host: 'other.example', port: 2022),
      );

      // The old endpoint's block lifts via the pinned key (1a). The scoped
      // delete must not touch s1's new-endpoint record.
      final pane = await harness.manager.openBrowseChannel(
        's1',
        paneTabId: 'back',
      );
      await pane.close();
      await _eventually(
        () => store.load(),
        (records) =>
            records.length == 1 &&
            records.single.serverId == 's1' &&
            records.single.host == 'other.example',
      );
    },
  );

  test('a lift removes a stale same-endpoint record', () async {
    final store = InMemoryIncidentStore();
    final harness = await _harness([
      _originalKey,
      _changedKey,
      _originalKey,
    ], store: store);
    await _declineViaGrowth(harness);
    await _eventually(() => store.load(), (records) => records.length == 2);

    // Simulate a failed re-write: the store holds an older payload of the
    // same endpoint. The lift must still delete it — matching by payload
    // equality would miss it and re-block after a restart.
    for (final record in await store.load()) {
      await store.put(
        IncidentRecord(
          serverId: record.serverId,
          host: record.host,
          port: record.port,
          username: record.username,
          presentedFingerprintSha256: 'SHA256:stale',
          pinnedFingerprintSha256: record.pinnedFingerprintSha256,
        ),
      );
    }

    final pane = await harness.manager.openBrowseChannel(
      's1',
      paneTabId: 'back',
    );
    await pane.close();
    await _eventually(() => store.load(), (records) => records.isEmpty);
  });

  test('the removal cascade survives a thrown teardown', () async {
    final store = InMemoryIncidentStore();
    await store.put(_record(serverId: 's1'));
    final manager = _FailingTeardownManager(
      // Nothing resolves or dials: removeBookmark fails before any of it.
      resolveServer: (serverId) async => throw StateError('unused $serverId'),
      resolveCredentials: (config, scope) async =>
          throw StateError('unused ${config.id}'),
      tofu: TofuVerifier(FakeHostKeyStore()),
      onHostKey: (_) async => true,
      openTransport: FakeTransportOpener().opener,
      incidentStore: store,
      policy: _policy,
    );

    // The app has already deleted the bookmark, so removeBookmark may never
    // be retried: its cascade must run even when the teardown throws
    // (audit finding F), or the record and its owner stake outlive it.
    await expectLater(manager.removeBookmark('s1'), throwsStateError);
    expect(await store.load(), isEmpty);
  });

  test(
    'a failing record delete neither fails the removal nor strands the watch',
    () async {
      final harness = await _harness(
        [_originalKey],
        store: _ThrowingIncidentStore(),
      );
      final states = harness.manager.watchServer('s1').toList();

      // The delete is best-effort and reports through the observer: it must
      // not fail a removal the app cannot retry, and the fan-out teardown
      // runs before it, so the watch still completes.
      await harness.manager.removeBookmark('s1');

      expect(harness.incidentStoreErrors, isNotEmpty);
      expect(await states.timeout(_watchClosureTimeout), [
        const ServerStatus(ServerConnectionState.disconnected),
      ]);
    },
  );

  test('removing a bookmark completes its state watch', () async {
    final harness = await _harness(
      [_originalKey],
      store: InMemoryIncidentStore(),
    );

    // A disconnected bookmark keeps its watch open — it may reconnect. A
    // removed one can never emit again, so its stream completes instead of
    // leaving per-id state behind in a long-lived engine (audit finding C).
    final states = harness.manager.watchServer('s1').toList();
    final pane = await harness.manager.openBrowseChannel(
      's1',
      paneTabId: 'a',
    );
    await pane.close();
    await harness.manager.removeBookmark('s1');

    final observed = await states.timeout(_watchClosureTimeout);
    expect(
      observed.first,
      const ServerStatus(ServerConnectionState.disconnected),
    );
    expect(
      observed,
      contains(const ServerStatus(ServerConnectionState.connected)),
    );
    expect(
      observed.last,
      const ServerStatus(ServerConnectionState.disconnected),
    );
  });
}
