part of 'sidebar_view.dart';

/// FAVORITES takes every bookmark kind (10 §5, D33), so a drop of any
/// bookmark reorders or refiles there.
bool _anyBookmark(Bookmark bookmark) => true;

/// FAVORITES (10 §5, D33): every bookmark kind (local folders, remote
/// locations, workspaces, and saved syncs) in the store's one user
/// order. Loose favorites first, then each named group as a nested
/// disclosure row with its members indented, a group holding any mix of
/// kinds. A pinned remote favorite lists in PINNED instead, and its
/// group counts it no longer; a group left with nothing to show draws
/// no header. Drops still resolve against the store by id, so a hidden
/// pinned member between two rows only keeps its place. The empty
/// state offers Desktop, Documents, and Downloads as one click (never
/// seeded silently, because favorites sync to other devices) and the
/// ssh_config import, whose hosts land here; it waits for a store that
/// holds no favorite at all, pinned or not.
List<Widget> _favoritesSection(_SidebarData data) {
  final l10n = data.l10n;
  final view = data.view;
  final controller = data.controller;
  final context = data.context;
  final sectionKey = SidebarCollapseKeys.section(SidebarSection.favorites);

  final body = <Widget>[];
  var count = 0;
  var pinned = 0;
  final sections = controller.sections;
  // Remote favorites out of view without a drawn group to speak for
  // them (the filter hid them, or their whole group): the section's
  // header shows their live state (D33).
  final hiddenLoose = <Bookmark>[];

  final loading =
      (controller.load == SidebarLoad.idle ||
          controller.load == SidebarLoad.loading) &&
      sections.isEmpty;
  final failed = controller.load == SidebarLoad.failed && sections.isEmpty;

  if (loading && !data.filtering) {
    body.add(
      Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: Semantics(
            label: l10n.connectionsLoading,
            container: true,
            child: const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
    );
  } else if (failed && !data.filtering) {
    body.add(
      _SidebarHint(
        text: l10n.connectionsLoadFailed,
        presentation: view.presentation,
        action: TextButton(
          key: const ValueKey('sidebar.retry'),
          onPressed: () => unawaited(controller.reload()),
          child: Text(l10n.connectionRetry),
        ),
      ),
    );
  } else {
    // Named groups, in the store's order, then the ones New Group… made
    // that hold nothing yet.
    final groups = <({String name, String key, List<Bookmark> members})>[];
    for (final section in sections) {
      final members = [
        for (final bookmark in section.bookmarks)
          if (!_pinnedFavorite(data, bookmark)) bookmark,
      ];
      pinned += section.bookmarks.length - members.length;
      if (section.name == null) {
        count += members.length;
        for (final bookmark in members) {
          if (_favoriteShows(data, bookmark)) {
            body.add(_favoriteRow(data, bookmark, group: null, depth: 0));
          } else {
            hiddenLoose.add(bookmark);
          }
        }
        continue;
      }
      if (members.isEmpty) continue;
      groups.add((name: section.name!, key: section.key, members: members));
    }
    for (final pending in controller.pendingGroups) {
      groups.add((
        name: pending,
        key: serverGroupKey(pending),
        members: const [],
      ));
    }
    for (final group in groups) {
      count += group.members.length;
      final collapseKey = SidebarCollapseKeys.favoriteGroup(group.key);
      final rows = <Widget>[];
      final filtered = <Bookmark>[];
      for (final bookmark in group.members) {
        if (_favoriteShows(data, bookmark)) {
          rows.add(_favoriteRow(data, bookmark, group: group.name, depth: 1));
        } else {
          filtered.add(bookmark);
        }
      }
      if (data.filtering && rows.isEmpty) {
        hiddenLoose.addAll(filtered);
        continue;
      }
      final collapsed = data.collapsed(collapseKey);
      final hiddenDot = _hiddenLiveDot(
        data,
        _favoriteStatuses(data, collapsed ? group.members : filtered),
      );
      body.add(
        _SidebarDropZone(
          key: ValueKey('sidebar.group.$collapseKey'),
          planner: (payload, _) =>
              _regroupPlan(
                view,
                payload,
                group: group.name,
                accepts: _anyBookmark,
              ) ??
              _addFavoritePlan(
                context,
                view,
                payload,
                indicator: SidebarDropIndicator.into,
                group: group.name,
              ),
          builder: (indicator) => SidebarSectionHeader(
            headerKey: ValueKey('sidebar.section.$collapseKey'),
            nested: true,
            title: group.name,
            count: group.members.length,
            collapsed: collapsed,
            status: hiddenDot,
            dropHighlight: indicator != SidebarDropIndicator.none,
            onToggle: () => controller.toggleCollapsed(collapseKey),
          ),
        ),
      );
      if (collapsed) continue;
      body.addAll(rows);
      if (group.members.isEmpty) {
        body.add(
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8),
            child: _SidebarHint(
              text: l10n.sidebarGroupEmpty,
              presentation: view.presentation,
            ),
          ),
        );
      }
    }

    if (count == 0 &&
        pinned == 0 &&
        controller.pendingGroups.isEmpty &&
        !data.filtering) {
      body.add(data.home ? _homeEmptyFavorites(data) : _emptyFavorites(data));
    }
  }

  final collapsed = data.collapsed(sectionKey);
  final hiddenDot = _hiddenLiveDot(
    data,
    _favoriteStatuses(
      data,
      collapsed
          ? [
              for (final bookmark in controller.bookmarks)
                if (!_pinnedFavorite(data, bookmark)) bookmark,
            ]
          : hiddenLoose,
    ),
  );
  // A filter that hides every row drops the section, unless a live
  // server is among the hidden: its header stays to say so.
  if (data.filtering && body.isEmpty && hiddenDot == null) return const [];

  // Home shows no folder to add (D32 §9): its header keeps no "+".
  final addCurrent =
      !data.home &&
          data.canAddCurrentFolder &&
          data.facts.activeLocation is LocalPaneLocation
      ? () => unawaited(data.state._addCurrentFolder(data))
      : null;
  return [
    _SidebarDropZone(
      key: const ValueKey('sidebar.favorites.header'),
      planner: (payload, _) =>
          _regroupPlan(view, payload, group: null, accepts: _anyBookmark) ??
          _addFavoritePlan(
            context,
            view,
            payload,
            indicator: SidebarDropIndicator.into,
          ),
      builder: (indicator) => SidebarSectionHeader(
        headerKey: ValueKey('sidebar.section.$sectionKey'),
        title: l10n.sidebarFavoritesSection,
        count: count,
        collapsed: collapsed,
        status: hiddenDot,
        dropHighlight: indicator != SidebarDropIndicator.none,
        onToggle: () => controller.toggleCollapsed(sectionKey),
        onAdd: addCurrent,
        addKey: const ValueKey('sidebar.favorites.add'),
        addTooltip: l10n.sidebarFavoritesAdd,
      ),
    ),
    if (!collapsed) ...body,
  ];
}

