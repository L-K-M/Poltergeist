import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'engine_host_test.dart' show HostHarness;
import 'watch_supersession_test.dart' show GatedWatchBackend;

void main() {
  test('duplicate close during shutdown drain awaits backend release', () async {
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
    // addTearDown runs LIFO: this must remain the LAST registration so the
    // gate is released before h.dispose (which may await the drain) and
    // before the temp directory is deleted.
    addTearDown(() { if (!gate.isCompleted) gate.complete(); });

    // The second request must share pending retirement, not treat removal
    // from the routing map as proof that the backend has finished closing.
    final first = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channel.channelId,
    ));
    final shuttingDown = h.call((id) => ShutdownRequest(requestId: id));
    shuttingDown.ignore();
    // Match the sibling suite's park-the-drain strength (its for-loop
    // idiom) so the "during the drain" precondition is equally
    // deterministic here.
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
    final second = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channel.channelId,
    ));
    var firstAcked = false;
    var secondAcked = false;
    first
        .then((_) => firstAcked = true, onError: (_) => firstAcked = true)
        .ignore();
    // Records any completion — success or error — so a wrongly-early
    // error ack trips the checkpoint too, not just a late Future.wait.
    second
        .then((_) => secondAcked = true, onError: (_) => secondAcked = true)
        .ignore();
    await pumpEventQueue();
    // Precondition check: the drain really is parked at the backend gate
    // (the first close reached the backend — not merely that its ack
    // hasn't arrived — and is held until release); otherwise the
    // second-close assertion below could pass merely because nothing was
    // dispatched yet.
    expect(backend.cancelled, contains(channel.homePath),
      reason: 'first close never reached the backend gate');
    expect(firstAcked, isFalse,
      reason: 'drain not parked at the backend gate; precondition unmet');
    expect(secondAcked, isFalse,
      reason: 'second close acknowledged before backend cancellation completed');
    gate.complete();
    final acks = await Future.wait([first, second, shuttingDown]);
    expect(acks, everyElement(isA<EngineAck>()));
  });
}
