import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller.dart';
import '../../services/pane_location.dart';
import '../../services/quick_connect_address.dart';
import '../../services/workspace_controller.dart';

/// One server's presence in the panes: how far its bind got, and how many
/// tabs show it — the SERVERS row's fallback truth for ids the connection
/// list does not watch (catalog servers, Quick Connect sessions).
@immutable
final class SidebarPaneBinding {
  const SidebarPaneBinding({required this.state, required this.tabs});

  final ServerConnectionState state;
  final int tabs;

  @override
  bool operator ==(Object other) =>
      other is SidebarPaneBinding && other.state == state && other.tabs == tabs;

  @override
  int get hashCode => Object.hash(state, tabs);
}

/// A live Quick Connect session (10 §5's italic SERVERS row): the pane's
/// adhoc binding and the folder its first tab shows — what "Save to
/// Servers…" captures.
@immutable
final class SidebarAdhocSession {
  const SidebarAdhocSession({required this.bookmark, this.path});

  final Bookmark bookmark;
  final String? path;

  @override
  bool operator ==(Object other) =>
      other is SidebarAdhocSession &&
      other.bookmark.id == bookmark.id &&
      other.path == path;

  @override
  int get hashCode => Object.hash(bookmark.id, path);
}

/// What the panes tell the sidebar (10 §5): the active pane's location —
/// the selection pill and "Add Current Folder to Favorites" read it — the
/// live Quick Connect sessions SERVERS lists in italics, and every bound
/// server's binding.
///
/// A value: the view recomputes it on every pane notification and only
/// repaints when it changed, so a selection change in a listing (which
/// notifies the strips too) never rebuilds the rail.
@immutable
final class SidebarPaneFacts {
  const SidebarPaneFacts({
    this.activeLocation,
    this.activeRemote,
    this.adhoc = const [],
    this.bound = const {},
  });

  static const empty = SidebarPaneFacts();

  final PaneLocation? activeLocation;

  /// The active tab's server binding, when it browses one.
  final Bookmark? activeRemote;

  /// Live Quick Connect sessions, one per adhoc id, in pane order.
  final List<SidebarAdhocSession> adhoc;

  /// serverId → the best binding any tab holds.
  final Map<String, SidebarPaneBinding> bound;

  @override
  bool operator ==(Object other) =>
      other is SidebarPaneFacts &&
      other.activeLocation == activeLocation &&
      other.activeRemote?.id == activeRemote?.id &&
      listEquals(other.adhoc, adhoc) &&
      mapEquals(other.bound, bound);

  @override
  int get hashCode => Object.hash(
    activeLocation,
    activeRemote?.id,
    Object.hashAll(adhoc),
    Object.hashAllUnordered(
      bound.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

/// Reads [workspace]'s two strips into [SidebarPaneFacts].
SidebarPaneFacts sidebarPaneFactsOf(WorkspaceController workspace) {
  final active = workspace.activeTabController;
  final adhoc = <String, SidebarAdhocSession>{};
  final states = <String, ServerConnectionState>{};
  final tabs = <String, int>{};
  for (final strip in [workspace.left, workspace.right]) {
    for (final tab in strip.tabs) {
      final controller = tab.controller;
      final remote = controller.remoteBookmark;
      if (remote == null) continue;
      final state = _bindState(controller.phase);
      if (state == null) continue;
      final id = remote.id;
      tabs[id] = (tabs[id] ?? 0) + 1;
      final previous = states[id];
      if (previous == null || _rank(state) > _rank(previous)) {
        states[id] = state;
      }
      // Only a live, browsing session is worth saving — a pending
      // Quick Connect that never authenticated has nothing to keep.
      if (id.startsWith(quickConnectAdhocIdPrefix) &&
          controller.phase == PanePhase.browsing) {
        adhoc.putIfAbsent(
          id,
          () => SidebarAdhocSession(
            bookmark: remote,
            path: controller.location?.path,
          ),
        );
      }
    }
  }
  return SidebarPaneFacts(
    activeLocation: active?.location,
    activeRemote: active?.remoteBookmark,
    adhoc: List.unmodifiable(adhoc.values),
    bound: Map.unmodifiable({
      for (final entry in states.entries)
        entry.key: SidebarPaneBinding(
          state: entry.value,
          tabs: tabs[entry.key]!,
        ),
    }),
  );
}

ServerConnectionState? _bindState(PanePhase phase) => switch (phase) {
  PanePhase.browsing => ServerConnectionState.connected,
  PanePhase.connectingRemote => ServerConnectionState.connecting,
  // A restored tab holds no channel yet; an unbound one holds nothing.
  PanePhase.restored || PanePhase.unbound || PanePhase.openingLocal => null,
};

int _rank(ServerConnectionState state) =>
    state == ServerConnectionState.connected ? 1 : 0;

/// Séance's filter rule (server_filter.dart) over any row's haystack:
/// whitespace-split terms, every term must occur, case-insensitive. An
/// empty query matches everything.
bool sidebarQueryMatches(String haystack, String query) {
  final terms = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((term) => term.isEmpty);
  if (terms.isEmpty) return true;
  final lower = haystack.toLowerCase();
  return terms.every(lower.contains);
}

/// [path] without trailing separators (the root keeps its own), so a
/// favorite saved as `/srv/data/` still marks the pane at `/srv/data`.
String sidebarComparablePath(String path) {
  var result = path;
  while (result.length > 1 &&
      (result.endsWith('/') || result.endsWith(r'\')) &&
      !RegExp(r'^[A-Za-z]:[\\/]$').hasMatch(result)) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

/// [path] relative to [home] the way a shell prints it (`~`,
/// `~/Documents`), or [path] itself when it lies outside [home] or no
/// home is known. The compact Home's location lines use it: an absolute
/// app-storage path is noise on a phone.
String sidebarHomeRelativePath(String path, String? home) {
  if (home == null || home.isEmpty) return path;
  final base = sidebarComparablePath(home);
  final here = sidebarComparablePath(path);
  final separator = base.contains(r'\') ? r'\' : '/';
  // A home at a root would make every path "~": not a home worth naming.
  if (base.endsWith(separator)) return path;
  if (here == base) return '~';
  if (!here.startsWith('$base$separator')) return path;
  return '~$separator${here.substring(base.length + 1)}';
}

/// `user@host`, with the port only when it is not SSH's 22 (10 §4's
/// address grammar) and an IPv6 literal bracketed so the port reads as
/// one. The compact Home's server lines spell the endpoint with it.
String sidebarEndpointText({
  required String username,
  required String host,
  required int port,
}) {
  final address = port == _sshPort
      ? host
      : (host.contains(':') ? '[$host]:$port' : '$host:$port');
  return username.isEmpty ? address : '$username@$address';
}

const _sshPort = 22;
