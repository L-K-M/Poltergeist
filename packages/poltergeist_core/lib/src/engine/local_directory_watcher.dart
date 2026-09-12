import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'protocol.dart' show DirectoryWatchSignal;

/// The injectable backend for one non-recursive directory watch (03
/// §7.5). The production default wraps dart:io's `Directory.watch`; tests
/// inject deterministic fakes. An interface, not a function type: the
/// engine protocol guard forbids function-typed fields in engine sources
/// (08 §3.3), and this seam stays engine-internal either way — nothing
/// here crosses the isolate port.
abstract interface class LocalWatchBackend {
  /// Returns the event stream for [directory] — dart:io's contract: the
  /// OS watch starts when the stream is listened to.
  Stream<FileSystemEvent> watch(String directory);
}

/// The production backend: dart:io's non-recursive `Directory.watch`.
final class DartIoWatchBackend implements LocalWatchBackend {
  const DartIoWatchBackend();

  @override
  Stream<FileSystemEvent> watch(String directory) =>
      Directory(directory).watch();
}

/// One typed signal off a [LocalDirectoryWatcher] (engine-internal; the
/// host crosses it as a `DirectoryWatchEvent`).
final class LocalWatchSignal {
  final DirectoryWatchSignal kind;

  /// The canonical watched path the signal names.
  final String path;

  /// Failure detail for a lost signal; null for a changed signal.
  final String? detail;

  const LocalWatchSignal({required this.kind, required this.path, this.detail});
}

/// One non-recursive watch on one local directory, engine-owned (03 §7.5).
///
/// - Ordinary changes in the watched directory (its direct children and
///   the directory itself) coalesce into
///   [DirectoryWatchSignal.changed] signals [debounceInterval] after the
///   last event — a burst reads as one refresh, and a stream of changes
///   keeps the refresh deferred until it quiets (by design: rescanning a
///   directory mid-copy wastes the scan).
/// - Anything that ends the watch — the directory removed or renamed away,
///   a backend error, a backend close — emits [DirectoryWatchSignal.lost]
///   immediately and releases the watch. A watch never stops silently.
/// - `retarget` replaces the watch atomically: the replacement runs
///   synchronously (release, then subscribe, with no await between), and
///   every backend callback and the pending debounce capture the watch's
///   epoch — a release bumps it — so stale events from a replaced watch
///   can never invalidate the new binding.
///
/// Verified dart:io backend guarantees this adapter is built on (Dart
/// 3.13, `runtime/bin/file_system_watcher_{linux,macos,win}.cc` plus the
/// Dart-side patch): Linux and macOS report a removed/renamed watched
/// directory as a delete event naming the watched path itself, then close
/// the stream; Windows surfaces `ReadDirectoryChangesW` buffer overflow
/// and unexpected closure as stream errors — but not root deletion:
/// the OS defers removing a directory an open handle watches
/// (delete-pending), so no loss signal exists there and the
/// children-removal `changed` with its rescan is the observable path;
/// macOS FSEvents already
/// depth-filters non-recursive watches to direct children in the C++
/// layer, so the child filter below is defense in depth (it also covers a
/// future backend that reports subtrees). FSEvents' documented quirks —
/// changes made shortly before the watch started may still appear, and
/// short-window changes may arrive coalesced or out of order — are
/// consumer-benign through this adapter: every shape collapses into the
/// same debounced `changed` (an occasional spurious early refresh), and
/// only the root-loss shape is immediate.
///
/// Known gap (recorded as a dated STATUS.md item): Linux's inotify queue
/// overflow (`IN_Q_OVERFLOW`) is invisible through dart:io — the overflow
/// event carries watch descriptor -1, which matches no watched path, and
/// its decoded mask is 0 — so a Linux overflow silently drops events with
/// no signal this adapter can observe. The continuous subscription drains
/// the kernel queue promptly, which is the available mitigation; surfacing
/// the overflow needs a compatible FFI inotify backend behind the same
/// [LocalWatchBackend] seam.
final class LocalDirectoryWatcher {
  /// 03 §7.5's fixed debounce: ordinary changes coalesce for this long
  /// after the last event.
  static const Duration debounceInterval = Duration(milliseconds: 300);

  static const _backendClosedDetail = 'The directory watcher closed '
      'unexpectedly.';
  static const _unexpectedStopDetail = 'The directory watcher stopped '
      'unexpectedly.';

  LocalDirectoryWatcher({LocalWatchBackend? backend})
    : _backend = backend ?? const DartIoWatchBackend();

  final LocalWatchBackend _backend;
  final _signals = StreamController<LocalWatchSignal>.broadcast();

  StreamSubscription<FileSystemEvent>? _subscription;
  Timer? _debounce;

