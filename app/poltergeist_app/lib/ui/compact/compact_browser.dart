import 'dart:async';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/checkout_session.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_location.dart';
import '../../services/pane_tabs_controller.dart';
import '../../services/registered_command.dart';
import '../../services/sync_plan_controller.dart';
import '../../services/workspace_controller.dart';
import '../../theme/app_theme.dart';
import '../panes/pane_commands.dart' show kEditSelectAllCommandId;
import '../panes/pane_format.dart';
import '../panes/pane_tabs_view.dart' show paneTabTitle;
import '../panes/quick_connect_view.dart';
import '../sync/sync_plan_view.dart';
import 'compact_breadcrumbs.dart';
import 'compact_command_sheet.dart';
import 'compact_listing.dart';
import 'compact_pane_switcher.dart';
import 'compact_posture.dart';
import 'compact_selection_bar.dart';

/// The pane seams the compact browser hands to its surfaces — the same
/// ones the desktop pane view receives from the shell, so a phone and a
/// desktop pane bind one set of behaviors.
@immutable
class CompactPaneSeams {
  const CompactPaneSeams({
    required this.onCancelRecovery,
    this.bookmarks,
    this.checkoutSession,
    this.onReviewLocalEdits,
    this.onSyncSaveAsFavorite,
    this.onSyncEditRules,
    this.onImportSshConfig,
  });

  /// The shell's sibling-aware cancel for a pane's pending bind or lost
  /// connection (a shared server is detached, never severed).
  final void Function(PaneController pane) onCancelRecovery;
  final BookmarkStore? bookmarks;
  final CheckoutSession? checkoutSession;
  final void Function(String serverId)? onReviewLocalEdits;
  final void Function(SyncPlanController session)? onSyncSaveAsFavorite;
  final void Function(SyncPlanController session)? onSyncEditRules;
  final VoidCallback? onImportSshConfig;
}

/// The selection's title (D32 §9): "3 selected · 42 MB" — the count,
/// then the selected FILES' bytes through the pane's own summary join
/// and size formatter (a folder's listed size is not its contents, so
/// folders add nothing, as in the desktop location header).
String compactSelectionTitle(
  AppLocalizations l10n,
  PaneController pane,
  TargetPlatform platform,
) {
  final count = l10n.compactSelectionCount(pane.selectedCount);
  var bytes = 0;
  var files = 0;
  for (final entry in pane.selectedEntries) {
    final size = entry.size;
    if (entry.type != RemoteFileType.file || size == null) continue;
    bytes += size;
    files++;
  }
  if (files == 0) return count;
  return l10n.paneSelectionSummaryWithSize(
    count,
    formatPaneSize(bytes, platform: platform),
  );
}

/// D32 §9's browser: one pane at a time under an app bar with back, the
/// folder name, `user@host` for a remote, the filter, the A · B pane
/// switcher, and ⋮ (the registry's menus). The breadcrumb chips sit
/// under the bar; a selection swaps the bar for the contextual one and
/// raises the bottom action bar. All state it shows is the workspace's
/// (the active pane, its active tab); the transient modes — selecting,
/// the filter field — belong to the compact workspace, because system
/// back walks them.
class CompactBrowser extends StatelessWidget {
  const CompactBrowser({
    super.key,
    required this.workspace,
    required this.commands,
    required this.onRunCommand,
    required this.seams,
    required this.selecting,
    required this.filterOpen,
    required this.rowCallbacks,
    required this.onBack,
    required this.onSwitchPane,
    required this.onEndSelection,
    required this.onOpenFilter,
    required this.onCloseFilter,
    this.listingBottomPadding = 0,
    this.clock = DateTime.now,
  });

  final WorkspaceController workspace;
  final List<RegisteredCommand> commands;
  final Future<void> Function(RegisteredCommand command) onRunCommand;
  final CompactPaneSeams seams;
  final bool selecting;
  final bool filterOpen;
  final CompactRowCallbacks rowCallbacks;
  final VoidCallback onBack;
  final VoidCallback onSwitchPane;
  final VoidCallback onEndSelection;
  final VoidCallback onOpenFilter;
  final VoidCallback onCloseFilter;

  /// Room below the last row for floating chrome (the progress pill).
  final double listingBottomPadding;
  final DateTime Function() clock;

