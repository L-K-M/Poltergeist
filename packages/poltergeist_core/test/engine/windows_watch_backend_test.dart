import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:poltergeist_core/src/engine/local_watch_backend.dart';
import 'package:test/test.dart';

final _parent = p.join(p.current, 'windows-watch-fixture');
final _root = p.join(_parent, 'watched');

Future<void> _flush() => Future<void>.delayed(Duration.zero);

/// Native notifications and metadata replies advance independently, as on IOCP.
final class _Harness {
  final watchedPaths = <String>[];
  final recursiveModes = <bool>[];
  final cancelledPaths = <String>[];
  final watches = <String, _NativeWatch>{};
  final probes = <Completer<FileSystemEntityType>>[];
  final probePaths = <String>[];
  final probeFollowLinks = <bool>[];
  final events = <FileSystemEvent>[];
  final errors = <Object>[];
  final done = Completer<void>();
  StreamSubscription<FileSystemEvent>? subscription;
  String? throwOnWatch;

  Future<void> run(Future<void> Function() body) => IOOverrides.runZoned(
    () async {
      try {
        await body();
      } finally {
        final cancellation = subscription?.cancel();
        for (final probe in probes) {
          if (!probe.isCompleted) {
            probe.complete(FileSystemEntityType.directory);
          }
        }
        for (final watch in watches.values) {
          watch.releaseCancellation();
        }
        await cancellation;
      }
    },
    createDirectory: (path) => _FakeDirectory(path, this),
    fseGetType: (path, followLinks) {
      probePaths.add(path);
      probeFollowLinks.add(followLinks);
      final probe = Completer<FileSystemEntityType>();
      probes.add(probe);
      return probe.future;
    },
  );

  Future<void> start([String? path]) async {
    subscription = const WindowsWatchBackend()
        .watch(path ?? _root)
        .listen(events.add, onError: errors.add, onDone: done.complete);
    await _flush();
  }

  Future<void> healthy() async {
    await start();
    probes.single.complete(FileSystemEntityType.directory);
    await _flush();
  }

  _NativeWatch watchFor(String path) =>
      watches.putIfAbsent(path, () => _NativeWatch(path, this));
}

final class _FakeDirectory implements Directory {
  _FakeDirectory(this.path, this._harness);

  @override
  final String path;
  final _Harness _harness;

  @override
  Directory get parent => _FakeDirectory(p.dirname(path), _harness);

