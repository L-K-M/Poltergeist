import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/workspace_controller.dart';
import '../../theme/app_theme.dart';
import '../activity/activity_panel.dart';
import '../inspector/alerts_view.dart';
import '../inspector/inspector_view.dart';
import '../panes/info_panel.dart';
import '../preview_panel.dart';
import 'compact_posture.dart';

/// The sheet's resting heights, as a share of the room above the
/// status bar: half for a glance, nearly full for real work.
const double _halfExtent = 0.55;
const double _fullExtent = 1.0;

/// A drag released faster than this (logical px/s) steps one detent in
/// its direction instead of settling on the nearest.
const double _flingVelocity = 700;

/// Below this share a released drag closes the sheet.
const double _closeThreshold = 0.25;

/// D32 §9's inspector as a draggable bottom sheet: the same three tabs —
/// Info, Transfers, Alerts — over the same controllers the desktop
/// column renders ([inspector] is the shell's own configuration of that
/// column, so both postures show one truth).
///
/// Its visibility and tab ARE the workspace's inspector state: a command
/// that shows the inspector (Get Info, Show Alerts, the pill) opens the
/// sheet, and closing the sheet hides the inspector — one mechanism, no
/// compact-only flag to drift. It is non-modal on purpose: the listing
/// above stays live, and system back closes it in D32 §9's order (after
/// a selection, before folder history).
///
/// The handle and tab strip drag the sheet between half and full height
/// (a fling steps a detent; dragging low closes it); the tab bodies keep
/// their own scrolling.
class CompactInspectorSheet extends StatefulWidget {
  const CompactInspectorSheet({super.key, required this.inspector});

  final InspectorView inspector;

  @override
  State<CompactInspectorSheet> createState() => _CompactInspectorSheetState();
}

class _CompactInspectorSheetState extends State<CompactInspectorSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _extent = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  double _maxHeight = 1;

  /// The last visibility the sheet followed. It starts closed whatever
  /// the workspace says: the compact posture closes the inspector as it
  /// mounts (the desktop's shown default must not open a sheet over
  /// Home), and following only edges keeps that first frame clean.
  bool _shown = false;

  WorkspaceController get _workspace => widget.inspector.workspace;

  @override
  void initState() {
    super.initState();
    _workspace.addListener(_followWorkspace);
  }

  @override
  void didUpdateWidget(CompactInspectorSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.inspector.workspace;
    if (!identical(old, _workspace)) {
      old.removeListener(_followWorkspace);
      _workspace.addListener(_followWorkspace);
      _followWorkspace();
    }
  }

  @override
  void dispose() {
    _workspace.removeListener(_followWorkspace);
    _extent.dispose();
    super.dispose();
  }

  /// Opens to half height when the inspector is asked for, closes when
  /// it is hidden — whoever asked (a command, the pill, back). Only the
  /// visibility EDGE moves the sheet: a tab switch or an unrelated
  /// workspace notify leaves a dragged height alone.
  void _followWorkspace() {
    if (!mounted) return;
    final shown = !_workspace.inspectorHidden;
    if (shown != _shown) {
      _shown = shown;
      _settle(shown ? _halfExtent : 0);
    }
    setState(() {});
  }

  void _settle(double target) {
    _extent.animateTo(
      target,
      curve: target == 0 ? Curves.easeInCubic : Curves.easeOutCubic,
    );
  }

  void _close() {
    _settle(0);
    _workspace.setInspectorHidden(true);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    _extent.value = (_extent.value - delta / _maxHeight).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final value = _extent.value;
    double target;
    if (velocity > _flingVelocity) {
      target = value > _halfExtent ? _halfExtent : 0;
    } else if (velocity < -_flingVelocity) {
      target = _fullExtent;
    } else if (value < _closeThreshold) {
      target = 0;
    } else {
      target = (value - _halfExtent).abs() < (value - _fullExtent).abs()
          ? _halfExtent
          : _fullExtent;
    }
    if (target == 0) {
      _close();
    } else {
      _settle(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Nearly the whole screen at full height, but never under the
        // status bar: the sheet's top edge stays grabbable.
        _maxHeight = (constraints.maxHeight - padding.top - 8).clamp(
          1.0,
          double.infinity,
        );
        return AnimatedBuilder(
          animation: _extent,
          builder: (context, child) {
            final height = _maxHeight * _extent.value;
            if (height <= 0) return const SizedBox.shrink();
            return Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(height: height, child: child),
            );
          },
          child: _SheetSurface(
            inspector: widget.inspector,
            onDragUpdate: _onDragUpdate,
            onDragEnd: _onDragEnd,
            onClose: _close,
          ),
        );
      },
    );
  }
}

class _SheetSurface extends StatelessWidget {
  const _SheetSurface({
    required this.inspector,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onClose,
  });

