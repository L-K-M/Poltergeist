part of 'sidebar_view.dart';

/// A remote location (a remotePath bookmark): a server's row, listed
/// under FAVORITES with the other bookmark kinds (10 §5, D33).
bool _isServerKind(Bookmark bookmark) =>
    bookmark.kind == BookmarkKind.remotePath;

/// One SERVERS group: the shared account's catalog servers (by label)
/// under one disclosure row.
final class _ServerGroup {
  _ServerGroup(this.name);

  final String name;
  final catalog = <ServerConfig>[];

  int get length => catalog.length;
}

/// SERVERS (10 §5, D33): live Quick Connect sessions (italic, top), then
/// the shared account's server list, grouped by Séance's rules — each
/// row carrying its live state as its one dot. Saved remote locations
/// are favorites and list under FAVORITES with their own dots, so
/// without the shared account this section holds only live sessions.
List<Widget> _serversSection(_SidebarData data) {
  final l10n = data.l10n;
  final view = data.view;
  final controller = data.controller;
  final sectionKey = SidebarCollapseKeys.section(SidebarSection.servers);

  final loose = _ServerGroup('');
  final groups = <String, _ServerGroup>{};
  final catalog = view.catalog?.servers ?? const <ServerConfig>[];
  // A pinned server leaves its group for PINNED rather than showing
  // twice (Séance's rule): its group's count drops with it.
  final pinned = _ServerGroup('');
  for (final server in catalog) {
    if (controller.isPinned(server.id)) {
      pinned.catalog.add(server);
      continue;
    }
    final name = normalizeServerGroup(server.group);
    (name == null
            ? loose
            : groups.putIfAbsent(
                serverGroupKey(name),
                () => _ServerGroup(name),
              ))
        .catalog
        .add(server);
  }
  final remoteFavorites = controller.bookmarks.where(_isServerKind).toList();
  // A saved endpoint is the session's saved row: once "Save to
  // Favorites…" (or the pane's save bar) lands, the italic duplicate
  // retires.
  final saved = <String>{
    for (final bookmark in remoteFavorites) ?_endpointKeyOf(bookmark),
    for (final server in catalog)
      _endpointKey(server.host, server.port, server.username),
  };
  final sessions = [
    for (final session in data.facts.adhoc)
      if (!saved.contains(_endpointKeyOf(session.bookmark))) session,
  ];

  final total = sessions.length + catalog.length - pinned.length;
  // The filter's threshold counts every server the rail lists, the
  // remote favorites included: without the shared account they are
  // the user's servers.
  data.serverCount = total + pinned.length + remoteFavorites.length;

  final body = <Widget>[];
  for (final session in sessions) {
    final bookmark = session.bookmark;
    if (!data.countRow(
      '${bookmark.label} ${sessionEndpointLabel(bookmark)}',
      open: view.onOpenFavorite == null
          ? null
          : () => view.onOpenFavorite!(bookmark, SidebarOpenAction.plain),
    )) {
      continue;
    }
    body.add(
      _AdhocRow(
        key: ValueKey('sidebar.adhoc.${bookmark.id}'),
        data: data,
        session: session,
      ),
    );
  }
  body.addAll(_serverRows(data, loose, depth: 0));

  final sortedKeys = groups.keys.toList()..sort();
  for (final key in sortedKeys) {
    final group = groups[key]!;
    final collapseKey = SidebarCollapseKeys.serverGroup(key);
    final rows = _serverRows(data, group, depth: 1);
    if (data.filtering && rows.isEmpty) continue;
    final collapsed = data.collapsed(collapseKey);
    // The account's groups take no bookmark drops: a catalog server's
    // group is edited in the server editor, and bookmarks file under
    // FAVORITES.
    body.add(
      SidebarSectionHeader(
        key: ValueKey('sidebar.group.$collapseKey'),
        headerKey: ValueKey('sidebar.section.$collapseKey'),
        nested: true,
        title: group.name,
        count: group.length,
        collapsed: collapsed,
        onToggle: () => controller.toggleCollapsed(collapseKey),
      ),
    );
    if (!collapsed) body.addAll(rows);
  }

  // Only a loaded store can say "none": mid-load or after a failed read
  // (FAVORITES carries that error) the empty copy would be a claim.
  final empty =
      total == 0 && !data.filtering && controller.load == SidebarLoad.ready;
  if (empty && data.home) {
    body.add(_homeEmptyServers(data));
  } else if (empty) {
    body.add(
      _SidebarHint(
        key: const ValueKey('sidebar.servers.empty'),
        // With the shared account SERVERS is its server list; without
        // it, the live sessions only.
        text: view.catalog == null
            ? l10n.sidebarServersEmpty
            : l10n.sidebarCatalogEmpty,
        presentation: view.presentation,
      ),
    );
  }
  if (data.filtering && body.isEmpty) return const [];

  final collapsed = data.collapsed(sectionKey);
  final VoidCallback? onAdd = view.onAddCatalogServer ?? view.onQuickConnect;
  return [
    ..._pinnedSection(data, pinned),
    SidebarSectionHeader(
      key: const ValueKey('sidebar.servers.header'),
      headerKey: ValueKey('sidebar.section.$sectionKey'),
      title: l10n.sidebarServersSection,
      count: total,
      collapsed: collapsed,
      onToggle: () => controller.toggleCollapsed(sectionKey),
      onAdd: onAdd,
      addKey: const ValueKey('sidebar.servers.add'),
      addTooltip: view.onAddCatalogServer != null
          ? l10n.sidebarServersAddNew
          : l10n.sidebarServersAddConnect,
    ),
    if (!collapsed) ...body,
  ];
}

