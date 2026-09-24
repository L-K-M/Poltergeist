import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/activity_panel_controller.dart';
import 'compact_posture.dart';

/// The queue's live summary for the pill: how many tasks run and their
/// aggregate progress (null while no live task knows its total).
({int live, double? progress}) compactTransferSummary(
  ActivityPanelController activity,
) {
  var live = 0;
  var done = 0;
  var total = 0;
  for (final task in activity.tasks) {
    if (task.isTerminal) continue;
    live++;
    done += task.transferredBytes;
    total += task.totalBytes ?? 0;
  }
  return (
    live: live,
    progress: total > 0 ? (done / total).clamp(0.0, 1.0) : null,
  );
}

/// D32 §9's floating progress pill — the compact posture's always-visible
/// honesty signal (D16) that replaces the header's activity ring: it shows
/// only while transfers run, carries their count and overall progress,
/// and opens the inspector sheet on Transfers. It slides in and out
/// rather than popping, so its arrival reads as "work started".
class CompactProgressPill extends StatelessWidget {
  const CompactProgressPill({
    super.key,
    required this.activity,
    required this.onPressed,
    this.hidden = false,
  });

  final ActivityPanelController activity;
  final VoidCallback onPressed;

  /// Suppressed while the inspector sheet already shows the transfers.
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: activity,
      builder: (context, _) {
        final summary = compactTransferSummary(activity);
        final visible = summary.live > 0 && !hidden;
        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 1.6),
            duration: const Duration(milliseconds: 260),
            curve: visible ? Curves.easeOutBack : Curves.easeInCubic,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: summary.live == 0
                  ? const SizedBox.shrink()
                  : _Pill(summary: summary, onPressed: onPressed),
            ),
          ),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.summary, required this.onPressed});

  final ({int live, double? progress}) summary;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final count = l10n.compactTransfersPill(summary.live);
    final progress = summary.progress;
    final text = progress == null
        ? count
        : l10n.compactTransfersPillProgress(count, (progress * 100).floor());
    return Semantics(
      button: true,
      label: text,
      hint: l10n.compactTransfersPillTooltip,
      excludeSemantics: true,
      child: Material(
        key: const ValueKey(CompactKey.progressPill),
        color: colors.inverseSurface,
        elevation: 3,
        shadowColor: Colors.black54,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 18, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 2.5,
                      color: colors.inversePrimary,
                      backgroundColor: colors.onInverseSurface.withValues(
                        alpha: 0.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Shrinks rather than overflows: the Home slot leaves
                  // room for the FAB, and translations run long.
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colors.onInverseSurface,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.keyboard_arrow_up,
                    size: 20,
                    color: colors.onInverseSurface,
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
