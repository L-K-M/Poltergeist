import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'engine_host_test.dart' show HostHarness;
import 'watch_supersession_test.dart' show GatedWatchBackend;

const _closeBound = Duration(milliseconds: 200);
const _testDeadline = Duration(seconds: 3);

void main() {
  test('non-shutdown close timeout reports failure, not completed release',
      () async {
    final root = Directory.systemTemp.createTempSync('close-timeout-result-');
    addTearDown(() => root.deleteSync(recursive: true));
    final backend = GatedWatchBackend();
    final host = HostHarness(
      localWatch: backend,
      shutdownDrainTimeout: _closeBound,
    );
    addTearDown(host.dispose);
    final channel = await host.openLocal(root.path);
    await host.call((id) => WatchLocalDirectoryRequest(
          requestId: id,
          channelId: channel.channelId,
          path: channel.homePath,
        ));
    final release = backend.gates.values.single;
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });

    // A live engine cannot treat a deadline as successful resource release.
    final closing = host.call((id) => CloseBrowseChannelRequest(
          requestId: id,
          channelId: channel.channelId,
        ));
    final duplicate = host.call((id) => CloseBrowseChannelRequest(
          requestId: id,
          channelId: channel.channelId,
        ));
    final results = await Future.wait([closing, duplicate]).timeout(_testDeadline);
    expect(backend.cancelled, contains(channel.homePath));
    expect(release.isCompleted, isFalse);
    final stillLive = await host.openLocal(root.path);
    expect(stillLive, isA<BrowseChannelOpened>());
    expect(results, everyElement(isA<EngineError>()),
        reason: 'timed-out backend release returned success while the engine '
            'and unreleased resource remain live');
  });
}
