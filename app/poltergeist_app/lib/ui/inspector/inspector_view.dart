import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/activity_panel_controller.dart';
import '../../services/alert_center.dart';
import '../../services/pane_controller.dart';
import '../../services/preview_session.dart';
import '../../services/workspace_controller.dart';
import '../../theme/app_theme.dart';
import '../activity/activity_panel.dart';
import '../panes/info_panel.dart';
import '../preview_panel.dart';
import '../shell/corner_count_badge.dart';
import 'alerts_view.dart';

/// Inspector width bounds (10 §3.1).
const inspectorDefaultWidth = 280.0;
const inspectorMinWidth = 240.0;
const inspectorMaxWidth = 440.0;

/// The preview well's height as a share of the inspector's width,
/// clamped — a square-ish well at the default width (Transmit's
/// inspector proportions).
double _previewWellHeight(double width) => (width * 0.7).clamp(150.0, 280.0);

/// D32's right inspector (10 §3): one window-level column with three
/// tabs — Info (the focused item's preview and facts), Transfers (D16's
/// activity rows, unchanged in substance), and Alerts (everything that
/// needs the user). It never covers the listing; the shell mounts it
/// inline or, on narrow windows, as an overlay sheet at the right edge.
class InspectorView extends StatelessWidget {
  const InspectorView({
    super.key,
    required this.workspace,
    required this.activity,
    required this.alerts,
    required this.alertActions,
    this.preview,
    this.pdfRenderer,
    this.onOpen,
    this.onOpenWith,
    this.onOpenInEditor,
    this.onReveal,
    this.onEscape,
  });

  final WorkspaceController workspace;
  final ActivityPanelController activity;
  final AlertCenter alerts;
  final AlertActions alertActions;
  final PreviewSession? preview;
  final PreviewPdfBuilder? pdfRenderer;
  final void Function(PaneController pane, RemoteFileEntry entry)? onOpen;
  final void Function(
    BuildContext context,
    PaneController pane,
    RemoteFileEntry entry,
  )?
  onOpenWith;
  final void Function(PaneController pane, RemoteFileEntry entry)?
  onOpenInEditor;
  final void Function(TransferTask task)? onReveal;

  /// The focused pane's Esc-tier dispatch, so Esc pressed on an Info
  /// control still runs the pane's ordered chain (02 §8.2).
  final KeyEventResult Function(KeyEvent event)? onEscape;

