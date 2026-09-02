import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'layout/pane_allocation.dart';

const _defaultPaneRatio = 0.5;
const _keyboardResizeStep = 16.0;

typedef PaneRatioSaver = FutureOr<void> Function(double ratio);
typedef PaneRatioFormatter = String Function(double ratio);

/// Owns pane allocation and splitter input independently of pane contents.
class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({
    super.key,
    required this.primary,
    required this.secondary,
    required this.resizeLabel,
    required this.formatRatio,
    this.initialPaneRatio = _defaultPaneRatio,
    this.onPaneRatioChanged,
    this.onPaneRatioSaveError,
  });

  static const primaryPaneKey = ValueKey('primary-pane');
  static const secondaryPaneKey = ValueKey('secondary-pane');
  static const splitterKey = ValueKey('pane-splitter');

  final Widget primary;
  final Widget secondary;
  final String resizeLabel;
  final PaneRatioFormatter formatRatio;
  final double initialPaneRatio;
  final PaneRatioSaver? onPaneRatioChanged;
  final void Function(Object, StackTrace)? onPaneRatioSaveError;

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends State<AdaptiveShell> {
  final _splitterFocusNode = FocusNode();
  late double _paneRatio;
  late double _lastSavedPaneRatio;
  double _contentWidth = 0;
  Future<void> _saveTail = Future.value();
  var _saveRevision = 0;
  var _hasPendingSave = false;

  @override
  void initState() {
    super.initState();
    _paneRatio = widget.initialPaneRatio.clamp(0, 1).toDouble();
    _lastSavedPaneRatio = _paneRatio;
  }

  @override
  void dispose() {
    _commitPaneRatio();
    _splitterFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _contentWidth = constraints.maxWidth;
        final allocation = allocatePanes(
          width: _contentWidth,
          ratio: _paneRatio,
          secondPaneIntent: SecondPaneIntent.shown,
        );

        return _buildPanes(context, allocation);
      },
    );
  }

  Widget _buildPanes(BuildContext context, PaneAllocation allocation) {
    final displayedRatio = _displayedRatio(allocation, _paneRatio);
    final increasedRatio = _displayedRatio(
      allocation,
      _ratioAfterLogicalDelta(allocation, _keyboardResizeStep),
    );
    final decreasedRatio = _displayedRatio(
      allocation,
      _ratioAfterLogicalDelta(allocation, -_keyboardResizeStep),
    );
    final primary = SizedBox(
      key: AdaptiveShell.primaryPaneKey,
      width: allocation.primaryWidth,
      child: widget.primary,
    );
    if (!allocation.showsSecondPane) return primary;

    return Row(
      children: [
        primary,
        SizedBox(
          width: allocation.splitterWidth,
          child: _PaneSplitter(
            key: AdaptiveShell.splitterKey,
            focusNode: _splitterFocusNode,
            label: widget.resizeLabel,
            value: widget.formatRatio(displayedRatio),
            increasedValue: widget.formatRatio(increasedRatio),
            decreasedValue: widget.formatRatio(decreasedRatio),
            onResize: (delta) => _resize(context, delta),
            onResizeEnd: _commitPaneRatio,
          ),
        ),
        SizedBox(
          key: AdaptiveShell.secondaryPaneKey,
          width: allocation.secondaryWidth,
          child: widget.secondary,
        ),
      ],
    );
  }

  void _resize(BuildContext context, double physicalDelta) {
    final allocation = allocatePanes(
      width: _contentWidth,
      ratio: _paneRatio,
      secondPaneIntent: SecondPaneIntent.shown,
    );
    final usableWidth = allocation.primaryWidth + allocation.secondaryWidth;
    if (usableWidth <= 0) return;

    final direction = Directionality.of(context);
    final logicalDelta = direction == TextDirection.ltr
        ? physicalDelta
        : -physicalDelta;
    final ratio = _ratioAfterLogicalDelta(allocation, logicalDelta);

    if (ratio == _paneRatio) return;

    setState(() => _paneRatio = ratio);
    _saveRevision++;
    _hasPendingSave = true;
  }

  double _ratioAfterLogicalDelta(
    PaneAllocation allocation,
    double logicalDelta,
  ) {
    final usableWidth = allocation.primaryWidth + allocation.secondaryWidth;
    if (usableWidth <= 0) return _paneRatio;

    final displayedRatio = allocation.primaryWidth / usableWidth;
    final movesInFromRight = logicalDelta < 0 && _paneRatio > displayedRatio;
    final movesInFromLeft = logicalDelta > 0 && _paneRatio < displayedRatio;
    final startingRatio = movesInFromRight || movesInFromLeft
        ? displayedRatio
        : _paneRatio;
    final requestedRatio = startingRatio + logicalDelta / usableWidth;
    final minimumRatio =
        allocatePanes(
          width: _contentWidth,
          ratio: 0,
          secondPaneIntent: SecondPaneIntent.shown,
        ).primaryWidth /
        usableWidth;
    final maximumRatio =
        allocatePanes(
          width: _contentWidth,
          ratio: 1,
          secondPaneIntent: SecondPaneIntent.shown,
        ).primaryWidth /
        usableWidth;

    // Persist edge intent as 0/1, but adopt the visible edge when moving in.
    var ratio = requestedRatio.clamp(0, 1).toDouble();
    if (requestedRatio <= minimumRatio) ratio = 0;
    if (requestedRatio >= maximumRatio) ratio = 1;
    return ratio;
  }

  double _displayedRatio(PaneAllocation allocation, double logicalRatio) {
    final usableWidth = allocation.primaryWidth + allocation.secondaryWidth;
    if (usableWidth <= 0) return 0;

    final displayed = allocatePanes(
      width: _contentWidth,
      ratio: logicalRatio,
      secondPaneIntent: SecondPaneIntent.shown,
    );
    return displayed.primaryWidth / usableWidth;
  }

  void _commitPaneRatio() {
    if (!_hasPendingSave) return;

    // Persist once at the interaction boundary, not per drag or key repeat.
    _hasPendingSave = false;
    _savePaneRatio(_paneRatio, _saveRevision);
  }

  void _savePaneRatio(double ratio, int revision) {
    final save = widget.onPaneRatioChanged;
    if (save == null) {
      _lastSavedPaneRatio = ratio;
      return;
    }

    final report = widget.onPaneRatioSaveError;
    _saveTail = _saveTail.then((_) async {
      try {
        await save(ratio);
        _lastSavedPaneRatio = ratio;
      } catch (error, stack) {
        try {
          report?.call(error, stack);
        } catch (_) {
          // Reporting cannot be allowed to create another async failure.
        }
        if (!mounted || revision != _saveRevision) return;

        setState(() => _paneRatio = _lastSavedPaneRatio);
      }
    });
  }
}

