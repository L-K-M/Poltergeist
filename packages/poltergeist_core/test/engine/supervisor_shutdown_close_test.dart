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
    addTearDown(() { if (!gate.isCompleted) gate.complete(); });

    // The second request must share pending retirement, not treat removal
    // from the routing map as proof that the backend has finished closing.
    final first = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channel.channelId,
    ));
    final shuttingDown = h.call((id) => ShutdownRequest(requestId: id));
    await pumpEventQueue();
    final second = h.call((id) => CloseBrowseChannelRequest(
      requestId: id, channelId: channel.channelId,
    ));
    var secondAcked = false;
    unawaited(second.then((_) => secondAcked = true));
    await pumpEventQueue();
    expect(secondAcked, isFalse,
      reason: 'second close acknowledged before backend cancellation completed');
    gate.complete();
    final acks = await Future.wait([first, second, shuttingDown]);
    expect(acks, everyElement(isA<EngineAck>()));
  });
}
