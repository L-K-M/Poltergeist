import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'engine_host_test.dart' show HostHarness;
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

  test('a first close arriving during the drain is awaited by shutdown',
      () async {
    final rootA = Directory.systemTemp.createTempSync('drain-new-a-');
    addTearDown(() => rootA.deleteSync(recursive: true));
    final backend = GatedWatchBackend();
    final h = HostHarness(localWatch: backend);
    addTearDown(h.dispose);
    final channelA = await h.openLocal(rootA.path);
    await h.call((id) => WatchLocalDirectoryRequest(
      requestId: id, channelId: channelA.channelId, path: channelA.homePath,
    ));
    final gateA = backend.gates[channelA.homePath]!;
    addTearDown(() {
      if (!gateA.isCompleted) gateA.complete();
    });

    // Park the drain on A's tracked retirement: A is closed by request
    // (so the channel loop has nothing to close) and shutdown's drain
    // snapshot holds exactly A.
    final closingA = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channelA.channelId,
    ));
    final shuttingDown = h.call((id) => ShutdownRequest(requestId: id));
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }

    // A channel OPENED during shutdown is not in the channel loop's
    // snapshot, so only its own close request retires it — during the
    // drain, creating an entry after the drain's one-shot snapshot.
    final openedC = await h.call(
      (id) => OpenLocalBrowseChannelRequest(
        requestId: id,
        rootPath: rootA.parent.path,
      ),
    );
    final opened = openedC as BrowseChannelOpened;
    final channelC = opened.channelId;
    final canonicalC = opened.homePath;
    await h.call((id) => WatchLocalDirectoryRequest(
      requestId: id, channelId: channelC, path: canonicalC,
    ));
    final gateC = backend.gates[canonicalC]!;
    addTearDown(() {
      if (!gateC.isCompleted) gateC.complete();
    });
    final closingC = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channelC,
    ));
    var shutdownAcked = false;
    unawaited(shuttingDown.then((_) => shutdownAcked = true));
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
    expect(backend.cancelled, containsAll([channelA.homePath, canonicalC]));

    // A's release completes; C's is still gated. Shutdown must NOT ack
    // over C's in-flight retirement.
    gateA.complete();
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
    expect(shutdownAcked, isFalse,
        reason: 'shutdown acked over a retirement created during the drain');

    gateC.complete();
    expect(await shuttingDown, isA<EngineAck>());
    expect(await closingC, isA<EngineAck>());
    expect(await closingA, isA<EngineAck>());
  });

  test('a channel opened during shutdown is retired before the ack',
      () async {
    final rootA = Directory.systemTemp.createTempSync('drain-open-a-');
    addTearDown(() => rootA.deleteSync(recursive: true));
    final backend = GatedWatchBackend();
    final h = HostHarness(localWatch: backend);
    addTearDown(h.dispose);
    final channelA = await h.openLocal(rootA.path);
    await h.call((id) => WatchLocalDirectoryRequest(
      requestId: id, channelId: channelA.channelId, path: channelA.homePath,
    ));
    final gateA = backend.gates[channelA.homePath]!;

    // Park the drain on A's tracked retirement.
    final closingA = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channelA.channelId,
    ));
    final shuttingDown = h.call((id) => ShutdownRequest(requestId: id));
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }

    // Open and WATCH a channel during the drain, then never close it —
    // no retirement exists for the drain to await, so only the retire
    // loop can keep this watch from outliving the shutdown ack.
    final openedC = await h.call(
      (id) => OpenLocalBrowseChannelRequest(
        requestId: id,
        rootPath: rootA.parent.path,
      ),
    );
    final opened = openedC as BrowseChannelOpened;
    await h.call((id) => WatchLocalDirectoryRequest(
      requestId: id, channelId: opened.channelId, path: opened.homePath,
    ));
    final gateC = backend.gates[opened.homePath]!;
    addTearDown(() {
      if (!gateA.isCompleted) gateA.complete();
      if (!gateC.isCompleted) gateC.complete();
    });

    gateA.complete();
    var shutdownAcked = false;
    unawaited(shuttingDown.then((_) => shutdownAcked = true));
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
    expect(shutdownAcked, isFalse,
        reason: 'shutdown acked while an never-closed channel\'s watch '
            'was still live');

    gateC.complete();
    expect(await shuttingDown, isA<EngineAck>());
    await closingA;
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