  final InspectorView inspector;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chrome = PoltergeistChrome.of(context);
    final colors = Theme.of(context).colorScheme;
    final workspace = inspector.workspace;
    return Semantics(
      container: true,
      label: l10n.inspectorLabel,
      child: Material(
        key: const ValueKey(CompactKey.inspectorSheet),
        color: chrome.inspectorBackground,
        elevation: 6,
        shadowColor: Colors.black,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListenableBuilder(
          listenable: Listenable.merge([
            workspace,
            inspector.alerts,
            inspector.activity,
          ]),
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: onDragUpdate,
                onVerticalDragEnd: onDragEnd,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      button: true,
                      label: l10n.compactSheetClose,
                      onTap: onClose,
                      excludeSemantics: true,
                      child: SizedBox(
                        key: const ValueKey(CompactKey.inspectorHandle),
                        height: 24,
                        child: Center(
                          child: Container(
                            width: 32,
                            height: 4,
                            decoration: BoxDecoration(
                              color: colors.onSurfaceVariant.withValues(
                                alpha: 0.4,
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                    _SheetTabs(
                      selected: workspace.inspectorTab,
                      onSelect: workspace.selectInspectorTab,
                      liveTransfers: inspector.activity.tasks
                          .where((task) => !task.isTerminal)
                          .length,
                      alertCount: inspector.alerts.attentionCount,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: chrome.separator),
              Expanded(
                child: Padding(
                  // The compact posture draws edge to edge: the sheet
                  // keeps its content clear of the gesture bar itself.
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.paddingOf(context).bottom,
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: KeyedSubtree(
                      key: ValueKey(workspace.inspectorTab),
                      child: _body(workspace.inspectorTab, onClose),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(InspectorTab tab, VoidCallback onClose) => switch (tab) {
    InspectorTab.info => _CompactInfoTab(inspector: inspector),
    InspectorTab.transfers => ActivityPanel(
      key: const ValueKey('activity.panel'),
      controller: inspector.activity,
      embedded: true,
      onClose: onClose,
      onReveal: inspector.onReveal,
    ),
    InspectorTab.alerts => AlertsView(
      center: inspector.alerts,
      actions: inspector.alertActions,
    ),
  };
}

/// The sheet's tab strip: three 48 dp tabs with an animated underline,
/// Transfers badged with live work and Alerts with the attention count —
/// the desktop switcher's facts at touch size.
class _SheetTabs extends StatelessWidget {
  const _SheetTabs({
    required this.selected,
    required this.onSelect,
    required this.liveTransfers,
    required this.alertCount,
  });

  final InspectorTab selected;
  final ValueChanged<InspectorTab> onSelect;
  final int liveTransfers;
  final int alertCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final chrome = PoltergeistChrome.of(context);

    Widget tab(
      InspectorTab value,
      IconData icon,
      String label,
      int badge, {
      bool errorBadge = false,
    }) {
      final isSelected = value == selected;
      final color = isSelected ? colors.primary : chrome.secondaryText;
      Widget glyph = Icon(icon, size: 20, color: color);
      if (badge > 0) {
        glyph = Badge(
          label: Text(
            badge > 99 ? l10n.badgeCountOverflow : l10n.badgeCount(badge),
          ),
          backgroundColor: errorBadge ? colors.error : colors.primary,
          textColor: errorBadge ? colors.onError : colors.onPrimary,
          child: glyph,
        );
      }
      return Expanded(
        child: Semantics(
          selected: isSelected,
          button: true,
          label: label,
          // The InkWell below is excluded, so the node carries the tap:
          // without one it is not clickable to TalkBack or Switch Access.
          onTap: () => onSelect(value),
          excludeSemantics: true,
          child: InkWell(
            key: ValueKey((CompactKey.inspectorTab, value)),
            onTap: () => onSelect(value),
            child: SizedBox(
              height: 48,
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          glyph,
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: color,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    start: 24,
                    end: 24,
                    bottom: 0,
                    child: AnimatedOpacity(
                      opacity: isSelected ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Container(
                        height: 3,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(3),
                          ),
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
    }

    return Row(
      children: [
        tab(
          InspectorTab.info,
          selected == InspectorTab.info ? Icons.info : Icons.info_outline,
          l10n.inspectorTabInfo,
          0,
        ),
        tab(
          InspectorTab.transfers,
          Icons.swap_vert,
          l10n.inspectorTabTransfers,
          liveTransfers,
        ),
        tab(
          InspectorTab.alerts,
          selected == InspectorTab.alerts
              ? Icons.warning_amber
              : Icons.warning_amber_outlined,
          l10n.inspectorTabAlerts,
          alertCount,
          errorBadge: true,
        ),
      ],
    );
  }
}

/// The Info tab at touch width: the focused item's preview well over its
/// facts and permissions — the desktop Info tab's content, following the
/// active pane.
class _CompactInfoTab extends StatelessWidget {
  const _CompactInfoTab({required this.inspector});

  final InspectorView inspector;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final controller = inspector.workspace.activeTabController;
    if (controller == null) {
      return Center(
        child: Text(
          l10n.infoPanelEmpty,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
        ),
      );
    }
    final preview = inspector.preview;
    final onEscape =
        inspector.onEscape ?? (KeyEvent _) => KeyEventResult.ignored;
    return LayoutBuilder(
      builder: (context, constraints) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preview != null && controller.infoTarget != null) ...[
                SizedBox(
                  height: (constraints.maxWidth * 0.6).clamp(160.0, 320.0),
                  child: PreviewPanel(
                    session: preview,
                    embedded: true,
                    pdfRenderer: inspector.pdfRenderer,
                    onOpen: inspector.onOpen,
                    onOpenWith: inspector.onOpenWith,
                    onOpenInEditor: inspector.onOpenInEditor,
                    onClose: () {},
                    onEscape: onEscape,
                  ),
                ),
                const SizedBox(height: 16),
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