  @override
  Widget build(BuildContext context) {
    final chrome = PoltergeistChrome.of(context);
    final l10n = AppLocalizations.of(context);
    return Semantics(
      container: true,
      label: l10n.inspectorLabel,
      child: Material(
        key: const ValueKey('inspector'),
        color: chrome.inspectorBackground,
        child: ListenableBuilder(
          listenable: Listenable.merge([workspace, alerts, activity]),
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TabSwitcher(
                selected: workspace.inspectorTab,
                onSelect: workspace.selectInspectorTab,
                alertCount: alerts.attentionCount,
                liveTransfers: activity.tasks
                    .where((task) => !task.isTerminal)
                    .length,
              ),
              Divider(height: 1, color: chrome.separator),
              Expanded(
                child: switch (workspace.inspectorTab) {
                  InspectorTab.info => _InfoTab(
                    workspace: workspace,
                    preview: preview,
                    pdfRenderer: pdfRenderer,
                    onOpen: onOpen,
                    onOpenWith: onOpenWith,
                    onOpenInEditor: onOpenInEditor,
                    onEscape: onEscape ?? (_) => KeyEventResult.ignored,
                  ),
                  InspectorTab.transfers => ActivityPanel(
                    key: const ValueKey('activity.panel'),
                    controller: activity,
                    embedded: true,
                    onClose: () => workspace.setInspectorHidden(true),
                    onReveal: onReveal,
                  ),
                  InspectorTab.alerts => AlertsView(
                    center: alerts,
                    actions: alertActions,
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ForkLift's inspector header: three icon tabs, centered, the Alerts
/// tab badged with the attention count and Transfers with live work.
class _TabSwitcher extends StatelessWidget {
  const _TabSwitcher({
    required this.selected,
    required this.onSelect,
    required this.alertCount,
    required this.liveTransfers,
  });

  final InspectorTab selected;
  final ValueChanged<InspectorTab> onSelect;
  final int alertCount;
  final int liveTransfers;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chrome = PoltergeistChrome.of(context);
    final colors = Theme.of(context).colorScheme;
    Widget tab(
      InspectorTab value,
      IconData icon,
      IconData selectedIcon,
      String label, {
      int badge = 0,
      String Function(int count)? announce,
      bool errorBadge = false,
    }) {
      final isSelected = value == selected;
      Widget glyph = Icon(
        isSelected ? selectedIcon : icon,
        size: 18,
        color: isSelected ? colors.primary : chrome.secondaryText,
      );
      if (badge > 0) {
        glyph = CornerCountBadge(
          label: badge > 99 ? l10n.badgeCountOverflow : l10n.badgeCount(badge),
          backgroundColor: errorBadge ? colors.error : colors.primary,
          textColor: errorBadge ? colors.onError : colors.onPrimary,
          child: glyph,
        );
      }
      return Tooltip(
        message: label,
        child: Semantics(
          selected: isSelected,
          button: true,
          label: label,
          // The painted count is excluded with the glyph; say it.
          value: badge > 0 ? announce?.call(badge) : null,
          excludeSemantics: true,
          // The excluded InkWell's tap, kept for screen readers.
          onTap: () => onSelect(value),
          child: InkWell(
            key: ValueKey('inspector.tab.${value.name}'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => onSelect(value),
            child: Container(
              width: 40,
              height: 28,
              alignment: Alignment.center,
              decoration: isSelected
                  ? BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    )
                  : null,
              child: glyph,
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          tab(
            InspectorTab.info,
            Icons.info_outline,
            Icons.info,
            l10n.inspectorTabInfo,
          ),
          const SizedBox(width: 6),
          tab(
            InspectorTab.transfers,
            Icons.swap_vert,
            Icons.swap_vert,
            l10n.inspectorTabTransfers,
            badge: liveTransfers,
            announce: l10n.transferCountSemantics,
          ),
          const SizedBox(width: 6),
          tab(
            InspectorTab.alerts,
            Icons.warning_amber_outlined,
            Icons.warning_amber,
            l10n.inspectorTabAlerts,
            badge: alertCount,
            announce: l10n.alertCountSemantics,
            errorBadge: true,
          ),
        ],
      ),
    );
  }
}

/// The Info tab (10 §3): the preview well on top, then the focused
/// item's facts and the D28 permissions editor — the old per-pane Get
/// Info overlay and preview rail, merged, following the active pane.
class _InfoTab extends StatelessWidget {
  const _InfoTab({
    required this.workspace,
    required this.preview,
    required this.pdfRenderer,
    required this.onOpen,
    required this.onOpenWith,
    required this.onOpenInEditor,
    required this.onEscape,
  });

  final WorkspaceController workspace;
  final PreviewSession? preview;
  final PreviewPdfBuilder? pdfRenderer;
  final void Function(PaneController pane, RemoteFileEntry entry)? onOpen;
  final void Function(
    BuildContext context,
    PaneController pane,
    RemoteFileEntry entry,
  )?
  onOpenWith;
  final void Function(PaneController pane, RemoteFileEntry entry)?
  onOpenInEditor;
  final KeyEventResult Function(KeyEvent event) onEscape;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final controller = workspace.activeTabController;
    if (controller == null) {
      return Center(
        child: Text(
          l10n.infoPanelEmpty,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 12, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preview != null && controller.infoTarget != null) ...[
                SizedBox(
                  height: _previewWellHeight(constraints.maxWidth),
                  child: PreviewPanel(
                    session: preview!,
                    embedded: true,
                    pdfRenderer: pdfRenderer,
                    onOpen: onOpen,
                    onOpenWith: onOpenWith,
                    onOpenInEditor: onOpenInEditor,
                    onClose: () {},
                    onEscape: onEscape,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              InfoPanel(
                controller: controller,
                clock: DateTime.now,
                onEscape: onEscape,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