  /// The generation of the live watch. Releasing bumps it synchronously,
  /// so every callback captured by a replaced or stopped watch is stale
  /// from that instant.
  int _epoch = 0;

  String? _watchedPath;
  bool _disposed = false;

  /// The typed signals; broadcast, closes on [dispose]. A signal emitted
  /// while no listener is attached is dropped — subscribe before the first
  /// `retarget` to observe every lost signal.
  Stream<LocalWatchSignal> get signals => _signals.stream;

  /// Starts watching [canonicalPath], replacing any current watch. The
  /// replacement is atomic: the old watch is released and the new one
  /// subscribed with no await between, so the two can never interleave.
  Future<void> retarget(String canonicalPath) {
    _retarget(canonicalPath);
    return Future.value();
  }

  /// Releases the current watch without a signal (an explicit
  /// unsubscribe). Idempotent.
  Future<void> stop() {
    _release();
    return Future.value();
  }

  /// Releases the watch and closes [signals]; the watcher is unusable
  /// afterwards. Idempotent — a second call is a no-op, like [stop].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _release();
    await _signals.close();
  }

  void _retarget(String path) {
    _release();
    if (_disposed) return;

    final epoch = _epoch;
    _watchedPath = path;

    late final StreamSubscription<FileSystemEvent> subscription;
    try {
      subscription = _backend.watch(path).listen(
        (event) => _onEvent(epoch, event),
        onError: (Object error) => _lost(epoch, _failureDetail(error)),
        onDone: () => _lost(epoch, _backendClosedDetail),
      );
    } on Object catch (error) {
      // A backend that throws at subscribe time cannot be trusted to
      // deliver anything later — fail the watch loud and immediately.
      _lost(epoch, _failureDetail(error));
      return;
    }
    _subscription = subscription;
  }

  // Synchronous by contract: the epoch bump retires every captured
  // callback and the pending debounce at once, and the backend cancel is
  // issued without awaiting it — a subscription's cancel future completes
  // on the event loop (under fake_async it never does), while correctness
  // depends only on the epoch, never on the cancel's completion.
  void _release() {
    _epoch++;
    _debounce?.cancel();
    _debounce = null;
    _watchedPath = null;
    _subscription?.cancel().catchError((Object _) {});
    _subscription = null;
  }

  void _onEvent(int epoch, FileSystemEvent event) {
    if (epoch != _epoch) return;
    final watched = _watchedPath;
    if (watched == null) return;
    final path = event.path;

    // The watched directory itself removed or renamed away: the backends'
    // uniform root-loss shape (IN_DELETE_SELF on Linux, FSEvents is_self
    // on macOS). Immediate, never debounced.
    if ((event is FileSystemDeleteEvent || event is FileSystemMoveEvent) &&
        p.equals(path, watched)) {
      _lost(epoch, 'the watched directory was removed');
      return;
    }

    // Direct children and the watched directory itself (attribute edits
    // change the listing's reachability) qualify; so does a move whose
    // destination is a direct child. Deeper events — a backend reporting
    // subtrees — are dropped: the watch is non-recursive.
    if (!_isDirectChild(watched, path) &&
        !p.equals(path, watched)) {
      final destination =
          event is FileSystemMoveEvent ? event.destination : null;
      if (destination == null || !_isDirectChild(watched, destination)) {
        return;
      }
    }

    _debounce?.cancel();
    _debounce = Timer(debounceInterval, () {
      _debounce = null;
      final current = _watchedPath;
      if (epoch != _epoch || current == null) return;
      _signals.add(
        LocalWatchSignal(kind: DirectoryWatchSignal.changed, path: current),
      );
    });
  }

  void _lost(int epoch, String detail) {
    if (epoch != _epoch) return;
    final watched = _watchedPath;
    if (watched == null) return;

    _signals.add(
      LocalWatchSignal(
        kind: DirectoryWatchSignal.lost,
        path: watched,
        detail: detail,
      ),
    );
    _release();
  }

  /// True when [candidate] is exactly one path component below [watched]
  /// (pure lexical comparison; both sides are already canonical).
  static bool _isDirectChild(String watched, String candidate) {
    final rel = p.relative(candidate, from: watched);
    if (p.isAbsolute(rel)) return false;
    if (rel == '..' || rel.startsWith('..${p.context.separator}')) {
      return false;
    }
    // p.split('.') is empty; anything deeper than one component has a
    // separator in the relative path.
    return p.split(rel).length == 1;
  }

  /// Failure detail for a lost signal: OS text from the backend where the
  /// backend produced any, a fixed sentence otherwise — never arbitrary
  /// exception internals.
  static String _failureDetail(Object error) => error is FileSystemException
      ? error.toString()
      : _unexpectedStopDetail;
}
