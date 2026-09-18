import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/activity_panel_controller.dart';
import '../panes/pane_format.dart';
import 'activity_format.dart';
import 'conflict_widgets.dart';

/// 02 §6's task-state presentation order: live rows pin to the top,
/// reorderable admissions follow in queue order, terminal rows sit at
/// the bottom until Clear-completed or the linger removes them.
enum _RowBand { live, pending, terminal }

/// The Activity tab's task list: one row per task, always rendered while
/// a task exists (D16 forbids aggregate-only display), expandable into
/// per-file sub-rows, draggable only inside the pending band.
class ActivityTaskList extends StatefulWidget {
  const ActivityTaskList({
    super.key,
    required this.controller,
    this.onReveal,
  });

  final ActivityPanelController controller;

  /// Reveal-in-pane (02 §6): opens the task's destination directory in
  /// the active pane. Null disables the action (no pane host).
  final void Function(TransferTask task)? onReveal;

  @override
  State<ActivityTaskList> createState() => _ActivityTaskListState();
}

class _ActivityTaskListState extends State<ActivityTaskList> {
  final _expanded = <String>{};

  ActivityPanelController get _controller => widget.controller;

  static _RowBand _band(TransferTask task) => switch (task.state) {
    TransferTaskState.running ||
    TransferTaskState.paused => _RowBand.live,
    TransferTaskState.queued ||
    TransferTaskState.scanning => _RowBand.pending,
    _ => _RowBand.terminal,
  };

  /// The core's own reorderable gate (queued/scanning — file work has
  /// not dispatched yet). Display bands and the queue agree: only the
  /// pending band carries drag handles.
  static bool _isReorderable(TransferTask task) =>
      _band(task) == _RowBand.pending;

  List<TransferTask> _orderedTasks() {
    final tasks = _controller.tasks;
    return [
      for (final task in tasks)
        if (_band(task) == _RowBand.live) task,
      for (final task in tasks)
        if (_band(task) == _RowBand.pending) task,
      for (final task in tasks)
        if (_band(task) == _RowBand.terminal) task,
    ];
  }

  /// Maps a ReorderableListView drop onto the queue's admission order:
  /// the drop target is clamped into the pending band, then translated
  /// to the `beforeTaskId` vocabulary — null lands behind the last
  /// reorderable task (the movable run's tail). `onReorderItem`'s
  /// newIndex is already adjusted for the removed row.
  void _onReorder(int oldIndex, int newIndex, List<TransferTask> display) {
    if (oldIndex < 0 || oldIndex >= display.length) return;
    final task = display[oldIndex];
    if (!_isReorderable(task)) return;

    final pendingIds = [
      for (final entry in display)
        if (_isReorderable(entry)) entry.id,
    ];
    final liveCount =
        display.where((t) => _band(t) == _RowBand.live).length;
    final target = newIndex.clamp(liveCount, liveCount + pendingIds.length);
    final pendingIndex = target - liveCount;
    _controller.moveTask(
      task.id,
      beforeTaskId: pendingIndex < pendingIds.length
          ? pendingIds[pendingIndex]
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final display = _orderedTasks();
    if (display.isEmpty) {
      return Center(child: Text(l10n.activityEmpty));
    }
    return ReorderableListView.builder(
      key: const ValueKey('activity.taskList'),
      buildDefaultDragHandles: false,
      itemCount: display.length,
      onReorderItem: (oldIndex, newIndex) =>
          _onReorder(oldIndex, newIndex, display),
      itemBuilder: (context, index) {
        final task = display[index];
        return _TaskRow(
          key: ValueKey('activity.task.${task.id}'),
          index: index,
          task: task,
          controller: _controller,
          expanded: _expanded.contains(task.id),
          onToggleExpanded: () => setState(() {
            if (!_expanded.remove(task.id)) _expanded.add(task.id);
          }),
          onReveal: widget.onReveal,
        );
      },
    );
  }
}

/// One task row plus its expanded per-file sub-rows.
class _TaskRow extends StatelessWidget {
  const _TaskRow({
    super.key,
    required this.index,
    required this.task,
    required this.controller,
    required this.expanded,
    required this.onToggleExpanded,
    this.onReveal,
  });

  final int index;
  final TransferTask task;
  final ActivityPanelController controller;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final void Function(TransferTask task)? onReveal;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final platform = Theme.of(context).platform;
    final colors = Theme.of(context).colorScheme;
    final reorderable = _ActivityTaskListState._isReorderable(task);

