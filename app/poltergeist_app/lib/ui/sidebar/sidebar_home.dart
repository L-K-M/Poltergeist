part of 'sidebar_view.dart';

/// The compact Home's search bar height before text scaling (M3's search
/// bar is 56 dp; 48 keeps the first section above the fold on a phone).
const double _homeSearchExtent = 48;

/// Room the list keeps under its last row for the floating "+".
const double _homeFabClearance = 88;

/// The glyph inside a Home mark's disc and the disc's tint strength —
/// the browser's kind badge (compact_listing.dart), so a location reads
/// the same on the list that opens it and on the screen it opens.
const double _homeGlyphSize = 22;
const double _homeTintAlpha = 0.14;

/// Home sits on the page surface, like the browser it pushes; the rail
/// keeps the sidebar's own fill.
Color _homeBackground(BuildContext context) =>
    PoltergeistChrome.of(context).paneBackground;

/// D32 §9's Home presentation of the sidebar: the same DEVICES,
/// FAVORITES, and SERVERS rows in the kit's list layout (56 dp rows, a
/// 40 dp tinted disc, a 16 sp title, and the location on a second line,
/// like the browser's rows), under an always-shown search bar that
/// filters all three, with the "+" menu as a floating action button and
/// the sync status as the list's footer. Nothing here forks a section —
/// the rows, menus, and verbs are the rail's own; only what a row spells
/// out differs, because touch has no hover tooltip.
extension _SidebarHome on _SidebarViewState {
  Widget _buildHome(_SidebarData data, List<Widget> sections) {
    final context = data.context;
    final l10n = data.l10n;
    final controller = widget.controller;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    if (controller.takeFilterFocus()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _filterFocus.requestFocus();
      });
    }
    final sync = _syncChip(l10n);
    final entries = _addMenuEntries(data);
    return ColoredBox(
      color: _homeBackground(context),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: _HomeSearchField(
                  key: const ValueKey('sidebar.home.search'),
                  query: controller.filterQuery,
                  focusNode: _filterFocus,
                  onChanged: controller.setFilterQuery,
                  onSubmitted: data.firstMatch,
                  countText: data.filtering
                      ? l10n.sidebarCatalogFilterCount(data.matched, data.total)
                      : null,
                ),
              ),
              Expanded(
                child: ListView(
                  key: const ValueKey('sidebar.home.list'),
                  padding: EdgeInsets.only(
                    top: 4,
                    bottom: _homeFabClearance + bottomInset,
                  ),
                  children: [
                    ...sections,
                    if (sync != null) _HomeSyncFooter(data: sync),
                  ],
                ),
              ),
            ],
          ),
          if (entries.isNotEmpty)
            PositionedDirectional(
              end: 16,
              bottom: 16 + bottomInset,
              child: FloatingActionButton(
                key: const ValueKey('sidebar.home.add'),
                tooltip: l10n.sidebarAddMenu,
                onPressed: () => unawaited(
                  showSidebarMenuSheet(
                    context,
                    title: l10n.sidebarAddMenu,
                    entries: _addMenuEntries(data),
                  ),
                ),
                child: const Icon(Icons.add),
              ),
            ),
        ],
      ),
    );
  }
}

/// Home's search bar: M3's pill-shaped field, filtering every section as
/// the user types (the rail's filter, touch-sized). The ✕ clears the
/// query; "3 of 12" rides inside the field while one is live.
class _HomeSearchField extends StatefulWidget {
  const _HomeSearchField({
    super.key,
    required this.query,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    this.countText,
  });

  final String query;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;
  final String? countText;

  @override
  State<_HomeSearchField> createState() => _HomeSearchFieldState();
}

class _HomeSearchFieldState extends State<_HomeSearchField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.query,
  );

  @override
  void didUpdateWidget(_HomeSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != _text.text) {
      _text.value = TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      );
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final count = widget.countText;
    return SizedBox(
      height: MediaQuery.textScalerOf(context).scale(_homeSearchExtent),
      child: TextField(
        controller: _text,
        focusNode: widget.focusNode,
        onChanged: widget.onChanged,
        onSubmitted: (_) => widget.onSubmitted(),
        textInputAction: TextInputAction.search,
        textAlignVertical: TextAlignVertical.center,
        style: theme.textTheme.bodyLarge,
        decoration: InputDecoration(
          filled: true,
          fillColor: chrome.capsuleFill,
          hintText: l10n.compactHomeSearchHint,
          hintStyle: theme.textTheme.bodyLarge?.copyWith(
            color: chrome.secondaryText,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          prefixIcon: Icon(Icons.search, color: chrome.secondaryText),
          suffixIcon: widget.query.isEmpty
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (count != null)
                      Text(
                        count,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: chrome.secondaryText,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    IconButton(
                      key: const ValueKey('sidebar.home.search.clear'),
                      tooltip: l10n.sidebarCatalogFilterClear,
                      onPressed: () => widget.onChanged(''),
                      icon: Icon(Icons.close, color: chrome.secondaryText),
                    ),
                  ],
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// The sync status as Home's list footer: the rail's chip at touch size
/// — "Synced · 2 min" (a tap syncs now), a spinner while syncing, red
/// "Sync failed" (a tap retries), or "Sync off" leading to setup.
class _HomeSyncFooter extends StatelessWidget {
  const _HomeSyncFooter({required this.data});

  final SidebarSyncChipData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final color = data.tone == SidebarSyncTone.error
        ? theme.colorScheme.error
        : chrome.secondaryText;
    final Widget lead = switch (data.tone) {
      SidebarSyncTone.busy => SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      ),
      SidebarSyncTone.error => Icon(Icons.sync_problem, size: 18, color: color),
      SidebarSyncTone.muted => Icon(Icons.cloud_off, size: 18, color: color),
      SidebarSyncTone.normal => Icon(
        Icons.cloud_done_outlined,
        size: 18,
        color: color,
      ),
    };
    Widget chip = TextButton.icon(
      key: data.key,
      onPressed: data.onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        minimumSize: const Size(0, 48),
      ),
      icon: lead,
      label: Text(
        data.label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    final tooltip = data.tooltip;
    if (tooltip != null) chip = Tooltip(message: tooltip, child: chip);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Center(child: chip),
    );
  }
}

/// A Home row's 40 dp mark: [glyph] on a disc of [tint].
class _HomeDisc extends StatelessWidget {
  const _HomeDisc({required this.glyph, required this.tint});

  final IconData glyph;
  final Color tint;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: sidebarMarkExtent(context),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: tint.withValues(alpha: _homeTintAlpha),
        shape: BoxShape.circle,
      ),
      child: Icon(glyph, size: _homeGlyphSize, color: tint),
    ),
  );
}

