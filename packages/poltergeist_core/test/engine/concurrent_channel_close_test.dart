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

    gateA.complete();
    gateB.complete();
    final result = await shuttingDown;
    expect(result, isA<EngineAck>());
    await closingB;
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
