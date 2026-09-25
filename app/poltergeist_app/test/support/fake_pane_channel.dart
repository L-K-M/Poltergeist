import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_app/services/engine_session.dart';

/// A scripted browse channel: listings answer from [listings] by path, and
/// in-flight answers can be held back with [holdNext] to test stale
/// generations.
class FakePaneChannel implements AppBrowseChannel {
  FakePaneChannel(this.homePath);

  @override
  final String homePath;

  final listings = <String, List<RemoteFileEntry>>{};
  final listCalls = <String>[];
  int closeCalls = 0;
  Completer<void>? holdNext;

  /// When set, every listing throws this non-VFS error (drives the
  /// typed PaneFault list path).
  Object? listingFailure;

  /// Per-path listing refusals (a folder the user may not read),
  /// checked before [listings].
  final listingFailures = <String, Object>{};

  /// Recorded rename calls (oldPath, newPath) and a scripted failure —
  /// null renames succeed silently.
  final renameCalls = <(String, String)>[];
  Object? renameFailure;
  Completer<void>? heldRename;

  @override
  Future<void> rename(String oldPath, String newPath) async {
    renameCalls.add((oldPath, newPath));
    final held = heldRename;
    if (held != null) {
      heldRename = null;
      await held.future;
    }
    final failure = renameFailure;
    if (failure != null) throw failure;
  }

  /// Recorded chmod calls (path, permissions) and scripted failures —
  /// [permissionsFailures] keys a refusal by path (checked first) while
  /// [permissionsFailure] applies to every call; null calls succeed
  /// silently. [heldPermissions] parks the next call until completed —
  /// consumed once, like [heldRename].
  final permissionsCalls = <(String, int)>[];
  Object? permissionsFailure;
  final permissionsFailures = <String, Object>{};
  Completer<void>? heldPermissions;

  @override
  Future<void> setPermissions(String path, int permissions) async {
    permissionsCalls.add((path, permissions));
    final held = heldPermissions;
    if (held != null) {
      heldPermissions = null;
      await held.future;
    }
    final failure = permissionsFailures[path] ?? permissionsFailure;
    if (failure != null) throw failure;
  }

  /// Recorded default-app opens (paths) and a scripted failure — null
  /// opens succeed silently.
  final openCalls = <String>[];
  Object? openFailure;

  @override
  Future<void> openInDefaultApp(String path) async {
    openCalls.add(path);
    final failure = openFailure;
    if (failure != null) throw failure;
  }

  /// The scripted watch seam (03 §7.5): requests are recorded,
  /// [watchFailure] makes every watch request throw, [heldWatch] parks
  /// the next one until completed (consumed once, like [holdNext]),
  /// and [onWatch] runs inside the request before it answers — where an
  /// engine's immediate `lost` lands. [emitWatch] delivers a signal
  /// synchronously to every current listener.
  final watchCalls = <String>[];
  int unwatchCalls = 0;
  Object? watchFailure;
  Completer<void>? heldWatch;
  void Function(String path)? onWatch;
  final _watchEvents = StreamController<DirectoryWatchEvent>.broadcast(
    sync: true,
  );

  final _queuedWatchEvents = <DirectoryWatchEvent>[];
  bool _deliveringWatchEvent = false;

  /// Whether anything still listens to [directoryChanges].
  bool get hasWatchListener => _watchEvents.hasListener;

  /// An emit from inside a listener (an [onWatch] reached through a
  /// signal's own refresh) queues until the current delivery returns,
  /// still ahead of the pending watch reply, as a port would deliver it.
  void emitWatch(DirectoryWatchSignal signal, {String? path}) {
    _queuedWatchEvents.add(
      DirectoryWatchEvent(
        channelId: 0,
        path: path ?? (watchCalls.isEmpty ? '' : watchCalls.last),
        signal: signal,
      ),
    );
    if (_deliveringWatchEvent) return;
    _deliveringWatchEvent = true;
    try {
      while (_queuedWatchEvents.isNotEmpty) {
        _watchEvents.add(_queuedWatchEvents.removeAt(0));
      }
    } finally {
      _deliveringWatchEvent = false;
    }
  }

  /// Ends [directoryChanges] the way a closed channel or a dead engine
  /// does.
  Future<void> closeWatchStream() => _watchEvents.close();

  @override
  Stream<DirectoryWatchEvent> get directoryChanges => _watchEvents.stream;

  @override
  Future<void> watchDirectory(String path) async {
    watchCalls.add(path);
    final held = heldWatch;
    if (held != null) {
      heldWatch = null;
      await held.future;
    }
    final failure = watchFailure;
    if (failure != null) throw failure;
    onWatch?.call(path);
  }

  @override
  Future<void> unwatchDirectory() async {
    unwatchCalls++;
  }

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    listCalls.add(path);
    final hold = holdNext;
    if (hold != null) {
      holdNext = null;
      await hold.future;
    }
    final fault = listingFailure ?? listingFailures[path];
    if (fault != null) throw fault;
    final entries = listings[path];
    if (entries == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'list',
        path: path,
        message: 'Could not list "$path": no such directory',
      );
    }
    return entries;
  }

  /// Recorded create calls (`dir:<path>` / `file:<path>`), plus the
  /// paths created so far — a later create or stat of one sees it. A
  /// scripted [createFailure] refuses every create.
  final createCalls = <String>[];
  final created = <String>{};
  Object? createFailure;

  bool _exists(String path) {
    if (created.contains(path)) return true;
    for (final entries in listings.values) {
      if (entries.any((entry) => entry.path == path)) return true;
    }
    return false;
  }

  RemoteFileException _conflict(String operation, String path) =>
      RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: operation,
        path: path,
        message: 'already exists: $path',
      );

  @override
  Future<void> createDirectory(String path) async {
    createCalls.add('dir:$path');
    final failure = createFailure;
    if (failure != null) throw failure;
    if (_exists(path)) throw _conflict('create directory', path);
    created.add(path);
    _list(path, RemoteFileType.directory);
  }

  /// A create lands in its parent's scripted listing, so the refresh
  /// that follows shows it like a real filesystem would.
  void _list(String path, RemoteFileType type) {
    final slash = path.lastIndexOf('/');
    final parent = slash <= 0 ? '/' : path.substring(0, slash);
    final entries = listings[parent];
    if (entries == null) return;
    listings[parent] = [
      ...entries,
      RemoteFileEntry(
        path: path,
        name: path.substring(slash + 1),
        type: type,
        size: type == RemoteFileType.file ? 0 : null,
      ),
    ];
  }

  @override
  Future<RemoteFileEntry> createEmptyFile(String path) async {
    createCalls.add('file:$path');
    final failure = createFailure;
    if (failure != null) throw failure;
    if (_exists(path)) throw _conflict('create file', path);
    created.add(path);
    _list(path, RemoteFileType.file);
    return RemoteFileEntry(
      path: path,
      name: path.split('/').last,
      type: RemoteFileType.file,
      size: 0,
    );
  }

  @override
  Future<RemoteFileEntry> stat(String path) async {
    if (_exists(path)) {
      return RemoteFileEntry(
        path: path,
        name: path.split('/').last,
        type: RemoteFileType.file,
      );
    }
    throw RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'stat',
      path: path,
      message: 'no such path: $path',
    );
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}
