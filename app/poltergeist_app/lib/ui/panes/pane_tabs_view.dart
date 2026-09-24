import 'dart:async';

import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show BookmarkStore, FsLocation;
import 'package:poltergeist_sync/poltergeist_sync.dart'
    show LocalEndpoint, RemoteEndpoint, SyncEndpoint;

import '../../l10n/app_localizations.dart';
import '../../services/checkout_session.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_drop.dart';
import '../../services/pane_location.dart';
import '../../services/pane_tabs_controller.dart';
import '../../services/preview_session.dart';
import '../../services/sync_plan_controller.dart';
import '../../services/workspace_controller.dart';
import '../server_appearance.dart';
import '../server_state_indicator.dart';
import '../sync/sync_plan_view.dart';
import 'pane_drop_area.dart';
import 'pane_view.dart';
import 'quick_connect_view.dart';

/// A tab's display title (02 §3): the bound folder's last segment — the
/// `Folder name` default of the title setting, whose other modes land
/// with it. A remote tab mid-connect has no path yet, so its bookmark
/// label stands in; an unbound tab names the launcher surface.
String paneTabTitle(PaneTab tab, AppLocalizations l10n) {
  final session = tab.syncSession;
  if (session != null) return l10n.syncTabTitle(session.pair.name);
  final controller = tab.controller;
  final location = controller.location;
  if (location != null) return paneLastSegment(location.path);
  final bookmark = controller.remoteBookmark;
  if (bookmark != null) return bookmark.label;
  return l10n.tabLauncherTitle;
}

/// The chip's tooltip (02 §3): full path, plus the server for remote
/// tabs. Unbound tabs name their surface.
String _paneTabTooltip(PaneTab tab, AppLocalizations l10n) {
  final session = tab.syncSession;
  if (session != null) {
    return '${_endpointTooltip(session.pair.left)} ⇄ '
        '${_endpointTooltip(session.pair.right)}';
  }
  final controller = tab.controller;
  final bookmark = controller.remoteBookmark;
  final path = controller.location?.path ?? bookmark?.remotePath;
  if (bookmark != null) {
    return l10n.tabTooltipRemote(bookmark.label, path ?? '/');
  }
  if (path != null) return path;
  return l10n.tabLauncherTitle;
}

/// The sync tab's tooltip: both endpoint paths in the pair's order.
String _endpointTooltip(SyncEndpoint endpoint) => switch (endpoint) {
  LocalEndpoint(:final path) => path,
  RemoteEndpoint(:final server, :final path) =>
    '${server.identity?.host ?? server.serverConfigId ?? 'remote'}:$path',
};

/// The confirm dialog's one-line description of a fired guard trigger
/// (02 §3's list) — exhaustive over the registry's kinds so a trigger
/// added for a later slice fails to compile here, not silently unlabeled.
String tabCloseTriggerLabel(
  AppLocalizations l10n,
  TabCloseTrigger trigger,
) => switch (trigger) {
  TabCloseTrigger.navigation => l10n.tabCloseTriggerNavigation,
  TabCloseTrigger.inlineRename => l10n.tabCloseTriggerInlineRename,
  TabCloseTrigger.folderSize => l10n.tabCloseTriggerFolderSize,
  TabCloseTrigger.applyToEnclosed => l10n.tabCloseTriggerApplyToEnclosed,
  TabCloseTrigger.syncAnchor => l10n.tabCloseTriggerSyncAnchor,
};

/// One pane (02 §1) as a tabbed surface: the strip over the active tab's
/// browsing view — or over the launcher while the pane has no tabs. The
/// pane's one focus node lives here: whichever surface is mounted owns
/// it, so pane activation and the Tab swap keep working on the launcher.
class PaneTabsView extends StatelessWidget {
  const PaneTabsView({
    super.key,
    required this.tabs,
    required this.workspace,
    required this.focusNode,
    required this.onSwapFocus,
    required this.onCancelRecovery,
    this.bookmarks,
    this.dropDelegate,
    this.supportsOsDrop,
    this.preview,
    this.checkoutSession,
    this.onReviewLocalEdits,
    this.onSyncSaveAsFavorite,
    this.onSyncEditRules,
    this.onImportSshConfig,
    this.clock,
  });

