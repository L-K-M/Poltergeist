import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/connection_status_controller.dart';
import '../../services/sidebar_controller.dart';
import '../../services/sidebar_probe_owner.dart';
import '../probe_status_dot.dart';
import '../server_appearance.dart';
import '../server_filter.dart';
import '../server_grouping.dart';
import '../server_state_indicator.dart';

/// How a favorite's activation resolves against the panes (02 §4):
/// [plain] follows the preferred-pane rules, [newTab] grows a tab in the
/// pane a plain click would have used, and [oppositePane] flips to the
/// other side — the explicit modifier always wins over `preferredPane`.
enum SidebarOpenAction { plain, newTab, oppositePane }

/// One drag edge a favorite row reports while a bookmark hovers it.
enum _DropEdge { before, after }

/// The collapse key of the fixed Connections section — namespaces it
/// away from favorite-group keys, which are user content.
const _connectionsSectionKey = 'sidebar.connections';

/// The collapse key of the shared-mode Séance servers section, and the
/// prefix its group headers namespace under — a catalog group's key can
/// collide with a favorite group's, and collapsing one must not fold
/// the other.
const _catalogSectionKey = 'sidebar.catalog';
const _catalogGroupKeyPrefix = 'sidebar.catalog.';

/// Séance's own rule for offering a filter: below five servers it would
/// just be chrome. Kept identical so the catalog's filter affordance
/// appears on the same list sizes it does there.
const _catalogFilterThreshold = 5;

/// The global sidebar (02 §4): the fixed Connections section — the
/// servers the pool currently holds, with live state — above the
/// favorites groups. Every surface here reads through [controller];
/// the shell owns the open/mutation wiring.
class SidebarView extends StatelessWidget {
  const SidebarView({
    required this.controller,
    required this.onOpenFavorite,
    this.connections,
    this.probes,
    this.onOpenConnection,
    this.onDisconnect,
    this.onReviewBlocked,
    this.onUpdateWorkspace,
    this.onLocalEdits,
    this.onImportSshConfig,
    this.catalog,
    this.catalogListenable,
    this.catalogSyncing = false,
    this.catalogSyncError,
    this.onSyncNow,
    this.onOpenCatalogServer,
    this.onAddCatalogServer,
    this.onEditCatalogServer,
    this.onDuplicateCatalogServer,
    this.onDeleteCatalogServer,
    super.key,
  });

  /// The favorites sections, collapse state, and store-routed mutations.
  final SidebarController controller;

  /// Live connection truth for the Connections section and for the
  /// composed badge dot on server-backed favorites (02 §4: live truth
  /// outranks probes). Null renders favorites without a Connections
  /// section and unknown dots.
  final ConnectionStatusController? connections;

  /// The reachability owner behind the badge dots; null leaves every
  /// server-backed favorite at `unknown`.
  final SidebarProbeOwner? probes;

  /// Opens [bookmark] per the resolved action; the shell owns pane
  /// resolution, tab growth, and the honest not-yet notices for the
  /// workspace/saved-sync kinds. Null renders the rows' open gestures
  /// disabled (no workspace exists to bind panes into) — matching the
  /// Connections rows' null-callback posture, never a silent dead tap.
  final void Function(Bookmark bookmark, SidebarOpenAction action)?
  onOpenFavorite;

  /// The Connections row's "Open in other pane" — resolves the row's
  /// bookmark and binds the pane opposite the active one (02 §4).
  final void Function(ConnectionServer server)? onOpenConnection;

  /// Drops the pool reference (02 §4's Connections context verb).
  final void Function(ConnectionServer server)? onDisconnect;

  /// Leads a blocked row to the changed-key review (D18).
  final void Function(ConnectionServer server)? onReviewBlocked;

  /// The workspace row's "Update Workspace" verb (02 §3): re-captures
  /// both panes over the existing favorite. Null hides the item —
  /// surfaces without a workspace seam offer open only.
  final void Function(Bookmark bookmark)? onUpdateWorkspace;

  /// The remotePath row's `Local Edits…` (06 §3.7): opens the server's
  /// local-edits review dialog. Null hides the item — a shell without a
  /// checkout session owns no edits to review.
  final void Function(Bookmark bookmark)? onLocalEdits;

  /// D22's adoption affordance inside the empty-favorites state: opens
  /// the ssh_config import preview. Null (Windows in v1, or a shell
  /// without the import seam) renders the empty copy alone.
  final VoidCallback? onImportSshConfig;

  /// The shared-mode Séance server catalog (04 §4.2): non-null only while
  /// the enrolled account is shared. Null renders no catalog section at
  /// all — separate mode has nothing to show.
  final SeanceServerCatalog? catalog;

  /// The listenable that repaints the catalog section — the backup
  /// service, whose notifications land whenever a round materializes a
  /// new catalog or the sync status changes. The catalog itself is a
  /// mutable snapshot, not a listenable.
  final Listenable? catalogListenable;

  /// A sync round is in flight — the section's sync button shows busy.
  final bool catalogSyncing;

  /// The last round's failure, surfaced on the sync button's tooltip.
  final String? catalogSyncError;

  /// The reload affordance (04 §4.2): runs one sync round immediately
  /// rather than waiting for the periodic cycle. Null hides the button —
  /// a shell without the service has nothing to drive.
  final VoidCallback? onSyncNow;

  /// Opens a catalog server in the resolved pane (the same modifier
  /// vocabulary favorites use). Null renders rows non-activatable.
  final void Function(ServerConfig server, SidebarOpenAction action)?
  onOpenCatalogServer;

  /// 04 §4.2's management verbs: the section header's add affordance and
  /// the row menu's edit/duplicate/delete. Each null hides its verb — a
  /// shell without the editor seam renders the catalog read-only.
  final VoidCallback? onAddCatalogServer;
  final void Function(ServerConfig server)? onEditCatalogServer;
  final void Function(ServerConfig server)? onDuplicateCatalogServer;
  final void Function(ServerConfig server)? onDeleteCatalogServer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller,
        ?connections,
        ?probes,
        ?catalogListenable,
      ]),
      builder: (context, _) => _SidebarBody(view: this),
    );
  }
}