  RegisteredCommand? _command(String id) {
    for (final command in commands) {
      if (command.id == id) return command;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final strip = workspace.activePane;
    final tab = strip.activeTab;
    final pane = tab?.syncSession == null ? tab?.controller : null;
    final showsSelection = selecting && pane != null;
    final title = tab == null ? l10n.tabLauncherTitle : paneTabTitle(tab, l10n);
    final otherLetter = compactPaneLetter(l10n, !strip.isLeftPane);
    // Kept through selection mode: a long-press must never shift the
    // rows under the finger that made it.
    final Widget? breadcrumbs = pane == null || pane.location == null
        ? null
        : CompactBreadcrumbs(controller: pane);

    return Scaffold(
      key: const ValueKey(CompactKey.browser),
      backgroundColor: PoltergeistChrome.of(context).paneBackground,
      appBar: _SwitchingAppBar(
        child: showsSelection
            ? _selectionBar(context, l10n, pane)
            : _browsingBar(context, l10n, title, pane),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: breadcrumbs ?? const SizedBox(width: double.infinity),
          ),
          Expanded(
            child: _PaneSwitchTransition(
              child: KeyedSubtree(
                key: ValueKey(strip.paneId),
                child: _PaneBody(
                  strip: strip,
                  selecting: selecting,
                  rowCallbacks: rowCallbacks,
                  seams: seams,
                  bottomPadding: listingBottomPadding,
                  clock: clock,
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => SizeTransition(
          sizeFactor: animation,
          alignment: Alignment.topCenter,
          child: child,
        ),
        child: showsSelection
            ? CompactSelectionBar(
                commands: commands,
                onRun: onRunCommand,
                otherPaneLetter: otherLetter,
                moreTitle: l10n.compactSelectionCount(pane.selectedCount),
              )
            : const SizedBox(width: double.infinity),
      ),
    );
  }

  AppBar _browsingBar(
    BuildContext context,
    AppLocalizations l10n,
    String title,
    PaneController? pane,
  ) {
    final chrome = PoltergeistChrome.of(context);
    final theme = Theme.of(context);
    final subtitle = pane == null ? null : _subtitle(l10n, pane);
    final canFilter = pane != null && pane.verbsEnabled;
    return AppBar(
      key: const ValueKey((CompactKey.browser, false)),
      backgroundColor: chrome.paneBackground,
      leading: IconButton(
        key: const ValueKey(CompactKey.browserBack),
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        onPressed: onBack,
        icon: const BackButtonIcon(),
      ),
      titleSpacing: 0,
      title: filterOpen && pane != null
          ? _FilterField(controller: pane, onClose: onCloseFilter)
          : Semantics(
              header: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    key: const ValueKey(CompactKey.browserTitle),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      key: const ValueKey(CompactKey.browserSubtitle),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: chrome.secondaryText,
                      ),
                    ),
                ],
              ),
            ),
      actions: [
        if (!filterOpen)
          IconButton(
            key: const ValueKey(CompactKey.browserFilter),
            tooltip: l10n.compactFilterOpen,
            onPressed: canFilter ? onOpenFilter : null,
            icon: const Icon(Icons.search),
          ),
        // The filter field takes the bar's room while it is open.
        if (!filterOpen)
          CompactPaneSwitcher(workspace: workspace, onSwitch: onSwitchPane),
        IconButton(
          key: const ValueKey(CompactKey.browserMore),
          tooltip: l10n.compactMoreOptions,
          onPressed: () => unawaited(
            showCompactCommandSheet(
              context,
              title: title,
              commands: commands,
              onRun: onRunCommand,
            ),
          ),
          icon: const Icon(Icons.more_vert),
        ),
      ],
    );
  }

  AppBar _selectionBar(
    BuildContext context,
    AppLocalizations l10n,
    PaneController pane,
  ) {
    final colors = Theme.of(context).colorScheme;
    final selectAll = _command(kEditSelectAllCommandId);
    return AppBar(
      key: const ValueKey((CompactKey.browser, true)),
      backgroundColor: colors.primaryContainer,
      foregroundColor: colors.onPrimaryContainer,
      leading: IconButton(
        key: const ValueKey(CompactKey.selectionClose),
        tooltip: l10n.compactSelectionClear,
        onPressed: onEndSelection,
        icon: const Icon(Icons.close),
      ),
      title: Semantics(
        liveRegion: true,
        child: Text(
          compactSelectionTitle(l10n, pane, Theme.of(context).platform),
          key: const ValueKey(CompactKey.selectionTitle),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      actions: [
        if (selectAll != null)
          IconButton(
            key: const ValueKey(CompactKey.selectionSelectAll),
            tooltip: selectAll.label(l10n),
            onPressed: selectAll.enabled()
                ? () => unawaited(onRunCommand(selectAll))
                : null,
            icon: const Icon(Icons.select_all),
          ),
      ],
    );
  }

  /// The title's second line: `user@host` for a remote (10 §4's address
  /// grammar), the server's name when the binding carries no embedded
  /// identity (a shared-account catalog server), the item count for a
  /// local folder.
  String? _subtitle(AppLocalizations l10n, PaneController pane) {
    final bookmark = pane.remoteBookmark;
    if (bookmark != null) {
      final identity = bookmark.server?.identity;
      if (identity != null) return '${identity.username}@${identity.host}';
      return bookmark.label;
    }
    if (pane.location is LocalPaneLocation &&
        pane.phase == PanePhase.browsing) {
      return l10n.paneItemCount(pane.entries.length);
    }
    return null;
  }
}

/// Cross-fades the browsing and selection app bars so a long-press
/// reads as a mode change rather than a jump.
class _SwitchingAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _SwitchingAppBar({required this.child});

  final Widget child;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: child,
    );
  }
}

