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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller,
        ?connections,
        ?probes,
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
              child: Text(
                l10n.sidebarEmptyFavorites,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
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
    required this.collapsed,
    required this.onToggle,
    this.onAcceptBookmark,
  });

  final String sectionKey;
  final String title;
  final bool collapsed;
  final VoidCallback onToggle;
  final void Function(Bookmark bookmark)? onAcceptBookmark;

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
          return Semantics(
            header: true,
            button: true,
            expanded: !widget.collapsed,
            label: widget.title,
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
                      ? Border.all(color: scheme.primary, width: 1)
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
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    if (accept == null) return header;
    return DragTarget<Bookmark>(
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
            button: true,
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
                            ? BorderSide(color: scheme.primary, width: 1)
                            : BorderSide.none,
                        right: focused
                            ? BorderSide(color: scheme.primary, width: 1)
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
    return [
      MenuItemButton(
        key: const ValueKey('sidebar.menu.open'),
        onPressed: open == null
            ? null
            : () => _open(SidebarOpenAction.plain),
        child: Text(l10n.sidebarOpen),
      ),
      MenuItemButton(
        key: const ValueKey('sidebar.menu.openNewTab'),
        onPressed: open == null
            ? null
            : () => _open(SidebarOpenAction.newTab),
        child: Text(l10n.sidebarOpenInNewTab),
      ),
      MenuItemButton(
        key: const ValueKey('sidebar.menu.openOtherPane'),
        onPressed: open == null
            ? null
            : () => _open(SidebarOpenAction.oppositePane),
        child: Text(l10n.sidebarOpenInOtherPane),
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
    final accent = serverAccent(context, bookmark.color);

    final dotColor = switch (appearance.glyph) {
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
                      ? Border.all(color: scheme.primary, width: 1)
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
