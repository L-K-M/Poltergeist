import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/src/engine/local_directory_watcher.dart';
import 'package:poltergeist_core/src/engine/protocol.dart'
    show DirectoryWatchSignal;
import 'package:test/test.dart';

/// A scriptable injected backend: one controller per watched path, plus a
/// record of cancel events so release assertions can observe teardown.
class FakeBackend implements LocalWatchBackend {
  final controllers = <String, StreamController<FileSystemEvent>>{};
  final cancelled = <String>[];
  final threw = <String>[];
  String? throwOn;

  @override
  Stream<FileSystemEvent> watch(String directory) {
    if (directory == throwOn) {
      threw.add(directory);
      throw const FileSystemException('backend refused', 'watch');
    }
    return (controllers[directory] ??=
            StreamController<FileSystemEvent>.broadcast(onCancel: () {
              cancelled.add(directory);
            }))
        .stream;
  }

  void emit(String directory, FileSystemEvent event) =>
      controllers[directory]?.add(event);
}

const _root = '/watched';
const _other = '/other';

FileSystemCreateEvent _create(String path) =>
    FileSystemCreateEvent(path, false);
FileSystemDeleteEvent _delete(String path) =>
    FileSystemDeleteEvent(path, false);
FileSystemModifyEvent _modify(String path) =>
    FileSystemModifyEvent(path, false, true);
FileSystemMoveEvent _move(String from, String to) =>
    FileSystemMoveEvent(from, false, to);

/// Starts [watcher] on [path] and collects its signals synchronously.
List<LocalWatchSignal> collect(
  FakeAsync async,
  LocalDirectoryWatcher watcher,
  String path,
) {
  final signals = <LocalWatchSignal>[];
  watcher.signals.listen(signals.add);
  watcher.retarget(path);
  async.flushMicrotasks();
  return signals;
}

/// Tears the watcher down inside the fake zone, where its operation chain
/// can still run: a dispose left to addTearDown would await forever — the
/// chain's pending microtasks never advance once the zone is gone.
void finish(FakeAsync async, LocalDirectoryWatcher watcher) {
  unawaited(watcher.dispose());
  async.flushMicrotasks();
}

/// One fixed stream for every watched path — for tests that gate the
/// single subscription's cancellation.
class _SingleStreamBackend implements LocalWatchBackend {
  _SingleStreamBackend(this._stream);

  final Stream<FileSystemEvent> _stream;

  @override
  Stream<FileSystemEvent> watch(String directory) => _stream;
}

/// One `Stream.multi` per path; the first path's cancellation parks on a
/// caller-held gate, later paths release immediately.
class _GatedFirstPathBackend implements LocalWatchBackend {
  _GatedFirstPathBackend(this._gatedPath);

  final String _gatedPath;
  final gate = Completer<void>();

  @override
  Stream<FileSystemEvent> watch(String directory) {
    return Stream<FileSystemEvent>.multi((controller) {
      controller.onCancel = () =>
          directory == _gatedPath ? gate.future : Future.value();
    });
  }
}

