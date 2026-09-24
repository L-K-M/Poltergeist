import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/activity_panel_controller.dart';
import '../panes/pane_format.dart';
import 'activity_rows.dart';
import 'bandwidth_popover.dart';
import 'conflict_widgets.dart';
import 'history_view.dart';

/// The activity panel (02 §6, D16): optional bottom-panel chrome whose
/// rows are the transfer queue's ONLY window — hiding the panel hides
/// the chrome, never the queue's truth (the status chip still counts
/// live tasks, and the panel re-opens on new work).
///
/// Layout: header (tabs + queue controls), restored-queue banner,
/// pending-conflict strip, body (Activity list or History), and the
/// growing-totals footer.
class ActivityPanel extends StatelessWidget {
  const ActivityPanel({
    super.key,
    required this.controller,
    required this.onClose,
    this.onReveal,
    this.embedded = false,
  });

  final ActivityPanelController controller;

  /// D32's inspector embedding (10 §3): the panel is the inspector's
  /// Transfers tab — it paints on the inspector's surface, carries no ✕
  /// (the inspector toggle owns visibility), and its bandwidth popover
  /// opens downward from the top-edge header.
  final bool embedded;

  /// The header's close affordance — `view.toggleActivityPanel`'s
  /// hide direction (the user's persisted intent).
  final VoidCallback onClose;

  /// Reveal-in-pane: opens the task's destination in the active pane.
  final void Function(TransferTask task)? onReveal;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: embedded ? Colors.transparent : colors.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ActivityHeader(
            controller: controller,
            onClose: onClose,
            embedded: embedded,
          ),
          if (controller.restoredTasks.isNotEmpty)
            _RestoredBanner(controller: controller),
          if (controller.tab == ActivityPanelTab.activity &&
              controller.pendingConflicts.isNotEmpty)
            ConflictStrip(
              key: const ValueKey('activity.conflicts'),
              controller: controller,
            ),
          Expanded(
            child: switch (controller.tab) {
              ActivityPanelTab.activity => ActivityTaskList(
                  controller: controller,
                  onReveal: onReveal,
                ),
              ActivityPanelTab.history =>
                ActivityHistoryView(controller: controller),
            },
          ),
          if (controller.tab == ActivityPanelTab.activity)
            _TotalsFooter(controller: controller),
        ],
      ),
    );
  }
}

class _ActivityHeader extends StatelessWidget {
  const _ActivityHeader({
    required this.controller,
    required this.onClose,
    required this.embedded,
  });

  final ActivityPanelController controller;
  final VoidCallback onClose;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final paused = controller.queuePaused;
    final limited =
        controller.downloadLimit != null || controller.uploadLimit != null;
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
        child: Row(
          children: [
            // The tab pair yields width to the queue controls: in the
            // inspector's Transfers tab (D32) the header is only the
            // column's width, so long labels ellipsize instead of
            // overflowing the row.
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: _PanelTab(
                      key: const ValueKey('activity.tab.activity'),
                      label: l10n.activityTabActivity,
                      selected: controller.tab == ActivityPanelTab.activity,
                      onTap: () =>
                          controller.selectTab(ActivityPanelTab.activity),
                    ),
                  ),
                  Flexible(
                    child: _PanelTab(
                      key: const ValueKey('activity.tab.history'),
                      label: l10n.activityTabHistory,
                      selected: controller.tab == ActivityPanelTab.history,
                      onTap: () =>
                          controller.selectTab(ActivityPanelTab.history),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('activity.pause'),
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: paused
                  ? l10n.queueResumeTooltip
                  : l10n.queuePauseTooltip,
              onPressed:
                  controller.queue == null ? null : controller.toggleQueuePause,
              icon: Icon(paused ? Icons.play_arrow : Icons.pause),
            ),
            _BandwidthButton(
              controller: controller,
              limited: limited,
              opensDownward: embedded,
            ),
            IconButton(
              key: const ValueKey('activity.clearCompleted'),
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: l10n.activityClearCompleted,
              onPressed: controller.queue == null
                  ? null
                  : controller.clearCompleted,
              icon: const Icon(Icons.playlist_remove),
            ),
            if (!embedded)
              IconButton(
                key: const ValueKey('activity.close'),
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                tooltip: l10n.activityClosePanel,
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
      ),
    );
  }
}

