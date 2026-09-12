import 'package:poltergeist_core/poltergeist_core.dart';

import 'engine_session.dart';

/// The engine surface a browsing pane consumes (03 §6's PaneController
/// seam): the two channel opens, the per-server state lane, and the
/// disconnect the pane banner cancels recovery through. Production wires
/// [EngineSession.paneLanes]; widget tests script a fake, so the pane
/// flows are drivable without an isolate.
///
/// The live `watchServer` stream carries no replay (03 §5), so callers
/// must subscribe before the connect whose state they want to observe —
/// the pane controller upholds that ordering.
abstract interface class PaneEngineLanes {
  /// Opens a local browse channel (03 §5's engine-side seam): the engine
  /// owns the backing `LocalFileSystem` (D8 — no dart:io on the UI
  /// isolate) and canonicalizes [rootPath] ('~' expands through its
  /// environment) into the channel's home.
  Future<AppBrowseChannel> openLocalChannel({required String rootPath});

  /// Opens (or rejoins) a pane-tab's remote browse channel (03 §3.2),
  /// carrying the server's [ServerConfig] — the engine holds no bookmarks.
  Future<AppBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  });

  /// One server's connection status, current value first (03 §3.2).
  Stream<ServerStatus> watchServer(String serverId);

  /// Drops this serverId's pool reference (03 §3.2): the pane banner's
  /// cancel — transport-level recovery stops instead of retrying forever.
  Future<void> disconnectServer(String serverId);
}
