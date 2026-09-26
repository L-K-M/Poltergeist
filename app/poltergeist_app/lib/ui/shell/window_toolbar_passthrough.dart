import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';

import '../../services/workspace_windows/window_host.dart';
import '../../services/workspace_windows/window_titlebar.dart';

/// Hands clicks on [child] through the macOS unified toolbar band to
/// Flutter, in whichever workspace window it sits (00 D39): through
/// macos_window_utils in the main window, and through the workspace
/// windows' host in an extra one (`WindowTitlebars`).
class WindowToolbarPassthrough extends StatelessWidget {
  const WindowToolbarPassthrough({
    super.key,
    required this.child,
    this.titlebars,
  });

  final Widget child;

  /// An extra window's host; null is the app's one. A test seam.
  final WindowTitlebars? titlebars;

  @override
  Widget build(BuildContext context) {
    final viewId = View.maybeOf(context)?.viewId ?? mainWindowViewId;
    if (viewId == mainWindowViewId) {
      return MacosToolbarPassthrough(child: child);
    }
    return _ViewPassthrough(
      viewId: viewId,
      titlebars: titlebars ?? WindowTitlebars.instance,
      child: child,
    );
  }
}

/// The scope macos_window_utils wants around a group of passthroughs in
/// the main window, so they re-measure together when one moves. An extra
/// window's passthroughs measure themselves every frame and need none.
class WindowToolbarPassthroughScope extends StatelessWidget {
  const WindowToolbarPassthroughScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final viewId = View.maybeOf(context)?.viewId ?? mainWindowViewId;
    return viewId == mainWindowViewId
        ? MacosToolbarPassthroughScope(child: child)
        : child;
  }
}

class _ViewPassthrough extends StatefulWidget {
  const _ViewPassthrough({
    required this.viewId,
    required this.titlebars,
    required this.child,
  });

  final int viewId;
  final WindowTitlebars titlebars;
  final Widget child;

  @override
  State<_ViewPassthrough> createState() => _ViewPassthroughState();
}

class _ViewPassthroughState extends State<_ViewPassthrough> {
  static var _serial = 0;

  /// This rectangle's name within its window.
  final String _id = 'passthrough-${_serial++}';

  /// What the host was last told, in the view's logical pixels.
  Rect? _sent;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(_ViewPassthrough oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewId == widget.viewId &&
        identical(oldWidget.titlebars, widget.titlebars)) {
      return;
    }
    if (_sent != null) {
      oldWidget.titlebars.removePassthrough(oldWidget.viewId, _id);
      _sent = null;
    }
  }

  @override
  void dispose() {
    if (_sent != null) widget.titlebars.removePassthrough(widget.viewId, _id);
    super.dispose();
  }

  /// Measures after every frame while mounted: a control moves when its
  /// siblings resize, the window resizes, or the header folds, and none of
  /// that rebuilds it. Measuring costs one transform; the host hears only
  /// of a change. A post-frame callback never asks for a frame itself.
  void _scheduleMeasure() =>
      SchedulerBinding.instance.addPostFrameCallback(_measure);

  void _measure(Duration _) {
    if (!mounted) return;
    _scheduleMeasure();
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect == _sent) return;
    _sent = rect;
    widget.titlebars.updatePassthrough(widget.viewId, _id, rect);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
