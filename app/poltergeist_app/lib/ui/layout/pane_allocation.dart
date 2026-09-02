enum LayoutStage { desktop, compact, mobile }

enum SecondPaneIntent { shown, hidden }

const _desktopBoundary = 1080.0;
const _mobileBoundary = 680.0;
const _splitterExtent = 16.0;
const _minimumPaneWidth = 240.0;

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