  /// The pane's tab strip state (02 §3).
  final PaneTabsController tabs;

  /// The workspace owning pane activity: the active pane drives the
  /// accent path and receives pane-scoped commands.
  final WorkspaceController workspace;

  /// This pane's listing focus node (02 §8.2: one FocusScope per pane) —
  /// shared by the mounted tab view and the launcher.
  final FocusNode focusNode;

  /// `pane.swapFocus`: activates the other pane and moves focus there.
  final VoidCallback onSwapFocus;

  /// The connection-lost banner's cancel, routed by the shell onto the
  /// ACTIVE tab (the only surface that can raise it).
  final VoidCallback onCancelRecovery;

  /// The bookmark persistence seam for the "Save as favorite…" bar
  /// (02 §2.7) — see [PaneView.bookmarks].
  final BookmarkStore? bookmarks;

  /// The drop enqueue seam (02 §5.1, D14) — forwarded to the tab view's
  /// drop zone and the strip's tab-header targets. Null refuses every
  /// drop and leaves rows undraggable.
  final PaneDropDelegate? dropDelegate;

  /// Whether the OS drop-in `DropTarget` mounts — see
  /// [PaneView.supportsOsDrop].
  final bool? supportsOsDrop;

  /// The 06 §5 preview driver — forwarded to the mounted [PaneView],
  /// which dispatches Space to it and gives its Esc tier top slot.
  final PreviewSession? preview;

  /// The managed-checkout truth behind 06 §3.7's local-edits banner —
  /// forwarded to the mounted [PaneView].
  final CheckoutSession? checkoutSession;

  /// The banner's `Review…` — forwarded to the mounted [PaneView].
  final void Function(String serverId)? onReviewLocalEdits;

  /// `sync.saveAsFavorite` — the shell persists the session's pair as a
  /// savedSync bookmark.
  final void Function(SyncPlanController session)? onSyncSaveAsFavorite;

  /// The pair/rules editor — the shell opens the options surface for
  /// the session's pair.
  final void Function(SyncPlanController session)? onSyncEditRules;

  /// The ssh_config import offer on the §2.7 launcher (D22) — the shell
  /// routes it through the registered command so enablement and the
  /// one-shot session rule apply. Null mounts no offer.
  final VoidCallback? onImportSshConfig;