    return Column(
      key: ValueKey('activity.taskBody.${task.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (reorderable)
                ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsetsDirectional.only(end: 6, top: 2),
                    child: Icon(Icons.drag_indicator, size: 18),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsetsDirectional.only(end: 6, top: 2),
                  child: SizedBox(width: 18),
                ),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8, top: 2),
                child: Icon(
                  _operationIcon(task),
                  size: 18,
                  color: task.state == TransferTaskState.failed
                      ? colors.error
                      : null,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _taskTitle(task, l10n),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _taskStateLabel(task, l10n),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: task.state ==
                                        TransferTaskState.failed
                                    ? colors.error
                                    : colors.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                    Text(
                      formatTransferRoute(
                        task,
                        localLabel: l10n.activityTaskRouteLocal,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 4),
                    _TaskProgress(
                      task: task,
                      platform: platform,
                      controller: controller,
                    ),
                    _TaskActions(
                      task: task,
                      controller: controller,
                      expanded: expanded,
                      onToggleExpanded: onToggleExpanded,
                      onReveal: onReveal,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (expanded)
          for (final item in task.items)
            _ItemSubRow(
              key: ValueKey('activity.item.${item.id}'),
              task: task,
              item: item,
              controller: controller,
            ),
        const Divider(height: 1),
      ],
    );
  }

  static IconData _operationIcon(TransferTask task) {
    if (task.operation == TransferOperation.delete) {
      return Icons.delete_outline;
    }
    if (task.operation == TransferOperation.move) {
      return Icons.drive_file_move_outlined;
    }
    return switch ((task.source, task.destination)) {
      (LocalFsLocation(), ServerFsLocation()) => Icons.upload_outlined,
      (ServerFsLocation(), LocalFsLocation()) => Icons.download_outlined,
      (ServerFsLocation(), ServerFsLocation()) => Icons.swap_horiz,
      _ => Icons.content_copy_outlined,
    };
  }

  static String _taskTitle(TransferTask task, AppLocalizations l10n) {
    if (task.rootPaths.length == 1) {
      return pathBasename(task.rootPaths.first);
    }
    if (task.operation == TransferOperation.delete) {
      return l10n.activityTaskTitleDelete(task.rootPaths.length);
    }
    return l10n.activityTaskTitleMulti(
      task.rootPaths.length,
      pathBasename(task.destinationDir),
    );
  }

  static String _taskStateLabel(TransferTask task, AppLocalizations l10n) =>
      switch (task.state) {
        TransferTaskState.queued => l10n.transferStateQueued,
        TransferTaskState.scanning => l10n.transferStateScanning,
        TransferTaskState.running => l10n.transferStateRunning,
        TransferTaskState.paused => l10n.transferStatePaused,
        TransferTaskState.completed => l10n.transferStateCompleted,
        TransferTaskState.failed => l10n.transferStateFailed,
        TransferTaskState.cancelled => l10n.transferStateCancelled,
      };
}

/// The row's progress bar plus its bytes/rate/ETA readout (02 §5.3:
/// totals grow while scanning, marked by a trailing +).
class _TaskProgress extends StatelessWidget {
  const _TaskProgress({
    required this.task,
    required this.platform,
    required this.controller,
  });

  final TransferTask task;
  final TargetPlatform platform;
  final ActivityPanelController controller;

  @override
  Widget build(BuildContext context) {
    final total = task.totalBytes;
    final progress = total != null && total > 0
        ? (task.transferredBytes / total).clamp(0.0, 1.0)
        : null;
    // An unscanned or byteless task has no denominator — the
    // indeterminate bar is honest only while the task is actually
    // working (scanning/running). A queued or paused row sits still.
    final barValue =
        progress ??
        switch (task.state) {
          TransferTaskState.scanning || TransferTaskState.running => null,
          TransferTaskState.completed => 1.0,
          _ => 0.0,
        };
    final rate = controller.rateFor(task.id);
    final eta = controller.etaFor(task);
    final detail = StringBuffer()
      ..write(
        formatPaneSize(task.transferredBytes, platform: platform),
      )
      ..write(' / ')
      ..write(formatPaneSize(total, platform: platform))
      ..write(task.scanComplete ? '' : '+');
    if (rate != null && rate > 0) {
      detail
        ..write(' · ')
        ..write(formatTransferRate(rate, platform: platform));
    }
    if (eta != null) {
      detail
        ..write(' · ')
        ..write(formatTransferEta(eta));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: barValue, minHeight: 4),
        const SizedBox(height: 2),
        Text(
          detail.toString(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }
}

/// The row's verb strip (02 §6): per-state honest actions only — a
/// queued row can be cancelled but never retried, a failed row offers
/// Retry, Remove, and Copy error.
class _TaskActions extends StatelessWidget {
  const _TaskActions({
    required this.task,
    required this.controller,
    required this.expanded,
    required this.onToggleExpanded,
    this.onReveal,
  });

  final TransferTask task;
  final ActivityPanelController controller;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final void Function(TransferTask task)? onReveal;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final live = !task.isTerminal;
    return Row(
      children: [
        if (task.items.length > 1)
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: expanded
                ? l10n.activityCollapseTask
                : l10n.activityExpandTask,
            onPressed: onToggleExpanded,
            icon: Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
            ),
          ),
        const Spacer(),
        if (live && task.state != TransferTaskState.queued)
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: task.state == TransferTaskState.paused
                ? l10n.queueResumeTooltip
                : l10n.queuePauseTooltip,
            onPressed: () => task.state == TransferTaskState.paused
                ? controller.resumeTask(task.id)
                : controller.pauseTask(task.id),
            icon: Icon(
              task.state == TransferTaskState.paused
                  ? Icons.play_arrow
                  : Icons.pause,
            ),
          ),
        if (live)
          IconButton(
            key: ValueKey('activity.cancel.${task.id}'),
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: l10n.activityCancelTask,
            onPressed: () => controller.cancelTask(task.id),
            icon: const Icon(Icons.close),
          ),
        if (controller.canRetryTask(task.id))
          IconButton(
            key: ValueKey('activity.retry.${task.id}'),
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: l10n.activityRetryTask,
            onPressed: () => controller.retryTask(task.id),
            icon: const Icon(Icons.refresh),
          ),
        if (task.isTerminal)
          IconButton(
            key: ValueKey('activity.remove.${task.id}'),
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: l10n.activityRemoveTask,
            onPressed: () => controller.removeTask(task.id),
            icon: const Icon(Icons.remove_circle_outline),
          ),
        if (task.error != null)
          IconButton(
            key: ValueKey('activity.copyError.${task.id}'),
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: l10n.activityCopyError,
            onPressed: () => unawaited(
              Clipboard.setData(ClipboardData(text: task.error!)),
            ),
            icon: const Icon(Icons.copy_outlined),
          ),
        if (onReveal != null)
          IconButton(
            key: ValueKey('activity.reveal.${task.id}'),
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: l10n.activityRevealInPane,
            onPressed: () => onReveal!(task),
            icon: const Icon(Icons.folder_open_outlined),
          ),
      ],
    );
  }
}

