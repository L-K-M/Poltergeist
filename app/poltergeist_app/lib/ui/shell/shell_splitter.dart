import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import 'window_toolbar_passthrough.dart';

/// Pixels one arrow-key press moves a splitter (02 §1's keyboard resize).
const shellSplitterKeyStep = 16.0;

/// The layout width a [ShellSplitter] occupies: a 1 px visible line with
/// a few pixels of pane-coloured grab area either side, so the region
/// boundary reads as a hairline (ForkLift/Finder) while the pointer
/// target stays usable.
const shellSplitterExtent = 7.0;

/// D32's one splitter for every region boundary (sidebar | panes,
/// panes | inspector): drag to resize, arrow keys in 16 px steps while
/// focused, double-click to reset, and a screen-reader value that names
/// the current width. The owner keeps the width and persists it once in
/// [onResizeEnd] — never per drag pixel (02 §1's save-at-boundary rule).
/// Every interaction (a drag, one arrow-key step) opens with
/// [onResizeStart], so an owner can track the unclamped width a drag has
/// reached across its per-event deltas.
///
/// [grow] is the sign that maps a rightward drag onto the owned region:
/// +1 for a region left of the splitter (the sidebar), -1 for a region to
/// its right (the inspector).
class ShellSplitter extends StatefulWidget {
  const ShellSplitter({
    super.key,
    required this.label,
    required this.value,
    required this.onResize,
    required this.onResizeEnd,
    this.increasedValue,
    this.decreasedValue,
    this.onResizeStart,
    this.onReset,
    this.grow = 1,
    this.focusNode,
    this.nativeTitlebar = false,
  });

  /// macOS: a full-height splitter crosses the unified toolbar band,
  /// which claims clicks for window drag/zoom. True wraps it in a
  /// [WindowToolbarPassthrough] so a drag or double-click on its top
  /// segment still resizes or resets instead of moving the window.
  final bool nativeTitlebar;

  /// Announced name ("Resize sidebar").
  final String label;

  /// Announced value ("232 pixels").
  final String value;

  /// The values one assistive-tech increase (wider) or decrease
  /// (narrower) lands on, clamped by the owner — 02 §13's announced
  /// splitter values, like the A|B splitter's.
  final String? increasedValue;
  final String? decreasedValue;

  /// Width delta in logical pixels, already signed for the owned region.
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;
  final VoidCallback? onResizeStart;

  /// Double-click: back to the default width.
  final VoidCallback? onReset;
  final int grow;
  final FocusNode? focusNode;

  @override
  State<ShellSplitter> createState() => _ShellSplitterState();
}

class _ShellSplitterState extends State<ShellSplitter> {
  bool _hovered = false;
  bool _dragging = false;
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final rtl = Directionality.of(context) == TextDirection.rtl;
    double? delta;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      delta = shellSplitterKeyStep;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      delta = -shellSplitterKeyStep;
    }
    if (delta == null) return KeyEventResult.ignored;
    _step(delta * widget.grow * (rtl ? -1 : 1));
    return KeyEventResult.handled;
  }

  /// One discrete resize — an arrow key or an assistive-tech adjust —
  /// persisted at once. [delta] is signed for the owned region.
  void _step(double delta) {
    widget.onResizeStart?.call();
    widget.onResize(delta);
    widget.onResizeEnd();
  }

  @override
  Widget build(BuildContext context) {
    final chrome = PoltergeistChrome.of(context);
    final colors = Theme.of(context).colorScheme;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final active = _hovered || _dragging || _focused;
    final splitter = Semantics(
      label: widget.label,
      value: widget.value,
      increasedValue: widget.increasedValue,
      decreasedValue: widget.decreasedValue,
      // The value is the owned region's width, so increase always
      // widens it, whichever side of the splitter it sits on.
      onIncrease: () => _step(shellSplitterKeyStep),
      onDecrease: () => _step(-shellSplitterKeyStep),
      slider: true,
      child: Focus(
        focusNode: widget.focusNode,
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (_) {
              setState(() => _dragging = true);
              widget.onResizeStart?.call();
            },
            onHorizontalDragUpdate: (details) => widget.onResize(
              details.delta.dx * widget.grow * (rtl ? -1 : 1),
            ),
            onHorizontalDragEnd: (_) {
              setState(() => _dragging = false);
              widget.onResizeEnd();
            },
            onHorizontalDragCancel: () => setState(() => _dragging = false),
            onDoubleTap: widget.onReset,
            child: SizedBox(
              width: shellSplitterExtent,
              height: double.infinity,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: active ? 2 : 1,
                  color: _focused
                      ? colors.primary
                      : active
                      ? colors.outline
                      : chrome.separator,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return widget.nativeTitlebar
        ? WindowToolbarPassthrough(child: splitter)
        : splitter;
  }
}