/// The live states of the remote favorites among [bookmarks].
Iterable<ServerStatus?> _favoriteStatuses(
  _SidebarData data,
  Iterable<Bookmark> bookmarks,
) => [
  for (final bookmark in bookmarks)
    if (_isServerKind(bookmark)) _savedLive(data, bookmark).status,
];

bool _favoriteShows(_SidebarData data, Bookmark bookmark) => data.countRow(
  _isServerKind(bookmark)
      ? _remoteHaystack(bookmark)
      : [bookmark.label, ?bookmark.localPath, ?bookmark.group].join(' '),
  open: data.view.onOpenFavorite == null
      ? null
      : () => data.view.onOpenFavorite!(bookmark, SidebarOpenAction.plain),
);

/// Home's empty state (D32 §9): what FAVORITES keeps and where a folder
/// is added from, with the standard-folders offer when the platform has
/// any of the three (a phone's app storage usually has none), and D22's
/// adoption beat, the ssh_config import.
Widget _homeEmptyFavorites(_SidebarData data) {
  final l10n = data.l10n;
  final view = data.view;
  final offered = data.standardFolders;
  return _HomeEmptyState(
    key: const ValueKey('sidebar.favorites.empty'),
    icon: Icons.star_outline,
    title: l10n.compactHomeFavoritesEmptyTitle,
    body: l10n.compactHomeFavoritesEmptyBody,
    actions: [
      if (offered.isNotEmpty)
        FilledButton.tonalIcon(
          key: const ValueKey('sidebar.favorites.addStandard'),
          onPressed: () =>
              unawaited(_addFolders(data.context, data.view, offered)),
          icon: const Icon(Icons.add),
          label: Text(l10n.sidebarFavoritesAddStandard),
        ),
      if (view.onImportSshConfig != null)
        OutlinedButton.icon(
          key: const ValueKey('sidebar.importSshConfig'),
          onPressed: view.onImportSshConfig,
          icon: const Icon(Icons.download_outlined),
          label: Text(l10n.sidebarImportSshConfig),
        ),
    ],
  );
}