/// One per-file sub-row (02 §6's expanded task): name, per-item bytes,
/// state, and the state-honest verb — Skip while queued, Cancel in
/// flight, Retry when failed, Resolve… while parked on a conflict.
class _ItemSubRow extends StatelessWidget {
  const _ItemSubRow({
    super.key,
    required this.task,
    required this.item,
    required this.controller,
  });

  final TransferTask task;
  final TransferItem item;
  final ActivityPanelController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final platform = Theme.of(context).platform;
    final colors = Theme.of(context).colorScheme;

    final detail = StringBuffer(_itemStateLabel(item, l10n));
    if (item.state == TransferItemState.active || item.isTerminal) {
      detail
        ..write(' · ')
        ..write(formatPaneSize(item.transferredBytes, platform: platform))
        ..write(' / ')
        ..write(formatPaneSize(item.size, platform: platform));
    }
    if (item.error != null) {
      detail
        ..write(' · ')
        ..write(item.error);
    }
    // D15's disposition text on a completed delete item — the only
    // trash surfacing this task ships.
    if (item.state == TransferItemState.completed &&
        item.disposition != null) {
      detail
        ..write(' · ')
        ..write(
          item.disposition == ItemDisposition.permanent
              ? l10n.activityDeletePermanent
              : l10n.activityDeleteTrashed,
        );
    }

    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: 42,
        end: 10,
        bottom: 2,
      ),
      child: Row(
        children: [
          Icon(
            item.isDirectory
                ? Icons.folder_outlined
                : Icons.insert_drive_file_outlined,
            size: 16,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pathBasename(item.sourcePath),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                Text(
                  detail.toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: item.state == TransferItemState.failed
                        ? colors.error
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _itemAction(context, l10n),
        ],
      ),
    );
  }

  static String _itemStateLabel(
    TransferItem item,
    AppLocalizations l10n,
  ) =>
      switch (item.state) {
        TransferItemState.pending => l10n.transferItemPending,
        TransferItemState.active => l10n.transferStateRunning,
        TransferItemState.conflictPending => l10n.transferItemConflict,
        TransferItemState.completed => l10n.transferStateCompleted,
        TransferItemState.skipped => l10n.transferItemSkipped,
        TransferItemState.failed => l10n.transferStateFailed,
        TransferItemState.cancelled => l10n.transferStateCancelled,
      };

  Widget _itemAction(BuildContext context, AppLocalizations l10n) =>
      switch (item.state) {
        TransferItemState.pending => TextButton(
            key: ValueKey('activity.itemSkip.${item.id}'),
            onPressed: () => controller.cancelItem(task.id, item.id),
            child: Text(l10n.activitySkipItem),
          ),
        TransferItemState.active => TextButton(
            key: ValueKey('activity.itemCancel.${item.id}'),
            onPressed: () => controller.cancelItem(task.id, item.id),
            child: Text(l10n.activityCancelItem),
          ),
        TransferItemState.conflictPending => TextButton(
            key: ValueKey('activity.itemResolve.${item.id}'),
            onPressed: () {
              final conflict = controller.queue?.pendingConflictFor(
                task.id,
                item.id,
              );
              if (conflict != null) {
                unawaited(
                  showTransferConflictDialog(
                    context,
                    controller: controller,
                    conflict: conflict,
                  ),
                );
              }
            },
            child: Text(l10n.conflictResolve),
          ),
        TransferItemState.failed => controller.canRetryItem(task.id, item.id)
            ? TextButton(
                key: ValueKey('activity.itemRetry.${item.id}'),
                onPressed: () => controller.retryItem(task.id, item.id),
                child: Text(l10n.activityRetryTask),
              )
            : const SizedBox.shrink(),
        _ => const SizedBox.shrink(),
      };
}
