import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

/// Lets queued (async) stream deliveries land before asserting on them —
/// watchServer delivers with standard async stream semantics, and some
/// chains need more than one event-loop turn.
Future<void> flushEvents({int turns = 3}) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The 03 §3.2 growth rules, one named behavior each (08 §3.2's "Pool
/// growth rules" suite). Keepalive, idle teardown, and reconnect land with
/// their own milestone slice.
void main() {
  test('first connect is serialized: one connect, one TOFU prompt', () async {
    final harness = PoolHarness()..addServer('s1');
    final prompts = <HostKeyDecision>[];
    harness.onHostKey = (decision) async {
      prompts.add(decision);
      return true;
    };

    final states = <ServerConnectionState>[];
    harness.manager.watchServer('s1').listen(states.add);

    final results = await Future.wait([
      harness.manager.openBrowseChannel('s1', paneTabId: 'tab1'),
      harness.manager.openBrowseChannel('s1', paneTabId: 'tab2'),
    ]);
    await flushEvents();

    // One connect, one first-use prompt — growth rule 1 (D5, D18).
    expect(harness.opener.calls, hasLength(1));
    expect(prompts, hasLength(1));
    expect(prompts.single.verdict, HostKeyVerdict.firstUse);

    // Two tabs, two dedicated channels on that one transport.
    expect(harness.opener.transports.single.channels, hasLength(2));
    expect(results[0].fs, isNot(same(results[1].fs)));

    // The approval pinned the key; a second tab never re-prompts (the tab
    // count above already proves one prompt, the pin proves it stuck).
    expect(harness.store.pins, hasLength(1));

    expect(states.first, ServerConnectionState.disconnected);
    expect(states, containsAllInOrder([
      ServerConnectionState.connecting,
      ServerConnectionState.connected,
    ]));
    expect(await harness.manager.connectedServerIds(), {'s1'});
  });

  test('two bookmarks at one endpoint share one pool and one prompt',
      () async {
    final harness = PoolHarness()
      ..addServer('s1', host: 'example.com')
      // Case difference only: DNS names are case-insensitive.
      ..addServer('s2', host: 'EXAMPLE.com');
    final prompts = <HostKeyDecision>[];
    harness.onHostKey = (decision) async {
      prompts.add(decision);
      return true;
    };

    await Future.wait([
      harness.manager.openBrowseChannel('s1', paneTabId: 'tab1'),
      harness.manager.openBrowseChannel('s2', paneTabId: 'tab2'),
    ]);

    expect(harness.opener.calls, hasLength(1));
    expect(prompts, hasLength(1));
    expect(await harness.manager.connectedServerIds(), {'s1', 's2'});
  });

  test('distinct endpoints get distinct pools', () async {
    final harness = PoolHarness()
      ..addServer('s1', host: 'a.example.com')
      ..addServer('s2', host: 'a.example.com', username: 'other')
      ..addServer('s3', host: 'a.example.com', jumpHostId: 'bastion');

    await harness.manager.openBrowseChannel('s1', paneTabId: 't');
    await harness.manager.openBrowseChannel('s2', paneTabId: 't');
    await harness.manager.openBrowseChannel('s3', paneTabId: 't');

    expect(harness.opener.calls, hasLength(3));
  });

  test('re-opening a pane tab reuses its channel', () async {
    final harness = PoolHarness()..addServer('s1');

    final first = await harness.manager.openBrowseChannel('s1', paneTabId: 't');
    final second = await harness.manager.openBrowseChannel('s1', paneTabId: 't');

    expect(second.fs, same(first.fs));
    expect(second.homePath, first.homePath);
    expect(harness.channels, hasLength(1));
  });

  test('interactive auth caps the pool at one transport', () async {
    final harness = PoolHarness(
      opener: FakeTransportOpener(authKind: AuthKind.keyboardInteractive),
    )..addServer('s1');

    await harness.manager.openBrowseChannel('s1', paneTabId: 't');

    // A burst beyond the per-transport transfer budget: 5th and 6th block.
    final leases = [
      for (var i = 0; i < 6; i++) harness.manager.leaseTransferChannel('s1'),
    ];
    await Future.wait(leases.take(4));

    // One transport, four transfer channels plus the browse channel, and
    // exactly one opener call — growth never ran, so no second prompt path
    // was even attempted (rule 2 / D5).
    expect(harness.opener.transports, hasLength(1));
    expect(harness.opener.transports.single.channels, hasLength(5));
    expect(harness.opener.calls, hasLength(1));
    expect(
      harness.opener.calls.single.onKeyboardInteractive,
      isNotNull,
      reason: 'the first connect must be able to answer 2FA challenges',
    );

    // The 5th lease waits; a release serves it.
    var fifthServed = false;
    final fifth = leases[4].then((_) => fifthServed = true);
    await flushEvents();
    expect(fifthServed, isFalse);
    final released = await leases[0];
    await released.release();
    await fifth;
    expect(fifthServed, isTrue);

    // Return the granted leases so nothing dangles past the test's end;
    // freed slots may serve the ignored 6th — its future is already ignored.
    for (final pending in leases.sublist(1, 5)) {
      await (await pending).release();
    }

    // The 6th lease deliberately never completes — ignore it like the
    // ninth-lease case below so a later teardown error can't leak unhandled.
    leases[5].ignore();
  });

  test('non-interactive auth grows transports reusing resolved credentials',
      () async {
    final harness = PoolHarness()..addServer('s1');

    await harness.manager.openBrowseChannel('s1', paneTabId: 't');

    final leases = [
      for (var i = 0; i < 8; i++) harness.manager.leaseTransferChannel('s1'),
    ];
    await Future.wait(leases);

    expect(harness.opener.transports, hasLength(2));
    expect(harness.opener.calls, hasLength(2));

    // Growth reuses the first connect's credentials verbatim (rule 3) and
    // runs with every prompt disabled.
    final growth = harness.opener.calls[1];
    expect(growth.credentials, same(harness.opener.calls[0].credentials));
    expect(growth.onKeyboardInteractive, isNull);
    expect(growth.prompting, ConnectPrompting.disabled);

    // 2 transports x 4 transfer channels are all leased; the 9th blocks.
    var ninthServed = false;
    // Deliberately left dangling: the point is that it never completes.
    harness.manager
        .leaseTransferChannel('s1')
        .then((_) => ninthServed = true)
        .ignore();
    await flushEvents();
    expect(ninthServed, isFalse);
    // No third growth attempt began — the pool is at maxTransports.
    expect(harness.opener.calls, hasLength(2));

    // Return the granted leases so nothing dangles past the test's end; a
    // freed slot may serve the ignored 9th — its future is already ignored.
    for (final lease in leases) {
      await (await lease).release();
    }
  });

  test('a growth auth challenge marks the pool interactive-capped',
      () async {
    final harness = PoolHarness(
      opener: FakeTransportOpener(growthRequiresChallenge: true),
    )..addServer('s1');

    await harness.manager.openBrowseChannel('s1', paneTabId: 't');

    final leases = [
      for (var i = 0; i < 4; i++) harness.manager.leaseTransferChannel('s1'),
    ];
    await Future.wait(leases);

    // The 5th lease triggers one growth attempt; the challenge fails it and
    // caps the pool, so the lease queues on transport 1's budget instead.
    var fifthServed = false;
    final fifth = harness.manager
        .leaseTransferChannel('s1')
        .then((_) => fifthServed = true);
    await flushEvents();

    expect(harness.opener.calls, hasLength(2));
    expect(harness.opener.transports, hasLength(1));
    expect(fifthServed, isFalse);

    // Capped for good: releasing and re-leasing never grows again.
    final released = await leases[0];
    await released.release();
    await fifth;

    var sixthServed = false;
    final sixth = harness.manager
        .leaseTransferChannel('s1')
        .then((_) => sixthServed = true);
    await flushEvents();
    expect(sixthServed, isFalse);
    expect(harness.opener.calls, hasLength(2));

    await (await leases[1]).release();
    await sixth;
    expect(harness.opener.calls, hasLength(2));
    expect(harness.opener.transports, hasLength(1));
  });

  test('a changed key hard-blocks the pool; nothing auto-repins', () async {
    final opener = FakeTransportOpener(
      presentedFingerprints: ['SHA256:old', 'SHA256:attacker'],
    );
    final harness = PoolHarness(opener: opener)..addServer('s1');

    // Pre-pin the original key, as an earlier session would have.
    await harness.store.put(HostKey(
      host: 'example.com',
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:old',
      pinnedAt: 0,
    ));

    final states = <ServerConnectionState>[];
    harness.manager.watchServer('s1').listen(states.add);

    await harness.manager.openBrowseChannel('s1', paneTabId: 't');
    expect(harness.opener.calls, hasLength(1));

    // Fill transport 1's transfer budget so the next lease grows — and the
    // growth transport presents a different key.
    final leases = [
      for (var i = 0; i < 4; i++) harness.manager.leaseTransferChannel('s1'),
    ];
    await Future.wait(leases);

    // The 5th lease's growth attempt sees the changed key and blocks.
    await expectLater(
      harness.manager.leaseTransferChannel('s1'),
      throwsA(isA<RemoteFileException>()),
    );
    await flushEvents();

    expect(states.last, ServerConnectionState.blocked);

    // The whole pool is dead: transport closed, channels closed, the id no
    // longer counts as connected.
    expect(harness.opener.transports.single.closed, isTrue);
    expect(harness.channels, isNotEmpty);
    expect(harness.channels.every((channel) => channel.closed), isTrue);
    expect(await harness.manager.connectedServerIds(), isEmpty);

    // No code path auto-repinned (D18): the old pin stands untouched.
    expect(harness.store.pins['example.com:22']!.fingerprintSha256,
        'SHA256:old');

    // Every operation fails while blocked — a decline keeps it blocked, and
    // the retry went through the review prompt (the one clearing path).
    var promptsAfterBlock = 0;
    harness.onHostKey = (_) async {
      promptsAfterBlock++;
      return false;
    };
    await expectLater(
      harness.manager.openBrowseChannel('s1', paneTabId: 't2'),
      throwsA(isA<RemoteFileException>()),
    );
    await flushEvents();
    expect(promptsAfterBlock, 1);
    expect(states.last, ServerConnectionState.blocked);
    expect(harness.store.pins['example.com:22']!.fingerprintSha256,
        'SHA256:old');
  });

  test('accepting the changed key at the prompt re-pins and reconnects',
      () async {
    final opener = FakeTransportOpener(
      presentedFingerprints: ['SHA256:old', 'SHA256:new', 'SHA256:new'],
    );
    final harness = PoolHarness(opener: opener)..addServer('s1');

    await harness.store.put(HostKey(
      host: 'example.com',
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:old',
      pinnedAt: 0,
    ));

    await harness.manager.openBrowseChannel('s1', paneTabId: 't');

    final leases = [
      for (var i = 0; i < 4; i++) harness.manager.leaseTransferChannel('s1'),
    ];
    await Future.wait(leases);

    await expectLater(
      harness.manager.leaseTransferChannel('s1'),
      throwsA(isA<RemoteFileException>()),
    );

    // The user reviews and accepts: the next connect attempt prompts, the
    // approval pins the new key, and the pool comes back.
    harness.onHostKey =
        (decision) async => decision.verdict == HostKeyVerdict.changed;
    final channel =
        await harness.manager.openBrowseChannel('s1', paneTabId: 't2');

    expect(harness.store.pins['example.com:22']!.fingerprintSha256,
        'SHA256:new');
    expect(await harness.manager.connectedServerIds(), {'s1'});
    expect(channel.fs, isNotNull);
  });

  test('a declined first-use key disconnects without pinning', () async {
    final harness = PoolHarness()..addServer('s1');
    var promptCount = 0;
    harness.onHostKey = (_) async {
      promptCount++;
      return false;
    };

    final states = <ServerConnectionState>[];
    harness.manager.watchServer('s1').listen(states.add);

    await expectLater(
      harness.manager.openBrowseChannel('s1', paneTabId: 't'),
      throwsA(isA<SshConnectException>()),
    );
    await flushEvents();

    expect(states.last, ServerConnectionState.disconnected);
    expect(harness.store.pins, isEmpty);
    expect(await harness.manager.connectedServerIds(), isEmpty);

    // A retry prompts again — a decline is not remembered as an answer.
    await expectLater(
      harness.manager.openBrowseChannel('s1', paneTabId: 't'),
      throwsA(isA<SshConnectException>()),
    );
    expect(promptCount, 2);
  });

  test('the first transport follows pane lifetime, not leases', () async {
    final harness = PoolHarness()..addServer('s1');

    final browse = await harness.manager.openBrowseChannel('s1', paneTabId: 't');
    expect(harness.opener.transports.single.closed, isFalse);
    // A lease holds the transport open past the last tab.
    final lease = await harness.manager.leaseTransferChannel('s1');
    await browse.close();
    expect(harness.opener.transports.single.closed, isFalse);

    await lease.release();
    await flushEvents();
    expect(harness.opener.transports.single.closed, isTrue);

    // Pane-lifetime teardown wipes the pool but keeps the session's
    // reference: the next connect reuses it (vault re-resolution on auth
    // failure lands with reconnect, 03 §3.3).
    expect(harness.resolveCalls, 1);
    await harness.manager.openBrowseChannel('s1', paneTabId: 't');
    expect(harness.resolveCalls, 1);
  });

  test('disconnectServer closes the id\'s channels; siblings keep the pool',
      () async {
    final harness = PoolHarness()
      ..addServer('s1')
      ..addServer('s2');

    final s1Browse =
        await harness.manager.openBrowseChannel('s1', paneTabId: 't1');
    final s2Browse =
        await harness.manager.openBrowseChannel('s2', paneTabId: 't2');
    final s1Lease = await harness.manager.leaseTransferChannel('s1');

    await harness.manager.disconnectServer('s1');

    // s1's browse channel and lease are closed; s2 keeps browsing over the
    // shared transport, and no new connect happened.
    expect(harness.channels.where((c) => c.closed), hasLength(2));
    expect(s2Browse.fs, isNotNull);
    expect(harness.opener.calls, hasLength(1));
    expect(await harness.manager.connectedServerIds(), {'s2'});

    await s1Lease.release(); // force-released: a later release is a no-op
    await s1Browse.close();

    // The last reference out tears everything down; the reference went
    // with it, so the next connect re-resolves from the vault (03 §3.5).
    await harness.manager.disconnectServer('s2');
    expect(harness.opener.transports.single.closed, isTrue);
    expect(await harness.manager.connectedServerIds(), isEmpty);

    await harness.manager.openBrowseChannel('s2', paneTabId: 't2');
    expect(harness.resolveCalls, 3);
  });

  test('budget exhaustion shares the LRU browse channel', () async {
    // One transport, two transfer channels, three total: interactive auth
    // (no growth) with both browse slots beyond the first impossible.
    final harness = PoolHarness(
      opener: FakeTransportOpener(authKind: AuthKind.promptedPassword),
      policy: const PoolPolicy(
        maxTransports: 1,
        maxTransferChannelsPerTransport: 2,
        maxChannelsPerTransport: 3,
      ),
    )..addServer('s1');

    final leases = [
      for (var i = 0; i < 2; i++) harness.manager.leaseTransferChannel('s1'),
    ];
    await Future.wait(leases);
    final first = await harness.manager.openBrowseChannel('s1', paneTabId: 't1');

    // The third channel slot is the browse channel; a second tab finds every
    // budget exhausted and shares the LRU (only) browse channel — never a
    // failure, never a hang (03 §3.2 rule 4).
    final second = await harness.manager.openBrowseChannel('s1', paneTabId: 't2');
    expect(second.fs, same(first.fs));
    expect(harness.opener.transports.single.channels, hasLength(3));

    // Sharing is refcounted: one tab closing does not kill the other's view.
    await first.close();
    expect(harness.openChannels, hasLength(3));

    await second.close();
    expect(harness.openChannels, hasLength(2));

    // Release the outstanding transfer leases so nothing dangles past the
    // end of the test.
    for (final lease in leases) {
      await (await lease).release();
    }
  });

  test('a refused channel open falls back to sharing', () async {
    // The server (fake) allows exactly one SFTP channel per transport, and
    // interactive auth caps the pool at that one transport.
    final harness = PoolHarness(
      opener: FakeTransportOpener(
        authKind: AuthKind.keyboardInteractive,
        transportOpenLimit: 1,
      ),
    )..addServer('s1');

    final first = await harness.manager.openBrowseChannel('s1', paneTabId: 't1');
    expect(harness.opener.transports.single.channels, hasLength(1));

    // The second tab's channel open is refused; the pool must not surface
    // the raw failure — it shares the existing browse channel.
    final second = await harness.manager.openBrowseChannel('s1', paneTabId: 't2');
    expect(second.fs, same(first.fs));
    expect(harness.opener.transports.single.channels, hasLength(1));
  });

  test('a released lease parks idle and is stolen before opening new',
      () async {
    final harness = PoolHarness()..addServer('s1');

    // A live browse tab keeps the pool (and its idle channels) alive — an
    // empty pool tears down instead, by design (pane lifetime).
    final keeper = await harness.manager.openBrowseChannel('s1', paneTabId: 'keep');

    final lease = await harness.manager.leaseTransferChannel('s1');
    final leaseFs = lease.fs;
    await lease.release();

    final browse = await harness.manager.openBrowseChannel('s1', paneTabId: 't');
    expect(browse.fs, same(leaseFs));
    expect(harness.opener.transports.single.channels, hasLength(2));
    await keeper.close();
    await browse.close();
  });

  test('a disconnect racing the first connect tears the pool down', () async {
    final harness = PoolHarness()..addServer('s1');
    final gate = Completer<void>();
    harness.resolveGate = gate;

    // The connect parks inside the resolver — the widest window there is
    // (vault read, TOFU prompt, 2FA all sit behind it).
    final opening = harness.manager.openBrowseChannel('s1', paneTabId: 't');
    await flushEvents();

    await harness.manager.disconnectServer('s1');
    gate.complete();

    await expectLater(opening, throwsA(isA<RemoteFileException>()));

    // The transport that landed after the disconnect is closed, not live;
    // no reference, no credentials, nothing connected.
    expect(harness.opener.transports.single.closed, isTrue);
    expect(await harness.manager.connectedServerIds(), isEmpty);
  });

  test('a shared-pool joiner watches as connected', () async {
    final harness = PoolHarness()
      ..addServer('s1')
      ..addServer('s2');

    await harness.manager.openBrowseChannel('s1', paneTabId: 't');

    // s2 joins the already-connected pool: no connect runs, no state event
    // fires for it — the initial watch value must derive from the pool.
    await harness.manager.openBrowseChannel('s2', paneTabId: 't');
    expect(harness.opener.calls, hasLength(1));

    final seen = await harness.manager.watchServer('s2').first;
    expect(seen, ServerConnectionState.connected);
  });

  test('the initial watch value is read at listen time', () async {
    final harness = PoolHarness()..addServer('s1');

    final stream = harness.manager.watchServer('s1');
    await harness.manager.openBrowseChannel('s1', paneTabId: 't');

    final seen = <ServerConnectionState>[];
    stream.listen(seen.add);
    await flushEvents();
    expect(seen.single, ServerConnectionState.connected);
  });

  test('a growth connect that outlives its demand leaves no zombie',
      () async {
    final harness = PoolHarness()..addServer('s1');
    final gate = Completer<void>();
    harness.opener.growthGate = gate;

    final browse = await harness.manager.openBrowseChannel('s1', paneTabId: 't');
    final leases = [
      for (var i = 0; i < 4; i++) harness.manager.leaseTransferChannel('s1'),
    ];
    await Future.wait(leases);

    // The 5th lease triggers a growth connect that parks on the gate.
    final fifth = harness.manager.leaseTransferChannel('s1');
    await flushEvents();

    // Everything releases while the growth connect is in flight: teardown
    // is deferred (the growth guard), so the pool is not torn mid-connect.
    await browse.close();
    for (final lease in leases) {
      await (await lease).release();
    }
    await flushEvents();
    expect(harness.opener.transports.first.closed, isFalse);

    gate.complete();
    final lease = await fifth;

    // The grown transport served its one lease and died with the next
    // teardown trigger — no zombie connection outliving its demand.
    await lease.release();
    await flushEvents();
    expect(harness.opener.transports.last.closed, isTrue);
    expect(harness.opener.transports.first.closed, isTrue);
  });
}
