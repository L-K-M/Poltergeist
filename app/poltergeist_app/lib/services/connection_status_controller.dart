import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'application_error_reporter.dart';
import 'bookmark_store.dart';
import 'connection_state_bridge.dart';

/// The server list's own load state — distinct from per-server connection
/// state: a ready list can be entirely offline, and a failed load has no rows
/// to describe.
enum ConnectionListLoad {
  /// Never read: the surface has not asked for the list yet.
  idle,
  loading,
  ready,
  failed,
}

/// One pane binding's terminal recovery failure (03 §3.3): the pool survived,
/// this pane's home did not, and only an explicit reopen retries it.
final class PaneFailure {
  const PaneFailure({required this.paneTabId, required this.message});

  final String paneTabId;

  /// The summarized failure one-liner the engine already sanitized.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is PaneFailure &&
      other.paneTabId == paneTabId &&
      other.message == message;

  @override
  int get hashCode => Object.hash(paneTabId, message);

  @override
  String toString() => 'PaneFailure($paneTabId, $message)';
}

/// One server the app holds a reference to, plus the live truth the engine
/// reports for it (02 §4's Connections section).
final class ConnectionServer {
  const ConnectionServer({
    required this.serverId,
    required this.label,
    required this.host,
    required this.port,
    required this.username,
    this.status,
    this.paneFailure,
  });

  /// The bookmark's id — the pool's serverId (03 §3.5).
  final String serverId;

  final String label;
  final String host;
  final int port;
  final String username;

  /// Live connection truth; null while no engine reports this server, which
  /// is not a failure: the app simply holds no transport for it.
  final ServerStatus? status;

  /// Per-pane attribution from the recovery lane; null when no pane binding
  /// of this server failed terminally.
  final PaneFailure? paneFailure;

  ConnectionServer _withStatus(ServerStatus? status) => ConnectionServer(
    serverId: serverId,
    label: label,
    host: host,
    port: port,
    username: username,
    status: status,
    paneFailure: paneFailure,
  );

  ConnectionServer _withPaneFailure(PaneFailure? paneFailure) =>
      ConnectionServer(
        serverId: serverId,
        label: label,
        host: host,
        port: port,
        username: username,
        status: status,
        paneFailure: paneFailure,
      );

  ConnectionServer _withoutTruth() => _withStatus(null)._withPaneFailure(null);

  @override
  bool operator ==(Object other) =>
      other is ConnectionServer &&
      other.serverId == serverId &&
      other.label == label &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.status == status &&
      other.paneFailure == paneFailure;

  @override
  int get hashCode =>
      Object.hash(serverId, label, host, port, username, status, paneFailure);

  @override
  String toString() => 'ConnectionServer($serverId, $label, $status)';
}

/// Per-server connection truth for the servers the app holds references to —
/// 03 §6's app-wide `ConnectionStatus` notifier.
///
/// The bookmark store supplies the list, the engine's two state lanes supply
/// the truth:
///
/// ```
/// BookmarkRepository ──load()──► rows (serverId = bookmark id, 03 §3.5)
///                                  │
/// ConnectionStateBridge ───────────┤ watchServer(id) ─► state + detail
///   (EngineClient's lanes)          └ recoveryFailures ─► per-pane attribution
/// ```
///
/// The list is bookmark-derived, never engine-derived: the engine holds no
/// bookmark store, so it can name a live pool but never say which favorite it
/// belongs to. Live truth is optional — no engine means no transports, which
/// a row renders as "not connected" rather than as a failure.
///
/// Probe truth is deliberately absent here: 02 §4 gives the Connections
/// section pool state, not probe state, and the probe controller does not
/// override live connection state (03 §3.4). Surfaces that hold both compose
/// them through `serverIndicatorOf`.
final class ConnectionStatusController extends ChangeNotifier {
  ConnectionStatusController({
    required BookmarkRepository bookmarks,
    ConnectionStateBridge? bridge,
    ApplicationErrorReporter? errors,
  }) : // Keep the store seam private to the controller.
       // ignore: prefer_initializing_formals
       _bookmarks = bookmarks,
       // The engine seam is optional: no production engine exists until the
       // startup-wiring slice spawns one with its pins and incidents seeded
       // (STATUS item 3/6, audit finding A).
       // ignore: prefer_initializing_formals
       _bridge = bridge,
       // Keep the reporter private while allowing test-only injection.
       // ignore: prefer_initializing_formals
       _errors = errors ?? ApplicationErrorReporter();

  final BookmarkRepository _bookmarks;
  final ConnectionStateBridge? _bridge;
  final ApplicationErrorReporter _errors;

  List<ConnectionServer> _servers = const [];
  ConnectionListLoad _load = ConnectionListLoad.idle;
  final _watches = <String, StreamSubscription<ServerStatus>>{};
  StreamSubscription<RecoveryFailedEvent>? _recovery;
  int _generation = 0;
  bool _engineStopped = false;
  bool _disposed = false;

  /// The servers the app holds references to, in the store's own order (M5's
  /// sidebar owns grouping and reordering).
  List<ConnectionServer> get servers => _servers;

  ConnectionListLoad get load => _load;

