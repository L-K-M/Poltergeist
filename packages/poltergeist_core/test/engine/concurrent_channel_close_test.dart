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
    await Future.wait([first, second]);
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
    await Future.wait([closing, shuttingDown]);
    expect(shutdownAcked, isTrue);
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
