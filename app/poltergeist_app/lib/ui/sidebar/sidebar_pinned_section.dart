part of 'sidebar_view.dart';

/// Whether [bookmark] is a remote favorite the user pinned: PINNED lists
/// it and FAVORITES leaves it out (D33). Only a server's row pins, so a
/// stray id on another kind never hides it.
bool _pinnedFavorite(_SidebarData data, Bookmark bookmark) =>
    _isServerKind(bookmark) && data.controller.isPinned(bookmark.id);

/// One PINNED row: an account server or a remote favorite, drawn with
/// the row it has in its own section.
sealed class _PinnedEntry {
  const _PinnedEntry();

  String get id;
  String get label;

  /// Counts the row against the filter ([_SidebarData.countRow]); true
  /// when it shows.
  bool shows(_SidebarData data);

  Widget row(_SidebarData data);

  ServerStatus? status(_SidebarData data);
}

final class _PinnedServer extends _PinnedEntry {
  const _PinnedServer(this.server);

  final ServerConfig server;

  @override
  String get id => server.id;

  @override
  String get label => server.label;

  @override
  bool shows(_SidebarData data) => _catalogShows(data, server);

  @override
  Widget row(_SidebarData data) => _CatalogServerRow(
    key: ValueKey('sidebar.catalog.row.${server.id}'),
    data: data,
    server: server,
    depth: 0,
  );

  @override
  ServerStatus? status(_SidebarData data) => _liveStatus(data, server.id);
}

final class _PinnedFavorite extends _PinnedEntry {
  const _PinnedFavorite(this.bookmark);

  final Bookmark bookmark;

  @override
  String get id => bookmark.id;

  @override
  String get label => bookmark.label;

  @override
  bool shows(_SidebarData data) => _favoriteShows(data, bookmark);

  @override
  Widget row(_SidebarData data) => _SavedServerRow(
    key: ValueKey('sidebar.favorite.${bookmark.id}'),
    data: data,
    bookmark: bookmark,
    placement: _SavedRowPlacement.pinned,
    group: null,
    depth: 0,
  );

  @override
  ServerStatus? status(_SidebarData data) => _savedLive(data, bookmark).status;
}

/// PINNED's one order for the mix: by label with case folded, then by
/// id, the account catalog's own rule. A shortlist that sorted by kind or
/// by when each pin landed would reshuffle itself under the user.
int _pinnedOrder(_PinnedEntry a, _PinnedEntry b) {
  final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
  return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
}

/// PINNED (10 §5's "pinned servers come first", D33): the servers the
/// user pinned, the shared account's and the remote favorites alike,
/// first in the rail as Séance lists it, in [_pinnedOrder]. A pinned row
/// leaves the section it files under (its group's count drops with it)
/// rather than showing twice, and keeps the row it has there: the live
/// dot, ring, accent, second line and verbs. A remote favorite's row
/// neither drags nor takes drops here: PINNED's order is by label, so
/// there is no place in it to move to, and Move to Group in its menu
/// still refiles it. Built before every other section, so the filter
/// counts its rows first and Enter's first match reads the rail top to
/// bottom. Drawn only while one is listed, like Séance's.
List<Widget> _pinnedSection(_SidebarData data) {
  final controller = data.controller;
  final pinned = <_PinnedEntry>[
    for (final server in data.view.catalog?.servers ?? const <ServerConfig>[])
      if (controller.isPinned(server.id)) _PinnedServer(server),
    for (final bookmark in controller.bookmarks)
      if (_pinnedFavorite(data, bookmark)) _PinnedFavorite(bookmark),
  ]..sort(_pinnedOrder);
  if (pinned.isEmpty) return const [];

  final rows = <Widget>[];
  final filtered = <_PinnedEntry>[];
  for (final entry in pinned) {
    if (entry.shows(data)) {
      rows.add(entry.row(data));
    } else {
      filtered.add(entry);
    }
  }
  final sectionKey = SidebarCollapseKeys.section(SidebarSection.pinned);
  final collapsed = data.collapsed(sectionKey);
  final hidden = _hiddenLive(data, [
    for (final entry in collapsed ? pinned : filtered) entry.status(data),
  ]);
  if (rows.isEmpty && hidden == null) return const [];
  return [
    SidebarSectionHeader(
      key: const ValueKey('sidebar.pinned.header'),
      headerKey: ValueKey('sidebar.section.$sectionKey'),
      title: data.l10n.sidebarPinnedSection,
      count: pinned.length,
      collapsed: collapsed,
      status: hidden?.dot,
      statusLabel: hidden?.label,
      onToggle: () => controller.toggleCollapsed(sectionKey),
    ),
    if (!collapsed) ...rows,
  ];
}
