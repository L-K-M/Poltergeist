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
    final fault = listingFailure;
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

  @override
  Future<void> close() async {
    closeCalls++;
  }
}
