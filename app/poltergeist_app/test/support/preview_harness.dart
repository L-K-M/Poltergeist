import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/preview_session.dart';
import 'package:poltergeist_app/services/quick_look_channel.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../services/pane_controller_test.dart' as ctl;
import 'test_panes.dart';

/// Shared fixture for the preview suites (06 §5): a real [PreviewCache]
/// in a temp dir, scripted pane lanes, a recording producer, and a
/// fake Quick Look channel — everything [PreviewSession] touches.
///
/// NOTE: `cache.prepare`/`commit` run real file I/O and a chmod
/// subprocess, so callers wait with [previewSettle]/[untilPhase]/
/// [untilTrue] (real delays), never `Duration.zero` flushes.

RemoteFileEntry previewEntry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
  DateTime? modified,
  String parent = '/srv/home',
}) {
  return RemoteFileEntry(
    path: '$parent/$name',
    name: name,
    type: type,
    size: size,
    modifiedAt: modified,
  );
}

Bookmark previewRemoteBookmark() {
  final now = DateTime.utc(2026, 9, 12);
  return Bookmark(
    id: 'srv-1',
    kind: BookmarkKind.remotePath,
    label: 'web.example.com',
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 22,
        username: 'tester',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/srv/home',
    sortKey: 'k',
    createdAt: now,
    updatedAt: now,
  );
}

/// The session-facing producer double: records every spec, answers
/// through held completers, and writes real bytes into the cache slot's
/// temp file so the session's commit step exercises the cache for real.
final class FakePreviewProducer implements PreviewProducer {
  final specs = <PreviewProduceSpec>[];
  final cancels = <String>[];
  final _completers = <String, Completer<RemoteFileEntry>>{};
  int _next = 0;

  @override
  PreviewProduceTicket start(PreviewProduceSpec spec) {
    specs.add(spec);
    final id = 'produce-${_next++}';
    final completer = Completer<RemoteFileEntry>();
    _completers[id] = completer;
    return PreviewProduceTicket(taskId: id, result: completer.future);
  }

  @override
  void cancel(String taskId) {
    cancels.add(taskId);
    _completers[taskId]?.completeError(
      const RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: 'preview produce',
        message: 'cancelled',
      ),
    );
  }

  /// Feeds one progress tick into spec [index]'s onProgress callback.
  void progress(int index, int transferred, [int? total]) {
    specs[index].onProgress?.call(transferred, total);
  }

  /// Writes [bytes] to the spec's destination (the slot's temp file)
  /// and completes the ticket — the session's `slot.commit` then lands
  /// the bytes under the cache key.
  Future<void> complete(int index, List<int> bytes) async {
    final spec = specs[index];
    await File(spec.destinationPath).writeAsBytes(bytes, flush: true);
    _completers['produce-$index']!.complete(
      RemoteFileEntry(
        path: spec.remotePath,
        name: spec.remotePath.split('/').last,
        type: RemoteFileType.file,
        size: bytes.length,
      ),
    );
  }

  /// Fails spec [index]'s ticket.
  void fail(int index, Object error) {
    _completers['produce-$index']!.completeError(error);
  }
}

final class FakeQuickLookChannel implements QuickLookChannel {
  bool available = false;
  bool visible = false;
  final shows = <(List<String>, int)>[];
  final updates = <(List<String>, int)>[];
  int hideCalls = 0;
  final _closed = StreamController<void>.broadcast();

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> showPreview(List<String> paths, int index) async {
    shows.add((paths, index));
    visible = true;
  }

  @override
  Future<void> updatePreview(List<String> paths, int index) async {
    updates.add((paths, index));
  }

  @override
  Future<void> hidePreview() async {
    hideCalls++;
    if (visible) {
      visible = false;
      _closed.add(null);
    }
  }

  @override
  Future<bool> isVisible() async => visible;

  @override
  Stream<void> get onClosed => _closed.stream;

  /// The native panel closing itself (its own Esc / ✕ / focus loss).
  void emitClosed() {
    visible = false;
    _closed.add(null);
  }
}