  /// Reads the bookmark store and starts watching every listed server.
  ///
  /// Re-runnable: the surface reloads on each open so the list reflects the
  /// store rather than a cached snapshot. A superseded load drops itself on
  /// the generation counter (09 §3.1).
  Future<void> loadServers() async {
    if (_disposed) return;
    final generation = ++_generation;
    _load = ConnectionListLoad.loading;
    notifyListeners();

    final List<Bookmark> bookmarks;
    try {
      bookmarks = await _bookmarks.load();
    } on Object catch (error, stackTrace) {
      _errors.report(error, stackTrace);
      if (_disposed || generation != _generation) return;
      // Rows stay as they were: the view renders the failure with a retry,
      // and a later successful reload replaces them.
      _load = ConnectionListLoad.failed;
      notifyListeners();
      return;
    }
    if (_disposed || generation != _generation) return;

    _servers = List.unmodifiable(_serversOf(bookmarks));
    _load = ConnectionListLoad.ready;
    _restartWatches();
    notifyListeners();
  }

  /// The bookmarks that name a server the pool can hold a reference for: an
  /// embedded endpoint identity (04 §2.1), whose bookmark id is the serverId
  /// (03 §3.5). A `serverConfigId` reference carries no endpoint in
  /// Poltergeist (04 §2.2), and a workspace or saved-sync endpoint belongs to
  /// its location rather than to a serverId of its own — M5's sidebar owns
  /// those rows.
  static Iterable<ConnectionServer> _serversOf(Iterable<Bookmark> bookmarks) {
    return [
      for (final bookmark in bookmarks)
        if (bookmark.server?.identity case final identity?)
          ConnectionServer(
            serverId: bookmark.id,
            label: bookmark.label,
            host: identity.host,
            port: identity.port,
            username: identity.username,
          ),
    ];
  }

  /// Re-subscribes both lanes for the current rows. Watching replays current
  /// state first (03 §3.2), so a reload loses no truth and a state that
  /// changed while nothing watched arrives on the new subscription.
  void _restartWatches() {
    _cancelWatches();
    final bridge = _bridge;
    if (bridge == null || _engineStopped) return;

    for (final server in _servers) {
      _watch(server.serverId, bridge);
      // A refused watch means the engine is gone and its handler already
      // tore both lanes down: there is nothing left to subscribe.
      if (_engineStopped) return;
    }
    _recovery = bridge.recoveryFailures.listen(
      _onRecoveryFailure,
      onError: _onStreamError,
      onDone: _onEngineStopped,
    );
  }

  void _watch(String serverId, ConnectionStateBridge bridge) {
    final Stream<ServerStatus> statuses;
    try {
      statuses = bridge.watchServer(serverId);
    } on Object catch (error, stackTrace) {
      // A dead engine refuses a new watch synchronously rather than handing
      // out a stream that never emits (EngineClient's fail-fast contract).
      _errors.report(error, stackTrace);
      _onEngineStopped();
      return;
    }

    _watches[serverId] = statuses.listen(
      (status) => _onStatus(serverId, status),
      onError: _onStreamError,
      onDone: _onEngineStopped,
    );
  }

  void _onStatus(String serverId, ServerStatus status) {
    if (_disposed) return;
    _replace(serverId, (server) => server._withStatus(status));
  }

  void _onRecoveryFailure(RecoveryFailedEvent event) {
    if (_disposed) return;

    // Only the pane-scoped lane adds anything here: a pool-level terminal
    // failure also lands on the status lane as its detail, carrying the same
    // summary (03 §3.2's teardown fan-out), so rendering both would repeat
    // one sentence twice.
    final paneTabId = event.paneTabId;
    if (paneTabId == null) return;

    final failure = PaneFailure(
      paneTabId: paneTabId,
      message: event.error.message,
    );
    _replace(event.serverId, (server) => server._withPaneFailure(failure));
  }

  /// Applies [update] to one listed server. An id the list does not hold is
  /// ignored: an ad-hoc session id belongs to the surface that minted it, and
  /// this list is the store's.
  void _replace(
    String serverId,
    ConnectionServer Function(ConnectionServer server) update,
  ) {
    final index = _servers.indexWhere((server) => server.serverId == serverId);
    if (index < 0) return;

    final next = List<ConnectionServer>.of(_servers);
    next[index] = update(next[index]);
    _servers = List.unmodifiable(next);
    notifyListeners();
  }

  /// The engine is gone: its lanes closed, or it refused a watch. Live truth
  /// is unavailable, and a stale "connected" row would be a lie — the rows
  /// themselves stay, because the app still holds the references.
  void _onEngineStopped() {
    if (_disposed || _engineStopped) return;
    _engineStopped = true;
    _cancelWatches();
    _servers = List.unmodifiable([
      for (final server in _servers) server._withoutTruth(),
    ]);
    notifyListeners();
  }

  void _onStreamError(Object error, StackTrace stackTrace) {
    if (_disposed) return;
    // A faulting diagnostic lane must not blank the list: report it and keep
    // the last truth (the engine's lanes are broadcast, so one fault is
    // local to this listener).
    _errors.report(error, stackTrace);
  }

  void _cancelWatches() {
    for (final subscription in _watches.values) {
      unawaited(subscription.cancel());
    }
    _watches.clear();
    unawaited(_recovery?.cancel());
    _recovery = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Invalidate an in-flight load so its completion drops itself.
    _generation++;
    _cancelWatches();
    super.dispose();
  }
}
