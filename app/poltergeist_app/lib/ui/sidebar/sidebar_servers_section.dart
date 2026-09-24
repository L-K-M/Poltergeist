part of 'sidebar_view.dart';

bool _isServerKind(Bookmark bookmark) =>
    bookmark.kind == BookmarkKind.remotePath;

/// One SERVERS group: saved server rows (in the store's user order) and
/// shared-account catalog servers (by label), under one disclosure row.
final class _ServerGroup {
  _ServerGroup(this.name);

  final String name;
  final stored = <Bookmark>[];
  final catalog = <ServerConfig>[];

  int get length => stored.length + catalog.length;
}

/// SERVERS (10 §5): live Quick Connect sessions (italic, top), then the
/// saved server locations and the shared-account catalog merged into one
/// grouped list — each row carrying its live state as its one dot. This
/// replaces the separate Connections section: a connected server is the
/// same row, not a second copy of it.
List<Widget> _serversSection(_SidebarData data) {
  final l10n = data.l10n;
  final view = data.view;
  final controller = data.controller;
  final sectionKey = SidebarCollapseKeys.section(SidebarSection.servers);

  final loose = _ServerGroup('');
  final groups = <String, _ServerGroup>{};
  for (final section in controller.sections) {
    for (final bookmark in section.bookmarks.where(_isServerKind)) {
      final name = section.name;
      (name == null
              ? loose
              : groups.putIfAbsent(section.key, () => _ServerGroup(name)))
          .stored
          .add(bookmark);
    }
  }
  final catalog = view.catalog?.servers ?? const <ServerConfig>[];
  for (final server in catalog) {
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
  // A saved endpoint is the session's saved row: once "Save to Servers…"
  // (or the pane's save bar) lands, the italic duplicate retires.
  final saved = <String>{
    for (final group in [loose, ...groups.values]) ...[
      for (final bookmark in group.stored) ?_endpointKeyOf(bookmark),
      for (final server in group.catalog)
        _endpointKey(server.host, server.port, server.username),
    ],
  };
  final sessions = [
    for (final session in data.facts.adhoc)
      if (!saved.contains(_endpointKeyOf(session.bookmark))) session,
  ];

  final total =
      sessions.length +
      loose.length +
      groups.values.fold<int>(0, (sum, group) => sum + group.length);
  data.serverCount = total;

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
  body.addAll(_serverRows(data, loose, group: null, depth: 0));

  final sortedKeys = groups.keys.toList()..sort();
  for (final key in sortedKeys) {
    final group = groups[key]!;
    final collapseKey = SidebarCollapseKeys.serverGroup(key);
    final rows = _serverRows(data, group, group: group.name, depth: 1);
    if (data.filtering && rows.isEmpty) continue;
    final collapsed = data.collapsed(collapseKey);
    body.add(
      _SidebarDropZone(
        key: ValueKey('sidebar.group.$collapseKey'),
        planner: (payload, _) => _regroupPlan(
          view,
          payload,
          group: group.name,
          accepts: _isServerKind,
        ),
        builder: (indicator) => SidebarSectionHeader(
          headerKey: ValueKey('sidebar.section.$collapseKey'),
          nested: true,
          title: group.name,
          count: group.length,
          collapsed: collapsed,
          dropHighlight: indicator != SidebarDropIndicator.none,
          onToggle: () => controller.toggleCollapsed(collapseKey),
        ),
      ),
    );
    if (!collapsed) body.addAll(rows);
  }

  // Only a loaded store can say "none": mid-load or after a failed read
  // (FAVORITES carries that error) the empty copy would be a claim.
  if (total == 0 && !data.filtering && controller.load == SidebarLoad.ready) {
    body.add(
      _SidebarHint(
        key: const ValueKey('sidebar.servers.empty'),
        text: l10n.sidebarServersEmpty,
        // D22's adoption beat: an empty server list is the moment the
        // ssh_config import earns its keep.
        action: view.onImportSshConfig == null
            ? null
            : TextButton.icon(
                key: const ValueKey('sidebar.importSshConfig'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                onPressed: view.onImportSshConfig,
                icon: const Icon(Icons.download_outlined, size: 14),
                label: Text(l10n.sidebarImportSshConfig),
              ),
      ),
    );
  }
  if (data.filtering && body.isEmpty) return const [];

  final collapsed = data.collapsed(sectionKey);
  final VoidCallback? onAdd = view.onAddCatalogServer ?? view.onQuickConnect;
  return [
    _SidebarDropZone(
      key: const ValueKey('sidebar.servers.header'),
      planner: (payload, _) =>
          _regroupPlan(view, payload, group: null, accepts: _isServerKind),
      builder: (indicator) => SidebarSectionHeader(
        headerKey: ValueKey('sidebar.section.$sectionKey'),
        title: l10n.sidebarServersSection,
        count: total,
        collapsed: collapsed,
        dropHighlight: indicator != SidebarDropIndicator.none,
        onToggle: () => controller.toggleCollapsed(sectionKey),
        onAdd: onAdd,
        addKey: const ValueKey('sidebar.servers.add'),
        addTooltip: view.onAddCatalogServer != null
            ? l10n.sidebarServersAddNew
            : l10n.sidebarServersAddConnect,
      ),
    ),
    if (!collapsed) ...body,
  ];
}

List<Widget> _serverRows(
  _SidebarData data,
  _ServerGroup members, {
  required String? group,
  required int depth,
}) {
  final view = data.view;
  return [
    for (final bookmark in members.stored)
      if (data.countRow(
        [
          bookmark.label,
          ?_endpointKeyOf(bookmark),
          ?bookmark.remotePath,
          ?bookmark.group,
        ].join(' '),
        open: view.onOpenFavorite == null
            ? null
            : () => view.onOpenFavorite!(bookmark, SidebarOpenAction.plain),
      ))
        _SavedServerRow(
          key: ValueKey('sidebar.favorite.${bookmark.id}'),
          data: data,
          bookmark: bookmark,
          group: group,
          depth: depth,
        ),
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

/// A saved server location (a remotePath bookmark): its badge, the live
/// dot, the endpoint and any failure in the tooltip, and the connection
/// verbs beside the store edits.
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
    final status = _liveStatus(data, id);
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
        listed ??
        ConnectionServer(
          serverId: id,
          label: bookmark.label,
          host: identity?.host ?? '',
          port: identity?.port ?? 22,
          username: identity?.username ?? '',
        );
    final failure = listed?.paneFailure;
    final open = view.onOpenFavorite;
    final adhocEndpoint = _activeAdhocEndpoint(data);
    final mark = _serverMark(
      context,
      ServerTint(named: bookmark.color),
      ServerGlyphMark(bookmark.icon),
    );

    // The row's visuals are excluded from semantics; the label carries
    // the state and the failure a sighted user reads in the tooltip.
    final details = [
      if (blocked) l10n.connectionsBlockedWarning,
      ?status?.detail,
      if (failure != null)
        l10n.connectionsPaneFailure(failure.paneTabId, failure.message),
    ];
    final semanticLabel = [
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
      depth: depth,
      dropIndicator: indicator,
      trailingText: _tabsText(data, id),
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
        planner: (payload, fraction) => _reorderPlan(
          view,
          payload,
          fraction,
          target: bookmark,
          group: group,
          accepts: _isServerKind,
        ),
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

/// A server row's 18 px mark: a plain glyph like every other rail row
/// when the server has no colour and no image or emoji of its own; the
/// shared badge (Séance's tint and mark) when it does.
Widget _serverMark(
  BuildContext context,
  ServerTint tint,
  ServerMark mark, {
  String? label,
}) {
  if (mark is ServerGlyphMark && serverAccent(context, tint) == null) {
    return Icon(
      serverIconData(mark.icon),
      size: 16,
      color: PoltergeistChrome.of(context).secondaryText,
    );
  }
  return ServerBadge(tint: tint, mark: mark, size: 18, semanticsLabel: label);
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

    return _ProbeVisibility(
      probes: view.probes,
      id: server.id,
      child: SidebarRow(
        mark: _serverMark(
          context,
          ServerTint.of(server),
          server.mark,
          label: server.label,
        ),
        status: dot,
        title: server.label,
        depth: depth,
        trailingText: _tabsText(data, server.id),
        hoverAction: _disconnectAction(data, connection, live),
        tooltip: [
          if (appearance.label.isNotEmpty) appearance.label,
          '${server.username}@${server.host}:${server.port}',
        ].join('\n'),
        semanticLabel: appearance.label.isEmpty
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
/// top of SERVERS, with "Save to Servers…" beside the connection verbs.
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
    final (:appearance, :dot) = _serverIndicator(
      context,
      l10n,
      status: status,
    );
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
    return SidebarRow(
      mark: Icon(
        Icons.bolt,
        size: 16,
        color: PoltergeistChrome.of(context).secondaryText,
      ),
      status: dot,
      title: bookmark.label,
      italic: true,
      trailingText: _tabsText(data, bookmark.id),
      hoverAction: _disconnectAction(data, connection, live),
      tooltip: [
        if (appearance.label.isNotEmpty) appearance.label,
        ?_endpointLabelWithPort(bookmark),
        ?session.path,
      ].join('\n'),
      semanticLabel: [
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
          label: l10n.sidebarSaveToServers,
          onSelected: () =>
              unawaited(_saveSessionToServers(context, view, session)),
        ),
        ?_disconnectVerb(data, connection, live),
      ],
    );
  }
}