void main() {
  test('an ordinary change signals changed after the 300 ms debounce', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);
      backend.emit(_root, _create('$_root/a.txt'));

      async.elapse(const Duration(milliseconds: 299));
      expect(signals, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(signals, [
        isA<LocalWatchSignal>()
            .having((s) => s.kind, 'kind', DirectoryWatchSignal.changed)
            .having((s) => s.path, 'path', _root)
            .having((s) => s.detail, 'detail', isNull),
      ]);

      finish(async, watcher);
    });
  });

  test('a burst of events collapses into one changed signal', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      for (var i = 0; i < 5; i++) {
        backend.emit(_root, _create('$_root/file-$i.txt'));
        async.elapse(const Duration(milliseconds: 100));
      }

      // The debounce restarts per event; the loop ends at t=500 with the
      // last event delivered at t=400, so the signal lands at t=700.
      async.elapse(const Duration(milliseconds: 199));
      expect(signals, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.changed);

      finish(async, watcher);
    });
  });

  test('a change after a fired debounce arms a fresh one', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      backend.emit(_root, _create('$_root/a.txt'));
      async.elapse(const Duration(milliseconds: 301));
      expect(signals, hasLength(1));

      // The watch must keep notifying: a one-shot debounce regression
      // (or a subscription torn down after the first signal) would stop
      // here.
      backend.emit(_root, _create('$_root/b.txt'));
      async.elapse(const Duration(milliseconds: 301));

      expect(signals, hasLength(2));
      expect(signals.last.kind, DirectoryWatchSignal.changed);

      finish(async, watcher);
    });
  });

  test('grandchild events are filtered (non-recursive watch)', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      // A subtree-reporting backend (the macOS FSEvents shape): deep paths
      // and siblings outside the watch must never arm the debounce. A
      // direct child's own events (creating it) would qualify — deleting
      // a deeper path must not.
      backend.emit(_root, _create('$_root/sub/grandchild.txt'));
      backend.emit(_root, _delete('$_root/sub/nested.txt'));
      backend.emit(_root, _create('$_other/sibling.txt'));
      async.elapse(const Duration(seconds: 2));

      expect(signals, isEmpty);

      finish(async, watcher);
    });
  });

  test('a move whose destination is a direct child qualifies', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      backend.emit(_root, _move('$_root/old-name', '$_root/new-name'));
      async.elapse(const Duration(milliseconds: 301));

      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.changed);

      finish(async, watcher);
    });
  });

  test('a move from outside into a direct child qualifies', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      // The source is a grandchild path, the destination a direct child:
      // only the destination check makes this qualify.
      backend.emit(_root, _move('$_other/deep/src.txt', '$_root/arrived.txt'));
      async.elapse(const Duration(milliseconds: 301));

      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.changed);

      finish(async, watcher);
    });
  });

  test('an event on the watched directory itself is an ordinary change', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      // Attribute edits on the watched dir change the listing's
      // reachability (mode bits); a rescan is wanted, debounced.
      backend.emit(_root, _modify(_root));
      async.elapse(const Duration(milliseconds: 301));

      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.changed);

      finish(async, watcher);
    });
  });

  test('a removed watched directory signals lost immediately', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      backend.emit(_root, _delete(_root));
      async.flushMicrotasks();

      expect(signals, [
        isA<LocalWatchSignal>()
            .having((s) => s.kind, 'kind', DirectoryWatchSignal.lost)
            .having((s) => s.path, 'path', _root)
            .having((s) => s.detail, 'detail', isNotNull),
      ]);

      finish(async, watcher);
    });
  });

  test('a renamed-away watched directory signals lost immediately', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      backend.emit(_root, _move(_root, '$_other/moved'));
      async.flushMicrotasks();

      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.lost);

      finish(async, watcher);
    });
  });

  test('a backend error signals lost immediately with detail', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      backend.controllers[_root]!.addError(
        const FileSystemException('watcher failed', _root),
      );
      async.flushMicrotasks();

      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.lost);
      expect(signals.single.detail, contains('watcher failed'));

      finish(async, watcher);
    });
  });

  test('a non-filesystem backend error keeps a fixed detail sentence', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      backend.controllers[_root]!.addError(StateError('secret internals'));
      async.flushMicrotasks();

      expect(signals, hasLength(1));
      expect(signals.single.detail, isNot(contains('secret internals')));

      finish(async, watcher);
    });
  });

  test('a backend close signals lost immediately', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      backend.controllers[_root]!.close();
      async.flushMicrotasks();

      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.lost);
      expect(signals.single.detail, isNotNull);

      finish(async, watcher);
    });
  });

  test(
    'a delete-then-close root loss (the Linux shape) signals lost exactly once',
    () {
      fakeAsync((async) {
        final backend = FakeBackend();
        final watcher = LocalDirectoryWatcher(backend: backend);

        final signals = collect(async, watcher, _root);

        // IN_DELETE_SELF arrives as a delete-on-root and then the stream
        // closes; the epoch guard must swallow the second loss.
        backend.emit(_root, _delete(_root));
        async.flushMicrotasks();
        backend.controllers[_root]!.close();
        async.elapse(const Duration(seconds: 1));

        expect(signals, hasLength(1));
        expect(signals.single.kind, DirectoryWatchSignal.lost);

        finish(async, watcher);
      });
    },
  );

  test('a lost watch cancels its pending debounce', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);

      backend.emit(_root, _create('$_root/a.txt'));
      async.flushMicrotasks();
      backend.emit(_root, _delete(_root));
      async.elapse(const Duration(seconds: 5));

      // Only the immediate loss: no debounced change may follow it.
      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.lost);

      finish(async, watcher);
    });
  });

  test('a backend that throws at subscribe signals lost immediately', () {
    fakeAsync((async) {
      final backend = FakeBackend()
        ..throwOn = _root;
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = <LocalWatchSignal>[];
      watcher.signals.listen(signals.add);
      watcher.retarget(_root);
      async.flushMicrotasks();

      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.lost);
      expect(signals.single.path, _root);
      expect(backend.threw, [_root]);

      finish(async, watcher);
    });
  });

  test('stop cancels the pending debounce and emits nothing', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);
      backend.emit(_root, _create('$_root/a.txt'));
      async.flushMicrotasks();

      watcher.stop();
      async.elapse(const Duration(seconds: 5));

      expect(signals, isEmpty);
      expect(backend.cancelled, [_root]);

      finish(async, watcher);
    });
  });

  test('dispose cancels a pending debounce', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);
      backend.emit(_root, _create('$_root/a.txt'));
      async.flushMicrotasks();

      finish(async, watcher);
      async.elapse(const Duration(seconds: 5));

      // An orphaned timer firing into the closed signals stream would
      // surface as a nondeterministic unhandled error; it must be gone.
      expect(signals, isEmpty);
    });
  });

  test('events after stop are dropped', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);
      watcher.stop();
      async.flushMicrotasks();

      backend.emit(_root, _create('$_root/a.txt'));
      backend.controllers[_root]!.addError(
        const FileSystemException('late failure', _root),
      );
      async.elapse(const Duration(seconds: 5));

      expect(signals, isEmpty);

      finish(async, watcher);
    });
  });

  test('retarget releases the previous subscription and its timer', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);
      backend.emit(_root, _create('$_root/a.txt'));
      async.flushMicrotasks();

      watcher.retarget(_other);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));

      // The root's pending debounce died with the retarget; the other
      // watch stays silent (no events there).
      expect(signals, isEmpty);
      expect(backend.cancelled, [_root]);
      expect(backend.controllers.containsKey(_other), isTrue);

      finish(async, watcher);
    });
  });

  test('stale events from a replaced watch cannot signal the new binding', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);
      watcher.retarget(_other);

      // Emitted immediately after the retarget — with the synchronous
      // release the old subscription is already cancelled, so a
      // controller-backed fake drops these by broadcast semantics before
      // the epoch; cross-binding epoch coverage is the delete-then-close
      // shape below (same-binding late loss), the guard being
      // defense-in-depth for backend-internal delivery windows no
      // public-API fake can construct.
      backend.emit(_root, _create('$_root/late.txt'));
      backend.emit(_root, _delete(_root));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));

      expect(signals, isEmpty);

      // The live watch still works.
      backend.emit(_other, _create('$_other/b.txt'));
      async.elapse(const Duration(milliseconds: 301));
      expect(signals, hasLength(1));
      expect(signals.single.kind, DirectoryWatchSignal.changed);
      expect(signals.single.path, _other);

      finish(async, watcher);
    });
  });

  test('dispose closes the signals stream and releases the watch', () async {
    final backend = FakeBackend();
    final watcher = LocalDirectoryWatcher(backend: backend);

    final done = Completer<void>();
    watcher.signals.listen(
      (_) {},
      onDone: done.complete,
    );
    await watcher.retarget(_root);
    backend.emit(_root, _create('$_root/a.txt'));

    await watcher.dispose();

    await done.future;
    expect(backend.cancelled, [_root]);
  });

  test('stop completes only when the backend cancellation completes',
      () async {
    // A gated backend: the subscription's cancel future parks on the
    // gate, so release completion is driven by explicit delayed
    // completion, never by timing.
    final gate = Completer<void>();
    // Complete on teardown if a failing assertion skipped the happy path,
    // so a parked release can never outlive the test.
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    var cancelIssued = false;
    final stream = Stream<FileSystemEvent>.multi((controller) {
      controller.onCancel = () {
        cancelIssued = true;
        return gate.future;
      };
    });
    final watcher = LocalDirectoryWatcher(
      backend: _SingleStreamBackend(stream),
    );

    await watcher.retarget(_root);

    final stopped = watcher.stop();
    var completed = false;
    unawaited(stopped.then((_) => completed = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The cancellation was issued synchronously, but the acknowledged stop
    // must wait out its completion — epoch suppression is not release.
    expect(cancelIssued, isTrue);
    expect(completed, isFalse);

    gate.complete();
    await stopped;
    expect(completed, isTrue);
  });

  test('dispose waits the release tail before closing signals', () async {
    final gate = Completer<void>();
    // Complete on teardown if a failing assertion skipped the happy path.
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final stream = Stream<FileSystemEvent>.multi(
      (controller) => controller.onCancel = () => gate.future,
    );
    final watcher = LocalDirectoryWatcher(
      backend: _SingleStreamBackend(stream),
    );

    final done = Completer<void>();
    watcher.signals.listen(
      (_) {},
      onDone: done.complete,
    );
    await watcher.retarget(_root);

    final disposed = watcher.dispose();
    var closed = false;
    unawaited(done.future.then((_) => closed = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(closed, isFalse,
        reason: 'signals must not close before the backend released');

    gate.complete();
    await disposed;
    await done.future;
  });

  test('a concurrent second dispose awaits the first teardown', () async {
    final gate = Completer<void>();
    // Complete on teardown if a failing assertion skipped the happy path.
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final stream = Stream<FileSystemEvent>.multi((controller) {
      controller.onCancel = () => gate.future;
    });
    final watcher = LocalDirectoryWatcher(
      backend: _SingleStreamBackend(stream),
    );
    await watcher.retarget(_root);

    final first = watcher.dispose();
    // A concurrent second dispose must not complete while the first is
    // still parked on the release tail — an acknowledged dispose means
    // the teardown finished.
    final second = watcher.dispose();
    var secondDone = false;
    unawaited(second.then((_) => secondDone = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(secondDone, isFalse,
        reason: 'the second dispose must await the first teardown');

    gate.complete();
    await first;
    await second;
    expect(secondDone, isTrue);
  });

  test('a retarget ack does not wait the replaced watchs release', () async {
    final backend = _GatedFirstPathBackend(_root);
    final watcher = LocalDirectoryWatcher(backend: backend);

    await watcher.retarget(_root);
    // The replaced watch's cancellation parks; the retarget ack must not
    // wait it — the new watch is listening, and stop()/dispose() own the
    // wait.
    await watcher.retarget(_other);

    expect(backend.gate.isCompleted, isFalse);
    backend.gate.complete();
    await watcher.dispose();
  });

  test('a second watch after a lost watch still signals', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final watcher = LocalDirectoryWatcher(backend: backend);

      final signals = collect(async, watcher, _root);
      backend.emit(_root, _delete(_root));
      async.flushMicrotasks();
      expect(signals, hasLength(1));

      watcher.retarget(_other);
      async.flushMicrotasks();
      backend.emit(_other, _create('$_other/b.txt'));
      async.elapse(const Duration(milliseconds: 301));

      expect(signals, hasLength(2));
      expect(signals.last.kind, DirectoryWatchSignal.changed);
      expect(signals.last.path, _other);

      finish(async, watcher);
    });
  });
}