/// PINNED (10 §5's "pinned servers come first", D33): the account's
/// servers the user pinned, by label, above SERVERS. Drawn only while one
/// is listed, like Séance's.
List<Widget> _pinnedSection(_SidebarData data, _ServerGroup pinned) {
  final rows = _serverRows(data, pinned, depth: 0);
  if (rows.isEmpty) return const [];
  final sectionKey = SidebarCollapseKeys.section(SidebarSection.pinned);
  final collapsed = data.collapsed(sectionKey);
  return [
    SidebarSectionHeader(
      key: const ValueKey('sidebar.pinned.header'),
      headerKey: ValueKey('sidebar.section.$sectionKey'),
      title: data.l10n.sidebarPinnedSection,
      count: pinned.length,
      collapsed: collapsed,
      onToggle: () => data.controller.toggleCollapsed(sectionKey),
    ),
    if (!collapsed) ...rows,
  ];
}

/// Home's empty SERVERS (D32 §9): an invitation to connect, with Quick
/// Connect as its button. The ssh_config import is FAVORITES' offer now,
/// where the hosts it imports land (D33).
Widget _homeEmptyServers(_SidebarData data) {
  final l10n = data.l10n;
  final view = data.view;
  return _HomeEmptyState(
    key: const ValueKey('sidebar.servers.empty'),
    icon: Icons.dns_outlined,
    title: l10n.compactHomeServersEmptyTitle,
    body: view.catalog == null
        ? l10n.compactHomeServersEmptyBody
        : l10n.compactHomeServersEmptyAccountBody,
    actions: [
      if (view.onQuickConnect != null)
        FilledButton.tonalIcon(
          key: const ValueKey('sidebar.servers.quickConnect'),
          onPressed: view.onQuickConnect,
          icon: const Icon(Icons.power_outlined),
          label: Text(l10n.sidebarAddQuickConnect),
        ),
    ],
  );
}

/// The filter haystack of a remote location's row: its name, endpoint,
/// landing path and group.
String _remoteHaystack(Bookmark bookmark) => [
  bookmark.label,
  ?_endpointKeyOf(bookmark),
  ?bookmark.remotePath,
  ?bookmark.group,
].join(' ');

List<Widget> _serverRows(
  _SidebarData data,
  _ServerGroup members, {
  required int depth,
}) {
  final view = data.view;
  return [
    for (final server in members.catalog)
      if (data.countRow(
        serverSearchHaystack(server),
        open: view.onOpenCatalogServer == null
            ? null
            : () => view.onOpenCatalogServer!(server, SidebarOpenAction.plain),
      ))
        _CatalogServerRow(
          key: ValueKey('sidebar.catalog.row.${server.id}'),
          data: data,
          server: server,
          depth: depth,
        ),
  ];
}