/// The empty state: the one-click standard folders (only those that
/// exist), else a hint — and either way a drop target for folders. D22's
/// adoption beat rides here too: an empty list is the moment the
/// ssh_config import earns its keep, and the hosts it imports land in
/// FAVORITES.
Widget _emptyFavorites(_SidebarData data) {
  final l10n = data.l10n;
  final view = data.view;
  final context = data.context;
  final offered = data.standardFolders;
  return _SidebarDropZone(
    key: const ValueKey('sidebar.favorites.empty'),
    planner: (payload, _) => _addFavoritePlan(
      context,
      view,
      payload,
      indicator: SidebarDropIndicator.into,
    ),
    builder: (indicator) => DecoratedBox(
      decoration: BoxDecoration(
        color: indicator == SidebarDropIndicator.none
            ? null
            : PoltergeistChrome.of(context).hoverFill,
      ),
      child: _SidebarHint(
        text: l10n.sidebarFavoritesEmpty,
        presentation: view.presentation,
        action: offered.isEmpty && view.onImportSshConfig == null
            ? null
            : Wrap(
                children: [
                  if (offered.isNotEmpty)
                    TextButton.icon(
                      key: const ValueKey('sidebar.favorites.addStandard'),
                      style: _hintButtonStyle,
                      onPressed: () =>
                          unawaited(_addFolders(context, view, offered)),
                      icon: const Icon(Icons.add, size: 14),
                      label: Text(l10n.sidebarFavoritesAddStandard),
                    ),
                  if (view.onImportSshConfig != null)
                    TextButton.icon(
                      key: const ValueKey('sidebar.importSshConfig'),
                      style: _hintButtonStyle,
                      onPressed: view.onImportSshConfig,
                      icon: const Icon(Icons.download_outlined, size: 14),
                      label: Text(l10n.sidebarImportSshConfig),
                    ),
                ],
              ),
      ),
    ),
  );
}

/// The compact buttons under a rail hint.
final ButtonStyle _hintButtonStyle = TextButton.styleFrom(
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: 6),
);

/// One FAVORITES row: a remote location is a server's row (its live dot
/// and connection verbs), every other kind a place's.
Widget _favoriteRow(
  _SidebarData data,
  Bookmark bookmark, {
  required String? group,
  required int depth,
}) => _isServerKind(bookmark)
    ? _SavedServerRow(
        key: ValueKey('sidebar.favorite.${bookmark.id}'),
        data: data,
        bookmark: bookmark,
        group: group,
        depth: depth,
      )
    : _FavoriteRow(
        key: ValueKey('sidebar.favorite.${bookmark.id}'),
        data: data,
        bookmark: bookmark,
        group: group,
        depth: depth,
      );

