import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Native watch mechanics stay behind this engine-internal seam (03 §7.5).
abstract interface class LocalWatchBackend {
  factory LocalWatchBackend.platform() => Platform.isWindows
      ? const WindowsWatchBackend()
      : const DartIoWatchBackend();

  /// Requires an absolute, link-resolved path from the engine's VFS.
  /// Starts on listen; cancellation must await all owned resources.
  Stream<FileSystemEvent> watch(String directory);
}

/// dart:io watches plus the shared ancestor chain (03 §7.5).
///
/// No desktop OS reports a rename of a watched directory's ancestor to
/// the moved tree's own watchers: inotify delivers `IN_MOVE_SELF` only
/// to the renamed directory's own watch, while FSEvents and
/// `ReadDirectoryChangesW` report a rename only through the renamed
/// entry's parent. Each ancestor of the watched directory therefore gets
/// its own non-recursive watch. Linux's inotify queue-overflow gap
/// remains (STATUS item 14).
final class DartIoWatchBackend implements LocalWatchBackend {
  const DartIoWatchBackend();

  @override
  Stream<FileSystemEvent> watch(String directory) =>
      _AncestorWatch(directory, _RootChecks.nativeOnly).stream;
}

/// Adds event-driven root metadata checks to the shared ancestor chain.
///
/// Windows retains delete-pending directory entries while a native
/// handle holds them open, and Dart drops the synchronous read failure
/// when re-arming the watcher, so root loss can arrive as silence rather
/// than an event. Neither mechanism scans descendants or polls on a
/// timer.
final class WindowsWatchBackend implements LocalWatchBackend {
  const WindowsWatchBackend();

  @override
  Stream<FileSystemEvent> watch(String directory) =>
      _AncestorWatch(directory, _RootChecks.eventDriven).stream;
}

/// When the backend verifies the watched root's metadata outside native
/// loss events (03 §7.5).
enum _RootChecks {
  /// Native self-loss events suffice (Linux inotify, macOS FSEvents).
  nativeOnly,

  /// Also check root type after setup and qualifying events: Windows
  /// retains delete-pending entries while a watch handle holds them, and
  /// Dart drops the synchronous read failure when re-arming the watcher.
  eventDriven,
}

/// One logical pane watch: the watched directory plus one non-recursive
/// native watch per ancestor above it.
///
/// Ownership and cost: one native handle per path component above the
/// watched directory (a volume-root watch owns none beyond the root
/// itself). Any chain subscription that fails to install — access
/// denied, handle exhaustion — fails the whole watch explicitly; the
/// backend never covers fewer ancestors silently.
final class _AncestorWatch {
  _AncestorWatch(this._path, this._rootChecks)
    : assert(p.isAbsolute(_path), 'The watch path must be absolute.'),
      _chain = _ancestorChain(_path) {
    _events = StreamController<FileSystemEvent>(
      onListen: _start,
      onCancel: _stop,
    );
  }

  final String _path;
  final _RootChecks _rootChecks;

  /// One entry per ancestor, child-first: the immediate parent's watch
  /// first, the filesystem root's last. Each key is the directory
  /// watched; each value is the chain child whose removal or rename at
  /// that level detaches the canonical path. Empty at a volume root.
  final List<MapEntry<String, String>> _chain;

  late final StreamController<FileSystemEvent> _events;
  StreamSubscription<FileSystemEvent>? _rootSubscription;
  final List<StreamSubscription<FileSystemEvent>> _chainSubscriptions = [];
  Future<void>? _probeFuture;
  Future<void>? _stopFuture;
  bool _probeAgain = false;
  bool _stopped = false;

  Stream<FileSystemEvent> get stream => _events.stream;

  /// Walks [path]'s ancestors child-first up to the filesystem root.
  ///
  /// The walk terminates at any `dirname` fixed point — `/` on POSIX, a
  /// drive root (`C:\`) or UNC share root (`\\server\share`) on Windows —
  /// so traversal always terminates with a finite chain and never climbs
  /// past a volume onto the host or another share.
  static List<MapEntry<String, String>> _ancestorChain(String path) {
    final chain = <MapEntry<String, String>>[];
    var child = path;
    var dir = p.dirname(child);
    while (!p.equals(dir, child)) {
      chain.add(MapEntry(dir, child));
      child = dir;
      dir = p.dirname(child);
    }
    return chain;
  }