/// The endpoint of the active pane's Quick Connect session, if it shows one.
String? _activeAdhocEndpoint(_SidebarData data) {
  final remote = data.facts.activeRemote;
  if (remote == null || !remote.id.startsWith(quickConnectAdhocIdPrefix)) {
    return null;
  }
  if (data.facts.activeLocation is! RemotePaneLocation) return null;
  return _endpointKeyOf(remote);
}

String _endpointKey(String host, int port, String username) =>
    '$username@${host.toLowerCase()}:$port';

String? _endpointKeyOf(Bookmark bookmark) {
  final identity = bookmark.server?.identity;
  if (identity == null) return null;
  return _endpointKey(identity.host, identity.port, identity.username);
}

/// The live status a SERVERS row paints: the connection list's truth
/// (the pool's own lane) first, else what the panes' binding implies —
/// the connection list only watches saved servers with embedded
/// endpoints, so catalog servers and Quick Connect sessions read here.
ServerStatus? _liveStatus(_SidebarData data, String serverId) {
  for (final server in data.view.connections?.servers ?? const []) {
    if (server.serverId == serverId && server.status != null) {
      return server.status;
    }
  }
  final bound = data.facts.bound[serverId];
  return bound == null ? null : ServerStatus(bound.state);
}

/// The live Quick Connect session a saved row stands in for (10 §5):
/// "Save to Favorites…" leaves the session browsing under its adhoc id and
/// retires its italic row, so the saved row of the same endpoint paints
/// that session's status and its Disconnect drops it.
SidebarAdhocSession? _sessionSavedAs(_SidebarData data, Bookmark bookmark) {
  final key = _endpointKeyOf(bookmark);
  if (key == null) return null;
  for (final session in data.facts.adhoc) {
    if (_endpointKeyOf(session.bookmark) == key) return session;
  }
  return null;
}

ConnectionServer? _connectionOf(_SidebarData data, String serverId) {
  for (final server in data.view.connections?.servers ?? const []) {
    if (server.serverId == serverId) return server;
  }
  return null;
}

bool _isLive(ServerStatus? status) => switch (status?.state) {
  ServerConnectionState.connecting ||
  ServerConnectionState.connected ||
  ServerConnectionState.reconnecting => true,
  _ => false,
};

/// `×N` when a server shows in more than one tab (10 §5's trailing text).
String? _tabsText(_SidebarData data, String serverId) {
  final tabs = data.facts.bound[serverId]?.tabs ?? 0;
  return tabs > 1 ? data.l10n.sidebarTabCount(tabs) : null;
}

/// The hover glyph and menu verb that drop a live server's pool
/// reference.
SidebarRowAction? _disconnectAction(
  _SidebarData data,
  ConnectionServer server,
  bool live,
) {
  final disconnect = data.view.onDisconnect;
  if (disconnect == null || !live) return null;
  return SidebarRowAction(
    key: ValueKey('sidebar.row.disconnect.${server.serverId}'),
    icon: Icons.eject,
    tooltip: data.l10n.sidebarDisconnect,
    onPressed: () => disconnect(server),
  );
}

SidebarMenuEntry? _disconnectVerb(
  _SidebarData data,
  ConnectionServer server,
  bool live,
) {
  final disconnect = data.view.onDisconnect;
  if (disconnect == null) return null;
  return SidebarMenuAction(
    key: const ValueKey('sidebar.menu.disconnect'),
    label: data.l10n.sidebarDisconnect,
    onSelected: live ? () => disconnect(server) : null,
  );
}