  @override
  Stream<FileSystemEvent> watch({
    int events = FileSystemEvent.all,
    bool recursive = false,
  }) {
    if (path == _harness.throwOnWatch) {
      throw FileSystemException('subscribe failure', path);
    }
    _harness.recursiveModes.add(recursive);
    return _harness.watchFor(path).stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _NativeWatch {
  _NativeWatch(this._path, this._harness);

  final String _path;
  final _Harness _harness;
  final _cancelGate = Completer<void>();
  late MultiStreamController<FileSystemEvent> _controller;

  Stream<FileSystemEvent> get stream => Stream.multi((controller) {
    _controller = controller;
    _harness.watchedPaths.add(_path);
    controller.onCancel = () {
      _harness.cancelledPaths.add(_path);
      return _cancelGate.future;
    };
  });

  void emit(FileSystemEvent event) => _controller.add(event);

  void fail() =>
      _controller.addError(FileSystemException('native failure', _path));

  void close() {
    // A completed native stream has already released its own resources.
    releaseCancellation();
    _controller.close();
  }

  void releaseCancellation() {
    if (!_cancelGate.isCompleted) _cancelGate.complete();
  }
}

void main() {
  test('relative watch paths violate the canonical-path precondition', () {
    expect(
      () => const WindowsWatchBackend().watch('relative'),
      throwsA(isA<AssertionError>()),
    );
  });

  test('attaches parent first and checks the root without following links', () {
    final h = _Harness();
    return h.run(() async {
      await h.start();

      expect(h.watchedPaths, [_parent, _root]);
      expect(h.recursiveModes, [false, false]);
      expect(h.probePaths, [_root]);
      expect(h.probeFollowLinks, [false]);
      expect(h.events, isEmpty);
    });
  });

  test('healthy root events retain their objects and order', () {
    final h = _Harness();
    return h.run(() async {
      await h.healthy();
      final original = p.join(_root, 'original');
      final renamed = p.join(_root, 'renamed');
      final changes = <FileSystemEvent>[
        FileSystemCreateEvent(original, false),
        FileSystemModifyEvent(original, false, true),
        FileSystemMoveEvent(original, false, renamed),
        FileSystemDeleteEvent(renamed, false),
      ];
      for (final change in changes) {
        h.watchFor(_root).emit(change);
      }
      await _flush();

      h.probes[1].complete(FileSystemEntityType.directory);
      await _flush();
      h.probes.last.complete(FileSystemEntityType.directory);
      await _flush();

      expect(h.events, changes.map(same).toList());
      expect(h.errors, isEmpty);
      expect(h.cancelledPaths, isEmpty);
    });
  });

  test('a missing setup target fails and closes both native watches', () {
    final h = _Harness();
    return h.run(() async {
      await h.start();
      h.probes.single.complete(FileSystemEntityType.notFound);
      await _flush();

      expect(h.errors, [isA<FileSystemException>()]);
      expect(h.cancelledPaths, unorderedEquals([_parent, _root]));
      expect(h.events, isEmpty);
      h.watchFor(_parent).releaseCancellation();
      h.watchFor(_root).releaseCancellation();
      await h.done.future;
    });
  });

  test('queued child removal detects a delete-pending root', () {
    final h = _Harness();
    return h.run(() async {
      await h.healthy();
      final removal = FileSystemDeleteEvent(p.join(_root, 'last-child'), false);
      h.watchFor(_root).emit(removal);
      await _flush();
      h.probes.last.complete(FileSystemEntityType.notFound);
      await _flush();

      expect(h.probes, hasLength(2));
      expect(h.errors, [isA<FileSystemException>()]);
      expect(h.cancelledPaths, unorderedEquals([_parent, _root]));
    });
  });

  test('root attribute events also check reachability', () {
    final h = _Harness();
    return h.run(() async {
      await h.healthy();
      h.watchFor(_root).emit(FileSystemModifyEvent(_root, true, false));
      await _flush();

      expect(h.probePaths, [_root, _root]);
    });
  });

  test('target attribute events on the parent also check reachability', () {
    final h = _Harness();
    return h.run(() async {
      await h.healthy();
      h.watchFor(_parent).emit(FileSystemModifyEvent(_root, true, false));
      await _flush();

      expect(h.probePaths, [_root, _root]);
    });
  });

  for (final replacement in [
    FileSystemEntityType.file,
    FileSystemEntityType.link,
  ]) {
    test('a setup target replaced by $replacement fails closed', () {
      final h = _Harness();
      return h.run(() async {
        await h.start();
        h.probes.single.complete(replacement);
        await _flush();

        expect(h.errors, [isA<FileSystemException>()]);
        expect(h.cancelledPaths, unorderedEquals([_parent, _root]));
      });
    });
  }

  test('parent rename emits one terminal root deletion', () {
    final h = _Harness();
    return h.run(() async {
      await h.healthy();
      h
          .watchFor(_parent)
          .emit(FileSystemMoveEvent(_root, true, p.join(_parent, 'renamed')));
      await _flush();

      expect(h.events, [
        isA<FileSystemDeleteEvent>().having(
          (event) => event.path,
          'path',
          _root,
        ),
      ]);
      expect(h.cancelledPaths, unorderedEquals([_parent, _root]));
      expect(h.errors, isEmpty);
    });
  });

  test('parent target deletion maps to terminal root deletion', () {
    final h = _Harness();
    return h.run(() async {
      await h.healthy();
      h.watchFor(_parent).emit(FileSystemDeleteEvent(_root, false));
      await _flush();

      expect(h.events, [
        isA<FileSystemDeleteEvent>().having(
          (event) => event.path,
          'path',
          _root,
        ),
      ]);
      expect(h.cancelledPaths, unorderedEquals([_parent, _root]));
    });
  });

  test('loss of the parent invalidates the watched target', () {
    final h = _Harness();
    return h.run(() async {
      await h.healthy();
      h.watchFor(_parent).emit(FileSystemDeleteEvent(_parent, false));
      await _flush();

      expect(h.events, [
        isA<FileSystemDeleteEvent>().having(
          (event) => event.path,
          'path',
          _root,
        ),
      ]);
      expect(h.cancelledPaths, unorderedEquals([_parent, _root]));
    });
  });

  test('parent sibling changes neither escape nor trigger probes', () {
    final h = _Harness();
    return h.run(() async {
      await h.healthy();
      final sibling = p.join(_parent, 'sibling');
      h.watchFor(_parent).emit(FileSystemCreateEvent(sibling, true));
      h.watchFor(_parent).emit(FileSystemDeleteEvent(sibling, false));
      h.watchFor(_parent).emit(FileSystemModifyEvent(sibling, true, false));
      h
          .watchFor(_parent)
          .emit(
            FileSystemMoveEvent(
              sibling,
              true,
              p.join(_parent, 'another-sibling'),
            ),
          );
      await _flush();

      expect(h.events, isEmpty);
      expect(h.errors, isEmpty);
      expect(h.probes, hasLength(1));
      expect(h.cancelledPaths, isEmpty);
    });
  });

  test('parent subscribe failure stops setup and closes the stream', () {
    final h = _Harness()..throwOnWatch = _parent;
    return h.run(() async {
      await h.start();

      expect(h.errors, [isA<FileSystemException>()]);
      expect(h.watchedPaths, isEmpty);
      expect(h.probes, isEmpty);
      await h.done.future;
    });
  });

  test('root subscribe failure releases the installed parent', () {
    final h = _Harness()..throwOnWatch = _root;
    return h.run(() async {
      await h.start();

      expect(h.errors, [isA<FileSystemException>()]);
      expect(h.watchedPaths, [_parent]);
      expect(h.cancelledPaths, [_parent]);
      expect(h.probes, isEmpty);
      expect(h.done.isCompleted, isFalse);

      h.watchFor(_parent).releaseCancellation();
      await h.done.future;
    });
  });

  for (final (label, failedPath) in [('parent', _parent), ('root', _root)]) {
    test('native $label failure fails the combined watch', () {
      final h = _Harness();
      return h.run(() async {
        await h.healthy();
        h.watchFor(failedPath).fail();
        await _flush();

        expect(h.errors, [isA<FileSystemException>()]);
        expect(h.cancelledPaths, unorderedEquals([_parent, _root]));
      });
    });
  }

  test('unexpected native close fails the combined watch', () {
    final h = _Harness();
    return h.run(() async {
      await h.healthy();
      h.watchFor(_parent).close();
      await _flush();

      expect(h.errors, [isA<FileSystemException>()]);
      expect(h.cancelledPaths, unorderedEquals([_parent, _root]));
    });
  });

  test('probe failure fails and closes the watch', () {
    final h = _Harness();
    return h.run(() async {
      await h.start();
      h.probes.single.completeError(const FileSystemException('probe failure'));
      await _flush();

      expect(h.errors, [isA<FileSystemException>()]);
      expect(h.cancelledPaths, unorderedEquals([_parent, _root]));
    });
  });

  test('events during a probe coalesce into one trailing check', () {
    final h = _Harness();
    return h.run(() async {
      await h.healthy();
      final change = FileSystemModifyEvent(p.join(_root, 'child'), false, true);
      h.watchFor(_root).emit(change);
      await _flush();

      h.watchFor(_root).emit(change);
      h.watchFor(_root).emit(change);
      await _flush();
      expect(h.probes, hasLength(2));

      h.probes[1].complete(FileSystemEntityType.directory);
      await _flush();
      expect(h.probes, hasLength(3));
      h.probes[2].complete(FileSystemEntityType.notFound);
      await _flush();

      expect(h.errors, [isA<FileSystemException>()]);
      expect(h.cancelledPaths, unorderedEquals([_parent, _root]));
    });
  });

  test('cancel awaits both native releases and the pending probe', () {
    final h = _Harness();
    return h.run(() async {
      await h.start();
      var cancelled = false;
      final cancellation = h.subscription!.cancel().then(
        (_) => cancelled = true,
      );
      await _flush();

      expect(h.cancelledPaths, unorderedEquals([_parent, _root]));
      h.watchFor(_parent).releaseCancellation();
      await _flush();
      expect(cancelled, isFalse);
      h.watchFor(_root).releaseCancellation();
      await _flush();
      expect(cancelled, isFalse);

      // A failed result after cancellation must neither signal nor restart work.
      h.probes.single.complete(FileSystemEntityType.notFound);
      await cancellation;
      await _flush();
      expect(cancelled, isTrue);
      expect(h.events, isEmpty);
      expect(h.errors, isEmpty);
      expect(h.probes, hasLength(1));
    });
  });

  test('cancelling a probe with queued changes prevents a trailing check', () {
    final h = _Harness();
    return h.run(() async {
      await h.start();
      h
          .watchFor(_root)
          .emit(FileSystemCreateEvent(p.join(_root, 'child'), false));
      await _flush();
      final beforeCancel = List<FileSystemEvent>.of(h.events);
      final cancellation = h.subscription!.cancel();
      h.watchFor(_parent).releaseCancellation();
      h.watchFor(_root).releaseCancellation();
      h.probes.single.completeError(const FileSystemException('late probe'));
      await cancellation;
      await _flush();

      expect(h.events, beforeCancel);
      expect(h.errors, isEmpty);
      expect(h.probes, hasLength(1));
    });
  });

  test('a filesystem root is watched only once', () {
    final h = _Harness();
    return h.run(() async {
      final filesystemRoot = p.rootPrefix(_root);
      await h.start(filesystemRoot);

      expect(h.watchedPaths, [filesystemRoot]);
      expect(h.probePaths, [filesystemRoot]);
      expect(h.recursiveModes, [false]);
    });
  });
}