  void _start() {
    try {
      // Install the immediate parent first so a root rename during the
      // remaining setup is retained, then walk upward. On Windows the
      // post-setup root check backstops a rename that slips past a
      // not-yet-installed ancestor watch.
      for (final link in _chain) {
        _chainSubscriptions.add(
          Directory(link.key).watch().listen(
            (event) => _onChainEvent(link.key, link.value, event),
            onError: _fail,
            onDone: _closed,
          ),
        );
      }
      final events = Directory(_path).watch();
      _rootSubscription = events.listen(
        _onRootEvent,
        onError: _fail,
        onDone: _closed,
      );
      if (_rootChecks == _RootChecks.eventDriven) _requestProbe();
    } on Object catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _onRootEvent(FileSystemEvent event) {
    if (_stopped) return;
    _events.add(event);
    if (_rootChecks == _RootChecks.eventDriven) _requestProbe();
  }

  void _onChainEvent(String dir, String child, FileSystemEvent event) {
    if (_stopped) return;
    if (!p.equals(event.path, child) && !p.equals(event.path, dir)) {
      return;
    }

    // A removal or rename at any chain level detaches the canonical path
    // from the native binding — even if a replacement already occupies
    // the old pathname. Emit the adapter's uniform root-loss shape.
    if (event is FileSystemDeleteEvent || event is FileSystemMoveEvent) {
      _events.add(FileSystemDeleteEvent(_path, true));
      _finish();
      return;
    }
    if (_rootChecks == _RootChecks.eventDriven) _requestProbe();
  }

  void _requestProbe() {
    if (_stopped) return;
    _probeAgain = true;
    if (_probeFuture != null) return;

    _probeFuture = _probeRoot().whenComplete(() {
      _probeFuture = null;
      if (_probeAgain && !_stopped) _requestProbe();
    });
  }

  Future<void> _probeRoot() async {
    while (_probeAgain && !_stopped) {
      _probeAgain = false;
      try {
        // Windows rejects metadata queries for delete-pending directories.
        // Check after every native batch; a pending check cannot absorb an
        // event that happened after that check took its snapshot.
        final type = await FileSystemEntity.type(_path, followLinks: false);
        if (_stopped) return;
        if (type == FileSystemEntityType.directory) continue;

        _fail(
          FileSystemException('The watched directory is unavailable.', _path),
        );
      } on Object catch (error, stack) {
        if (_stopped) return;
        _fail(error, stack);
      }
    }
  }

  void _closed() => _fail(
    FileSystemException('A directory watch closed unexpectedly.', _path),
  );

  void _fail(Object error, [StackTrace? stack]) {
    if (_stopped) return;
    _events.addError(error, stack);
    _finish();
  }

  void _finish() {
    // Terminal events retire resources even if the consumer does not cancel.
    // Stream closure must follow teardown, never participate in its future:
    // closing the controller invokes onCancel, which awaits that same future.
    _stop()
        .then(
          (_) => _events.close(),
          onError: (Object error, StackTrace stack) {
            _events.addError(error, stack);
            return _events.close();
          },
        )
        .ignore();
  }

  Future<void> _stop() => _stopFuture ??= _release();

  Future<void> _release() async {
    _stopped = true;
    _probeAgain = false;
    final root = _rootSubscription;
    _rootSubscription = null;
    final chain = List.of(_chainSubscriptions);
    _chainSubscriptions.clear();

    // Issue every cancel before awaiting any, preserving the engine's
    // close boundary when one native cancellation is slow; wait for all
    // of them even when one fails, so cancellation acknowledges only
    // full release.
    await Future.wait<void>([
      if (root != null) Future<void>.sync(root.cancel),
      for (final subscription in chain) Future<void>.sync(subscription.cancel),
      if (_probeFuture case final probe?) probe,
    ]);
  }
}
