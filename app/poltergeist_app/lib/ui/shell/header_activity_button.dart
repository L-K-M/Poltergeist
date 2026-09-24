import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/activity_panel_controller.dart';

/// How long the activity button lingers after the last live task ends.
/// A queue that finishes one task and starts the next inside this window
/// keeps the button where it is instead of blinking it out and back, so
/// the header controls beside it never jitter.
const headerActivityHideDelay = Duration(seconds: 1);

/// The width animation when the button arrives or leaves — the header's
/// other controls slide over instead of jumping.
const _resizeDuration = Duration(milliseconds: 160);

/// The header's activity button (10 §4, D16): shown with the queue's
/// aggregate progress ring while any task is live, and hidden otherwise.
/// It appears as soon as work starts and leaves [headerActivityHideDelay]
/// after the last task ends, animating its width both ways.
///
/// [child] is the registry-rendered `view.toggleActivityPanel` button;
/// this widget only decides whether it is on screen and rings it.
class HeaderActivityButton extends StatefulWidget {
  const HeaderActivityButton({
    super.key,
    required this.controller,
    required this.child,
  });

  final ActivityPanelController controller;
  final Widget child;

  @override
  State<HeaderActivityButton> createState() => _HeaderActivityButtonState();
}

class _HeaderActivityButtonState extends State<HeaderActivityButton> {
  late bool _shown = _live;
  Timer? _hideTimer;

  bool get _live => widget.controller.tasks.any((task) => !task.isTerminal);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onActivity);
  }

  @override
  void didUpdateWidget(HeaderActivityButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_onActivity);
    widget.controller.addListener(_onActivity);
    _onActivity();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onActivity);
    super.dispose();
  }

  void _onActivity() {
    if (_live) {
      // New work cancels a pending hide: the button stays put.
      _hideTimer?.cancel();
      _hideTimer = null;
      setState(() => _shown = true);
      return;
    }
    if (!_shown || _hideTimer != null) {
      // Idle and already hidden, or already on the way out; the ring
      // still repaints to its settled state.
      setState(() {});
      return;
    }
    _hideTimer = Timer(headerActivityHideDelay, () {
      _hideTimer = null;
      if (!mounted || _live) return;
      setState(() => _shown = false);
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: _resizeDuration,
      curve: Curves.easeOut,
      alignment: AlignmentDirectional.centerEnd,
      child: _shown ? _ringed(context) : const SizedBox.shrink(),
    );
  }

  Widget _ringed(BuildContext context) {
    var done = 0;
    var total = 0;
    var live = false;
    for (final task in widget.controller.tasks) {
      if (task.isTerminal) continue;
      live = true;
      done += task.transferredBytes;
      total += task.totalBytes ?? 0;
    }
    final colors = Theme.of(context).colorScheme;
    // Lingering after the last task ends reads as done, not unknown.
    final double? value = !live
        ? 1
        : (total > 0 ? (done / total).clamp(0.0, 1.0) : null);
    return Stack(
      alignment: Alignment.center,
      children: [
        widget.child,
        IgnorePointer(
          child: SizedBox(
            key: const ValueKey('header.activityRing'),
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: value,
              color: colors.primary,
              backgroundColor: colors.primary.withValues(alpha: 0.15),
            ),
          ),
        ),
      ],
    );
  }
}
