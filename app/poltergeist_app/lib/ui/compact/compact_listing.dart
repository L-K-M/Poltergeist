import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/checkout_session.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_location.dart';
import '../../services/pane_permissions.dart' show nameIsFlagged;
import '../../services/quick_connect_address.dart';
import '../../services/quick_select_state.dart';
import '../../theme/app_theme.dart';
import '../local_edits_review.dart';
import '../panes/pane_format.dart';
import '../panes/save_favorite_bar.dart';
import 'compact_pane_messages.dart';
import 'compact_path_dialog.dart';
import 'compact_posture.dart';
import 'compact_rename_dialog.dart';

/// D32 §9's row: 56 dp, two lines (name; size · date). Scaled with the
/// text scale so larger type grows the row instead of clipping (D20),
/// and fixed per build so the list keeps its fixed-extent layout.
const double _rowExtent = 56;

/// 02 §2.8's anti-flash grace: no spinner or dim before this, so a fast
/// navigation never flashes.
const _antiFlashGrace = Duration(milliseconds: 150);

/// A pull-to-refresh never spins forever: past this the indicator lets
/// go even if the listing is still loading (the inline progress bar
/// keeps reporting it).
const _refreshCeiling = Duration(seconds: 15);

/// The compact listing's row callbacks, owned by the compact workspace
/// (selection mode and the action sheet are workspace state, because the
/// back order walks them).
@immutable
class CompactRowCallbacks {
  const CompactRowCallbacks({
    required this.onTap,
    required this.onLongPress,
    required this.onActions,
  });

  /// A tap: opens the entry, or toggles it while selecting.
  final void Function(PaneController pane, int index) onTap;

  /// A long-press: starts (or extends) the selection.
  final void Function(PaneController pane, int index) onLongPress;

  /// The trailing ⋮: the item's action sheet.
  final void Function(PaneController pane, int index) onActions;
}

/// One pane's listing in the compact posture (10 §9): a pull-to-refresh
/// list of 56 dp two-line rows over [controller], with the pane's honest
/// states — connecting, the inline error card, an empty folder, the one
/// banner slot (lost connection > reconnect > local edits > notice) — and
/// the rename session rendered as a dialog, Android's convention for an
/// in-place edit a finger cannot target precisely.
///
/// Every byte still crosses the engine channel the controller drives
/// (D8); this widget only renders the controller's truth.
class CompactListing extends StatefulWidget {
  const CompactListing({
    super.key,
    required this.controller,
    required this.selecting,
    required this.callbacks,
    required this.onCancelRecovery,
    this.bookmarks,
    this.checkoutSession,
    this.onReviewLocalEdits,
    this.bottomPadding = 0,
    this.clock = DateTime.now,
  });

  final PaneController controller;

  /// Selection mode: rows show their check state and a tap toggles.
  final bool selecting;
  final CompactRowCallbacks callbacks;

  /// The connection banner's and the connecting state's Cancel — the
  /// shell's sibling-aware detach (a shared server is never severed).
  final VoidCallback onCancelRecovery;

  /// The "Save as favorite…" bar's store (02 §2.7).
  final BookmarkStore? bookmarks;

  /// The local-edits banner's truth and its Review… (06 §3.7).
  final CheckoutSession? checkoutSession;
  final void Function(String serverId)? onReviewLocalEdits;

  /// Room the floating chrome (FAB, progress pill, selection bar) needs
  /// below the last row.
  final double bottomPadding;

  final DateTime Function() clock;

  @override
  State<CompactListing> createState() => _CompactListingState();
}

class _CompactListingState extends State<CompactListing> {
  final _scroll = ScrollController();
  Timer? _graceTimer;
  bool _pastGrace = false;
  String? _revealedPath;
  bool _renameDialogOpen = false;
  bool _pathDialogOpen = false;

