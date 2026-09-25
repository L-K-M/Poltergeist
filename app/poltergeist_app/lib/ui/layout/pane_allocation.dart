enum LayoutStage { desktop, compact, mobile }

enum SecondPaneIntent { shown, hidden }

const _desktopBoundary = 1080.0;

/// 02 §1's stage-0 threshold, exposed for layout decisions outside the
/// pane split: below it the sidebar mounts in the overlay drawer (stage
/// 1) and `view.toggleSidebar` opens that drawer instead of flipping
/// the inline region's hidden intent. The pane stage math itself stays
/// private to [allocatePanes].
const double desktopStageBoundary = _desktopBoundary;

/// The A|B splitter's layout extent: a 1 px hairline centered in a grab
/// area, matching the region splitters (D32 §3.1).
const _splitterExtent = 7.0;

/// D32 §3.1's pane floor.
const _minimumPaneWidth = 260.0;

/// Below this pane-region width pane B auto-hides: two panes at their
/// floor no longer fit. The shell folds the inspector and then the
/// sidebar away at the same floor (D32 §3.2), so the panes are the last
/// region to give way; a desktop window (content ≥ 720) never gets
/// here, and a touch window under 600 dp takes the compact posture.
const _mobileBoundary = 2 * _minimumPaneWidth + _splitterExtent;

/// Public mirrors for the shell's region allocation (D32 §3.2): the
/// panes' floor is what the inspector and sidebar yield to.
const double minPaneWidth = _minimumPaneWidth;
const double paneSplitterExtent = _splitterExtent;

class PaneAllocation {
  const PaneAllocation({
    required this.stage,
    required this.primaryWidth,
    required this.splitterWidth,
    required this.secondaryWidth,
  });

  final LayoutStage stage;
  final double primaryWidth;
  final double splitterWidth;
  final double secondaryWidth;

  bool get showsSecondPane => secondaryWidth > 0;

  double get totalWidth => primaryWidth + splitterWidth + secondaryWidth;
}

PaneAllocation allocatePanes({
  required double width,
  required double ratio,
  required SecondPaneIntent secondPaneIntent,
}) {
  if (!width.isFinite || width < 0) {
    throw ArgumentError.value(
      width,
      'width',
      'must be finite and non-negative',
    );
  }
  if (!ratio.isFinite) {
    throw ArgumentError.value(ratio, 'ratio', 'must be finite');
  }

  final stage = switch (width) {
    >= _desktopBoundary => LayoutStage.desktop,
    >= _mobileBoundary => LayoutStage.compact,
    _ => LayoutStage.mobile,
  };
  final responsiveHide = stage == LayoutStage.mobile;
  final userHide = secondPaneIntent == SecondPaneIntent.hidden;
  if (responsiveHide || userHide) {
    return PaneAllocation(
      stage: stage,
      primaryWidth: width,
      splitterWidth: 0,
      secondaryWidth: 0,
    );
  }

  final available = (width - _splitterExtent).clamp(0, width).toDouble();
  final minimum = _minimumPaneWidth.clamp(0, available / 2).toDouble();
  final primary = (available * ratio)
      .clamp(minimum, available - minimum)
      .toDouble();

  return PaneAllocation(
    stage: stage,
    primaryWidth: primary,
    splitterWidth: width - available,
    secondaryWidth: available - primary,
  );
}