final class PreviewHarness {
  late final Directory tempDir;
  late final PreviewCache cache;
  late final ctl.FakePaneLanes lanes;
  late final PaneController left;
  late final PaneController right;
  late final WorkspaceController workspace;
  final producer = FakePreviewProducer();
  final quickLook = FakeQuickLookChannel();
  late final PreviewSession session;

  static Future<PreviewHarness> create({
    bool withProducer = true,
    bool quickLookAvailable = false,
    TargetPlatform platform = TargetPlatform.linux,
    int thresholdBytes = 4096,
    int cacheCapacityBytes = 1 << 20,
  }) async {
    final h = PreviewHarness();
    h.tempDir = Directory.systemTemp.createTempSync('preview_test');
    h.cache = PreviewCache(
      directory: h.tempDir,
      capacityBytes: cacheCapacityBytes,
    );
    await h.cache.open();
    h.lanes = ctl.FakePaneLanes();
    h.left = PaneController(paneTabId: 'pane.left', lanes: h.lanes);
    h.right = PaneController(paneTabId: 'pane.right', lanes: h.lanes);
    h.workspace = WorkspaceController(
      left: testPaneStrip(h.left, lanes: h.lanes),
      right: testPaneStrip(h.right, lanes: h.lanes),
    );
    h.quickLook.available = quickLookAvailable;
    h.session = PreviewSession(
      workspace: h.workspace,
      cache: h.cache,
      largeDownloadThresholdBytes: () => thresholdBytes,
      producer: withProducer ? h.producer : null,
      quickLook: h.quickLook,
      platform: platform,
    );
    // Drain in-flight production continuations before disposing — a
    // late _setPhase on a disposed session throws, and deleting the
    // cache dir under a pending prepare breaks its temp create. The
    // dir's teardown runs last for the same reason.
    addTearDown(() async {
      await previewSettle();
      h.session.dispose();
      h.workspace.dispose();
      if (h.tempDir.existsSync()) {
        h.tempDir.deleteSync(recursive: true);
      }
    });
    return h;
  }

  /// Binds the left pane to a scripted remote listing and lands the
  /// cursor on row [cursor].
  Future<ctl.FakePaneChannel> connectRemote(
    List<RemoteFileEntry> entries, {
    int cursor = 0,
  }) async {
    final channel = ctl.FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = entries;
    lanes.nextRemoteChannel = channel;
    await left.connectRemote(previewRemoteBookmark());
    await previewSettle();
    if (cursor >= 0) left.setCursorIndex(cursor);
    await previewSettle();
    return channel;
  }

  /// Binds the left pane to a scripted local listing of [dir].
  Future<ctl.FakePaneChannel> connectLocal(
    Directory dir,
    List<RemoteFileEntry> entries, {
    int cursor = 0,
  }) async {
    final channel = ctl.FakePaneChannel(dir.path);
    channel.listings[dir.path] = entries;
    lanes.nextLocalChannel = channel;
    await left.openLocalAt(dir.path);
    await previewSettle();
    if (cursor >= 0) left.setCursorIndex(cursor);
    await previewSettle();
    return channel;
  }
}

/// Real-async settle: `cache.prepare`/`commit` run a chmod subprocess
/// and real file I/O, so a zero-duration flush is not enough.
Future<void> previewSettle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

/// Polls until the session reaches [phase] (production, lookup, and
/// commit chains span several real-async hops — the chmod subprocess in
/// prepare/commit stretches past a second under full-suite load).
Future<void> untilPhase(PreviewSession session, PreviewPhase phase) async {
  for (var i = 0; i < 800 && session.phase != phase; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Polls an arbitrary predicate — for the Quick Look card/visibility
/// state that isn't a [PreviewPhase].
Future<void> untilTrue(bool Function() test) async {
  for (var i = 0; i < 800 && !test(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A sink tests push gated bytes into without a real download —
/// admission pays the [PreviewByteGate] threshold check.
final class NullByteSink implements StreamSink<List<int>> {
  const NullByteSink();

  @override
  void add(List<int> event) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();
}