class _PanelTab extends StatelessWidget {
  const _PanelTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(end: 4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 4,
            ),
            decoration: BoxDecoration(
              color: selected ? colors.surfaceContainerHighest : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: selected ? null : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The header's bandwidth button: the ∞ glyph while unlimited (02 §6),
/// a filled speed glyph while any direction is limited. The popover is
/// an anchored overlay — a `MenuAnchor` cannot host the custom-rate
/// field.
class _BandwidthButton extends StatefulWidget {
  const _BandwidthButton({
    required this.controller,
    required this.limited,
    this.opensDownward = false,
  });

  final ActivityPanelController controller;
  final bool limited;

  /// The inspector's header sits at the top edge — the popover opens
  /// below it there, above the bottom panel's header otherwise.
  final bool opensDownward;

  @override
  State<_BandwidthButton> createState() => _BandwidthButtonState();
}

class _BandwidthButtonState extends State<_BandwidthButton> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => Stack(
          children: [
            // Tap-outside dismissal — modal semantics without a route.
            // Opaque: translucent would leak tap-down/ripple and hover
            // to the widgets behind the barrier.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _portal.hide,
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              // Bottom-edge chrome opens the popover UPWARD over it,
              // never below into off-screen space; the inspector's
              // top-edge header opens it downward.
              targetAnchor: widget.opensDownward
                  ? Alignment.bottomRight
                  : Alignment.topRight,
              followerAnchor: widget.opensDownward
                  ? Alignment.topRight
                  : Alignment.bottomRight,
              offset: Offset(0, widget.opensDownward ? 4 : -4),
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: BandwidthPopover(
                    key: const ValueKey('activity.bandwidthPopover'),
                    controller: widget.controller,
                  ),
                ),
              ),
            ),
          ],
        ),
        child: IconButton(
          key: const ValueKey('activity.bandwidth'),
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          tooltip: l10n.activityBandwidthButton,
          onPressed: _portal.toggle,
          icon: widget.limited
              ? const Icon(Icons.speed)
              : Text(
                  l10n.activityBandwidthUnlimited,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
        ),
      ),
    );
  }
}

/// 02 §6's restored-queue banner: a journal-restored queue arrives
/// paused — the banner names the count and offers Resume / Discard.
class _RestoredBanner extends StatelessWidget {
  const _RestoredBanner({required this.controller});

  final ActivityPanelController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final count = controller.restoredTasks.length;
    return Material(
      key: const ValueKey('activity.restoredBanner'),
      color: colors.tertiaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.history, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.activityRestoredBanner(count),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            TextButton(
              key: const ValueKey('activity.restoredBanner.resume'),
              onPressed: controller.resumeRestoredQueue,
              child: Text(l10n.activityRestoredResume),
            ),
            TextButton(
              key: const ValueKey('activity.restoredBanner.discard'),
              onPressed: controller.discardRestoredQueue,
              child: Text(l10n.activityRestoredDiscard),
            ),
          ],
        ),
      ),
    );
  }
}

/// The growing-totals footer (02 §5.3's "so far" semantics): item and
/// byte counts across every task, with a trailing + while any scan is
/// still discovering work.
class _TotalsFooter extends StatelessWidget {
  const _TotalsFooter({required this.controller});

  final ActivityPanelController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final platform = Theme.of(context).platform;
    var done = 0;
    var total = 0;
    var bytes = 0;
    var totalBytes = 0;
    var growing = false;
    for (final task in controller.tasks) {
      done += task.completedFiles +
          task.completedDirectories +
          task.failedItems +
          task.skippedItems;
      total += task.totalFiles + task.totalDirectories;
      bytes += task.transferredBytes;
      totalBytes += task.totalBytes ?? 0;
      if (!task.scanComplete && !task.isTerminal) growing = true;
    }
    return Padding(
      key: const ValueKey('activity.footer'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        l10n.activityFooterTotals(
          '$done${growing ? '+' : ''}',
          '$total${growing ? '+' : ''}',
          formatPaneSize(bytes, platform: platform),
          '${formatPaneSize(totalBytes, platform: platform)}'
          '${growing ? '+' : ''}',
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

/// The panes↔activity splitter (02 §1's third splitter): drags set the
/// panel's pixel height inside [min, max]; keyboard and semantics mirror
/// the pane splitter's pattern.
class ActivityHeightSplitter extends StatelessWidget {
  const ActivityHeightSplitter({
    super.key,
    required this.focusNode,
    required this.label,
    required this.value,
    required this.increasedValue,
    required this.decreasedValue,
    required this.onResize,
    required this.onResizeEnd,
  });

  final FocusNode focusNode;
  final String label;
  final String value;
  final String increasedValue;
  final String decreasedValue;

  /// Drag/key deltas — positive grows the panel upward.
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;

  static const _keyboardStep = 16.0;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onFocusChange: (hasFocus) {
        if (!hasFocus) onResizeEnd();
      },
      onKeyEvent: (_, event) {
        final delta = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowUp => _keyboardStep,
          LogicalKeyboardKey.arrowDown => -_keyboardStep,
          _ => null,
        };
        if (delta == null) return KeyEventResult.ignored;
        if (event is KeyUpEvent) {
          onResizeEnd();
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          onResize(delta);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedBuilder(
        animation: focusNode,
        builder: (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            border: focusNode.hasFocus
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : null,
          ),
          child: child,
        ),
        child: Semantics(
          label: label,
          value: value,
          increasedValue: increasedValue,
          decreasedValue: decreasedValue,
          onIncrease: () {
            onResize(_keyboardStep);
            onResizeEnd();
          },
          onDecrease: () {
            onResize(-_keyboardStep);
            onResizeEnd();
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeRow,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onTap: focusNode.requestFocus,
              onVerticalDragUpdate: (details) => onResize(-details.delta.dy),
              onVerticalDragEnd: (_) => onResizeEnd(),
              onVerticalDragCancel: onResizeEnd,
              child: Center(
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: Theme.of(context).dividerColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
