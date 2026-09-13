import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/src/engine/local_directory_watcher.dart';
import 'package:poltergeist_core/src/engine/protocol.dart'
    show DirectoryWatchSignal;
import 'package:poltergeist_core/src/engine/windows_root_watch_backend.dart';
import 'package:test/test.dart';

const _watched = '/w';
const _parent = '/';
const _sibling = '/sib';

FileSystemCreateEvent _create(String path) =>
    FileSystemCreateEvent(path, false);
FileSystemDeleteEvent _delete(String path) =>
    FileSystemDeleteEvent(path, false);
FileSystemModifyEvent _modify(String path) =>
    FileSystemModifyEvent(path, false, true);
FileSystemMoveEvent _move(String from, String to) =>
    FileSystemMoveEvent(from, false, to);

/// One `Stream.multi` controller per watched path — the shape dart:io's
/// `Directory.watch` returns, whose cancel future is the one release
/// contract that matters. Per-path cancel gates let tests hold releases
/// open deterministically.
class _ScriptedBackend implements LocalWatchBackend {
  final controllers = <String, StreamController<FileSystemEvent>>{};
  final cancels = <String>[];
  final gates = <String, Completer<void>>{};
  String? throwOn;

  @override
  Stream<FileSystemEvent> watch(String directory) {
    final refused = throwOn;
    if (refused != null && refused == directory) {
      throw const FileSystemException('backend refused', 'watch');
    }
    final stream = Stream<FileSystemEvent>.multi((multi) {
      controllers[directory] = multi;      multi.onCancel = () {
        cancels.add(directory);
        return gates[directory]?.future;
      };
    });
    return stream;
  }

  void emit(String directory, FileSystemEvent event) =>
      controllers[directory]?.add(event);

  /// Arms a cancel gate for [directory] — call before cancelling, or the
  /// release completes immediately.
  Completer<void> armGate(String directory) =>
      gates[directory] ??= Completer<void>();

  void completeCancel(String directory) => gates[directory]!.complete();

  void failCancel(String directory, Object error) =>
      gates[directory]!.completeError(error);
}

