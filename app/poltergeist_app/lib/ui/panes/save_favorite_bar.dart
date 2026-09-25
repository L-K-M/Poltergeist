import 'dart:async';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/quick_connect_address.dart'
    show quickConnectAdhocIdPrefix;
import '../../services/sidebar_controller.dart' show saveRemoteLocationTo;
import '../../theme/app_theme.dart';
import '../save_to_servers.dart';

/// The banner's button height on desktop, inside its 30 px line.
const double _desktopControlExtent = 26;

/// Below this line width "Save to Favorites…" folds to an icon button, so a
/// pane at its minimum width keeps the endpoint readable.
const double _labelledSaveMinWidth = 300;

/// The post-connect "Not saved" banner (02 §2.7, D32 §6's banner slot):
/// one slim line for a live Quick Connect session —
/// `Not saved · demo@host:2222   [Save to Favorites…]  ×` — naming the live
/// endpoint, never the raw address string (which may have carried a
/// stripped password).
///
/// Save to Favorites… runs the sidebar's own flow ([promptSaveToServers]:
/// the name prompt prefilled with the endpoint) and saves through
/// [saveRemoteLocationTo], so a session saved here or from the rail
/// lands as the same record. The banner watches [store] and leaves the
/// moment any stored server carries the session's endpoint, wherever the
/// save came from. A null [store] means no persistence path is wired:
/// the button reports through [onNoStore] (the pane's honest not-yet
/// notice, the #132 pattern) — never a fake write. A throwing store
/// keeps the banner up with the failure in its line, so the save stays
/// retryable. [onDismiss] hides it for this tab.
class SaveFavoriteBar extends StatefulWidget {
  const SaveFavoriteBar({
    super.key,
    required this.bookmark,
    this.currentPath,
    required this.store,
    required this.onNoStore,
    required this.onDismiss,
  });

  /// The live adhoc bookmark: endpoint identity and landing path source.
  final Bookmark bookmark;

  /// The tab's current remote path; the saved server opens here.
  final String? currentPath;

  final BookmarkStore? store;

  final VoidCallback onNoStore;

  final VoidCallback onDismiss;

  @override
  State<SaveFavoriteBar> createState() => _SaveFavoriteBarState();
}

class _SaveFavoriteBarState extends State<SaveFavoriteBar> {
  StreamSubscription<BookmarkStoreChange>? _changes;

  /// Whether a stored server already carries this session's endpoint.
  bool _saved = false;
  bool _failed = false;
  bool _saving = false;

  /// Drops a superseded store read (a change landing mid-load).
  int _check = 0;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(SaveFavoriteBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store) ||
        sessionEndpointKey(oldWidget.bookmark) !=
            sessionEndpointKey(widget.bookmark)) {
      _watch();
    }
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  void _watch() {
    unawaited(_changes?.cancel());
    _changes = widget.store?.changes.listen((_) => unawaited(_refresh()));
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final store = widget.store;
    final endpoint = sessionEndpointKey(widget.bookmark);
    if (store == null || endpoint == null) return;
    final check = ++_check;
    final List<Bookmark> rows;
    try {
      rows = await store.load();
    } on Object {
      // An unreadable store cannot prove the session saved: the banner
      // stays, and its button reports any real save failure.
      return;
    }
    if (!mounted || check != _check) return;
    final saved = rows.any(
      (row) =>
          row.kind == BookmarkKind.remotePath &&
          !row.id.startsWith(quickConnectAdhocIdPrefix) &&
          sessionEndpointKey(row) == endpoint,
    );
    if (saved != _saved) setState(() => _saved = saved);
  }

  Future<void> _save() async {
    final store = widget.store;
    if (store == null) {
      widget.onNoStore();
      return;
    }
    if (_saving) return;
    final name = await promptSaveToServers(
      context,
      widget.bookmark,
      fieldKey: const ValueKey('saveFavorite.name'),
      saveKey: const ValueKey('saveFavorite.confirm'),
    );
    if (name == null || !mounted) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await saveRemoteLocationTo(
        store,
        live: widget.bookmark,
        path: widget.currentPath,
        label: name,
      );
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failed = true;
      });
      return;
    }
    if (!mounted) return;
    // The store's change event confirms it too; this spares the reload.
    setState(() {
      _saving = false;
      _saved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_saved) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final chrome = PoltergeistChrome.of(context);
    // Desktop keeps the line at 30 px; touch keeps Material's targets.
    final desktop = isDesktopPlatform(theme.platform);
    final compact = ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 8),
      ),
      minimumSize: desktop
          ? const WidgetStatePropertyAll(Size(0, _desktopControlExtent))
          : null,
      textStyle: WidgetStatePropertyAll(theme.textTheme.labelMedium),
      tapTargetSize: desktop ? MaterialTapTargetSize.shrinkWrap : null,
    );
    return Semantics(
      container: true,
      child: Container(
        key: const ValueKey('saveFavorite.bar'),
        constraints: BoxConstraints(
          minHeight: MediaQuery.textScalerOf(context).scale(30),
        ),
        padding: const EdgeInsetsDirectional.only(start: 10, end: 2),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(bottom: BorderSide(color: chrome.separator)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              ExcludeSemantics(
                child: Icon(Icons.bolt, size: 14, color: chrome.secondaryText),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _failed
                      ? l10n.saveFavoriteFailed
                      : l10n.paneUnsavedSession(
                          sessionEndpointLabel(widget.bookmark),
                        ),
                  key: ValueKey(
                    _failed ? 'saveFavorite.error' : 'saveFavorite.label',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _failed ? colors.error : chrome.secondaryText,
                  ),
                ),
              ),
              // A pane at its minimum width keeps the verb as an icon so
              // the endpoint still has room; wider panes spell it out.
              if (constraints.maxWidth >= _labelledSaveMinWidth)
                TextButton(
                  key: const ValueKey('saveFavorite.save'),
                  style: compact,
                  onPressed: _saving ? null : _save,
                  child: Text(l10n.sidebarSaveToFavorites),
                )
              else
                IconButton(
                  key: const ValueKey('saveFavorite.save'),
                  tooltip: l10n.sidebarSaveToFavorites,
                  onPressed: _saving ? null : _save,
                  visualDensity: VisualDensity.compact,
                  iconSize: 15,
                  constraints: desktop
                      ? const BoxConstraints.tightFor(
                          width: _desktopControlExtent,
                          height: _desktopControlExtent,
                        )
                      : null,
                  padding: desktop ? EdgeInsets.zero : null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
              IconButton(
                key: const ValueKey('saveFavorite.dismiss'),
                tooltip: l10n.paneUnsavedDismiss,
                onPressed: widget.onDismiss,
                visualDensity: VisualDensity.compact,
                iconSize: 14,
                constraints: desktop
                    ? const BoxConstraints.tightFor(
                        width: _desktopControlExtent,
                        height: _desktopControlExtent,
                      )
                    : null,
                padding: desktop ? EdgeInsets.zero : null,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