/// A saved remote location (a remotePath bookmark), listed under
/// FAVORITES (D33): its badge, the live dot, the endpoint and any failure
/// in the tooltip, and the connection verbs beside the store edits.
class _SavedServerRow extends StatelessWidget {
  const _SavedServerRow({
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
    final id = bookmark.id;
    final own = _liveStatus(data, id);
    // The row's own connection outranks a saved session's; otherwise the
    // session it was saved from speaks for it.
    final session = _isLive(own) ? null : _sessionSavedAs(data, bookmark);
    final liveId = session?.bookmark.id ?? id;
    final status = session == null ? own : _liveStatus(data, liveId);
    final probe = view.probes?.statuses[id];
    final (:appearance, :dot) = _serverIndicator(
      context,
      l10n,
      status: status,
      probe: probe,
    );
    final blocked = appearance.glyph == ServerIndicatorGlyph.blocked;
    final live = _isLive(status);
    final listed = _connectionOf(data, id);
    final identity = bookmark.server?.identity;
    final server =
        (session == null ? listed : null) ??
        ConnectionServer(
          serverId: liveId,
          label: bookmark.label,
          host: identity?.host ?? '',
          port: identity?.port ?? 22,
          username: identity?.username ?? '',
        );
    final failure = listed?.paneFailure;
    final open = view.onOpenFavorite;
    final adhocEndpoint = _activeAdhocEndpoint(data);
    final mark = _serverMark(
      data,
      context,
      ServerTint(named: bookmark.color),
      ServerGlyphMark(bookmark.icon),
    );
    final endpoint = _savedEndpoint(data, bookmark);
    // The landing path follows the endpoint: two remote favorites of one
    // server differ only there.
    final place = bookmark.remotePath;
    final where = endpoint == null || place == null
        ? endpoint ?? place
        : l10n.compactHomeRemoteLocation(endpoint, place);

    // The row's visuals are excluded from semantics; the label carries
    // the state and the failure a sighted user reads in the tooltip.
    final details = [
      if (blocked) l10n.connectionsBlockedWarning,
      ?status?.detail,
      if (failure != null)
        l10n.connectionsPaneFailure(failure.paneTabId, failure.message),
    ];
    final semanticLabel = data.comfortable
        ? _spokenLabel([
            bookmark.label,
            appearance.label,
            where,
            ...details,
            _tabsSpoken(data, liveId),
          ])
        : [
            bookmark.label,
            if (appearance.label.isNotEmpty) appearance.label,
            ...details,
          ].join(', ');
    final tooltip = [
      if (appearance.label.isNotEmpty) appearance.label,
      ?_endpointLabelWithPort(bookmark),
      ?bookmark.remotePath,
      ...details,
    ].join('\n');

    Widget row(SidebarDropIndicator indicator) => SidebarRow(
      mark: mark,
      status: dot,
      title: bookmark.label,
      subtitle: _serverLine(l10n, _stateWords(appearance, probe), where),
      depth: depth,
      dropIndicator: indicator,
      trailingText: _tabsText(data, liveId),
      hoverAction: _disconnectAction(data, server, live),
      tooltip: tooltip.isEmpty ? null : tooltip,
      semanticLabel: semanticLabel,
      // A Quick Connect session saved from here (or the pane's bar) keeps
      // browsing under its adhoc id; its italic row retires, so the
      // saved row of the same endpoint carries the pill.
      selected:
          data.selectionKey == _serverSelectionKey(id) ||
          (adhocEndpoint != null && adhocEndpoint == _endpointKeyOf(bookmark)),
      onActivate: open == null
          ? null
          : (how) => open(bookmark, _openActionFor(how)),
      menuEntries: () => [
        ..._openVerbs(
          l10n,
          open == null ? null : (action) => open(bookmark, action),
        ),
        const SidebarMenuDivider(),
        ?_disconnectVerb(data, server, live),
        if (blocked && view.onReviewBlocked != null)
          SidebarMenuAction(
            key: ValueKey('sidebar.menu.review.$id'),
            label: l10n.connectionsReviewHostKey,
            onSelected: () => view.onReviewBlocked!(server),
          ),
        // 06 §3.7's review entry: server-scoped — a managed copy's record
        // belongs to the server, including edits on paths no pane shows.
        if (view.onLocalEdits != null)
          SidebarMenuAction(
            key: const ValueKey('sidebar.menu.localEdits'),
            label: l10n.sidebarLocalEdits,
            onSelected: () => view.onLocalEdits!(bookmark),
          ),
        const SidebarMenuDivider(),
        ..._editVerbs(context, data, bookmark),
      ],
    );

    return _ProbeVisibility(
      probes: view.probes,
      id: id,
      child: _SidebarDropZone(
        // A bookmark of any kind reorders around it (FAVORITES keeps one
        // user order); a dragged folder adds itself beside it.
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
      ),
    );
  }
}

/// A server row's mark. Compact, a plain glyph like every other rail row
/// when the server has no colour and no image or emoji of its own, and
/// the shared badge (Séance's tint and mark) at the kit's 18 px (24 on
/// touch) when it does. Comfortable, always the 32 px badge, whose
/// neutral tile an uncoloured server wears, as Séance's rows did before
/// the kit (D33). Home's list draws the 40 dp disc instead.
Widget _serverMark(
  _SidebarData data,
  BuildContext context,
  ServerTint tint,
  ServerMark mark, {
  String? label,
}) {
  if (data.list) return _homeServerMark(context, tint, mark, label: label);
  final extent = sidebarMarkExtent(context);
  if (!data.comfortable &&
      mark is ServerGlyphMark &&
      serverAccent(context, tint) == null) {
    return Icon(
      serverIconData(mark.icon),
      size: sidebarGlyphSize(context),
      color: PoltergeistChrome.of(context).secondaryText,
    );
  }
  return ServerBadge(
    tint: tint,
    mark: mark,
    size: extent,
    semanticsLabel: label,
  );
}

/// A saved server's endpoint for its second line: the embedded identity,
/// else the catalog server it references.
String? _savedEndpoint(_SidebarData data, Bookmark bookmark) {
  final identity = bookmark.server?.identity;
  if (identity != null) {
    return sidebarEndpointText(
      username: identity.username,
      host: identity.host,
      port: identity.port,
    );
  }
  final id = bookmark.server?.serverConfigId;
  final config = id == null ? null : data.view.catalog?.byId(id);
  if (config == null) return null;
  return sidebarEndpointText(
    username: config.username,
    host: config.host,
    port: config.port,
  );
}

/// `user@host:port` — the endpoint line a server row keeps in its tooltip.
String? _endpointLabelWithPort(Bookmark bookmark) {
  final identity = bookmark.server?.identity;
  if (identity == null) return null;
  return '${identity.username}@${identity.host}:${identity.port}';
}

/// A shared-account catalog server (04 §4.2): Séance's own mark and tint,
/// the same dot, the open verbs, and the editor verbs the shell offers.
class _CatalogServerRow extends StatelessWidget {
  const _CatalogServerRow({
    required this.data,
    required this.server,
    required this.depth,
    super.key,
  });