/// One favorite: its kind glyph (tinted by the favorite's colour), the
/// label, the path in the tooltip, and both halves of the drag contract
/// (reorder/regroup as a bookmark; a folder favorite also takes pane rows
/// dropped into it, and adds dragged folders at its edges).
class _FavoriteRow extends StatelessWidget {
  const _FavoriteRow({
    required this.data,
    required this.bookmark,
    required this.group,
    required this.depth,
    super.key,
  });

  final _SidebarData data;
  final Bookmark bookmark;
  final String? group;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final l10n = data.l10n;
    final view = data.view;
    final open = view.onOpenFavorite;
    final accent = serverAccent(context, ServerTint(named: bookmark.color));
    final mark = data.list
        ? _HomeDisc(
            glyph: _favoriteIcon(bookmark),
            tint: accent?.line ?? _homeFavoriteTint(context, bookmark),
          )
        : _placeMark(context, _favoriteIcon(bookmark), accent: accent);
    final localPath = bookmark.kind == BookmarkKind.localFolder
        ? bookmark.localPath
        : null;
    final subtitle = _favoriteLine(data, bookmark);

    Widget row(SidebarDropIndicator indicator) => SidebarRow(
      mark: mark,
      title: bookmark.label,
      subtitle: subtitle,
      semanticLabel: data.comfortable
          ? _spokenLabel([bookmark.label, subtitle])
          : null,
      depth: depth,
      dropIndicator: indicator,
      tooltip: switch (bookmark.kind) {
        BookmarkKind.localFolder => bookmark.localPath,
        BookmarkKind.workspace => l10n.sidebarKindWorkspace,
        BookmarkKind.savedSync => l10n.sidebarKindSavedSync,
        BookmarkKind.remotePath => bookmark.remotePath,
      },
      selected: data.selectionKey == _favoriteSelectionKey(bookmark.id),
      onActivate: open == null
          ? null
          : (how) => open(bookmark, _openActionFor(how)),
      menuEntries: () => _favoriteMenu(context, data, bookmark),
    );

    return _SidebarDropZone(
      planner: (payload, fraction) {
        final reorder = _reorderPlan(
          view,
          payload,
          fraction,
          target: bookmark,
          group: group,
          accepts: _anyBookmark,
        );
        if (reorder != null || payload is Bookmark) return reorder;
        // The middle half of a folder favorite is INTO it; its edges add
        // the dragged folder beside it (Finder's sidebar split).
        if (localPath != null && fraction >= 0.25 && fraction <= 0.75) {
          final into = _transferPlan(
            context,
            view,
            payload,
            destinationDir: localPath,
          );
          if (into != null) return into;
        }
        final before = fraction < 0.5;
        return _addFavoritePlan(
          context,
          view,
          payload,
          indicator: before
              ? SidebarDropIndicator.before
              : SidebarDropIndicator.after,
          group: group,
          beforeId: before ? null : bookmark.id,
          afterId: before ? bookmark.id : null,
        );
      },
      builder: (indicator) => _bookmarkDraggable(
        context,
        bookmark: bookmark,
        mark: mark,
        child: row(indicator),
      ),
    );
  }
}

/// A favorite's Home disc tint by kind when it has no colour of its own:
/// a folder in the browser's folder tint; a workspace or a saved sync —
/// two places at once — in the secondary role, apart from the servers'.
Color _homeFavoriteTint(BuildContext context, Bookmark bookmark) {
  final colors = Theme.of(context).colorScheme;
  return switch (bookmark.kind) {
    BookmarkKind.localFolder || BookmarkKind.remotePath => colors.primary,
    BookmarkKind.workspace || BookmarkKind.savedSync => colors.secondary,
  };
}