class _PaneSplitter extends StatelessWidget {
  const _PaneSplitter({
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
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onFocusChange: (hasFocus) {
        if (hasFocus) return;

        onResizeEnd();
      },
      onKeyEvent: (_, event) {
        final delta = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowLeft => -_keyboardResizeStep,
          LogicalKeyboardKey.arrowRight => _keyboardResizeStep,
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
        builder: (context, child) {
          final border = focusNode.hasFocus
              ? Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                )
              : null;

          return DecoratedBox(
            decoration: BoxDecoration(border: border),
            child: child,
          );
        },
        child: Semantics(
          label: label,
          value: value,
          increasedValue: increasedValue,
          decreasedValue: decreasedValue,
          onIncrease: () {
            final direction = Directionality.of(context);
            onResize(
              direction == TextDirection.ltr
                  ? _keyboardResizeStep
                  : -_keyboardResizeStep,
            );
            onResizeEnd();
          },
          onDecrease: () {
            final direction = Directionality.of(context);
            onResize(
              direction == TextDirection.ltr
                  ? -_keyboardResizeStep
                  : _keyboardResizeStep,
            );
            onResizeEnd();
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onTap: focusNode.requestFocus,
              onHorizontalDragUpdate: (details) => onResize(details.delta.dx),
              onHorizontalDragEnd: (_) => onResizeEnd(),
              onHorizontalDragCancel: onResizeEnd,
              child: Center(
                child: VerticalDivider(
                  width: 1,
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