class _SidebarBody extends StatelessWidget {
  const _SidebarBody({required this.view});

  final SidebarView view;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final controller = view.controller;

    final children = <Widget>[];

    // The fixed Connections section (02 §4): pool-held servers only —
    // live truth or a pane failure — never a copy of the favorites list.
    final live = _liveConnections(view.connections);
    if (live.isNotEmpty) {
      final collapsed = controller.isCollapsed(_connectionsSectionKey);
      children.add(
        _SectionHeader(
          sectionKey: _connectionsSectionKey,
          title: l10n.sidebarConnectionsSection,
          itemCount: live.length,
          collapsed: collapsed,
          onToggle: () => controller.toggleCollapsed(_connectionsSectionKey),
        ),
      );
      if (!collapsed) {
        children.addAll([
          for (final server in live)
            _ConnectionRow(
              key: ValueKey('sidebar.connection.${server.serverId}'),
              server: server,
              onOpenOtherPane: view.onOpenConnection,
              onDisconnect: view.onDisconnect,
              onReviewBlocked: view.onReviewBlocked,
            ),
        ]);
      }
    }

    switch (controller.load) {
      case SidebarLoad.idle || SidebarLoad.loading
          when controller.sections.isEmpty:
        children.add(
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Semantics(
                label: l10n.connectionsLoading,
                container: true,
                child: const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ),
        );
      case SidebarLoad.failed when controller.sections.isEmpty:
        children.add(
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Icon(Icons.error_outline, color: scheme.error, size: 28),
                const SizedBox(height: 8),
                Text(
                  l10n.connectionsLoadFailed,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const ValueKey('sidebar.retry'),
                  onPressed: () => unawaited(controller.reload()),
                  child: Text(l10n.connectionRetry),
                ),
              ],
            ),
          ),
        );
      case _:
        final sections = controller.sections;
        final favoriteCount = [
          for (final section in sections) ...section.bookmarks,
        ].length;
        if (favoriteCount == 0 && live.isEmpty) {
          children.add(
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    l10n.sidebarEmptyFavorites,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  // D22's adoption beat: an empty favorites list is the
                  // moment the ssh_config import earns its keep.
                  if (view.onImportSshConfig != null) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      key: const ValueKey('sidebar.importSshConfig'),
                      onPressed: view.onImportSshConfig,
                      icon: const Icon(Icons.download_outlined, size: 16),
                      label: Text(l10n.sidebarImportSshConfig),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        // One flat list when nothing is grouped (the sectioning contract
        // returns a single anonymous section); otherwise a header per
        // named group and a "Favorites" header over the ungrouped tail.
        final grouped = sections.length > 1 || sections.first.name != null;
        for (final section in sections) {
          if (grouped) {
            final collapsed = controller.isCollapsed(section.key);
            children.add(
              _SectionHeader(
                sectionKey: section.key,
                title: section.name ?? l10n.sidebarUngroupedSection,
                itemCount: section.bookmarks.length,
                collapsed: collapsed,
                onToggle: () => controller.toggleCollapsed(section.key),
                onAcceptBookmark: (bookmark) =>
                    unawaited(_dropBookmark(view, bookmark, section.name)),
              ),
            );
            if (collapsed) continue;
          }
          for (final bookmark in section.bookmarks) {
            children.add(
              _FavoriteRow(
                key: ValueKey('sidebar.favorite.${bookmark.id}'),
                bookmark: bookmark,
                section: section,
                view: view,
              ),
            );
          }
        }
    }

    // The shared-mode catalog (04 §4.2): pulled Séance servers in
    // Séance's own sectioning, independent of the favorites store's
    // load state — a failed favorites read must not hide servers that
    // did arrive.
    if (view.catalog != null) {
      children.add(_CatalogSection(view: view));
    }

    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: children,
      ),
    );
  }

  /// The pool's live rows: any reported state that is not a plain idle
  /// teardown, plus pane-attributed failures. A disconnected-with-detail
  /// row keeps its failure visible until the next truth arrives.
  static List<ConnectionServer> _liveConnections(
    ConnectionStatusController? connections,
  ) {
    if (connections == null) return const [];
    return [
      for (final server in connections.servers)
        if ((server.status != null &&
                (server.status!.state != ServerConnectionState.disconnected ||
                    server.status!.detail != null)) ||
            server.paneFailure != null)
          server,
    ];
  }
}

/// The drop operation both targets resolve to: same-group drops land on
/// [BookmarkStore.moveToGroup]'s neighbor math; dropping on a group
/// header appends at its tail. A no-op adjacent drop still writes —
/// harmless, and the store's serialized tail keeps it honest.
///
/// [beforeId]/[afterId] follow the store's between-neighbors convention:
/// `beforeId` names the member the dropped bookmark lands *after*,
/// `afterId` the member it lands *before* — not "insert before this id".
Future<void> _dropBookmark(
  SidebarView view,
  Bookmark bookmark,
  String? group, {
  String? beforeId,
  String? afterId,
}) async {
  try {
    await view.controller.drop(
      bookmark.id,
      group,
      beforeId: beforeId,
      afterId: afterId,
    );
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
  }
}

/// A collapsible section header: the chevron + title, tappable and
/// keyboard-operable (Enter toggles; focus traversal reaches it like a
/// row), and — for favorite groups — a drop target that appends the
/// dragged bookmark at the group's tail.
class _SectionHeader extends StatefulWidget {
  const _SectionHeader({
    required this.sectionKey,
    required this.title,
    required this.itemCount,
    required this.collapsed,
    required this.onToggle,
    this.onAcceptBookmark,
    this.trailing,
  });

  final String sectionKey;
  final String title;

  /// The section's row count, spelled out in the semantics label
  /// (02 §13's group-header rule).
  final int itemCount;
  final bool collapsed;
  final VoidCallback onToggle;
  final void Function(Bookmark bookmark)? onAcceptBookmark;

  /// An optional widget at the header's trailing edge — the catalog
  /// section parks its sync button there. Excluded from the merged
  /// semantics node: the button announces itself.
  final Widget? trailing;

  @override
  State<_SectionHeader> createState() => _SectionHeaderState();
}