  PaneController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _revealedPath = _controller.location?.path;
  }

  @override
  void didUpdateWidget(CompactListing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _graceTimer?.cancel();
      _graceTimer = null;
      _pastGrace = false;
      _revealedPath = widget.controller.location?.path;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _graceTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  bool get _busy =>
      _controller.loading ||
      _controller.phase == PanePhase.openingLocal ||
      _controller.phase == PanePhase.connectingRemote;

  void _onControllerChanged() {
    if (!mounted) return;
    _syncGrace();
    _syncReveal();
    _syncRenameDialog();
    _syncPathDialog();
    setState(() {});
  }

  /// The grace gates every busy surface (02 §2.8): the spinner, the
  /// progress bar, and the dim of the disowned listing.
  void _syncGrace() {
    if (!_busy) {
      _graceTimer?.cancel();
      _graceTimer = null;
      _pastGrace = false;
      return;
    }
    if (_pastGrace || _graceTimer != null) return;
    _graceTimer = Timer(_antiFlashGrace, () {
      _graceTimer = null;
      if (!mounted || !_busy) return;
      setState(() => _pastGrace = true);
    });
  }

  /// A new folder opens at its top — the old offset belongs to the
  /// folder the user just left.
  void _syncReveal() {
    final path = _controller.location?.path;
    if (path == _revealedPath) return;
    _revealedPath = path;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.offset != 0) _scroll.jumpTo(0);
    });
  }

  /// `file.rename` opens a session on the controller (from the action
  /// sheet, the More sheet, or a hardware-keyboard chord); the compact
  /// posture answers it with the rename dialog. One dialog per session:
  /// a failed commit re-opens the session inside the same dialog.
  void _syncRenameDialog() {
    if (_renameDialogOpen || _controller.renameTarget == null) return;
    _renameDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _controller.renameTarget == null) {
        _renameDialogOpen = false;
        return;
      }
      await showCompactRenameDialog(context, controller: _controller);
      _renameDialogOpen = false;
    });
  }

  /// `go.toFolder` / `go.editPath` open the controller's path session;
  /// the compact posture answers it with the path dialog.
  void _syncPathDialog() {
    if (_pathDialogOpen || !_controller.pathFieldOpen) return;
    _pathDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_controller.pathFieldOpen) {
        _pathDialogOpen = false;
        return;
      }
      await showCompactPathDialog(context, controller: _controller);
      _pathDialogOpen = false;
    });
  }

  /// Pull to refresh: re-lists the folder and holds the indicator until
  /// the listing lands (or fails), never past [_refreshCeiling].
  Future<void> _refresh() async {
    final controller = _controller;
    controller.refresh();
    if (!controller.loading) return;
    final landed = Completer<void>();
    void listener() {
      if (!controller.loading && !landed.isCompleted) landed.complete();
    }

    controller.addListener(listener);
    try {
      await landed.future.timeout(_refreshCeiling, onTimeout: () {});
    } finally {
      controller.removeListener(listener);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = _controller;
    final chrome = PoltergeistChrome.of(context);
    final loadingVisible =
        _pastGrace && controller.loading && !controller.connectionLost;
    return ColoredBox(
      color: chrome.paneBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 2 px, so the rows never jump when a load starts or lands.
          SizedBox(
            height: 2,
            child: loadingVisible
                ? const LinearProgressIndicator(
                    key: ValueKey(CompactKey.loading),
                    minHeight: 2,
                  )
                : null,
          ),
          ..._bannerSlot(context, l10n),
          Expanded(child: _body(context, l10n)),
        ],
      ),
    );
  }

  /// D32 §6's one banner slot, same priority as the desktop pane: lost
  /// connection > restored reconnect > local edits > notice; the save
  /// bar stays mounted under a higher banner so its typed name survives.
  List<Widget> _bannerSlot(BuildContext context, AppLocalizations l10n) {
    final controller = _controller;
    final bookmark = controller.remoteBookmark;
    final session = widget.checkoutSession;
    Widget? banner;
    if (controller.connectionLost) {
      banner = _CompactBanner(
        icon: Icons.cloud_off_outlined,
        tone: _BannerTone.error,
        text: controller.canRetryRecovery
            ? l10n.paneConnectionRecoveryFailed(bookmark?.label ?? '')
            : l10n.paneConnectionLost(bookmark?.label ?? ''),
        actions: [
          if (controller.canRetryRecovery)
            TextButton(
              key: const ValueKey(CompactKey.bannerRetry),
              onPressed: () => unawaited(controller.retry()),
              child: Text(l10n.connectionRetry),
            ),
          TextButton(
            key: const ValueKey(CompactKey.bannerCancel),
            onPressed: widget.onCancelRecovery,
            child: Text(l10n.paneConnectionLostCancel),
          ),
        ],
      );
    } else if (controller.phase == PanePhase.restored && bookmark != null) {
      banner = _CompactBanner(
        icon: Icons.cloud_off_outlined,
        tone: _BannerTone.neutral,
        text: l10n.paneRestoredOffline(bookmark.label),
        actions: [
          TextButton(
            key: const ValueKey(CompactKey.bannerRetry),
            onPressed: () => unawaited(controller.resumeRestored()),
            child: Text(l10n.paneReconnect),
          ),
        ],
      );
    } else if (session != null &&
        bookmark != null &&
        LocalEditsBanner.localEditCount(session, bookmark.id) > 0) {
      banner = LocalEditsBanner(
        session: session,
        serverId: bookmark.id,
        onReview: () => widget.onReviewLocalEdits?.call(bookmark.id),
      );
    } else if (controller.notice case final notice?) {
      banner = _CompactBanner(
        icon: Icons.info_outline,
        tone: _BannerTone.neutral,
        text: compactNoticeText(
          l10n,
          notice,
          dragOutLeftOut: controller.dragOutLeftOut,
        ),
        actions: [
          IconButton(
            key: const ValueKey(CompactKey.noticeDismiss),
            tooltip: l10n.paneNoticeDismiss,
            onPressed: controller.dismissNotice,
            icon: const Icon(Icons.close),
          ),
        ],
      );
    }
    final adhoc = _saveBarBookmark(controller);
    return [
      // 02 §2.5's Quick Select session drops in above the banner slot,
      // as it does under the desktop header.
      if (controller.quickSelectActive)
        _QuickSelectStrip(
          key: const ValueKey(CompactKey.quickSelect),
          controller: controller,
        ),
      if (banner != null)
        KeyedSubtree(key: const ValueKey(CompactKey.banner), child: banner),
      if (adhoc != null && !controller.unsavedBannerDismissed)
        Offstage(
          offstage: banner != null,
          child: SaveFavoriteBar(
            key: ValueKey((CompactKey.banner, adhoc.id)),
            bookmark: adhoc,
            currentPath: switch (controller.location) {
              RemotePaneLocation(:final path) => path,
              _ => null,
            },
            store: widget.bookmarks,
            onNoStore: controller.noteSaveFavoriteUnavailable,
            onDismiss: controller.dismissUnsavedBanner,
          ),
        ),
    ];
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final controller = _controller;
    if (!controller.hasEngine) return _Centered(text: l10n.paneNoEngine);
    final Widget content;
    if (controller.connectionLost) {
      content = _listing(context, l10n);
    } else {
      content = switch (controller.phase) {
        PanePhase.unbound => _Centered(text: l10n.paneNoLocation),
        PanePhase.openingLocal ||
        PanePhase.connectingRemote => _connecting(context, l10n),
        PanePhase.browsing || PanePhase.restored => _listing(context, l10n),
      };
    }
    // The disowned listing (a navigation in flight, the inline error,
    // the lost connection, a restored tab's cache) stays visible but
    // inert — pointer AND semantics, like the desktop pane (02 §2.8).
    final inert =
        controller.connectionLost ||
        controller.error != null ||
        controller.staleRows ||
        (controller.phase == PanePhase.restored &&
            controller.remoteBookmark != null);
    final dimmed =
        controller.connectionLost ||
        (controller.phase == PanePhase.restored &&
            controller.remoteBookmark != null) ||
        (_pastGrace && controller.loading);
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          ignoring: inert,
          child: ExcludeSemantics(
            excluding: inert,
            child: AnimatedOpacity(
              opacity: dimmed ? 0.45 : 1,
              duration: const Duration(milliseconds: 150),
              child: content,
            ),
          ),
        ),
        if (controller.error != null && !controller.connectionLost)
          _ErrorCard(
            error: controller.error!,
            onRetry: () => unawaited(controller.retry()),
          ),
      ],
    );
  }

  Widget _connecting(BuildContext context, AppLocalizations l10n) {
    if (_controller.error != null || !_pastGrace) {
      return const SizedBox.shrink();
    }
    final label = _controller.remoteBookmark?.label;
    final pendingRemote =
        _controller.phase == PanePhase.connectingRemote &&
        _controller.remoteBookmark != null;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 16),
          Text(
            label == null ? l10n.paneOpeningHome : l10n.paneConnectingTo(label),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          if (pendingRemote) ...[
            const SizedBox(height: 12),
            TextButton(
              key: const ValueKey(CompactKey.connectCancel),
              onPressed: widget.onCancelRecovery,
              child: Text(l10n.paneConnectCancel),
            ),
          ],
        ],
      ),
    );
  }

  Widget _listing(BuildContext context, AppLocalizations l10n) {
    final controller = _controller;
    final entries = controller.entries;
    final padding = EdgeInsets.only(bottom: widget.bottomPadding + 8);
    final Widget scrollable;
    if (entries.isEmpty) {
      // A scrollable even when empty: pull-to-refresh must still work on
      // an empty folder (a file may have just landed there).
      final Widget? empty = controller.loading || controller.connectionLost
          ? null
          : controller.filterActive
          ? _FilteredEmpty(controller: controller)
          : _EmptyFolder(text: l10n.paneEmptyFolder);
      scrollable = CustomScrollView(
        key: const ValueKey(CompactKey.listing),
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [SliverFillRemaining(hasScrollBody: false, child: empty)],
      );
    } else {
      final extent = MediaQuery.textScalerOf(context).scale(_rowExtent);
      scrollable = ListView.builder(
        key: const ValueKey(CompactKey.listing),
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: padding,
        itemExtent: extent,
        itemCount: entries.length,
        itemBuilder: (context, index) => _CompactRow(
          key: ValueKey((CompactKey.row, entries[index].path)),
          entry: entries[index],
          selected: controller.isRowSelected(index),
          selecting: widget.selecting,
          clock: widget.clock,
          onTap: () => widget.callbacks.onTap(controller, index),
          onLongPress: () => widget.callbacks.onLongPress(controller, index),
          onActions: () => widget.callbacks.onActions(controller, index),
          onRename:
              controller.verbsEnabled && !nameIsFlagged(entries[index].name)
              ? () {
                  controller.setCursorIndex(index);
                  controller.startRename();
                }
              : null,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      // Refresh needs a bound, live listing — never a stale or lost one.
      notificationPredicate: (notification) =>
          controller.verbsEnabled && notification.depth == 0,
      child: scrollable,
    );
  }
}

/// The adhoc bookmark qualifying for 02 §2.7's "Save as favorite…" bar:
/// a live Quick Connect session past a successful connect.
Bookmark? _saveBarBookmark(PaneController controller) {
  final bookmark = controller.remoteBookmark;
  if (bookmark == null) return null;
  if (!bookmark.id.startsWith(quickConnectAdhocIdPrefix)) return null;
  if (controller.phase != PanePhase.browsing) return null;
  return bookmark;
}

/// The kind glyph and its category tint (D32 §6), shared with the
/// desktop row's families: a scheme role per family, never an ad-hoc hue.
(IconData, Color) compactKindGlyph(
  PaneKindCategory category,
  ColorScheme colors,
  PoltergeistChrome chrome,
) => switch (category) {
  PaneKindCategory.folder => (Icons.folder, colors.primary),
  PaneKindCategory.link => (Icons.shortcut_outlined, chrome.secondaryText),
  PaneKindCategory.image => (Icons.image_outlined, colors.tertiary),
  PaneKindCategory.text => (Icons.description_outlined, chrome.secondaryText),
  PaneKindCategory.archive => (Icons.inventory_2_outlined, colors.secondary),
  PaneKindCategory.pdf => (Icons.picture_as_pdf_outlined, colors.error),
  PaneKindCategory.media => (Icons.play_circle_outline, colors.tertiary),
  PaneKindCategory.other => (
    Icons.insert_drive_file_outlined,
    chrome.secondaryText,
  ),
};

/// D32 §9's 56 dp two-line row: a 40 dp kind badge (a check while
/// selected), the name over `size · date`, and a trailing ⋮ for the
/// item's action sheet. Outside selection mode a tap opens; inside it a
/// tap toggles and the ⋮ steps aside (the bottom bar owns the verbs).
class _CompactRow extends StatelessWidget {
  const _CompactRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.selecting,
    required this.clock,
    required this.onTap,
    required this.onLongPress,
    required this.onActions,
    required this.onRename,
  });

  final RemoteFileEntry entry;
  final bool selected;
  final bool selecting;
  final DateTime Function() clock;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onActions;
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final chrome = PoltergeistChrome.of(context);
    final platform = theme.platform;
    final directory = entry.type == RemoteFileType.directory;
    final size = formatPaneSize(
      directory ? null : entry.size,
      platform: platform,
    );
    final modified = formatPaneModified(
      entry.modifiedAt,
      now: clock(),
      localeName: Localizations.localeOf(context).toString(),
      today: l10n.paneDateToday,
      yesterday: l10n.paneDateYesterday,
    );
    final sizeSlot = switch (entry.type) {
      RemoteFileType.directory => l10n.compactRowFolder,
      RemoteFileType.symbolicLink => l10n.compactRowLink,
      _ => size,
    };
    final kind = switch (entry.type) {
      RemoteFileType.file => l10n.paneRowKindFile,
      RemoteFileType.directory => l10n.paneRowKindDirectory,
      RemoteFileType.symbolicLink => l10n.paneRowKindSymbolicLink,
      RemoteFileType.other => l10n.paneRowKindOther,
    };
    final flagged = nameIsFlagged(entry.name);
    final (glyph, tint) = compactKindGlyph(
      paneKindCategory(entry),
      colors,
      chrome,
    );

    final label = flagged
        ? l10n.paneRowSemanticsFlagged(entry.name, kind, size, modified)
        : l10n.paneRowSemantics(entry.name, kind, size, modified);

    final main = Semantics(
      container: true,
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      onLongPress: onLongPress,
      customSemanticsActions: {
        CustomSemanticsAction(label: l10n.fileRenameLabel): ?onRename,
      },
      excludeSemantics: true,
      child: Row(
        children: [
          _KindBadge(
            glyph: glyph,
            tint: tint,
            selected: selected,
            selecting: selecting,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    if (flagged)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 4),
                        child: Icon(
                          Icons.warning_amber_outlined,
                          size: 16,
                          color: colors.error,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.compactRowDetails(sizeSlot, modified),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: chrome.secondaryText,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final fill = selected
        ? Color.alphaBlend(
            colors.primary.withValues(alpha: 0.14),
            chrome.paneBackground,
          )
        : Colors.transparent;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      color: fill,
      child: InkWell(
        // The Semantics node above owns tap/long-press for assistive
        // tech; the ink stays purely visual.
        excludeFromSemantics: true,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
          child: Row(
            children: [
              Expanded(child: main),
              // The ⋮ keeps its slot in selection mode (hidden, inert) so
              // the text column never reflows when the mode flips.
              Visibility.maintain(
                visible: !selecting,
                child: IconButton(
                  key: ValueKey((CompactKey.rowMore, entry.path)),
                  tooltip: l10n.compactRowActions(entry.name),
                  onPressed: selecting ? null : onActions,
                  icon: Icon(Icons.more_vert, color: chrome.secondaryText),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The row's 40 dp leading badge: the kind glyph on a tinted disc, which
/// turns into the accent check while selected (Material's list-selection
/// idiom) and into an empty ring for unselected rows in selection mode.
class _KindBadge extends StatelessWidget {
  const _KindBadge({
    required this.glyph,
    required this.tint,
    required this.selected,
    required this.selecting,
  });

  final IconData glyph;
  final Color tint;
  final bool selected;
  final bool selecting;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final Widget face = selected
        ? DecoratedBox(
            key: const ValueKey(CompactKey.rowCheck),
            decoration: BoxDecoration(
              color: colors.primary,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.check, size: 22, color: colors.onPrimary),
          )
        : DecoratedBox(
            key: ValueKey(glyph),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.14),
              shape: BoxShape.circle,
              border: selecting
                  ? Border.all(color: colors.outline, width: 1.5)
                  : null,
            ),
            child: Icon(glyph, size: 22, color: tint),
          );
    return SizedBox.square(
      dimension: 40,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutBack,
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: child),
        child: SizedBox.expand(key: face.key, child: face),
      ),
    );
  }
}

/// 02 §2.5's Quick Select at touch size: the match field (a name
/// fragment or `*.ext`), the Add/Remove toggle, and Done / ✕. The
/// controller owns the session and its live preview; the strip is its
/// surface. Confirming a multi-row match lands in selection mode.
class _QuickSelectStrip extends StatefulWidget {
  const _QuickSelectStrip({super.key, required this.controller});

  final PaneController controller;

  @override
  State<_QuickSelectStrip> createState() => _QuickSelectStripState();
}

class _QuickSelectStripState extends State<_QuickSelectStrip> {
  // Seeded from the session: it outlives the strip (a pane flip unmounts
  // it), and a blank field over a live preview would confirm an
  // invisible query.
  late final TextEditingController _query = TextEditingController(
    text: widget.controller.quickSelectQuery,
  );

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final controller = widget.controller;
    return Material(
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey(CompactKey.quickSelectField),
                    controller: _query,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: l10n.quickSelectFieldLabel,
                      hintText: l10n.quickSelectFieldHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: controller.changeQuickSelectQuery,
                    onSubmitted: (_) => controller.confirmQuickSelect(),
                  ),
                ),
                IconButton(
                  key: const ValueKey(CompactKey.quickSelectCancel),
                  tooltip: l10n.compactCancel,
                  onPressed: controller.cancelQuickSelect,
                  icon: const Icon(Icons.close),
                ),
                IconButton(
                  key: const ValueKey(CompactKey.quickSelectDone),
                  tooltip: l10n.compactDone,
                  onPressed: controller.confirmQuickSelect,
                  icon: const Icon(Icons.check),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: SegmentedButton<QuickSelectMode>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: QuickSelectMode.add,
                    label: Text(l10n.quickSelectAddLabel),
                  ),
                  ButtonSegment(
                    value: QuickSelectMode.remove,
                    label: Text(l10n.quickSelectRemoveLabel),
                  ),
                ],
                selected: {controller.quickSelectMode},
                onSelectionChanged: (modes) =>
                    controller.changeQuickSelectMode(modes.first),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _BannerTone { neutral, error }

/// The banner slot's touch rendering: an icon, the sentence, and 48 dp
/// actions, wrapping onto a second line on a narrow phone.
class _CompactBanner extends StatelessWidget {
  const _CompactBanner({
    required this.icon,
    required this.tone,
    required this.text,
    required this.actions,
  });

  final IconData icon;
  final _BannerTone tone;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      _BannerTone.error => (colors.errorContainer, colors.onErrorContainer),
      _BannerTone.neutral => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
    };
    return Material(
      color: background,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, size: 20, color: foreground),
                ),
                const SizedBox(width: 12),
                Expanded(
                  // The dimmed listing below leaves the semantics tree, so
                  // the banner is the announcement of the pane's state.
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      text,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: foreground),
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButtonTheme(
                data: TextButtonThemeData(
                  style: TextButton.styleFrom(foregroundColor: foreground),
                ),
                child: IconTheme(
                  data: IconThemeData(color: foreground),
                  child: Wrap(spacing: 4, children: actions),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 02 §2.8's inline error, as a card over the disowned listing.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error, required this.onRetry});

  final RemoteFileException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final detail = compactErrorDetail(l10n, error);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Card(
          elevation: 0,
          color: colors.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Semantics(
              liveRegion: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: colors.error),
                  const SizedBox(height: 12),
                  Text(
                    compactErrorTitle(l10n, error),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      detail,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton.tonalIcon(
                      key: const ValueKey(CompactKey.errorRetry),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.connectionRetry),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyFolder extends StatelessWidget {
  const _EmptyFolder({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final chrome = PoltergeistChrome.of(context);
    return Center(
      key: const ValueKey(CompactKey.emptyFolder),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_open_outlined,
            size: 56,
            color: chrome.secondaryText,
          ),
          const SizedBox(height: 12),
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: chrome.secondaryText),
          ),
        ],
      ),
    );
  }
}

/// 02 §2.7's filtered-to-nothing state: the message plus Clear.
class _FilteredEmpty extends StatelessWidget {
  const _FilteredEmpty({required this.controller});

  final PaneController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.paneFilterNoMatch(controller.filterQuery),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              key: const ValueKey(CompactKey.filterEmptyClear),
              onPressed: controller.clearFilter,
              child: Text(l10n.paneFilterClear),
            ),
          ],
        ),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