  final _SidebarData data;
  final ServerConfig server;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final l10n = data.l10n;
    final view = data.view;
    final status = _liveStatus(data, server.id);
    final probe = view.probes?.statuses[server.id];
    final (:appearance, :dot) = _serverIndicator(
      context,
      l10n,
      status: status,
      probe: probe,
    );
    final live = _isLive(status);
    final connection =
        _connectionOf(data, server.id) ??
        ConnectionServer(
          serverId: server.id,
          label: server.label,
          host: server.host,
          port: server.port,
          username: server.username,
        );
    final open = view.onOpenCatalogServer;
    final endpoint = sidebarEndpointText(
      username: server.username,
      host: server.host,
      port: server.port,
    );

    return _ProbeVisibility(
      probes: view.probes,
      id: server.id,
      child: SidebarRow(
        mark: _serverMark(
          data,
          context,
          ServerTint.of(server),
          server.mark,
          label: server.label,
        ),
        status: dot,
        title: server.label,
        subtitle: _serverLine(l10n, _stateWords(appearance, probe), endpoint),
        depth: depth,
        trailingText: _tabsText(data, server.id),
        hoverAction: _disconnectAction(data, connection, live),
        tooltip: [
          if (appearance.label.isNotEmpty) appearance.label,
          '${server.username}@${server.host}:${server.port}',
        ].join('\n'),
        semanticLabel: data.comfortable
            ? _spokenLabel([
                server.label,
                appearance.label,
                endpoint,
                _tabsSpoken(data, server.id),
              ])
            : appearance.label.isEmpty
            ? server.label
            : '${server.label}, ${appearance.label}',
        selected: data.selectionKey == _serverSelectionKey(server.id),
        onActivate: open == null
            ? null
            : (how) => open(server, _openActionFor(how)),
        menuEntries: () => [
          ..._openVerbs(
            l10n,
            open == null ? null : (action) => open(server, action),
            keyPrefix: 'sidebar.catalog.menu',
          ),
          const SidebarMenuDivider(),
          ?_disconnectVerb(data, connection, live),
          const SidebarMenuDivider(),
          SidebarMenuAction(
            key: const ValueKey('sidebar.catalog.menu.pin'),
            label: data.controller.isPinned(server.id)
                ? l10n.sidebarUnpin
                : l10n.sidebarPinToTop,
            onSelected: () => data.controller.togglePinned(server.id),
          ),
          const SidebarMenuDivider(),
          if (view.onEditCatalogServer != null)
            SidebarMenuAction(
              key: const ValueKey('sidebar.catalog.menu.edit'),
              label: l10n.sidebarCatalogEdit,
              onSelected: () => view.onEditCatalogServer!(server),
            ),
          if (view.onDuplicateCatalogServer != null)
            SidebarMenuAction(
              key: const ValueKey('sidebar.catalog.menu.duplicate'),
              label: l10n.sidebarCatalogDuplicate,
              onSelected: () => view.onDuplicateCatalogServer!(server),
            ),
          if (view.onDeleteCatalogServer != null)
            SidebarMenuAction(
              key: const ValueKey('sidebar.catalog.menu.delete'),
              label: l10n.sidebarCatalogDelete,
              onSelected: () => view.onDeleteCatalogServer!(server),
            ),
        ],
      ),
    );
  }
}

