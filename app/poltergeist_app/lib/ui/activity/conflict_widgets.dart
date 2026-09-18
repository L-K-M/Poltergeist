import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/activity_panel_controller.dart';
import '../panes/pane_format.dart';
import 'activity_format.dart';

/// The conflict dialog's outcome (02 §5.2): a verb answer with its
/// scope, the Stop escape, or a dismissal that leaves the item parked.
sealed class ConflictDialogResult {
  const ConflictDialogResult();
}

final class ConflictDialogAnswer extends ConflictDialogResult {
  const ConflictDialogAnswer(this.verb, this.scope);

  final ConflictResolution verb;
  final ConflictResolutionScope scope;
}

/// Stop — cancels the task the parked conflict belongs to.
final class ConflictDialogStop extends ConflictDialogResult {
  const ConflictDialogStop();
}

/// The Activity tab's pending-conflict strip (02 §5.2/§6): renders from
/// the queue's `pendingConflicts` query — never a mirror of its own —
/// with one Resolve affordance per parked item.
class ConflictStrip extends StatelessWidget {
  const ConflictStrip({super.key, required this.controller});

  final ActivityPanelController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final conflicts = controller.pendingConflicts;
    return Material(
      color: colors.errorContainer.withValues(alpha: 0.35),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 10, 2),
            child: Text(
              l10n.activityConflictsTitle(conflicts.length),
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          for (final conflict in conflicts)
            Padding(
              key: ValueKey('activity.conflict.${conflict.itemId}'),
              padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 10, 4),
              child: Row(
                children: [
                  Icon(
                    conflict.isDirectory
                        ? Icons.folder_outlined
                        : Icons.insert_drive_file_outlined,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      pathBasename(conflict.destinationPath),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  TextButton(
                    key: ValueKey(
                      'activity.conflictResolve.${conflict.itemId}',
                    ),
                    onPressed: () => showTransferConflictDialog(
                      context,
                      controller: controller,
                      conflict: conflict,
                    ),
                    child: Text(l10n.conflictResolve),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The 02 §5.2 chooser: the collision's two sides, the five verbs
/// (Merge only on folders — `availableVerbs` carries the rule), the
/// task-scope checkbox, and Stop. A dismissed dialog answers nothing —
/// the item stays parked.
Future<void> showTransferConflictDialog(
  BuildContext context, {
  required ActivityPanelController controller,
  required PendingConflict conflict,
}) async {
  final result = await showDialog<ConflictDialogResult>(
    context: context,
    builder: (_) => _ConflictDialog(
      controller: controller,
      conflict: conflict,
    ),
  );
  switch (result) {
    case ConflictDialogAnswer(:final verb, :final scope):
      controller.resolveConflict(conflict, verb, scope: scope);
    case ConflictDialogStop():
      controller.stopConflictTask(conflict);
    case null:
      break;
  }
}

class _ConflictDialog extends StatefulWidget {
  const _ConflictDialog({required this.controller, required this.conflict});

  final ActivityPanelController controller;
  final PendingConflict conflict;

  @override
  State<_ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<_ConflictDialog> {
  bool _applyToAll = false;

  /// The checkbox's N (02 §5.2's wording): the OTHER conflicts parked in
  /// the same task — the answer to "all" excludes the item being
  /// answered.
  int get _remainingInTask => [
    for (final other in widget.controller.pendingConflicts)
      if (other.taskId == widget.conflict.taskId &&
          other.itemId != widget.conflict.itemId)
        other,
  ].length;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final conflict = widget.conflict;
    final remaining = _remainingInTask;
    return AlertDialog(
      title: Text(
        l10n.conflictDialogTitle(
          conflict.source.name,
          pathDirname(conflict.destinationPath) ??
              conflict.destinationPath,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.conflictExistingLine(_statSummary(conflict.existing)),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.conflictReplacingLine(_entrySummary(conflict.source)),
          ),
          const SizedBox(height: 12),
          for (final verb in conflict.availableVerbs)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  key: ValueKey('conflict.verb.${verb.name}'),
                  onPressed: () => Navigator.of(context).pop(
                    ConflictDialogAnswer(
                      verb,
                      _applyToAll
                          ? ConflictResolutionScope.task
                          : ConflictResolutionScope.item,
                    ),
                  ),
                  child: Text(_verbLabel(verb, l10n)),
                ),
              ),
            ),
          if (remaining > 0)
            CheckboxListTile(
              key: const ValueKey('conflict.applyToAll'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                l10n.conflictApplyToAll(remaining),
                style: Theme.of(context).textTheme.labelMedium,
              ),
              value: _applyToAll,
              onChanged: (value) =>
                  setState(() => _applyToAll = value ?? false),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            const ConflictDialogStop(),
          ),
          child: Text(l10n.conflictStop),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.conflictNotNow),
        ),
      ],
    );
  }

  String _statSummary(DestinationStat stat) {
    final platform = Theme.of(context).platform;
    final localeName = Localizations.localeOf(context).toString();
    final size = formatPaneSize(stat.size, platform: platform);
    final modified = stat.modifiedAt == null
        ? paneUnevaluated
        : DateFormat.yMd(localeName)
            .add_jm()
            .format(stat.modifiedAt!.toLocal());
    return '$size · $modified';
  }

  String _entrySummary(RemoteFileEntry entry) {
    final platform = Theme.of(context).platform;
    final localeName = Localizations.localeOf(context).toString();
    final size = formatPaneSize(entry.size, platform: platform);
    final modified = entry.modifiedAt == null
        ? paneUnevaluated
        : DateFormat.yMd(localeName)
            .add_jm()
            .format(entry.modifiedAt!.toLocal());
    return '$size · $modified';
  }

  static String _verbLabel(
    ConflictResolution verb,
    AppLocalizations l10n,
  ) =>
      switch (verb) {
        ConflictResolution.replace => l10n.conflictVerbReplace,
        ConflictResolution.replaceIfNewer => l10n.conflictVerbReplaceIfNewer,
        ConflictResolution.keepBoth => l10n.conflictVerbKeepBoth,
        ConflictResolution.skip => l10n.conflictVerbSkip,
        ConflictResolution.merge => l10n.conflictVerbMerge,
        // `ask` is the prompt, never an answer — availableVerbs cannot
        // produce it.
        ConflictResolution.ask => l10n.conflictVerbSkip,
      };
}