/// A favorite's second line (D32 §9, D33): where it opens — a folder's
/// path home-relative, a saved sync's two sides — or, for a workspace
/// (two panes, no single place), its kind.
String? _favoriteLine(_SidebarData data, Bookmark bookmark) {
  final l10n = data.l10n;
  switch (bookmark.kind) {
    case BookmarkKind.localFolder:
      final path = bookmark.localPath;
      return path == null
          ? null
          : sidebarHomeRelativePath(path, data.localHome);
    case BookmarkKind.workspace:
      return l10n.sidebarKindWorkspace;
    case BookmarkKind.savedSync:
      final sync = bookmark.sync;
      if (sync == null) return l10n.sidebarKindSavedSync;
      return l10n.compactHomeSyncRoute(
        _locationLine(data, sync.source),
        _locationLine(data, sync.destination),
      );
    case BookmarkKind.remotePath:
      final path = bookmark.remotePath;
      final server = bookmark.server;
      if (path == null) return null;
      return server == null
          ? path
          : _locationLine(data, BookmarkLocation(server: server, path: path));
  }
}

IconData _favoriteIcon(Bookmark bookmark) => switch (bookmark.kind) {
  BookmarkKind.localFolder =>
    bookmark.icon != null
        ? serverIconData(bookmark.icon)
        : Icons.folder_outlined,
  BookmarkKind.remotePath => serverIconData(bookmark.icon),
  BookmarkKind.workspace => Icons.space_dashboard_outlined,
  BookmarkKind.savedSync => Icons.sync_alt,
};

/// A favorite's verbs: open (a workspace replaces both panes, so it has
/// no pane-target variants — its second verb is the re-capture), then
/// the store edits.
List<SidebarMenuEntry> _favoriteMenu(
  BuildContext context,
  _SidebarData data,
  Bookmark bookmark,
) {
  final l10n = data.l10n;
  final view = data.view;
  final open = view.onOpenFavorite;
  final isWorkspace = bookmark.kind == BookmarkKind.workspace;
  return [
    ..._openVerbs(
      l10n,
      open == null ? null : (action) => open(bookmark, action),
      modifiers: !isWorkspace,
    ),
    if (isWorkspace && view.onUpdateWorkspace != null)
      SidebarMenuAction(
        key: const ValueKey('sidebar.menu.updateWorkspace'),
        label: l10n.sidebarWorkspaceUpdate,
        onSelected: () => view.onUpdateWorkspace!(bookmark),
      ),
    const SidebarMenuDivider(),
    ..._editVerbs(context, data, bookmark),
  ];
}

/// Rename, Move to Group ▸, Delete — shared by favorites and saved
/// servers (both are bookmarks in the one store).
List<SidebarMenuEntry> _editVerbs(
  BuildContext context,
  _SidebarData data,
  Bookmark bookmark,
) {
  final l10n = data.l10n;
  final view = data.view;
  // The loaded sections carry every group name in the store's own order —
  // an async groupNames() read here would flash an empty submenu.
  final names = <String>[
    for (final section in data.controller.sections) ?section.name,
    for (final pending in data.controller.pendingGroups) pending,
  ];
  return [
    SidebarMenuAction(
      key: const ValueKey('sidebar.menu.rename'),
      label: l10n.sidebarRename,
      onSelected: () => unawaited(_renameBookmark(context, view, bookmark)),
    ),
    SidebarMenuSubmenu(
      key: const ValueKey('sidebar.menu.moveToGroup'),
      label: l10n.sidebarMoveToGroup,
      children: [
        SidebarMenuAction(
          key: const ValueKey('sidebar.menu.ungroup'),
          label: l10n.sidebarNoGroup,
          onSelected: () => unawaited(_dropBookmark(view, bookmark, null)),
        ),
        for (final name in names)
          SidebarMenuAction(
            label: name,
            onSelected: () => unawaited(_dropBookmark(view, bookmark, name)),
          ),
        const SidebarMenuDivider(),
        SidebarMenuAction(
          key: const ValueKey('sidebar.menu.newGroup'),
          label: l10n.sidebarNewGroup,
          onSelected: () => unawaited(_newGroupFor(context, view, bookmark)),
        ),
      ],
    ),
    const SidebarMenuDivider(),
    SidebarMenuAction(
      key: const ValueKey('sidebar.menu.delete'),
      label: l10n.sidebarDelete,
      onSelected: () => unawaited(_deleteBookmark(context, view, bookmark)),
    ),
  ];
}
