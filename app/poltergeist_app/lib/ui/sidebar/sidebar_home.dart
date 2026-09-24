part of 'sidebar_view.dart';

/// The compact Home's search bar height before text scaling (M3's search
/// bar is 56 dp; 48 keeps the first section above the fold on a phone).
const double _homeSearchExtent = 48;

/// Room the list keeps under its last row for the floating "+".
const double _homeFabClearance = 88;

/// D32 §9's Home presentation of the sidebar: the same DEVICES,
/// FAVORITES, and SERVERS rows (the kit already sizes them for touch on
/// touch platforms), under an always-shown search bar that filters all
/// three, with the rail's "+" menu as a floating action button and the
/// sync status as the list's footer. Nothing here forks a section — the
/// rows, menus, and verbs are the rail's own.
extension _SidebarHome on _SidebarViewState {
  Widget _buildHome(_SidebarData data, List<Widget> sections) {
    final context = data.context;
    final l10n = data.l10n;
    final chrome = PoltergeistChrome.of(context);
    final controller = widget.controller;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    if (controller.takeFilterFocus()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _filterFocus.requestFocus();
      });
    }
    final sync = _syncChip(l10n);
    final entries = _addMenuEntries(data, icons: true);
    return ColoredBox(
      color: chrome.sidebarBackground,
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
                    entries: _addMenuEntries(data, icons: true),
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