/// A pane flip slides the incoming pane in from its side — B from the
/// end edge, A from the start — so the two panes read as neighbours.
class _PaneSwitchTransition extends StatelessWidget {
  const _PaneSwitchTransition({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final fromEnd = child.key == ValueKey(PaneTabsController.rightPaneId);
        final rtl = Directionality.of(context) == TextDirection.rtl;
        final dx = (fromEnd ? 0.25 : -0.25) * (rtl ? -1 : 1);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(
              begin: Offset(dx, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// The active pane's surface: the launcher while it holds no tab, a sync
/// plan tab's review, or the listing.
class _PaneBody extends StatelessWidget {
  const _PaneBody({
    required this.strip,
    required this.selecting,
    required this.rowCallbacks,
    required this.seams,
    required this.bottomPadding,
    required this.clock,
  });

  final PaneTabsController strip;
  final bool selecting;
  final CompactRowCallbacks rowCallbacks;
  final CompactPaneSeams seams;
  final double bottomPadding;
  final DateTime Function() clock;

  @override
  Widget build(BuildContext context) {
    final tab = strip.activeTab;
    final Widget body;
    if (tab == null) {
      body = _CompactLauncher(
        key: ValueKey((CompactKey.launcher, strip.paneId)),
        strip: strip,
        onImportSshConfig: seams.onImportSshConfig,
      );
    } else if (tab.syncSession case final session?) {
      body = SyncPlanView(
        key: ValueKey(tab.id),
        controller: session,
        onSaveAsFavorite: seams.onSyncSaveAsFavorite == null
            ? null
            : () => seams.onSyncSaveAsFavorite!(session),
        onEditRules: seams.onSyncEditRules == null
            ? null
            : () => seams.onSyncEditRules!(session),
      );
    } else {
      body = CompactListing(
        key: ValueKey(tab.id),
        controller: tab.controller,
        selecting: selecting,
        callbacks: rowCallbacks,
        onCancelRecovery: () => seams.onCancelRecovery(tab.controller),
        bookmarks: seams.bookmarks,
        checkoutSession: seams.checkoutSession,
        onReviewLocalEdits: seams.onReviewLocalEdits,
        bottomPadding: bottomPadding,
        clock: clock,
      );
    }
    // A tab switch (⋮ ▸ Next Tab) cross-fades inside the pane.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: body,
    );
  }
}

/// 02 §2.7's launcher in the compact posture: a pane with no tab open
/// offers Quick Connect in place (the Home screen is one back away).
class _CompactLauncher extends StatefulWidget {
  const _CompactLauncher({
    super.key,
    required this.strip,
    this.onImportSshConfig,
  });

  final PaneTabsController strip;
  final VoidCallback? onImportSshConfig;

  @override
  State<_CompactLauncher> createState() => _CompactLauncherState();
}

class _CompactLauncherState extends State<_CompactLauncher> {
  final _addressFocus = FocusNode();

  @override
  void dispose() {
    _addressFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chrome = PoltergeistChrome.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        Text(
          l10n.compactLauncherHint,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: chrome.secondaryText),
        ),
        const SizedBox(height: 16),
        QuickConnectView(
          focusNode: _addressFocus,
          onImportSshConfig: widget.onImportSshConfig,
          onConnect: (bookmark, initialPath) {
            final tab = widget.strip.newTab(target: NewTabTarget.launcher);
            unawaited(
              tab.controller.connectRemote(bookmark, initialPath: initialPath),
            );
          },
        ),
      ],
    );
  }
}

/// The app bar's filter field (D32 §4's filter, touch-sized): filters the
/// shown pane as the user types; the ✕ clears the filter and closes the
/// field. Seeded from — and writing to — the pane's own filter, so the
/// query survives a trip to Home and matches the desktop header's.
class _FilterField extends StatefulWidget {
  const _FilterField({required this.controller, required this.onClose});

  final PaneController controller;
  final VoidCallback onClose;

  @override
  State<_FilterField> createState() => _FilterFieldState();
}

class _FilterFieldState extends State<_FilterField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.filterQuery,
  );

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
    final pane = widget.controller;
    return ListenableBuilder(
      listenable: pane,
      builder: (context, _) => TextField(
        key: const ValueKey(CompactKey.filterField),
        controller: _text,
        autofocus: true,
        textInputAction: TextInputAction.search,
        textAlignVertical: TextAlignVertical.center,
        style: theme.textTheme.titleMedium,
        onChanged: pane.setFilterQuery,
        decoration: InputDecoration(
          hintText: l10n.headerFilterHint,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pane.filterActive)
                Text(
                  l10n.paneFilterCount(
                    pane.entries.length,
                    pane.unfilteredCount,
                  ),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: chrome.secondaryText,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              IconButton(
                key: const ValueKey(CompactKey.filterClose),
                tooltip: l10n.compactFilterClose,
                onPressed: widget.onClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