/// A live Quick Connect session with no saved row (10 §5): italic, at the
/// top of SERVERS, with "Save to Favorites…" beside the connection verbs.
class _AdhocRow extends StatelessWidget {
  const _AdhocRow({required this.data, required this.session, super.key});

  final _SidebarData data;
  final SidebarAdhocSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = data.l10n;
    final view = data.view;
    final bookmark = session.bookmark;
    final status = _liveStatus(data, bookmark.id);
    final (:appearance, :dot) = _serverIndicator(context, l10n, status: status);
    final live = _isLive(status);
    final identity = bookmark.server?.identity;
    final connection = ConnectionServer(
      serverId: bookmark.id,
      label: bookmark.label,
      host: identity?.host ?? '',
      port: identity?.port ?? 22,
      username: identity?.username ?? '',
    );
    final open = view.onOpenFavorite;
    final endpoint = identity == null
        ? null
        : sidebarEndpointText(
            username: identity.username,
            host: identity.host,
            port: identity.port,
          );
    final unsaved = l10n.paneUnsavedSession(endpoint ?? bookmark.label);
    return SidebarRow(
      mark: data.list
          ? _HomeDisc(
              glyph: Icons.bolt,
              tint: Theme.of(context).colorScheme.tertiary,
            )
          : _placeMark(context, Icons.bolt),
      status: dot,
      title: bookmark.label,
      subtitle: _serverLine(l10n, _stateWords(appearance, null), unsaved),
      italic: true,
      trailingText: _tabsText(data, bookmark.id),
      hoverAction: _disconnectAction(data, connection, live),
      tooltip: [
        if (appearance.label.isNotEmpty) appearance.label,
        ?_endpointLabelWithPort(bookmark),
        ?session.path,
      ].join('\n'),
      semanticLabel: data.comfortable
          ? _spokenLabel([
              bookmark.label,
              l10n.sidebarUnsavedSession,
              appearance.label,
              endpoint,
              _tabsSpoken(data, bookmark.id),
            ])
          : [
              bookmark.label,
              l10n.sidebarUnsavedSession,
              if (appearance.label.isNotEmpty) appearance.label,
            ].join(', '),
      selected: data.selectionKey == _serverSelectionKey(bookmark.id),
      onActivate: open == null
          ? null
          : (how) => open(bookmark, _openActionFor(how)),
      menuEntries: () => [
        ..._openVerbs(
          l10n,
          open == null ? null : (action) => open(bookmark, action),
        ),
        const SidebarMenuDivider(),
        SidebarMenuAction(
          key: const ValueKey('sidebar.adhoc.menu.save'),
          label: l10n.sidebarSaveToFavorites,
          onSelected: () => unawaited(
            saveSessionToServers(context, view.controller, session),
          ),
        ),
        ?_disconnectVerb(data, connection, live),
      ],
    );
  }
}