  /// Injectable clock forwarded to the tab view's date rendering.
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabStrip(
          tabs: tabs,
          workspace: workspace,
          focusNode: focusNode,
          dropDelegate: dropDelegate,
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: tabs,
            builder: (context, _) {
              final activeTab = tabs.activeTab;
              if (activeTab == null) {
                return _PaneLauncher(
                  tabs: tabs,
                  workspace: workspace,
                  focusNode: focusNode,
                  onSwapFocus: onSwapFocus,
                  onImportSshConfig: onImportSshConfig,
                );
              }
              final syncSession = activeTab.syncSession;
              if (syncSession != null) {
                return SyncPlanView(
                  key: ValueKey(activeTab.id),
                  controller: syncSession,
                  onSaveAsFavorite: onSyncSaveAsFavorite == null
                      ? null
                      : () => onSyncSaveAsFavorite!(syncSession),
                  onEditRules: onSyncEditRules == null
                      ? null
                      : () => onSyncEditRules!(syncSession),
                );
              }
              return PaneView(
                // Keyed per tab so a switch mounts a clean view state —
                // per-tab state lives on the controller, so nothing the
                // view owns (scroll offset, field focus) may leak across.
                key: ValueKey(activeTab.id),
                controller: activeTab.controller,
                pane: tabs,
                workspace: workspace,
                focusNode: focusNode,
                onSwapFocus: onSwapFocus,
                onCancelRecovery: onCancelRecovery,
                bookmarks: bookmarks,
                dropDelegate: dropDelegate,
                supportsOsDrop: supportsOsDrop,
                preview: preview,
                checkoutSession: checkoutSession,
                onReviewLocalEdits: onReviewLocalEdits,
                clock: clock ?? DateTime.now,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The strip (02 §3): ordered tab chips plus the `tab.new` affordance.
/// Scrolls horizontally instead of shrinking chips below usability; the
/// new-tab button stays pinned at the trailing edge. An activation
/// change scrolls the active chip back into the visible extent —
/// ⌃⇥-cycling or ⌘T must never leave the active tab's chip offscreen.
///
/// The strip is also the drop target for 02 §3's inter-pane drag: a
/// foreign tab hovering shows the insertion indicator at the drop
/// index; this strip's own tabs are refused — there is no within-strip
/// reorder this slice.
class _TabStrip extends StatefulWidget {
  const _TabStrip({
    required this.tabs,
    required this.workspace,
    required this.focusNode,
    required this.dropDelegate,
  });

  final PaneTabsController tabs;
  final WorkspaceController workspace;
  final FocusNode focusNode;

  /// The drop enqueue seam (02 §5.1) — the tab chips' entry-drop
  /// targets route through it; null leaves the chips refusing drops.
  final PaneDropDelegate? dropDelegate;

  @override
  State<_TabStrip> createState() => _TabStripState();
}

class _TabStripState extends State<_TabStrip> {
  /// Keys the strip container so drop positions resolve in strip-local
  /// coordinates.
  final _stripKey = GlobalKey();

  /// Keys the chips' scroll area so a scrolled-off chip's drop geometry
  /// resolves against its VISIBLE edge, not its clipped one.
  final _scrollAreaKey = GlobalKey();

  /// One key per chip, for drop-index geometry only — a dragged tab's
  /// insertion point resolves against the chips' rendered edges.
  final _chipKeys = <PaneTab, GlobalKey>{};
  PaneTab? _lastActive;

  /// The active tab's list position at the last reveal check — a same-
  /// identity tab whose index shifted (a tab inserted before it, or a
  /// neighbor closing while scrolled) still needs the reveal pass.
  int _lastActiveIndex = -1;

  /// The pending drop's insertion index into the strip's tab list and
  /// the indicator's strip-local x — non-null only while a foreign tab
  /// hovers the strip.
  int? _dropIndex;
  double? _dropX;

  /// Resolves a hovering foreign tab's insertion index and indicator
  /// position from the chips' rendered edges: left of a chip's midpoint
  /// inserts before it; past the last chip's midpoint appends. Chip
  /// rects clip to the scroll viewport — a half-scrolled chip's
  /// offscreen half must not swallow the strip's trailing drop zone,
  /// or appending becomes unreachable while it is clipped.
  void _updateDropPosition(Offset global) {
    final stripBox = _stripKey.currentContext?.findRenderObject();
    final scrollBox = _scrollAreaKey.currentContext?.findRenderObject();
    if (stripBox is! RenderBox ||
        !stripBox.hasSize ||
        scrollBox is! RenderBox ||
        !scrollBox.hasSize) {
      return;
    }
    final scrollRect = scrollBox.localToGlobal(Offset.zero) & scrollBox.size;
    final tabs = widget.tabs.tabs;
    var index = tabs.length;
    // Empty-strip fallback: the scroll area's own leading edge, so the
    // indicator tracks the chip row's inset rather than a constant.
    var x = stripBox.globalToLocal(scrollRect.topLeft).dx;
    for (var i = 0; i < tabs.length; i++) {
      final chip = _chipKeys[tabs[i]]?.currentContext?.findRenderObject();
      if (chip is! RenderBox || !chip.hasSize) continue;
      final chipRect =
          (chip.localToGlobal(Offset.zero) & chip.size).intersect(
            scrollRect,
          );
      if (chipRect.isEmpty) continue;
      x = stripBox.globalToLocal(chipRect.topRight).dx;
      if (global.dx < chipRect.center.dx) {
        index = i;
        x = stripBox.globalToLocal(chipRect.topLeft).dx;
        break;
      }
    }
    final clampedX = x.clamp(0.0, stripBox.size.width);
    if (_dropIndex == index && _dropX == clampedX) return;
    setState(() {
      _dropIndex = index;
      _dropX = clampedX;
    });
  }

  void _clearDropTarget() {
    if (_dropIndex == null) return;
    setState(() {
      _dropIndex = null;
      _dropX = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final tabs = widget.tabs;
    return Semantics(
      container: true,
      label: l10n.tabStripLabel,
      child: DragTarget<PaneTab>(
        // A tab only ever lands on the OTHER pane's strip (02 §3): this
        // strip's own residents are refused, so a drop back here is the
        // cancelled case rather than a within-strip reorder.
        onWillAcceptWithDetails: (details) =>
            !tabs.tabs.contains(details.data),
        onMove: (details) => _updateDropPosition(details.offset),
        onLeave: (_) => _clearDropTarget(),
        onAcceptWithDetails: (details) {
          // Snapshot before clearing: a stationary drop that never
          // fired onMove keeps a null index, which the move reads as
          // append.
          final index = _dropIndex;
          _clearDropTarget();
          widget.workspace.moveTabToPane(details.data, tabs, index: index);
        },
        builder: (context, candidateData, rejectedData) => Container(
          key: _stripKey,
          height: 34,
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            border: Border(
              bottom: BorderSide(color: colors.outlineVariant),
            ),
          ),
          child: Stack(
            children: [
              Row(
                children: [
                  Expanded(
                    key: _scrollAreaKey,
                    child: ListenableBuilder(
                      listenable: tabs,
                      builder: (context, _) {
                        final active = tabs.activeTab;
                        final activeIndex =
                            active == null ? -1 : tabs.tabs.indexOf(active);
                        // Identity OR position change: inserting or
                        // removing a tab before the active one shifts
                        // its rendered offset without an activation.
                        if (!identical(active, _lastActive) ||
                            activeIndex != _lastActiveIndex) {
                          _lastActive = active;
                          _lastActiveIndex = activeIndex;
                          if (active != null) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              // Reads the CURRENT active tab at callback
                              // time, so activations coalescing in one
                              // frame scroll to the latest one.
                              final chipContext =
                                  _chipKeys[tabs.activeTab]
                                      ?.currentContext;
                              if (chipContext == null) return;
                              // Scroll only when the chip is actually
                              // offscreen — an already-visible
                              // activation shouldn't animate. (There is
                              // no "only-if-offscreen" alignmentPolicy
                              // constant; the rect check is the guard.)
                              final chipObject =
                                  chipContext.findRenderObject();
                              final viewObject = Scrollable.of(
                                chipContext,
                              ).context.findRenderObject();
                              if (chipObject is RenderBox &&
                                  viewObject is RenderBox) {
                                // Inclusive edge comparison, not
                                // Rect.contains: a chip pixel-flush with
                                // the viewport edge is fully visible
                                // (contains is half-open and would
                                // recenter it).
                                final chipRect =
                                    chipObject.localToGlobal(
                                          Offset.zero,
                                        ) &
                                        chipObject.size;
                                final viewRect =
                                    viewObject.localToGlobal(
                                          Offset.zero,
                                        ) &
                                        viewObject.size;
                                // Half-logical-pixel tolerance:
                                // localToGlobal can drift a fraction of
                                // a pixel after a settled scroll
                                // (fractional DPR, matrix composition),
                                // which would still recenter a visually
                                // flush chip.
                                if (chipRect.left >= viewRect.left - 0.5 &&
                                    chipRect.right <=
                                        viewRect.right + 0.5 &&
                                    chipRect.top >= viewRect.top - 0.5 &&
                                    chipRect.bottom <=
                                        viewRect.bottom + 0.5) {
                                  return;
                                }
                              }
                              Scrollable.ensureVisible(
                                chipContext,
                                alignment: 0.5,
                              );
                            });
                          }
                        }
                        // Keys minted for tabs that left (moved or
                        // closed) are dead weight — drop them.
                        _chipKeys.removeWhere(
                          (tab, _) => !tabs.tabs.contains(tab),
                        );
                        return SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final tab in tabs.tabs)
                                // The per-tab key doubles as the
                                // scroll-into-view handle and the
                                // drop-index geometry anchor — a chip
                                // keeps its element across activation
                                // changes (no reparenting wrapper).
                                KeyedSubtree(
                                  key: _chipKeys.putIfAbsent(
                                    tab,
                                    GlobalKey.new,
                                  ),
                                  // 02 §5.1: a tab header is also an
                                  // entry-drop target — the chip stays
                                  // the 02 §3 tab-drag source inside.
                                  child: _TabEntryDrop(
                                    // Keyed by tab id: a reorder must
                                    // move the hover timer and target
                                    // ring with the tab, not the slot.
                                    key: ValueKey('entry-drop-${tab.id}'),
                                    tabs: tabs,
                                    tab: tab,
                                    delegate: widget.dropDelegate,
                                    child: _TabChip(
                                      key: ValueKey(tab.id),
                                      tabs: tabs,
                                      tab: tab,
                                      workspace: widget.workspace,
                                      focusNode: widget.focusNode,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  IconButton(
                    key: ValueKey('${tabs.paneId}.tab.new'),
                    tooltip: l10n.tabNewLabel,
                    onPressed: () => tabs.newTab(),
                    icon: const Icon(Icons.add, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              if (_dropX != null)
                // The insertion indicator (02 §3's hover feedback) —
                // overlay-painted so it never shifts the chips' layout.
                Positioned(
                  key: const ValueKey('pane.tabDropIndicator'),
                  left: _dropX! - 1,
                  top: 0,
                  bottom: 0,
                  width: 2,
                  child: IgnorePointer(
                    child: ColoredBox(color: colors.primary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One tab chip: title, remote badge + connection dot, close affordance.
/// Primary tap activates the tab (and its pane); middle-click closes it
/// through the SAME guarded operation ⌘W uses — [requestCloseTab] owns
/// the confirmation, so no close route can bypass the guard (02 §3).
///
/// The chip is also the drag source for the inter-pane move (02 §3):
/// the drag carries the [PaneTab] itself and only ever lands on the
/// OTHER pane's strip, which owns the insertion index; a release
/// anywhere else cancels. While the chip is dragged it stays in place,
/// dimmed — the tab is not moving until the drop commits.
class _TabChip extends StatelessWidget {
  const _TabChip({
    super.key,
    required this.tabs,
    required this.tab,
    required this.workspace,
    required this.focusNode,
  });

  final PaneTabsController tabs;
  final PaneTab tab;
  final WorkspaceController workspace;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final controller = tab.controller;
    final active = identical(tabs.activeTab, tab);
    final bookmark = controller.remoteBookmark;
    final title = paneTabTitle(tab, l10n);

    final chip = Listener(
      // Buttons are read at pointer-DOWN: the up event reports buttons
      // already released. Middle-click closes through the one guarded
      // operation — no call-site confirm (02 §3, SEA-009 lesson).
      onPointerDown: (event) {
        if (event.buttons & kMiddleMouseButton != 0) {
          unawaited(tabs.requestCloseTab(tab));
        }
      },
      child: Tooltip(
        message: _paneTabTooltip(tab, l10n),
        child: Semantics(
          button: true,
          selected: active,
          label: title,
          child: Material(
            color: active
                ? colors.surfaceContainerHighest
                : colors.surfaceContainerLow,
            child: InkWell(
              onTap: () {
                // A chip tap claims the pane too — the two-pane muscle
                // memory applies to the strip, not just the listing.
                workspace.setActivePane(tabs);
                tabs.activateTab(tab);
                focusNode.requestFocus();
              },
              child: Container(
                height: 34,
                constraints: const BoxConstraints(
                  minWidth: 72,
                  maxWidth: 220,
                ),
                padding: const EdgeInsetsDirectional.only(start: 10),
                decoration: BoxDecoration(
                  border: BorderDirectional(
                    end: BorderSide(color: colors.outlineVariant),
                    top: active
                        ? BorderSide(color: colors.primary, width: 2)
                        : BorderSide.none,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (bookmark != null) ...[
                      ServerBadge.glyph(
                        tint: ServerTint(named: bookmark.color),
                        icon: bookmark.icon,
                        size: 16,
                      ),
                      const SizedBox(width: 4),
                      _ConnectionDot(controller: controller),
                    ],
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: IconButton(
                        key: ValueKey('${tab.id}.close'),
                        tooltip: l10n.tabCloseLabel,
                        padding: EdgeInsets.zero,
                        iconSize: 14,
                        onPressed: () =>
                            unawaited(tabs.requestCloseTab(tab)),
                        icon: const Icon(Icons.close),
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

    // The immediate multi-drag recognizer claims the pointer only after
    // movement past slop, so taps and middle-clicks on the chip are
    // unaffected; the strip's own DragTarget refuses its residents, so
    // a released drag that landed nowhere foreign cancels cleanly. The
    // pointer anchor matters beyond looks: DragTargetDetails.offset is
    // the avatar's top-left, and pointer anchoring keeps that equal to
    // the pointer — the drop-index math works on the pointer itself.
    return Draggable<PaneTab>(
      // One tab can only be under one pointer: a second concurrent drag
      // of the same chip would carry a payload that is already gone.
      maxSimultaneousDrags: 1,
      data: tab,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _TabDragAvatar(tab: tab),
      childWhenDragging: Opacity(opacity: 0.4, child: chip),
      child: chip,
    );
  }
}

/// The drag avatar under the pointer while a tab moves between panes
/// (02 §3): a compact chip naming the tab — the carried payload, not a
/// drop preview.
class _TabDragAvatar extends StatelessWidget {
  const _TabDragAvatar({required this.tab});

  final PaneTab tab;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final bookmark = tab.controller.remoteBookmark;
    // The overlay gives the avatar loose constraints: without a cap a
    // long tab title drags a screen-wide chip and the ellipsis never
    // engages (a Row needs a bounded Text to ellipsize at all).
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: Material(
        elevation: 4,
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (bookmark != null) ...[
                ServerBadge.glyph(
                  tint: ServerTint(named: bookmark.color),
                  icon: bookmark.icon,
                  size: 14,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  paneTabTitle(tab, l10n),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tab header as an entry-drop target (02 §5.1): hovering a chip with
/// dragged rows arms the 700 ms activation timer (the tab then accepts
/// the drop through its listing), and a direct drop on the chip lands
/// in that tab's current directory — same verb and containment rules as
/// the listing zone. While a payload can land here the chip shows the
/// target ring; a refused drop (no queue, unbound or inert tab,
/// containment) keeps the chip plain.
class _TabEntryDrop extends StatefulWidget {
  const _TabEntryDrop({
    super.key,
    required this.tabs,
    required this.tab,
    required this.delegate,
    required this.child,
  });

  final PaneTabsController tabs;
  final PaneTab tab;
  final PaneDropDelegate? delegate;
  final Widget child;

  @override
  State<_TabEntryDrop> createState() => _TabEntryDropState();
}

class _TabEntryDropState extends State<_TabEntryDrop> {
  /// The hover timer behind §5.1's "hover 700 ms switches to that tab"
  /// — armed once per hover, disarmed on leave/accept/dispose.
  Timer? _activateTimer;

  /// Whether the currently hovering payload may land (drives the ring).
  bool _accepting = false;

  /// The chip's destination endpoint + directory: the tab's bound
  /// location, null while the tab is unbound or its pane is inert
  /// (loading, error, connection-lost — same eligibility as the
  /// listing's own drop zone).
  ({FsLocation fs, String dir})? get _destination {
    final controller = widget.tab.controller;
    if (!controller.verbsEnabled) return null;
    final location = controller.location;
    if (location == null) return null;
    return (fs: fsLocationForLocation(location), dir: location.path);
  }

  /// Whether this payload may land on the chip right now — verb and
  /// containment resolved exactly as the listing zone resolves them.
  bool _accepts(PaneEntryDrag drag) {
    final delegate = widget.delegate;
    final destination = _destination;
    var allowed = false;
    if (delegate != null && destination != null) {
      final modifiers = paneDropModifiers(context);
      final verb = paneDropVerb(
        source: drag.source,
        sourceRoots: drag.rootPaths,
        destination: destination.fs,
        destinationDir: destination.dir,
        copyModifier: modifiers.copy,
        moveModifier: modifiers.move,
      );
      allowed = paneDropAllowed(
        source: drag.source,
        sourceRoots: drag.rootPaths,
        destination: destination.fs,
        destinationDir: destination.dir,
        operation: verb,
      );
      drag.verb.value = allowed ? verb : null;
    } else {
      drag.verb.value = null;
    }
    _armActivation(allowed);
    if (allowed != _accepting) setState(() => _accepting = allowed);
    return allowed;
  }

  /// Arms the activation timer while an accepting payload hovers — a
  /// refused hover never switches the tab. A re-evaluation that flips
  /// to refused mid-hover (modifier change, tab gone inert) cancels the
  /// armed timer too, not just leave/accept.
  void _armActivation(bool allowed) {
    if (!allowed) {
      _activateTimer?.cancel();
      _activateTimer = null;
      return;
    }
    if (_activateTimer != null) return;
    _activateTimer = Timer(const Duration(milliseconds: 700), () {
      _activateTimer = null;
      widget.tabs.activateTab(widget.tab);
    });
  }

  void _disarm() {
    _activateTimer?.cancel();
    _activateTimer = null;
    if (_accepting) setState(() => _accepting = false);
  }

  /// The direct chip drop: the tab's current directory is the target —
  /// the verb reads the modifiers held at release, like the listing.
  void _accept(PaneEntryDrag drag) {
    final delegate = widget.delegate;
    final destination = _destination;
    drag.verb.value = null;
    if (delegate == null || destination == null) return;
    final modifiers = paneDropModifiers(context);
    final verb = paneDropVerb(
      source: drag.source,
      sourceRoots: drag.rootPaths,
      destination: destination.fs,
      destinationDir: destination.dir,
      copyModifier: modifiers.copy,
      moveModifier: modifiers.move,
    );
    if (!paneDropAllowed(
      source: drag.source,
      sourceRoots: drag.rootPaths,
      destination: destination.fs,
      destinationDir: destination.dir,
      operation: verb,
    )) {
      return;
    }
    delegate.enqueue(
      source: drag.source,
      rootPaths: drag.rootPaths,
      destination: destination.fs,
      destinationDir: destination.dir,
      operation: verb,
    );
  }

  @override
  void dispose() {
    _activateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DragTarget<PaneEntryDrag>(
      // Same posture as the listing zone: willAccept gates on the type
      // only (a refused chip would lock out a modifier flip that turns
      // the drop legal); the honest resolution rides onMove/onAccept.
      onWillAcceptWithDetails: (details) {
        _accepts(details.data);
        // Not gated on _destination: willAccept runs at entry only, so
        // a chip that becomes eligible mid-hover (tab finished
        // loading) must still accept the release; _accept re-resolves
        // the destination honestly at drop time.
        return widget.delegate != null;
      },
      onMove: (details) => _accepts(details.data),
      onLeave: (data) {
        // The badge outlives the hover — clear the resolved verb so a
        // drag parked over a non-target doesn't keep advertising one.
        // A move into another target re-resolves after this (leave
        // fires before enter), so no flicker.
        data?.verb.value = null;
        _disarm();
      },
      onAcceptWithDetails: (details) {
        _disarm();
        _accept(details.data);
      },
      builder: (context, candidateData, rejectedData) => Container(
        // A border that appears on acceptance would add 4px each axis
        // and reflow the strip mid-drag — keep it mounted and swap the
        // color so toggling repaints only.
        decoration: BoxDecoration(
          border: Border.all(
            color: _accepting ? colors.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

/// The remote tab's connection dot (02 §3): the shared server-truth
/// glyph, mapped through the pane's own status lane — reconnecting and
/// mid-connect states read as pending, a dropped binding as failed.
class _ConnectionDot extends StatelessWidget {
  const _ConnectionDot({required this.controller});

  final PaneController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (glyph, label) = _resolve(l10n);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        container: true,
        child: ServerStateGlyph(glyph),
      ),
    );
  }

  (ServerIndicatorGlyph, String) _resolve(AppLocalizations l10n) {
    final controller = this.controller;
    if (controller.connectionLost) {
      return controller.canRetryRecovery
          ? (ServerIndicatorGlyph.failed, l10n.connectionFailedTitle)
          : (ServerIndicatorGlyph.pending, l10n.connectionStateReconnecting);
    }
    if (controller.phase == PanePhase.connectingRemote) {
      return (ServerIndicatorGlyph.pending, l10n.connectionStateConnecting);
    }
    final appearance = serverIndicatorOf(
      l10n,
      status: controller.connectionStatus,
    );
    // A bound remote tab always shows a dot: a watch that has not
    // answered yet reads as idle, never blank.
    return switch (appearance.glyph) {
      ServerIndicatorGlyph.none ||
      ServerIndicatorGlyph.probe => (ServerIndicatorGlyph.idle, appearance.label),
      _ => (appearance.glyph, appearance.label),
    };
  }
}

/// The 02 §2.7 launcher: the pane's surface while it holds no tabs —
/// never blank, never an auto-opened replacement. Focusable like the
/// listing surface so pane activation and the Tab swap keep working.
class _PaneLauncher extends StatefulWidget {
  const _PaneLauncher({
    required this.tabs,
    required this.workspace,
    required this.focusNode,
    required this.onSwapFocus,
    this.onImportSshConfig,
  });

  final PaneTabsController tabs;
  final WorkspaceController workspace;
  final FocusNode focusNode;
  final VoidCallback onSwapFocus;
  final VoidCallback? onImportSshConfig;

  @override
  State<_PaneLauncher> createState() => _PaneLauncherState();
}

class _PaneLauncherState extends State<_PaneLauncher> {
  /// The Quick Connect field's focus node, owned here so the mount
  /// reclaim can aim at the field rather than the pane node.
  final _addressFocus = FocusNode();

  /// Hit-test boundary for the pane's pointer-down listener: clicks
  /// inside the form keep the field's focus (mirrors the listing's
  /// field-strip exclusions).
  final _quickConnectKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Mounting the launcher means the last PaneView — which held the
    // pane's shared focus node — just unmounted; detaching the node's
    // last attachment drops its focus to the parent scope, so the
    // pane's own keys (Tab swap) would go dead until a click. Reclaim
    // focus onto the address field, but only when this pane is the
    // workspace's active one: an inactive pane's launcher must never
    // steal focus on mount. A focused field keeps the pane node in its
    // focus chain, so the Tab swap keeps working.
    if (identical(widget.workspace.activePane, widget.tabs)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.focusNode.hasFocus) {
          _addressFocus.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _addressFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      container: true,
      label: widget.tabs.isLeftPane ? l10n.paneAName : l10n.paneBName,
      child: Focus(
        focusNode: widget.focusNode,
        onFocusChange: (focused) {
          if (focused) widget.workspace.setActivePane(widget.tabs);
        },
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey != LogicalKeyboardKey.tab) {
            return KeyEventResult.ignored;
          }
          final modified =
              HardwareKeyboard.instance.isShiftPressed ||
              HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed ||
              HardwareKeyboard.instance.isAltPressed;
          // Modified Tab (Ctrl+Tab cycling, Shift+Tab traversal) belongs
          // to the chord layer / focus traversal — the launcher only owns
          // the plain key, and its repeats must fall through the same way
          // the initial keydown did.
          if (modified) return KeyEventResult.ignored;
          // The launcher's single pane key: plain Tab swaps panes (02
          // §8.2); repeats are consumed so a held key cannot oscillate.
          if (event is KeyRepeatEvent) return KeyEventResult.handled;
          widget.onSwapFocus();
          return KeyEventResult.handled;
        },
        child: Listener(
          // Clicking the launcher focuses the pane (activates it) — the
          // same muscle memory as the listing — except inside the Quick
          // Connect form, whose controls keep their own focus.
          onPointerDown: (event) {
            final formBox =
                _quickConnectKey.currentContext?.findRenderObject()
                    as RenderBox?;
            if (formBox != null &&
                formBox.hasSize &&
                formBox.size.contains(
                  formBox.globalToLocal(event.position),
                )) {
              return;
            }
            widget.focusNode.requestFocus();
          },
          child: QuickConnectView(
            key: _quickConnectKey,
            focusNode: _addressFocus,
            onImportSshConfig: widget.onImportSshConfig,
            onConnect: (bookmark, initialPath) {
              // Quick Connect binds a fresh tab through the existing
              // remote-connect seam: the tab opens immediately on the
              // launcher target and the connect flow owns prompts,
              // errors, and banner behavior from there.
              final tab = widget.tabs.newTab(
                target: NewTabTarget.launcher,
              );
              unawaited(
                tab.controller.connectRemote(
                  bookmark,
                  initialPath: initialPath,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