void main() {
  test('target events are relayed untouched', () async {
    final backend = _ScriptedBackend();
    final merged = WindowsRootWatchBackend(raw: backend).watch(_watched);

    final events = <FileSystemEvent>[];
    final subscription = merged.listen(events.add);
    await pumpEventQueue();
    backend.emit(_watched, _create('$_watched/a.txt'));
    await pumpEventQueue();

    expect(events, hasLength(1));
    expect(events.single.path, '$_watched/a.txt');

    await subscription.cancel();
  });

  test('a parent delete naming the target becomes the root-loss shape',
      () async {
    final backend = _ScriptedBackend();
    final merged = WindowsRootWatchBackend(raw: backend).watch(_watched);

    final events = <FileSystemEvent>[];
    final subscription = merged.listen(events.add);
    await pumpEventQueue();
    backend.emit(_parent, _delete(_watched));
    await pumpEventQueue();

    expect(events, hasLength(1));
    expect(events.single, isA<FileSystemDeleteEvent>());
    expect(events.single.path, _watched);

    await subscription.cancel();
  });

  test('a parent move whose source is the target becomes the loss shape',
      () async {
    final backend = _ScriptedBackend();
    final merged = WindowsRootWatchBackend(raw: backend).watch(_watched);

    final events = <FileSystemEvent>[];
    final subscription = merged.listen(events.add);
    await pumpEventQueue();
    backend.emit(_parent, _move(_watched, '$_parent/moved'));
    await pumpEventQueue();

    expect(events, hasLength(1));
    expect(events.single, isA<FileSystemDeleteEvent>());
    expect(events.single.path, _watched);

    await subscription.cancel();
  });

  test('parent events for siblings, descendants, and target churn drop',
      () async {
    final backend = _ScriptedBackend();
    final merged = WindowsRootWatchBackend(raw: backend).watch(_watched);

    final events = <FileSystemEvent>[];
    final subscription = merged.listen(events.add);
    await pumpEventQueue();
    // A sibling's whole life cycle must never reach the merge.
    backend.emit(_parent, _create(_sibling));
    backend.emit(_parent, _modify(_sibling));
    backend.emit(_parent, _delete(_sibling));
    // A descendant shares the watched name as a prefix, not the name.
    backend.emit(_parent, _delete('$_watched/sub/x'));
    // A move INTO the target's name is not a loss of the target: the
    // filter keys on the source path.
    backend.emit(_parent, _move(_sibling, _watched));
    // Target create/modify are the target watch's business.
    backend.emit(_parent, _create(_watched));
    backend.emit(_parent, _modify(_watched));
    await pumpEventQueue();

    expect(events, isEmpty);

    await subscription.cancel();
  });

  test('a parent error crosses as a stream error', () async {
    final backend = _ScriptedBackend();
    final merged = WindowsRootWatchBackend(raw: backend).watch(_watched);

    final errors = <Object>[];
    final subscription = merged.listen(
      (_) {},
      onError: errors.add,
    );
    await pumpEventQueue();
    backend.emit(_parent, _create(_sibling));
    backend
        .controllers[_parent]!
        .addError(const FileSystemException('parent died', _parent));
    await pumpEventQueue();

    expect(errors, hasLength(1));
    expect(errors.single, isA<FileSystemException>());

    await subscription.cancel();
  });

  test('a parent close ends the stream and releases both watches', () async {
    final backend = _ScriptedBackend();
    final merged = WindowsRootWatchBackend(raw: backend).watch(_watched);

    final done = Completer<void>();
    merged.listen((_) {}, onDone: done.complete);
    await pumpEventQueue();
    unawaited(backend.controllers[_parent]!.close());
    await done.future;

    // Delivery order of the implicit cancel-after-done and the explicit
    // releases is the SDK's business; the contract is that BOTH watches
    // end up released.
    expect(backend.cancels, containsAll([_watched, _parent]));
  });

  test('a parent watch refused at subscribe releases the target watch',
      () async {
    final backend = _ScriptedBackend()..throwOn = _parent;
    final merged = WindowsRootWatchBackend(raw: backend).watch(_watched);

    // The synchronous refusal surfaces as the stream's error (fail loud,
    // never a silent target-only watch), and the acquired target watch is
    // released before it does.
    final errors = <Object>[];
    final done = Completer<void>();
    merged.listen((_) {}, onError: errors.add, onDone: done.complete);

    await done.future;
    expect(errors, hasLength(1));
    expect(errors.single, isA<FileSystemException>());
    expect(backend.cancels, [_watched]);
  });

  test('paths without a parent watch only the target', () async {
    final backend = _ScriptedBackend();
    final backend2 = _ScriptedBackend();
    final volumeRoot = WindowsRootWatchBackend(raw: backend).watch('/');
    final relative = WindowsRootWatchBackend(raw: backend2)
        .watch('relative/dir');

    final first = volumeRoot.listen((_) {});
    final second = relative.listen((_) {});
    await pumpEventQueue();

    expect(backend.controllers.keys, ['/']);
    expect(backend2.controllers.keys, ['relative/dir']);

    await first.cancel();
    await second.cancel();
    expect(backend.cancels, ['/']);
    expect(backend2.cancels, ['relative/dir']);
  });

  test('release completes only when BOTH cancellations complete', () async {
    final backend = _ScriptedBackend();
    final merged = WindowsRootWatchBackend(raw: backend).watch(_watched);

    final subscription = merged.listen((_) {});
    await pumpEventQueue();

    backend.armGate(_watched);
    backend.armGate(_parent);
    final cancelled = subscription.cancel();
    var completed = false;
    unawaited(cancelled.then((_) => completed = true));
    await pumpEventQueue();
    expect(backend.cancels, [_watched, _parent],
        reason: 'both cancellations are issued up front');
    expect(completed, isFalse);

    backend.completeCancel(_watched);
    await pumpEventQueue();
    expect(completed, isFalse,
        reason: 'one released link must not ack for the other');

    backend.completeCancel(_parent);
    await cancelled;
    expect(completed, isTrue);
  });

  test('a failing cancellation does not skip its sibling', () async {
    final backend = _ScriptedBackend();
    final merged = WindowsRootWatchBackend(raw: backend).watch(_watched);

    final subscription = merged.listen((_) {});
    await pumpEventQueue();

    backend.armGate(_watched);
    backend.armGate(_parent);
    final cancelled = subscription.cancel();
    backend.failCancel(_watched, const FileSystemException('release failed'));
    await pumpEventQueue();
    backend.completeCancel(_parent);

    // The error is contained; the acknowledged release still waited out
    // both links.
    await cancelled;
    expect(backend.cancels, [_watched, _parent]);
  });

  test('release during partial setup cannot be double-issued', () async {
    final backend = _ScriptedBackend();
    final merged = WindowsRootWatchBackend(raw: backend).watch(_watched);

    final subscription = merged.listen((_) {});
    await pumpEventQueue();
    // A parent close racing the watcher's own release: whichever runs
    // release() first nulls the subscriptions, and the second call stays
    // a no-op — no double cancel, no late crash.
    unawaited(backend.controllers[_parent]!.close());
    await pumpEventQueue();
    final afterLoss = List.of(backend.cancels);
    expect(afterLoss, containsAll([_watched, _parent]));
    await subscription.cancel();
    await pumpEventQueue();

    // The explicit cancel issues nothing new: the end-of-stream release
    // already nulled both subscriptions.
    expect(backend.cancels, afterLoss);
  });

  test('a parent delete signals lost immediately, cancelling the debounce',
      () {
    fakeAsync((async) {
      final backend = _ScriptedBackend();
      final watcher = LocalDirectoryWatcher(
        backend: WindowsRootWatchBackend(raw: backend),
      );

      final signals = <LocalWatchSignal>[];
      watcher.signals.listen(signals.add);
      watcher.retarget(_watched);
      async.flushMicrotasks();

      // A pending ordinary change must not survive the loss.
      backend.emit(_watched, _create('$_watched/a.txt'));
      async.flushMicrotasks();
      backend.emit(_parent, _delete(_watched));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));

      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.lost);
      expect(signals.single.path, _watched);
      expect(signals.single.detail, isNotNull);
      expect(backend.cancels, [_watched, _parent]);

      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('a parent rename-away signals lost; a replacement stays silent', () {
    fakeAsync((async) {
      final backend = _ScriptedBackend();
      final watcher = LocalDirectoryWatcher(
        backend: WindowsRootWatchBackend(raw: backend),
      );

      final signals = <LocalWatchSignal>[];
      watcher.signals.listen(signals.add);
      watcher.retarget(_watched);
      async.flushMicrotasks();

      backend.emit(_parent, _move(_watched, '$_parent/moved'));
      async.flushMicrotasks();
      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.lost);

      // The same-name replacement racing after the loss is noise: the
      // released watch must not re-arm anything.
      backend.emit(_parent, _create(_watched));
      backend.emit(_parent, _delete(_watched));
      async.elapse(const Duration(seconds: 5));
      expect(signals, hasLength(1));

      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('sibling noise on the parent never signals', () {
    fakeAsync((async) {
      final backend = _ScriptedBackend();
      final watcher = LocalDirectoryWatcher(
        backend: WindowsRootWatchBackend(raw: backend),
      );

      final signals = <LocalWatchSignal>[];
      watcher.signals.listen(signals.add);
      watcher.retarget(_watched);
      async.flushMicrotasks();

      backend.emit(_parent, _create(_sibling));
      backend.emit(_parent, _delete(_sibling));
      async.elapse(const Duration(seconds: 5));

      expect(signals, isEmpty);

      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });

  test('an explicit stop releases both watches in issue order', () {
    fakeAsync((async) {
      final backend = _ScriptedBackend();
      final watcher = LocalDirectoryWatcher(
        backend: WindowsRootWatchBackend(raw: backend),
      );

      final signals = <LocalWatchSignal>[];
      watcher.signals.listen(signals.add);
      watcher.retarget(_watched);
      async.flushMicrotasks();

      final stopped = watcher.stop();
      async.flushMicrotasks();
      expect(backend.cancels, [_watched, _parent]);

      unawaited(stopped);
      unawaited(watcher.dispose());
      async.flushMicrotasks();
    });
  });
}