/// A server's Home mark: its own badge (colour, emoji, or image) as a
/// disc, or — for a server with none of its own — its glyph on the
/// servers' tint, so an untagged server still reads as a server beside
/// the folders.
Widget _homeServerMark(
  BuildContext context,
  ServerTint tint,
  ServerMark mark, {
  String? label,
}) {
  if (mark is ServerGlyphMark && serverAccent(context, tint) == null) {
    return _HomeDisc(
      glyph: serverIconData(mark.icon),
      tint: Theme.of(context).colorScheme.tertiary,
    );
  }
  return ClipOval(
    child: ServerBadge(
      tint: tint,
      mark: mark,
      size: sidebarMarkExtent(context),
      semanticsLabel: label,
    ),
  );
}

/// A Home row's announcement: its visible lines and the state the dot
/// shows, in reading order (the row's visuals are excluded from
/// semantics, so what is not here is not heard).
String _homeSemantics(List<String?> parts) => [
  for (final part in parts)
    if (part != null && part.isNotEmpty) part,
].join(', ');

/// Where a bookmark location sits, for a Home line: a local path
/// home-relative (`~/Documents`), a remote one as "server · path".
String _homeLocation(_SidebarData data, BookmarkLocation location) {
  final server = location.server;
  if (server == null) {
    return sidebarHomeRelativePath(location.path, data.localHome);
  }
  final name = _homeServerName(data, server);
  return name == null
      ? location.path
      : data.l10n.compactHomeRemoteLocation(name, location.path);
}

/// The name a remote location's server goes by: the catalog server's
/// label, else a saved server of the same endpoint, else the endpoint.
String? _homeServerName(_SidebarData data, BookmarkServerRef server) {
  if (server.serverConfigId case final id?) {
    if (data.view.catalog?.byId(id) case final config?) return config.label;
  }
  final identity = server.identity;
  if (identity == null) return null;
  final key = _endpointKey(identity.host, identity.port, identity.username);
  for (final section in data.controller.sections) {
    for (final bookmark in section.bookmarks) {
      if (_isServerKind(bookmark) && _endpointKeyOf(bookmark) == key) {
        return bookmark.label;
      }
    }
  }
  return sidebarEndpointText(
    username: identity.username,
    host: identity.host,
    port: identity.port,
  );
}

/// A server row's live state in words for its Home line, when the dot
/// alone would leave it unexplained: an attempt running, a failure, a
/// host-key block, or a probe that found the host down. Connected and
/// idle rows need no words — the dot, or its absence, says it.
String? _homeStateWords(
  ServerIndicatorAppearance appearance,
  ProbeStatus? probe,
) => switch (appearance.glyph) {
  ServerIndicatorGlyph.pending ||
  ServerIndicatorGlyph.failed ||
  ServerIndicatorGlyph.blocked => appearance.label,
  ServerIndicatorGlyph.probe when probe == ProbeStatus.offline =>
    appearance.label,
  _ => null,
};

/// A server row's Home line: the state words (first, so the ellipsis
/// never takes them) and the endpoint.
String? _homeServerLine(
  AppLocalizations l10n,
  String? state,
  String? endpoint,
) => switch ((state, endpoint)) {
  (final state?, final endpoint?) => l10n.compactHomeServerState(
    state,
    endpoint,
  ),
  (final state?, null) => state,
  (null, final endpoint) => endpoint,
};

/// "N tabs open" for a Home row's announcement, where the rail's `×N`
/// shows (a screen reader would read the glyph as "times").
String? _homeTabsSpoken(_SidebarData data, String serverId) {
  final tabs = data.facts.bound[serverId]?.tabs ?? 0;
  return tabs > 1 ? data.l10n.compactHomeTabsOpen(tabs) : null;
}

/// A Home section's empty state (D32 §9): what the section is for and
/// the one or two verbs that fill it, laid out like a row so the list
/// keeps its rhythm.
class _HomeEmptyState extends StatelessWidget {
  const _HomeEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HomeDisc(glyph: icon, tint: theme.colorScheme.primary),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MergeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(title, style: theme.textTheme.bodyLarge),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        body,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: chrome.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: actions),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
