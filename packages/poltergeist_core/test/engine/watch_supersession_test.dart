import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_core/src/engine/local_directory_watcher.dart'
    show LocalWatchBackend;
import 'package:test/test.dart';

import 'engine_host_test.dart' show FakeWatchBackend, HostHarness;

/// A watch backend whose cancellations park on a caller-held gate, so
/// release-completion ordering is driven by explicit delayed completion,
/// never by timing. `Stream.multi` is dart:io's watch-stream shape — the
/// one whose subscription cancel actually gates on `onCancel`'s future
/// (a broadcast controller's cancel completes regardless).
class GatedWatchBackend implements LocalWatchBackend {
  final gates = <String, Completer<void>>{};
  final cancelled = <String>[];

  @override
  Stream<FileSystemEvent> watch(String directory) {
    // A fresh gate per watch call: a repeated path must not inherit an
    // already-completed gate and silently lose its cancellation gating.
    final gate = gates[directory] = Completer<void>();
    return Stream<FileSystemEvent>.multi((controller) {
      controller.onCancel = () {
        cancelled.add(directory);
        return gate.future;
      };
    });
  }
}

Directory _fixture(String name) {
  final root = Directory.systemTemp.createTempSync(name);
  addTearDown(() => root.deleteSync(recursive: true));
  return root;
}

void main() {
  test('unwatch supersedes an in-flight watch validation', () async {
    final root = Directory.systemTemp.createTempSync('watch-unwatch-race-');
    addTearDown(() => root.deleteSync(recursive: true));
    final backend = FakeWatchBackend();
    final harness = HostHarness(localWatch: backend);
    addTearDown(harness.dispose);
    final channel = await harness.openLocal(root.path);

    // Both requests enter before validation resumes; the later stop must win.
    final watching = harness.call((id) => WatchLocalDirectoryRequest(
      requestId: id, channelId: channel.channelId, path: root.path,
    ));
    final stopping = harness.call((id) => UnwatchLocalDirectoryRequest(
      requestId: id, channelId: channel.channelId,
    ));
    await stopping;
    await watching;

    expect(backend.controllers.values.any((c) => c.hasListener), isFalse,
      reason: 'an acknowledged unwatch must not be undone by older validation');
  });

  test('a superseded watch answers the typed cancelled refusal', () async {
    final root = _fixture('watch-superseded-typed-');
    final backend = FakeWatchBackend();
    final harness = HostHarness(localWatch: backend);
    addTearDown(harness.dispose);
    final channel = await harness.openLocal(root.path);

    final watching = harness.call(
      (id) => WatchLocalDirectoryRequest(
        requestId: id,
        channelId: channel.channelId,
        path: channel.homePath,
      ),
    );
    final stopping = harness.call(
      (id) => UnwatchLocalDirectoryRequest(
        requestId: id,
        channelId: channel.channelId,
      ),
    );
    await stopping;
    final result = await watching;

    // The stale ack must not imply a watch: it answers cancelled, and no
    // backend was ever touched.
    expect(result, isA<EngineError>());
    final error = result as EngineError;
    expect(error.kind, RemoteFileErrorKind.cancelled);
    expect(error.operation, 'watch');
    expect(backend.controllers, isEmpty);
  });

  test('a later watch supersedes an older in-flight validation', () async {
    final root = _fixture('watch-reorder-');
    final sub = Directory('${root.path}/sub')..createSync();

    final backend = FakeWatchBackend();
    final harness = HostHarness(localWatch: backend);
    addTearDown(harness.dispose);
    final channel = await harness.openLocal(root.path);
    final subCanonical = await LocalFileSystem().canonicalize(sub.path);

    // Both validations are in flight; whichever I/O completes first, only
    // the NEWER request may install — the older must answer cancelled.
    final older = harness.call(
      (id) => WatchLocalDirectoryRequest(
        requestId: id,
        channelId: channel.channelId,
        path: channel.homePath,
      ),
    );
    final newer = harness.call(
      (id) => WatchLocalDirectoryRequest(
        requestId: id,
        channelId: channel.channelId,
        path: sub.path,
      ),
    );

    expect(await newer, isA<EngineAck>());
    final olderResult = await older;
    expect(olderResult, isA<EngineError>());
    expect((olderResult as EngineError).kind, RemoteFileErrorKind.cancelled);

    // Exactly the newer target is watched.
    expect(backend.controllers.keys, [subCanonical]);
  });

  test('shutdown superseding a validating watch answers disconnected',
      () async {
    final root = _fixture('watch-shutdown-race-');
    final backend = FakeWatchBackend();
    final harness = HostHarness(localWatch: backend);
    addTearDown(harness.dispose);
    final channel = await harness.openLocal(root.path);

    final watching = harness.call(
      (id) => WatchLocalDirectoryRequest(
        requestId: id,
        channelId: channel.channelId,
        path: channel.homePath,
      ),
    );
    await harness.call((id) => ShutdownRequest(requestId: id));

    final result = await watching;
    expect(result, isA<EngineError>());
    expect((result as EngineError).kind, RemoteFileErrorKind.disconnected);
    expect(backend.controllers, isEmpty);
  });

  test('an unwatch ack means the backend cancellation completed', () async {
    final root = _fixture('watch-gated-unwatch-');
    final backend = GatedWatchBackend();
    final harness = HostHarness(localWatch: backend);
    addTearDown(harness.dispose);
    final channel = await harness.openLocal(root.path);

    await harness.call(
      (id) => WatchLocalDirectoryRequest(
        requestId: id,
        channelId: channel.channelId,
        path: channel.homePath,
      ),
    );
    // The backend registration is synchronous under listen; the gate exists
    // by the time the watch acked. Completed on teardown if a failing
    // assertion skips the happy path, so a parked release cannot outlive
    // the test.
    final gate = backend.gates[channel.homePath]!;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });

    final stopping = harness.call(
      (id) => UnwatchLocalDirectoryRequest(
        requestId: id,
        channelId: channel.channelId,
      ),
    );
    // The cancellation is parked on the gate: the ack must not arrive.
    var acknowledged = false;
    unawaited(stopping.then((_) => acknowledged = true));
    // Deterministic: a wrongly-immediate ack completes within the pumped
    // event-loop turns; no wall-clock sleep.
    await pumpEventQueue();
    expect(acknowledged, isFalse,
        reason: 'the unwatch ack must wait out the backend cancellation');
    expect(backend.cancelled, [channel.homePath]);

    gate.complete();
    await stopping;
    expect(acknowledged, isTrue);
  });
}
