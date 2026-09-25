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
/// the shared account's server list, grouped by Séance's rules, each
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
  var pinned = 0;
  for (final server in catalog) {
    if (controller.isPinned(server.id)) {
      pinned++;
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

  final total = sessions.length + catalog.length - pinned;
  // The filter's threshold counts every server the rail lists once, the
  // remote favorites included (without the shared account they are the
  // user's servers), wherever PINNED put them.
  data.serverCount = sessions.length + catalog.length + remoteFavorites.length;

  final body = <Widget>[];
  // Live rows out of view with no drawn group header to speak for them
  // (the filter hid them, or their whole group): SERVERS' header shows
  // their state (D33).
  final hiddenLoose = <ServerStatus?>[];
  for (final session in sessions) {
    final bookmark = session.bookmark;
    if (!data.countRow(
      '${bookmark.label} ${sessionEndpointLabel(bookmark)}',
      open: view.onOpenFavorite == null
          ? null
          : () => view.onOpenFavorite!(bookmark, SidebarOpenAction.plain),
    )) {
      hiddenLoose.add(_liveStatus(data, bookmark.id));
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
  final looseHidden = <ServerConfig>[];
  body.addAll(_serverRows(data, loose, depth: 0, hidden: looseHidden));
  hiddenLoose.addAll(_catalogStatuses(data, looseHidden));

  final sortedKeys = groups.keys.toList()..sort();
  for (final key in sortedKeys) {
    final group = groups[key]!;
    final collapseKey = SidebarCollapseKeys.serverGroup(key);
    final filtered = <ServerConfig>[];
    final rows = _serverRows(data, group, depth: 1, hidden: filtered);
    if (data.filtering && rows.isEmpty) {
      hiddenLoose.addAll(_catalogStatuses(data, filtered));
      continue;
    }
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
        status: _hiddenLiveDot(
          data,
          _catalogStatuses(data, collapsed ? group.catalog : filtered),
        ),
        onToggle: () => controller.toggleCollapsed(collapseKey),
      ),
    );
    if (!collapsed) body.addAll(rows);
  }

  // Only a loaded store can say "none": mid-load or after a failed read
  // (FAVORITES carries that error) the empty copy would be a claim. A
  // pinned server is still the account's, so all of them pinned is not
  // "none" either.
  final empty =
      sessions.isEmpty &&
      catalog.isEmpty &&
      !data.filtering &&
      controller.load == SidebarLoad.ready;
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
  final collapsed = data.collapsed(sectionKey);
  final hiddenDot = _hiddenLiveDot(
    data,
    collapsed
        ? [
            for (final session in sessions)
              _liveStatus(data, session.bookmark.id),
            ..._catalogStatuses(data, [
              ...loose.catalog,
              for (final group in groups.values) ...group.catalog,
            ]),
          ]
        : hiddenLoose,
  );
  // A filter that hides every row drops the section, unless a live
  // server is among the hidden: its header stays to say so.
  if (data.filtering && body.isEmpty && hiddenDot == null) return const [];

  final VoidCallback? onAdd = view.onAddCatalogServer ?? view.onQuickConnect;
  return [
    SidebarSectionHeader(
      key: const ValueKey('sidebar.servers.header'),
      headerKey: ValueKey('sidebar.section.$sectionKey'),
      title: l10n.sidebarServersSection,
      count: total,
      collapsed: collapsed,
      status: hiddenDot,
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

/// Counts an account server's row against the filter; true when it
/// shows.
bool _catalogShows(_SidebarData data, ServerConfig server) {
  final open = data.view.onOpenCatalogServer;
  return data.countRow(
    serverSearchHaystack(server),
    open: open == null ? null : () => open(server, SidebarOpenAction.plain),
  );
}

/// The rows of [members] the filter keeps; the ones it hides land in
/// [hidden], for a header to show their live state.
List<Widget> _serverRows(
  _SidebarData data,
  _ServerGroup members, {
  required int depth,
  required List<ServerConfig> hidden,
}) {
  final rows = <Widget>[];
  for (final server in members.catalog) {
    if (!_catalogShows(data, server)) {
      hidden.add(server);
      continue;
    }
    rows.add(
      _CatalogServerRow(
        key: ValueKey('sidebar.catalog.row.${server.id}'),
        data: data,
        server: server,
        depth: depth,
      ),
    );
  }
  return rows;
}

/// The live states of account servers, for [_hiddenLiveDot].
Iterable<ServerStatus?> _catalogStatuses(
  _SidebarData data,
  Iterable<ServerConfig> servers,
) => [for (final server in servers) _liveStatus(data, server.id)];

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

/// A remote favorite's live state: its own connection first, else the
/// Quick Connect session it was saved from, which speaks for it until
/// the row connects itself ([session], non-null in that case).
({ServerStatus? status, SidebarAdhocSession? session}) _savedLive(
  _SidebarData data,
  Bookmark bookmark,
) {
  final own = _liveStatus(data, bookmark.id);
  final session = _isLive(own) ? null : _sessionSavedAs(data, bookmark);
  return (
    status: session == null ? own : _liveStatus(data, session.bookmark.id),
    session: session,
  );
}

/// The dot a header draws for live servers it keeps out of view (D33):
/// a folded group's or section's rows, or rows the filter hides, so
/// "what am I connected to" never needs an unfold. A connection up
/// outranks one being attempted; with nothing live, no dot.
SidebarStatusDot? _hiddenLiveDot(
  _SidebarData data,
  Iterable<ServerStatus?> statuses,
) {
  final chrome = PoltergeistChrome.of(data.context);
  var pending = false;
  for (final status in statuses) {
    switch (status?.state) {
      case ServerConnectionState.connected:
        return SidebarStatusDot(chrome.statusConnected);
      case ServerConnectionState.connecting ||
          ServerConnectionState.reconnecting:
        pending = true;
      case _:
        break;
    }
  }
  return pending ? SidebarStatusDot(chrome.statusConnecting) : null;
}

ConnectionServer? _connectionOf(_SidebarData data, String serverId) {
  for (final server in data.view.connections?.servers ?? const []) {
    if (server.serverId == serverId) return server;
  }
  return null;
}

/// The green ring a connected server's mark wears beside its dot (D33,
/// Séance's old connected ring): only while a connection is up, not
/// while one is being attempted.
Color? _connectedRing(BuildContext context, ServerStatus? status) =>
    status?.state == ServerConnectionState.connected
    ? PoltergeistChrome.of(context).statusConnected
    : null;

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

/// Where a remote favorite's row is drawn (D33).
enum _SavedRowPlacement {
  /// Under FAVORITES, in the store's one user order: the row drags, and
  /// takes bookmark and folder drops at its edges.
  favorites,

  /// In PINNED, which orders by label: no position to drag to or drop
  /// at, so the row does neither.
  pinned,
}

/// A saved remote location (a remotePath bookmark), listed under
/// FAVORITES, or PINNED once pinned (D33): its badge, the live dot, the
/// endpoint and any failure in the tooltip, and the connection and pin
/// verbs beside the store edits.
class _SavedServerRow extends StatelessWidget {
  const _SavedServerRow({
    required this.data,
    required this.bookmark,
    required this.group,
    required this.depth,
    this.placement = _SavedRowPlacement.favorites,
    super.key,
  });

  final _SidebarData data;
  final Bookmark bookmark;

  /// The FAVORITES group its drops file into; unused in PINNED.
  final String? group;
  final int depth;
  final _SavedRowPlacement placement;

  @override
  Widget build(BuildContext context) {
    final l10n = data.l10n;
    final view = data.view;
    final id = bookmark.id;
    // The row's own connection outranks a saved session's; otherwise the
    // session it was saved from speaks for it.
    final (:status, :session) = _savedLive(data, bookmark);
    final liveId = session?.bookmark.id ?? id;
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
    final tint = ServerTint(named: bookmark.color);
    final mark = _serverMark(
      data,
      context,
      tint,
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
    // the state, the endpoint and the failure a sighted user reads on the
    // second line or in the tooltip, in either density (a tooltip is
    // not a screen reader's).
    final details = [
      if (blocked) l10n.connectionsBlockedWarning,
      ?status?.detail,
      if (failure != null)
        l10n.connectionsPaneFailure(failure.paneTabId, failure.message),
    ];
    final semanticLabel = _spokenLabel([
      bookmark.label,
      appearance.label,
      where,
      ...details,
      _tabsSpoken(data, liveId),
    ]);
    final tooltip = [
      if (appearance.label.isNotEmpty) appearance.label,
      ?_endpointLabelWithPort(bookmark),
      ?bookmark.remotePath,
      ...details,
    ].join('\n');

    Widget row(SidebarDropIndicator indicator) => SidebarRow(
      mark: mark,
      status: dot,
      accent: serverAccent(context, tint)?.line,
      markRing: _connectedRing(context, status),
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
        // The account server's verb and words: both are servers the
        // user shortlists (D33).
        SidebarMenuAction(
          key: const ValueKey('sidebar.menu.pin'),
          label: data.controller.isPinned(id)
              ? l10n.sidebarUnpin
              : l10n.sidebarPinToTop,
          onSelected: () => data.controller.togglePinned(id),
        ),
        const SidebarMenuDivider(),
        ..._editVerbs(context, data, bookmark),
      ],
    );

    if (placement == _SavedRowPlacement.pinned) {
      return _ProbeVisibility(
        probes: view.probes,
        id: id,
        child: row(SidebarDropIndicator.none),
      );
    }
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
    final tint = ServerTint.of(server);
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
          tint,
          server.mark,
          label: server.label,
        ),
        status: dot,
        accent: serverAccent(context, tint)?.line,
        markRing: _connectedRing(context, status),
        title: server.label,
        subtitle: _serverLine(l10n, _stateWords(appearance, probe), endpoint),
        depth: depth,
        // Provenance (D33): Edit, Duplicate and Delete here change the
        // account's record, not a bookmark of this device's, so the row
        // says where it comes from: a small mark, and in words.
        trailingIcon: Icons.cloud_outlined,
        trailingText: _tabsText(data, server.id),
        hoverAction: _disconnectAction(data, connection, live),
        tooltip: [
          if (appearance.label.isNotEmpty) appearance.label,
          '${server.username}@${server.host}:${server.port}',
          l10n.sidebarFromSeanceAccount,
        ].join('\n'),
        // What the row shows, in either density: the endpoint is the
        // tooltip's on a compact row, which a screen reader never gets.
        semanticLabel: _spokenLabel([
          server.label,
          appearance.label,
          endpoint,
          _tabsSpoken(data, server.id),
          l10n.sidebarFromSeanceAccount,
        ]),
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
      accent: serverAccent(context, ServerTint(named: bookmark.color))?.line,
      markRing: _connectedRing(context, status),
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
      semanticLabel: _spokenLabel([
        bookmark.label,
        l10n.sidebarUnsavedSession,
        appearance.label,
        endpoint,
        _tabsSpoken(data, bookmark.id),
      ]),
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