class _SectionHeaderState extends State<_SectionHeader> {
  bool _hovering = false;
  final _focusNode = FocusNode();

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
      return KeyEventResult.handled;
    }
    // Repeats may drive traversal, never activation — a held key must
    // not flicker the collapse state.
    if (event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        // The expandable pattern's directions: Right expands, Left
        // collapses — a blind toggle on either reads inverted half
        // the time.
        (key == LogicalKeyboardKey.arrowRight && widget.collapsed) ||
        (key == LogicalKeyboardKey.arrowLeft && !widget.collapsed)) {
      widget.onToggle();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final accept = widget.onAcceptBookmark;

    final header = Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          // 02 §13's group-header shape: one merged node carrying the
          // spelled-out title + count, with the expanded flag inside.
          return MergeSemantics(
            child: Semantics(
              header: true,
              button: true,
              expanded: !widget.collapsed,
              label: AppLocalizations.of(context).sidebarSectionSemantics(
                widget.title,
                AppLocalizations.of(context).paneItemCount(widget.itemCount),
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // The pointer moves focus with it, same as the rows —
                // arrows and Enter act on the header last touched.
                onTap: () {
                  _focusNode.requestFocus();
                  widget.onToggle();
                },
                child: Container(
                  key: ValueKey('sidebar.section.${widget.sectionKey}'),
                  height: 30,
                  padding: const EdgeInsetsDirectional.only(start: 8, end: 8),
                  decoration: BoxDecoration(
                    color: _hovering
                        ? scheme.primary.withValues(alpha: 0.12)
                        : null,
                    border: focused
                        ? Border.all(color: scheme.primary, width: 2)
                        : null,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        widget.collapsed
                            ? Icons.chevron_right
                            : Icons.expand_more,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        // The merged header node already announces the
                        // full "title, N items" label; exclude the raw
                        // text so screen readers don't read it twice.
                        child: ExcludeSemantics(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );

    Widget result = header;
    if (accept != null) {
      result = DragTarget<Bookmark>(
        onWillAcceptWithDetails: (details) => details.data.id.isNotEmpty,
        onAcceptWithDetails: (details) {
          // An accepted drop never fires onLeave — clear the highlight
          // here or the header stays armed-looking until the next drag.
          if (_hovering) setState(() => _hovering = false);
          accept(details.data);
        },
        onMove: (_) {
          if (!_hovering) setState(() => _hovering = true);
        },
        onLeave: (_) {
          if (_hovering) setState(() => _hovering = false);
        },
        builder: (context, candidates, rejected) => header,
      );
    }
    // The trailing widget sits OUTSIDE the header's semantics merge and
    // toggle gesture — a sync button must announce and act on itself,
    // not fold into the section header it ornaments.
    final trailing = widget.trailing;
    if (trailing != null) {
      result = Row(children: [Expanded(child: result), trailing]);
    }
    return result;
  }
}

/// One favorite row: badge with the composed status dot in its corner
/// (02 §4 — exactly one indicator), label + context subtitle, tap/modifier
/// activation, context menu, keyboard operation, and both halves of the
/// reorder/regroup drag contract.
class _FavoriteRow extends StatefulWidget {
  const _FavoriteRow({
    required this.bookmark,
    required this.section,
    required this.view,
    super.key,
  });

  final Bookmark bookmark;
  final BookmarkGroupSection section;
  final SidebarView view;

  @override
  State<_FavoriteRow> createState() => _FavoriteRowState();
}

class _FavoriteRowState extends State<_FavoriteRow> {
  final _menuController = MenuController();
  final _focusNode = FocusNode(debugLabel: 'sidebar.favorite');
  _DropEdge? _dropEdge;

  @override
  void initState() {
    super.initState();
    // 02 §4's "first probe waits until the favorite is visible in the
    // sidebar": mounting the row is the visibility mark. The owner
    // no-ops on ids it has no endpoint for, so every kind can report.
    widget.view.probes?.noteVisible(widget.bookmark.id);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  SidebarOpenAction _actionForTap() {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed) return SidebarOpenAction.oppositePane;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      return SidebarOpenAction.newTab;
    }
    return SidebarOpenAction.plain;
  }

  void _open([SidebarOpenAction? action]) {
    widget.view.onOpenFavorite?.call(
      widget.bookmark,
      action ?? _actionForTap(),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      // Repeats may drive traversal, never activation; a row with no
      // open seam is non-interactive and must not swallow the event.
      if (event is KeyRepeatEvent || widget.view.onOpenFavorite == null) {
        return KeyEventResult.ignored;
      }
      _open(SidebarOpenAction.plain);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        (key == LogicalKeyboardKey.f10 && keyboard.isShiftPressed)) {
      if (event is KeyRepeatEvent) return KeyEventResult.ignored;
      _menuController.open();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final view = widget.view;
    final bookmark = widget.bookmark;

    final liveStatus = _statusOf(view.connections, bookmark.id);
    final appearance = serverIndicatorOf(
      l10n,
      status: liveStatus,
      probe: view.probes?.statuses[bookmark.id],
    );
    final semanticLabel = appearance.label.isEmpty
        ? bookmark.label
        : '${bookmark.label}, ${appearance.label}';

    final row = Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: Builder(
        builder: (context) {
          final focused = _focusNode.hasFocus;
          return Semantics(
            container: true,
            // A row with no open seam is not an activatable button —
            // the same gate the connection row applies.
            button: view.onOpenFavorite != null,
            label: semanticLabel,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // The pointer moves focus with it (02 §4's keyboard rule):
              // a tapped row holds focus so Enter/arrows keep working
              // from the row the user last touched.
              onTapDown: (_) => _focusNode.requestFocus(),
              onTap: view.onOpenFavorite == null ? null : () => _open(),
              onSecondaryTapUp: (_) => _menuController.open(),
              child: ExcludeSemantics(
                child: MenuAnchor(
                  controller: _menuController,
                  menuChildren: _menuItems(context, l10n),
                  child: Container(
                    height: 40,
                    padding: const EdgeInsetsDirectional.only(
                      start: 10,
                      end: 8,
                    ),
                    decoration: BoxDecoration(
                      border: Border(
                        top: _dropEdge == _DropEdge.before
                            ? BorderSide(color: scheme.primary, width: 2)
                            : BorderSide.none,
                        bottom: _dropEdge == _DropEdge.after
                            ? BorderSide(color: scheme.primary, width: 2)
                            : BorderSide.none,
                        left: focused
                            ? BorderSide(color: scheme.primary, width: 2)
                            : BorderSide.none,
                        right: focused
                            ? BorderSide(color: scheme.primary, width: 2)
                            : BorderSide.none,
                      ),
                      color: focused
                          ? scheme.primary.withValues(alpha: 0.08)
                          : null,
                    ),
                    child: Row(
                      children: [
                        _FavoriteBadge(
                          bookmark: bookmark,
                          appearance: appearance,
                          probe: view.probes?.statuses[bookmark.id],
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                bookmark.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodyMedium,
                              ),
                              if (_subtitle(bookmark, l10n) case final sub?)
                                Text(
                                  sub,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );

    // Both halves of the reorder contract (02 §4): the row is the
    // dragged payload and the half-split drop target that resolves the
    // dragged bookmark's landing position inside this section.
    return DragTarget<Bookmark>(
      onWillAcceptWithDetails: (details) => details.data.id != bookmark.id,
      onMove: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        final local = box.globalToLocal(details.offset);
        final edge = local.dy < box.size.height / 2
            ? _DropEdge.before
            : _DropEdge.after;
        if (edge != _dropEdge) setState(() => _dropEdge = edge);
      },
      onLeave: (_) {
        if (_dropEdge != null) setState(() => _dropEdge = null);
      },
      onAcceptWithDetails: (details) {
        final edge = _dropEdge;
        setState(() => _dropEdge = null);
        unawaited(
          _dropBookmark(
            view,
            details.data,
            widget.section.name,
            // A drop on the row's bottom half lands *after* it — under
            // the store's between-neighbors convention that makes this
            // row the `beforeId` (see _dropBookmark's doc).
            beforeId: edge == _DropEdge.after ? bookmark.id : null,
            afterId: edge == _DropEdge.before ? bookmark.id : null,
          ),
        );
      },
      builder: (context, candidates, rejected) => Draggable<Bookmark>(
        data: bookmark,
        feedback: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 200,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                _FavoriteBadge(
                  bookmark: bookmark,
                  appearance: appearance,
                  probe: view.probes?.statuses[bookmark.id],
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    bookmark.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: row),
        child: row,
      ),
    );
  }

  List<Widget> _menuItems(BuildContext context, AppLocalizations l10n) {
    final view = widget.view;
    final bookmark = widget.bookmark;
    final open = view.onOpenFavorite;
    // A workspace replaces BOTH panes — the new-tab/other-pane modifier
    // verbs have no meaning for it; the row's second verb is the
    // re-capture (02 §3's update-over, one bookmark = one workspace).
    final isWorkspace = bookmark.kind == BookmarkKind.workspace;
    return [
      MenuItemButton(
        key: const ValueKey('sidebar.menu.open'),
        onPressed: open == null
            ? null
            : () => _open(SidebarOpenAction.plain),
        child: Text(l10n.sidebarOpen),
      ),
      if (!isWorkspace)
        MenuItemButton(
          key: const ValueKey('sidebar.menu.openNewTab'),
          onPressed: open == null
              ? null
              : () => _open(SidebarOpenAction.newTab),
          child: Text(l10n.sidebarOpenInNewTab),
        ),
      if (!isWorkspace)
        MenuItemButton(
          key: const ValueKey('sidebar.menu.openOtherPane'),
          onPressed: open == null
              ? null
              : () => _open(SidebarOpenAction.oppositePane),
          child: Text(l10n.sidebarOpenInOtherPane),
        ),
      if (isWorkspace && view.onUpdateWorkspace != null)
        MenuItemButton(
          key: const ValueKey('sidebar.menu.updateWorkspace'),
          onPressed: () => view.onUpdateWorkspace!(bookmark),
          child: Text(l10n.sidebarWorkspaceUpdate),
        ),
      // 06 §3.7's review entry: server-scoped, so remotePath favorites
      // surface it — a managed copy's record belongs to the server,
      // including edits on paths no pane currently shows. The dialog
      // still opens when nothing is pending (empty state) so the verb
      // never looks like a dead end.
      if (bookmark.kind == BookmarkKind.remotePath && view.onLocalEdits != null)
        MenuItemButton(
          key: const ValueKey('sidebar.menu.localEdits'),
          onPressed: () => view.onLocalEdits!(bookmark),
          child: Text(l10n.sidebarLocalEdits),
        ),
      const Divider(height: 1),
      MenuItemButton(
        key: const ValueKey('sidebar.menu.rename'),
        onPressed: () => unawaited(_renameFavorite(context, view, bookmark)),
        child: Text(l10n.sidebarRename),
      ),
      SubmenuButton(
        key: const ValueKey('sidebar.menu.moveToGroup'),
        menuChildren: _groupMenuItems(context, l10n),
        child: Text(l10n.sidebarMoveToGroup),
      ),
      const Divider(height: 1),
      MenuItemButton(
        key: const ValueKey('sidebar.menu.delete'),
        onPressed: () => unawaited(_deleteFavorite(context, view, bookmark)),
        child: Text(l10n.sidebarDelete),
      ),
    ];
  }

  List<Widget> _groupMenuItems(BuildContext context, AppLocalizations l10n) {
    final bookmark = widget.bookmark;
    // The loaded sections already carry every group name in the store's
    // own order — an async groupNames() read here would flash an empty
    // submenu on every rebuild and silently swallow a failed fetch.
    final names = [
      for (final section in widget.view.controller.sections) ?section.name,
    ];
    return [
      MenuItemButton(
        key: const ValueKey('sidebar.menu.ungroup'),
        onPressed: () => unawaited(_dropBookmark(widget.view, bookmark, null)),
        child: Text(l10n.sidebarNoGroup),
      ),
      for (final name in names)
        MenuItemButton(
          onPressed: () =>
              unawaited(_dropBookmark(widget.view, bookmark, name)),
          child: Text(name),
        ),
      const Divider(height: 1),
      MenuItemButton(
        key: const ValueKey('sidebar.menu.newGroup'),
        onPressed: () =>
            unawaited(_newGroupFor(context, widget.view, bookmark)),
        child: Text(l10n.sidebarNewGroup),
      ),
    ];
  }
}

/// The badge + its one corner indicator (02 §4: exactly one dot composed
/// into the badge corner, fixing SEA-021's doubled indicators).
class _FavoriteBadge extends StatelessWidget {
  const _FavoriteBadge({
    required this.bookmark,
    required this.appearance,
    this.probe,
  });

  final Bookmark bookmark;
  final ServerIndicatorAppearance appearance;

  /// The raw reachability truth the resolver saw — the appearance's
  /// glyph names the *kind* of indicator but not the tri-state behind
  /// it, which is what the corner dot paints.
  final ProbeStatus? probe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = serverAccent(
      context,
      ServerTint(named: bookmark.color),
    );

    final dotColor = _indicatorDotColor(scheme, appearance, probe);

    return SizedBox(
      width: 30,
      height: 30,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: accent?.container ?? scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(
                _iconFor(bookmark),
                size: 15,
                color: accent?.onContainer ?? scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (dotColor != null)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  // A surface-colored ring keeps the dot readable over
                  // any badge accent — the badge corner is theme-busy.
                  border: Border.all(color: scheme.surface, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static IconData _iconFor(Bookmark bookmark) => switch (bookmark.kind) {
    BookmarkKind.localFolder =>
      bookmark.icon != null
          ? serverIconData(bookmark.icon)
          : Icons.folder_outlined,
    BookmarkKind.remotePath => serverIconData(bookmark.icon),
    BookmarkKind.workspace => Icons.space_dashboard_outlined,
    BookmarkKind.savedSync => Icons.sync_alt,
  };
}

/// The corner dot's colour for one composed indicator — shared by the
/// favorite badge and the catalog badge so both surfaces paint the same
/// truth the same way.
Color? _indicatorDotColor(
  ColorScheme scheme,
  ServerIndicatorAppearance appearance,
  ProbeStatus? probe,
) =>
    switch (appearance.glyph) {
      ServerIndicatorGlyph.probe => switch (probe) {
        ProbeStatus.online => ProbeStatusDot.onlineColor,
        ProbeStatus.offline => scheme.error,
        _ => scheme.outline,
      },
      ServerIndicatorGlyph.connected => ProbeStatusDot.onlineColor,
      ServerIndicatorGlyph.pending => scheme.primary,
      ServerIndicatorGlyph.failed ||
      ServerIndicatorGlyph.blocked => scheme.error,
      ServerIndicatorGlyph.none || ServerIndicatorGlyph.idle => null,
    };

/// The subtitle under a favorite's label: the endpoint the row opens,
/// or the kind name when there is no single path to show.
String? _subtitle(Bookmark bookmark, AppLocalizations l10n) =>
    switch (bookmark.kind) {
      BookmarkKind.localFolder => bookmark.localPath,
      BookmarkKind.remotePath => bookmark.remotePath,
      BookmarkKind.workspace => l10n.sidebarKindWorkspace,
      BookmarkKind.savedSync => l10n.sidebarKindSavedSync,
    };

/// The live status the connections list reports for [id], if any.
ServerStatus? _statusOf(
  ConnectionStatusController? connections,
  String serverId,
) {
  final list = connections?.servers;
  if (list == null) return null;
  for (final server in list) {
    if (server.serverId == serverId) return server.status;
  }
  return null;
}

/// The rename dialog (02 §4's context verb): a store save through the
/// controller, so the `updatedAt` stamp lands. A failed save reports
/// and shows the honest transient notice — the record is untouched.
Future<void> _renameFavorite(
  BuildContext context,
  SidebarView view,
  Bookmark bookmark,
) async {
  final l10n = AppLocalizations.of(context);
  // TextFormField owns its controller through the pop animation — an
  // external TextEditingController disposed at `await` return would be
  // torn down under the still-animating route.
  var text = bookmark.label;
  final renamed = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      var canSave = text.trim().isNotEmpty;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.sidebarRenameTitle),
          content: TextFormField(
            key: const ValueKey('sidebar.renameField'),
            initialValue: bookmark.label,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.sidebarRenameFieldLabel,
            ),
            onChanged: (value) {
              text = value;
              setState(() => canSave = text.trim().isNotEmpty);
            },
            onFieldSubmitted: (_) {
              if (canSave) {
                Navigator.of(dialogContext).pop(text.trim());
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.tabCloseConfirmCancel),
            ),
            FilledButton(
              key: const ValueKey('sidebar.renameSave'),
              onPressed: canSave
                  ? () => Navigator.of(dialogContext).pop(text.trim())
                  : null,
              child: Text(l10n.saveFavoriteSave),
            ),
          ],
        ),
      );
    },
  );
  if (renamed == null || renamed == bookmark.label) return;
  if (!context.mounted) return;
  try {
    await view.controller.rename(bookmark.id, renamed);
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (!context.mounted) return;
    _showSidebarError(context, AppLocalizations.of(context));
  }
}

/// The "Move to Group ▸ New Group…" flow: prompt for the name, then
/// refile through the store — group records are member-carried, so
/// creating a group IS the move (there is no separate create verb).
Future<void> _newGroupFor(
  BuildContext context,
  SidebarView view,
  Bookmark bookmark,
) async {
  final l10n = AppLocalizations.of(context);
  var text = '';
  final group = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      var canSave = false;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.sidebarNewGroupTitle),
          content: TextFormField(
            key: const ValueKey('sidebar.groupField'),
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.sidebarGroupFieldLabel,
            ),
            onChanged: (value) {
              text = value;
              setState(() => canSave = text.trim().isNotEmpty);
            },
            onFieldSubmitted: (_) {
              if (canSave) {
                Navigator.of(dialogContext).pop(text.trim());
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.tabCloseConfirmCancel),
            ),
            FilledButton(
              key: const ValueKey('sidebar.groupSave'),
              onPressed: canSave
                  ? () => Navigator.of(dialogContext).pop(text.trim())
                  : null,
              child: Text(l10n.saveFavoriteSave),
            ),
          ],
        ),
      );
    },
  );
  if (group == null || !context.mounted) return;
  try {
    await view.controller.moveToGroup(bookmark.id, group);
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (!context.mounted) return;
    _showSidebarError(context, AppLocalizations.of(context));
  }
}

/// The delete verb: a confirmation, then the store remove — the engine
/// cascade rides the controller's `onBookmarkRemoved` seam after the
/// record is actually gone (never before, never without it).
Future<void> _deleteFavorite(
  BuildContext context,
  SidebarView view,
  Bookmark bookmark,
) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.sidebarDeleteTitle),
      content: Text(l10n.sidebarDeleteBody(bookmark.label)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.tabCloseConfirmCancel),
        ),
        FilledButton(
          key: const ValueKey('sidebar.deleteConfirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.sidebarDelete),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await view.controller.remove(bookmark.id);
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (!context.mounted) return;
    _showSidebarError(context, AppLocalizations.of(context));
  }
}

