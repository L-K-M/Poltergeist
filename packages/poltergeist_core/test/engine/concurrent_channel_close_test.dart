import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'engine_host_test.dart' show HostHarness, expectError;
import 'watch_supersession_test.dart' show GatedWatchBackend;

void main() {
  test('both close acknowledgements await backend release', () async {
    final root = Directory.systemTemp.createTempSync('concurrent-watch-close-');
    addTearDown(() => root.deleteSync(recursive: true));
    final backend = GatedWatchBackend();
    final h = HostHarness(localWatch: backend);
    addTearDown(h.dispose);
    final channel = await h.openLocal(root.path);
    await h.call((id) => WatchLocalDirectoryRequest(
      requestId: id, channelId: channel.channelId, path: channel.homePath,
    ));
    final gate = backend.gates.values.single;
    addTearDown(() { if (!gate.isCompleted) gate.complete(); });

    // The second request must share pending retirement, not treat removal
    // from the routing map as proof that the backend has finished closing.
    final first = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channel.channelId,
    ));
    final second = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channel.channelId,
    ));
    var secondAcked = false;
    unawaited(second.then((_) => secondAcked = true));
    await pumpEventQueue();
    expect(secondAcked, isFalse,
      reason: 'second close acknowledged before backend cancellation completed');
    gate.complete();
    final acks = await Future.wait([first, second]);
    expect(acks, everyElement(isA<EngineAck>()));
  });

  test('shutdown awaits a channel close still in flight', () async {
    final root = Directory.systemTemp.createTempSync('shutdown-pending-close-');
    addTearDown(() => root.deleteSync(recursive: true));
    final backend = GatedWatchBackend();
    final h = HostHarness(localWatch: backend);
    addTearDown(h.dispose);
    final channel = await h.openLocal(root.path);
    await h.call((id) => WatchLocalDirectoryRequest(
      requestId: id, channelId: channel.channelId, path: channel.homePath,
    ));
    final gate = backend.gates.values.single;
    addTearDown(() { if (!gate.isCompleted) gate.complete(); });

    // The close retires routing immediately; shutdown must not ack over
    // the still-closing channel's backend release.
    final closing = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channel.channelId,
    ));
    final shuttingDown = h.call((id) => ShutdownRequest(requestId: id));
    var shutdownAcked = false;
    unawaited(shuttingDown.then((_) => shutdownAcked = true));
    await pumpEventQueue();
    expect(shutdownAcked, isFalse,
        reason: 'shutdown acknowledged before the in-flight close released');

    gate.complete();
    final results = await Future.wait([closing, shuttingDown]);
    expect(results.first, isA<EngineAck>());
    expect(shutdownAcked, isTrue);
  });

  test('a close racing shutdown cannot corrupt the shutdown loop', () async {
    final rootA = Directory.systemTemp.createTempSync('shutdown-race-a-');
    addTearDown(() => rootA.deleteSync(recursive: true));
    final rootB = Directory.systemTemp.createTempSync('shutdown-race-b-');
    addTearDown(() => rootB.deleteSync(recursive: true));
    final backend = GatedWatchBackend();
    final h = HostHarness(localWatch: backend);
    addTearDown(h.dispose);
    final channelA = await h.openLocal(rootA.path);
    final channelB = await h.openLocal(rootB.path);
    for (final channel in [channelA, channelB]) {
      await h.call((id) => WatchLocalDirectoryRequest(
        requestId: id, channelId: channel.channelId, path: channel.homePath,
      ));
    }
    final gateA = backend.gates[channelA.homePath]!;
    final gateB = backend.gates[channelB.homePath]!;
    addTearDown(() {
      if (!gateA.isCompleted) gateA.complete();
      if (!gateB.isCompleted) gateB.complete();
    });

    final shuttingDown = h.call((id) => ShutdownRequest(requestId: id));
    // Drive the loop until it is parked closing the first channel — the
    // cancellation of A's backend subscription is observable.
    for (var i = 0;
        i < 20 && !backend.cancelled.contains(channelA.homePath);
        i++) {
      await pumpEventQueue();
    }
    expect(backend.cancelled, contains(channelA.homePath));

    // A close for B processed while the loop is parked in A's await
    // mutates the channel map mid-iteration — without the snapshot this
    // is a ConcurrentModificationError that fails shutdown.
    final closingB = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channelB.channelId,
    ));
    // The loop cannot advance while gateA is incomplete, so pumping here
    // guarantees closingB's handler mutates the map INSIDE the loop's
    // iteration — without this the microtask-resumed loop could finish
    // before the close's event delivery lands, and the regression would
    // pass without exercising the snapshot.
    await pumpEventQueue();

    gateA.complete();
    gateB.complete();
    final result = await shuttingDown;
    expect(result, isA<EngineAck>());
    await closingB;
  });

  test('a close racing the retire loop shares the tracked retirement',
      () async {
    final rootA = Directory.systemTemp.createTempSync('drain-race-a-');
    addTearDown(() => rootA.deleteSync(recursive: true));
    final rootB = Directory.systemTemp.createTempSync('drain-race-b-');
    addTearDown(() => rootB.deleteSync(recursive: true));
    final backend = GatedWatchBackend();
    final h = HostHarness(localWatch: backend);
    addTearDown(h.dispose);
    final channelA = await h.openLocal(rootA.path);
    final channelB = await h.openLocal(rootB.path);
    for (final channel in [channelA, channelB]) {
      await h.call((id) => WatchLocalDirectoryRequest(
        requestId: id, channelId: channel.channelId, path: channel.homePath,
      ));
    }
    final gateA = backend.gates[channelA.homePath]!;
    final gateB = backend.gates[channelB.homePath]!;
    // addTearDown runs LIFO: registered after h.dispose so the gates are
    // completed before the harness tears down (which may await the
    // drain).
    addTearDown(() {
      if (!gateA.isCompleted) gateA.complete();
      if (!gateB.isCompleted) gateB.complete();
    });

    // Park the drain on A's tracked retirement (A closed by request, so
    // the retire loop starts empty-handed).
    final closingA = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channelA.channelId,
    ));
    // Probes for all three in-flight futures: a regression that strands
    // or errors any of them fails its checkpoint, not just the final
    // awaits.
    closingA
        .then((_) {}, onError: (Object _) {})
        .ignore();
    final shuttingDown = h.call((id) => ShutdownRequest(requestId: id));
    shuttingDown.ignore();
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }

    // B is pre-existing and still open: its close races the retire loop.
    // Whichever retires it first, the close's ack and the shutdown ack
    // both await the SAME tracked release.
    final closingB = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channelB.channelId,
    ));
    var bAcked = false;
    closingB
        .then((_) => bAcked = true, onError: (_) => bAcked = true)
        .ignore();
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
    expect(backend.cancelled, containsAll([channelA.homePath, channelB.homePath]));

    // A settles first; B's release is still gated — neither B's close nor
    // shutdown may ack over it. The shutdown probe records any completion
    // so an early error ack trips this checkpoint too, not just the
    // final await.
    final shutdownProbe = shuttingDown;
    var shutdownAcked = false;
    shutdownProbe
        .then((_) => shutdownAcked = true,
            onError: (_) => shutdownAcked = true)
        .ignore();
    gateA.complete();
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
    expect(bAcked, isFalse,
        reason: 'close B must await its own backend release');
    expect(shutdownAcked, isFalse,
        reason: 'shutdown must await B\'s backend release');

    gateB.complete();
    expect(await shutdownProbe, isA<EngineAck>());
    expect(await closingB, isA<EngineAck>());
    await closingA;
  });

  test('opens are rejected once the engine is shutting down', () async {
    final root = Directory.systemTemp.createTempSync('shutdown-open-gate-');
    addTearDown(() => root.deleteSync(recursive: true));
    final backend = GatedWatchBackend();
    final h = HostHarness(localWatch: backend);
    addTearDown(h.dispose);
    final channel = await h.openLocal(root.path);
    await h.call((id) => WatchLocalDirectoryRequest(
      requestId: id, channelId: channel.channelId, path: channel.homePath,
    ));
    final gate = backend.gates[channel.homePath]!;
    // addTearDown runs LIFO: registered after h.dispose so the gate is
    // completed before the harness tears down.
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });

    // Park shutdown in the drain; a local open racing it is the only
    // intake that could mint an unretirable channel. The close is fired
    // without awaiting — its ack parks on the gate — and held for
    // consumption below so a regression that strands it fails loudly
    // here rather than as a silent unhandled future.
    final parkedClose = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channel.channelId,
    ));
    parkedClose.ignore();
    final shuttingDown = h.call((id) => ShutdownRequest(requestId: id));
    shuttingDown.ignore();
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }

    final error = await expectError(
      h.call(
        (id) => OpenLocalBrowseChannelRequest(
          requestId: id,
          rootPath: root.path,
        ),
      ),
    );
    expect(error.kind, RemoteFileErrorKind.disconnected);
    expect(error.message, contains('shutting down'));

    gate.complete();
    expect(await shuttingDown, isA<EngineAck>());
    await parkedClose;
  });

  test('a never-settling retirement cannot hang the shutdown ack',
      () async {
    final root = Directory.systemTemp.createTempSync('shutdown-hang-');
    addTearDown(() => root.deleteSync(recursive: true));
    final backend = GatedWatchBackend();
    final h = HostHarness(
      localWatch: backend,
      shutdownDrainTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(h.dispose);
    final channel = await h.openLocal(root.path);
    await h.call((id) => WatchLocalDirectoryRequest(
      requestId: id, channelId: channel.channelId, path: channel.homePath,
    ));
    // The gate is deliberately NEVER completed by the test flow: the
    // backend cancellation never settles within the bound. The LIFO
    // teardown below still releases it so h.dispose cannot hang past the
    // injected bound.
    final gate = backend.gates[channel.homePath]!;
    // addTearDown runs LIFO: registered after h.dispose so the gate is
    // completed before the harness tears down.
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });

    final result = await h
        .call((id) => ShutdownRequest(requestId: id))
        .timeout(const Duration(seconds: 5));
    expect(result, isA<EngineAck>());
    // Prove the drain actually reached the gated cancellation — it
    // entered the await that the bound later abandoned — rather than
    // acking from an empty drain. `cancelled` records entry into
    // cancellation synchronously, so this cannot race the timeout.
    expect(backend.cancelled, contains(channel.homePath),
        reason: 'drain never reached the gated backend cancellation');
  });

  test('an open parked across shutdown resolves rejected, registering nothing',
      () async {
    final root = Directory.systemTemp.createTempSync('open-toctou-');
    addTearDown(() => root.deleteSync(recursive: true));
    final backend = GatedWatchBackend();
    final h = HostHarness(localWatch: backend);
    addTearDown(h.dispose);

    // Deterministic staging: the open dispatches synchronously and parks
    // on its canonicalize I/O (an event-loop turn); the shutdown issued
    // right behind it drains nothing and completes entirely on
    // microtasks — so it always acks before the open resumes. Without the
    // mint-time gate the open then registers a channel no fixed point
    // will ever retire.
    final opening = h.call(
      (id) => OpenLocalBrowseChannelRequest(
        requestId: id,
        rootPath: root.path,
      ),
    );
    expect(
      await h.call((id) => ShutdownRequest(requestId: id)),
      isA<EngineAck>(),
    );

    final error = await expectError(opening);
    expect(error.kind, RemoteFileErrorKind.disconnected);
    expect(error.message, contains('shutting down'));
    expect(backend.cancelled, isEmpty,
        reason: 'nothing was ever watched on the aborted open');
  });

  test('closing a fully retired channel stays idempotent', () async {
    final root = Directory.systemTemp.createTempSync('retired-close-');
    addTearDown(() => root.deleteSync(recursive: true));
    final backend = GatedWatchBackend();
    final h = HostHarness(localWatch: backend);
    addTearDown(h.dispose);
    final channel = await h.openLocal(root.path);
    await h.call((id) => WatchLocalDirectoryRequest(
      requestId: id, channelId: channel.channelId, path: channel.homePath,
    ));
    final gate = backend.gates.values.single;
    gate.complete();

    await h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channel.channelId,
    ));

    // Retirement completed long ago: a later close acks immediately with
    // no pending entry to wait and no error.
    final result = await h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channel.channelId,
    ));
    expect(result, isA<EngineAck>());
  });
}
