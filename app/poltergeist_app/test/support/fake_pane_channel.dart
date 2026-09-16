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