void _showSidebarError(BuildContext context, AppLocalizations l10n) {
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(l10n.sidebarActionFailed)));
}

/// A Connections-section row: the pool's live state per server (glyph +
/// label + failure line), and its context menu (Open in other pane,
/// Disconnect, the blocked row's review affordance).
class _ConnectionRow extends StatefulWidget {
  const _ConnectionRow({
    required this.server,
    this.onOpenOtherPane,
    this.onDisconnect,
    this.onReviewBlocked,
    super.key,
  });

  final ConnectionServer server;
  final void Function(ConnectionServer server)? onOpenOtherPane;
  final void Function(ConnectionServer server)? onDisconnect;
  final void Function(ConnectionServer server)? onReviewBlocked;

  @override
  State<_ConnectionRow> createState() => _ConnectionRowState();
}

class _ConnectionRowState extends State<_ConnectionRow> {
  final _menuController = MenuController();
  final _focusNode = FocusNode(debugLabel: 'sidebar.connection');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      // Repeats may drive traversal, never activation; a row with no
      // open seam is non-interactive and must not swallow the event.
      if (event is KeyRepeatEvent || widget.onOpenOtherPane == null) {
        return KeyEventResult.ignored;
      }
      widget.onOpenOtherPane!(widget.server);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        (key == LogicalKeyboardKey.f10 && keyboard.isShiftPressed)) {
      if (event is KeyRepeatEvent) return KeyEventResult.ignored;
      _menuController.open();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final server = widget.server;

    final appearance = serverIndicatorOf(
      l10n,
      status:
          server.status ??
          const ServerStatus(ServerConnectionState.disconnected),
    );
    final blocked = appearance.glyph == ServerIndicatorGlyph.blocked;
    final live = switch (server.status?.state) {
      ServerConnectionState.connecting ||
      ServerConnectionState.connected ||
      ServerConnectionState.reconnecting => true,
      _ => false,
    };
    // The excluded subtree hides the failure detail and the blocked
    // warning from assistive tech — fold them into the announced label.
    final semanticLabel = [
      server.label,
      appearance.label,
      if (blocked) l10n.connectionsBlockedWarning,
      ?server.status?.detail,
    ].join(', ');

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: Semantics(
        container: true,
        // A row with no open seam is not an activatable button — an
        // announced-but-inert role is the same dead affordance the
        // detector placement guards against.
        button: widget.onOpenOtherPane != null,
        label: semanticLabel,
        // The detector must sit OUTSIDE ExcludeSemantics or its tap
        // never reaches the semantics tree — an announced button a
        // screen reader cannot activate (WCAG 4.1.2).
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _focusNode.requestFocus(),
          onTap: widget.onOpenOtherPane == null
              ? null
              : () => widget.onOpenOtherPane!(server),
          onSecondaryTapUp: (_) => _menuController.open(),
          child: ExcludeSemantics(
            child: MenuAnchor(
              controller: _menuController,
              menuChildren: [
                if (widget.onOpenOtherPane != null)
                  MenuItemButton(
                    key: const ValueKey('sidebar.menu.connOpen'),
                    onPressed: () => widget.onOpenOtherPane!(server),
                    child: Text(l10n.sidebarOpenInOtherPane),
                  ),
                if (widget.onDisconnect != null)
                  MenuItemButton(
                    key: const ValueKey('sidebar.menu.disconnect'),
                    onPressed: live
                        ? () => widget.onDisconnect!(server)
                        : null,
                    child: Text(l10n.sidebarDisconnect),
                  ),
                if (blocked && widget.onReviewBlocked != null)
                  MenuItemButton(
                    key: ValueKey('sidebar.menu.review.${server.serverId}'),
                    onPressed: () => widget.onReviewBlocked!(server),
                    child: Text(l10n.connectionsReviewHostKey),
                  ),
              ],
              child: Container(
                padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 8, 8),
                decoration: BoxDecoration(
                  border: _focusNode.hasFocus
                      ? Border.all(color: scheme.primary, width: 2)
                      : null,
                  color: _focusNode.hasFocus
                      ? scheme.primary.withValues(alpha: 0.08)
                      : null,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: ServerStateIndicator(status: server.status),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            server.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium,
                          ),
                          Text(
                            '${server.username}@${server.host}:${server.port}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          if (server.status?.detail != null)
                            Text(
                              server.status!.detail!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.labelSmall?.copyWith(
                                color: scheme.error,
                              ),
                            ),
                          // D18's copy on a blocked row: the block is
                          // never lifted silently — the review menu
                          // verb leads to the changed-key prompt.
                          if (blocked)
                            Text(
                              l10n.connectionsBlockedWarning,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.labelSmall?.copyWith(
                                color: scheme.error,
                              ),
                            ),
                          if (server.paneFailure != null)
                            Text(
                              l10n.connectionsPaneFailure(
                                server.paneFailure!.paneTabId,
                                server.paneFailure!.message,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.labelSmall?.copyWith(
                                color: scheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The shared-mode "Séance servers" section (04 §4.2's catalog surface):
/// the pulled `serverConfig` records rendered through Séance's own
/// grouping and filter rules, so the same account's list reads the same
/// way here — same groups, same order, same marks — while staying
/// distinct from the user-ordered favorites above it.
///
/// Stateful only for the filter field: the query, its controller, and
/// the Enter-opens-first-match affordance Séance's list carries.
class _CatalogSection extends StatefulWidget {
  const _CatalogSection({required this.view});

  final SidebarView view;

  @override
  State<_CatalogSection> createState() => _CatalogSectionState();
}

class _CatalogSectionState extends State<_CatalogSection> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setQuery(String query) => setState(() => _query = query);

  void _clearQuery() {
    _search.clear();
    setState(() => _query = '');
  }

  void _openFirstMatch(List<ServerConfig> matches) {
    if (matches.isEmpty) return;
    widget.view.onOpenCatalogServer?.call(
      matches.first,
      SidebarOpenAction.plain,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final view = widget.view;
    final controller = view.controller;
    final catalog = view.catalog!;
    final servers = catalog.servers;

    // Séance's stale-query rule: once the list it filtered is empty the
    // query has nothing to do, so it drops itself. Field assignment, not
    // setState — this runs inside build.
    if (servers.isEmpty && _query.isNotEmpty) {
      _search.clear();
      _query = '';
    }
    final matches = filterServers(servers, _query);
    // Séance's visibility rule: the field appears at five servers, and
    // stays while a query is active even below that — a vanished field
    // would strand a filter with no way to clear it. Never over the
    // empty state: a box beside "no servers" reads as "hidden", not
    // "none".
    final showFilter = servers.isNotEmpty &&
        (servers.length >= _catalogFilterThreshold || _query.isNotEmpty);

    final collapsed = controller.isCollapsed(_catalogSectionKey);
    final children = <Widget>[
      _SectionHeader(
        sectionKey: _catalogSectionKey,
        title: l10n.sidebarCatalogSection,
        itemCount: matches.length,
        collapsed: collapsed,
        onToggle: () => controller.toggleCollapsed(_catalogSectionKey),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _addButton(l10n, scheme),
            _syncButton(context, l10n, scheme),
          ],
        ),
      ),
    ];
    if (collapsed) {
      return Column(children: children);
    }

    if (showFilter) {
      children.add(_filterField(l10n, matches, servers.length));
    }
    if (matches.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            servers.isEmpty
                ? l10n.sidebarCatalogEmpty
                : l10n.sidebarCatalogNoMatches,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
      return Column(children: children);
    }

    // Séance's collapse rule: a live query overrides folded groups — a
    // filter reporting "3 of 12" while showing one row reads as broken,
    // not tidy.
    final sections = groupServers(matches);
    final collapsedKeys = <String>{};
    if (_query.isEmpty) {
      for (final section in sections) {
        if (controller.isCollapsed('$_catalogGroupKeyPrefix${section.key}')) {
          collapsedKeys.add(section.key);
        }
      }
    }
    for (final row
        in serverListRows(sections: sections, collapsedKeys: collapsedKeys)) {
      switch (row) {
        case ServerGroupHeaderRow(
          :final name,
          :final key,
          :final count,
          collapsed: final rowCollapsed,
        ):
          children.add(
            _SectionHeader(
              sectionKey: '$_catalogGroupKeyPrefix$key',
              title: name == kUngroupedLabel || name == kUnpinnedLabel
                  ? l10n.sidebarCatalogUngrouped
                  : name,
              itemCount: count,
              collapsed: rowCollapsed,
              onToggle: () =>
                  controller.toggleCollapsed('$_catalogGroupKeyPrefix$key'),
            ),
          );
        case ServerRow(:final server):
          children.add(
            _CatalogRow(
              key: ValueKey('sidebar.catalog.row.${server.id}'),
              server: server,
              view: view,
            ),
          );
      }
    }
    return Column(children: children);
  }

  /// The header's add affordance (04 §4.2's editor entry): a new server
  /// drafted blank. Hidden where the shell has no editor seam — the
  /// catalog then reads as the read-only surface it is.
  Widget _addButton(AppLocalizations l10n, ColorScheme scheme) {
    final onAdd = widget.view.onAddCatalogServer;
    if (onAdd == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 4),
      child: IconButton(
        key: const ValueKey('sidebar.catalog.add'),
        iconSize: 16,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        visualDensity: VisualDensity.compact,
        tooltip: l10n.sidebarCatalogAddServer,
        onPressed: onAdd,
        icon: Icon(Icons.add, color: scheme.onSurfaceVariant),
      ),
    );
  }

  /// The header's sync affordance (04 §4.2's reload button): one manual
  /// round on demand — busy while one is in flight, marked with the last
  /// failure otherwise.
  Widget _syncButton(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    final view = widget.view;
    final onSyncNow = view.onSyncNow;
    if (onSyncNow == null) return const SizedBox.shrink();
    if (view.catalogSyncing) {
      return const Padding(
        padding: EdgeInsetsDirectional.only(end: 12),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final error = view.catalogSyncError;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 4),
      child: IconButton(
        key: const ValueKey('sidebar.catalog.syncNow'),
        iconSize: 16,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        visualDensity: VisualDensity.compact,
        tooltip: error == null
            ? l10n.sidebarCatalogSyncNow
            : l10n.sidebarCatalogSyncFailed(error),
        onPressed: onSyncNow,
        icon: Icon(
          error == null ? Icons.sync : Icons.sync_problem,
          color: error == null ? scheme.onSurfaceVariant : scheme.error,
        ),
      ),
    );
  }

  /// The catalog's filter field — Séance's affordance, compacted for the
  /// rail: term matching, Escape clears, Enter opens the first match.
  Widget _filterField(
    AppLocalizations l10n,
    List<ServerConfig> matches,
    int total,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                _clearQuery();
                return null;
              },
            ),
          },
          child: TextField(
            controller: _search,
            onChanged: _setQuery,
            // _openFirstMatch no-ops on an empty match list, so Enter in
            // a field matching nothing cannot open a hidden row.
            onSubmitted: (_) => _openFirstMatch(matches),
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 8,
              ),
              prefixIcon: const Icon(Icons.search, size: 16),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 32,
                minHeight: 24,
              ),
              hintText: l10n.sidebarCatalogFilter,
              helperText: _query.isEmpty
                  ? null
                  : matches.isEmpty
                  ? l10n.sidebarCatalogFilterCount(matches.length, total)
                  : l10n.sidebarCatalogFilterCountOpenFirst(
                      matches.length,
                      total,
                    ),
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: l10n.sidebarCatalogFilterClear,
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: _clearQuery,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One catalog row: the Séance server rendered with its own accent bar
/// and mark (the appearance both apps now share), the composed status
/// dot in the badge corner, the same activation vocabulary favorites
/// use, and a context menu with the open verbs above the management
/// verbs the shell offers.
class _CatalogRow extends StatefulWidget {
  const _CatalogRow({required this.server, required this.view, super.key});

  final ServerConfig server;
  final SidebarView view;

  @override
  State<_CatalogRow> createState() => _CatalogRowState();
}

class _CatalogRowState extends State<_CatalogRow> {
  final _menuController = MenuController();
  final _focusNode = FocusNode(debugLabel: 'sidebar.catalogRow');

  @override
  void initState() {
    super.initState();
    // The same visibility mark favorites report: mounting the row is
    // what makes a catalog server probe-eligible on this device.
    widget.view.probes?.noteVisible(widget.server.id);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  SidebarOpenAction _actionForTap() {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed) return SidebarOpenAction.oppositePane;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      return SidebarOpenAction.newTab;
    }
    return SidebarOpenAction.plain;
  }

  void _open([SidebarOpenAction? action]) {
    widget.view.onOpenCatalogServer?.call(
      widget.server,
      action ?? _actionForTap(),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      if (event is KeyRepeatEvent ||
          widget.view.onOpenCatalogServer == null) {
        return KeyEventResult.ignored;
      }
      _open(SidebarOpenAction.plain);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        (key == LogicalKeyboardKey.f10 && keyboard.isShiftPressed)) {
      if (event is KeyRepeatEvent) return KeyEventResult.ignored;
      _menuController.open();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final view = widget.view;
    final server = widget.server;
    final openable = view.onOpenCatalogServer != null;

    final appearance = serverIndicatorOf(
      l10n,
      status: _statusOf(view.connections, server.id),
      probe: view.probes?.statuses[server.id],
    );
    final semanticLabel = appearance.label.isEmpty
        ? server.label
        : '${server.label}, ${appearance.label}';

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: Builder(
        builder: (context) {
          final focused = _focusNode.hasFocus;
          return Semantics(
            container: true,
            button: openable,
            label: semanticLabel,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => _focusNode.requestFocus(),
              onTap: openable ? () => _open() : null,
              onSecondaryTapUp: (_) => _menuController.open(),
              child: ExcludeSemantics(
                child: MenuAnchor(
                  controller: _menuController,
                  menuChildren: _menuItems(l10n),
                  child: Container(
                    height: 40,
                    padding: const EdgeInsetsDirectional.only(
                      start: 10,
                      end: 8,
                    ),
                    decoration: BoxDecoration(
                      border: focused
                          ? Border.all(color: scheme.primary, width: 2)
                          : null,
                      color: focused
                          ? scheme.primary.withValues(alpha: 0.08)
                          : null,
                    ),
                    child: Row(
                      children: [
                        // Séance's row mark: the thin accent line every
                        // coloured server draws at its edge.
                        ServerAccentBar(
                          tint: ServerTint.of(server),
                          height: 30,
                        ),
                        const SizedBox(width: 8),
                        _CatalogBadge(
                          server: server,
                          appearance: appearance,
                          probe: view.probes?.statuses[server.id],
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                server.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodyMedium,
                              ),
                              Text(
                                '${server.username}@${server.host}:${server.port}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _menuItems(AppLocalizations l10n) {
    final view = widget.view;
    final server = widget.server;
    final open = view.onOpenCatalogServer;
    final manage = view.onEditCatalogServer != null ||
        view.onDuplicateCatalogServer != null ||
        view.onDeleteCatalogServer != null;
    return [
      MenuItemButton(
        key: const ValueKey('sidebar.catalog.menu.open'),
        onPressed: open == null
            ? null
            : () => _open(SidebarOpenAction.plain),
        child: Text(l10n.sidebarOpen),
      ),
      MenuItemButton(
        key: const ValueKey('sidebar.catalog.menu.openNewTab'),
        onPressed: open == null
            ? null
            : () => _open(SidebarOpenAction.newTab),
        child: Text(l10n.sidebarOpenInNewTab),
      ),
      MenuItemButton(
        key: const ValueKey('sidebar.catalog.menu.openOtherPane'),
        onPressed: open == null
            ? null
            : () => _open(SidebarOpenAction.oppositePane),
        child: Text(l10n.sidebarOpenInOtherPane),
      ),
      if (manage) const Divider(height: 1),
      if (view.onEditCatalogServer != null)
        MenuItemButton(
          key: const ValueKey('sidebar.catalog.menu.edit'),
          onPressed: () => view.onEditCatalogServer!(server),
          child: Text(l10n.sidebarCatalogEdit),
        ),
      if (view.onDuplicateCatalogServer != null)
        MenuItemButton(
          key: const ValueKey('sidebar.catalog.menu.duplicate'),
          onPressed: () => view.onDuplicateCatalogServer!(server),
          child: Text(l10n.sidebarCatalogDuplicate),
        ),
      if (view.onDeleteCatalogServer != null)
        MenuItemButton(
          key: const ValueKey('sidebar.catalog.menu.delete'),
          onPressed: () => view.onDeleteCatalogServer!(server),
          child: Text(l10n.sidebarCatalogDelete),
        ),
    ];
  }
}

/// The catalog row's badge: the shared [ServerBadge] (mark + tint
/// exactly as Séance draws them) with the same composed corner dot the
/// favorite badge carries — one indicator, live truth outranking probes.
class _CatalogBadge extends StatelessWidget {
  const _CatalogBadge({
    required this.server,
    required this.appearance,
    this.probe,
  });

  final ServerConfig server;
  final ServerIndicatorAppearance appearance;
  final ProbeStatus? probe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dotColor = _indicatorDotColor(scheme, appearance, probe);
    return SizedBox(
      width: 30,
      height: 30,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: ServerBadge(
              tint: ServerTint.of(server),
              mark: server.mark,
              size: 26,
              semanticsLabel: server.label,
            ),
          ),
          if (dotColor != null)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
