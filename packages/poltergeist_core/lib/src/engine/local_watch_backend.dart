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

/// Non-recursive native events suffice on Linux and macOS, except for
/// dart:io's documented Linux overflow gap (STATUS item 14).
final class DartIoWatchBackend implements LocalWatchBackend {
  const DartIoWatchBackend();

  @override
  Stream<FileSystemEvent> watch(String directory) =>
      Directory(directory).watch();
}

/// Adds root-loss detection to Windows' child-only native notifications.
///
/// A parent watch detects renames. Event-driven metadata checks detect
/// delete-pending roots when Dart drops a synchronous native read failure.
/// Neither mechanism scans descendants or polls on a timer.
final class WindowsWatchBackend implements LocalWatchBackend {
  const WindowsWatchBackend();

  @override
  Stream<FileSystemEvent> watch(String directory) =>
      _WindowsWatch(directory).stream;
}

final class _WindowsWatch {
  _WindowsWatch(this._path)
    : assert(p.isAbsolute(_path), 'The watch path must be absolute.'),
      _parent = p.dirname(_path) {
    _events = StreamController<FileSystemEvent>(
      onListen: _start,
      onCancel: _stop,
    );
  }

  final String _path;
  final String _parent;
  late final StreamController<FileSystemEvent> _events;
  StreamSubscription<FileSystemEvent>? _rootSubscription;
  StreamSubscription<FileSystemEvent>? _parentSubscription;
  Future<void>? _probeFuture;
  Future<void>? _stopFuture;
  bool _probeAgain = false;
  bool _stopped = false;

  Stream<FileSystemEvent> get stream => _events.stream;

  void _start() {
    try {
      // Install the parent first so a rename during root setup is retained.
      // A volume root has no distinct parent to subscribe to.
      if (!p.equals(_path, _parent)) {
        final events = Directory(_parent).watch();
        _parentSubscription = events.listen(
          _onParentEvent,
          onError: _fail,
          onDone: _closed,
        );
      }
      final events = Directory(_path).watch();
      _rootSubscription = events.listen(
        _onRootEvent,
        onError: _fail,
        onDone: _closed,
      );
      _requestProbe();
    } on Object catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _onRootEvent(FileSystemEvent event) {
    if (_stopped) return;
    _events.add(event);
    _requestProbe();
  }

  void _onParentEvent(FileSystemEvent event) {
    if (_stopped) return;
    if (!p.equals(event.path, _path) && !p.equals(event.path, _parent)) {
      return;
    }

    // Emit the adapter's existing root-loss shape even if a new directory
    // already occupies the old path. The native binding follows the old one.
    if (event is FileSystemDeleteEvent || event is FileSystemMoveEvent) {
      _events.add(FileSystemDeleteEvent(_path, true));
      _finish();
      return;
    }
    _requestProbe();
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
    final parent = _parentSubscription;
    _rootSubscription = null;
    _parentSubscription = null;

    // Issue both cancels before awaiting either; preserve the existing
    // engine close boundary even when one native cancellation is slow.
    await Future.wait<void>([
      if (root != null) Future<void>.sync(root.cancel),
      if (parent != null) Future<void>.sync(parent.cancel),
      if (_probeFuture case final probe?) probe,
    ]);
  }
}
