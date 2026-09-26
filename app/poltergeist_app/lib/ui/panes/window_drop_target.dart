import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/widgets.dart';

import '../../services/window_drop_in.dart';
import '../../services/workspace_windows/window_host.dart';

/// Files dropped from other apps, in whichever workspace window this sits
/// (00 D39): desktop_drop's `DropTarget` in the main window, and the
/// workspace windows' own drop reports (`WindowDropIn`) in an extra one.
/// The callbacks are desktop_drop's, so a drop zone is written once.
class WindowDropTarget extends StatelessWidget {
  const WindowDropTarget({
    super.key,
    required this.child,
    this.enable = true,
    this.onDragEntered,
    this.onDragUpdated,
    this.onDragExited,
    this.onDragDone,
    this.dropIn,
  });

  final Widget child;

  /// Whether this target takes drops right now.
  final bool enable;

  final void Function(DropEventDetails details)? onDragEntered;
  final void Function(DropEventDetails details)? onDragUpdated;
  final void Function(DropEventDetails details)? onDragExited;
  final void Function(DropDoneDetails details)? onDragDone;

  /// Where an extra window's reports come from; null is the app's one
  /// decoder. A test seam.
  final WindowDropIn? dropIn;

  @override
  Widget build(BuildContext context) {
    final viewId = View.maybeOf(context)?.viewId ?? mainWindowViewId;
    if (viewId == mainWindowViewId) {
      return DropTarget(
        enable: enable,
        onDragEntered: onDragEntered,
        onDragUpdated: onDragUpdated,
        onDragExited: onDragExited,
        onDragDone: onDragDone,
        child: child,
      );
    }
    return _ViewDropTarget(
      viewId: viewId,
      dropIn: dropIn ?? WindowDropIn.instance,
      target: this,
    );
  }
}

class _ViewDropTarget extends StatefulWidget {
  const _ViewDropTarget({
    required this.viewId,
    required this.dropIn,
    required this.target,
  });

  final int viewId;
  final WindowDropIn dropIn;
  final WindowDropTarget target;

  @override
  State<_ViewDropTarget> createState() => _ViewDropTargetState();
}

class _ViewDropTargetState extends State<_ViewDropTarget> {
  /// Whether the drag is over this target: it has reported an enter and
  /// no exit since.
  bool _hovering = false;
  Offset _lastGlobal = Offset.zero;

  bool get _listening => widget.target.enable;

  @override
  void initState() {
    super.initState();
    if (_listening) widget.dropIn.addListener(widget.viewId, _onEvent);
  }

  @override
  void didUpdateWidget(_ViewDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasListening = oldWidget.target.enable;
    final moved =
        oldWidget.viewId != widget.viewId ||
        !identical(oldWidget.dropIn, widget.dropIn);
    if (wasListening && (moved || !_listening)) {
      oldWidget.dropIn.removeListener(oldWidget.viewId, _onEvent);
      _leave();
    }
    if (_listening && (moved || !wasListening)) {
      widget.dropIn.addListener(widget.viewId, _onEvent);
    }
  }

  @override
  void dispose() {
    if (_listening) widget.dropIn.removeListener(widget.viewId, _onEvent);
    super.dispose();
  }

  void _onEvent(WindowDropEvent event) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    switch (event) {
      case WindowDropHover(:final position):
        final local = box.globalToLocal(position);
        _lastGlobal = position;
        if (!box.paintBounds.contains(local)) {
          _leave();
          return;
        }
        final details = DropEventDetails(
          localPosition: local,
          globalPosition: position,
        );
        if (_hovering) {
          widget.target.onDragUpdated?.call(details);
        } else {
          _hovering = true;
          widget.target.onDragEntered?.call(details);
        }
      case WindowDropExit():
        _leave();
      case WindowDropDone(:final position, :final paths):
        final local = box.globalToLocal(position);
        _lastGlobal = position;
        final inBounds = box.paintBounds.contains(local);
        _leave();
        if (!inBounds) return;
        widget.target.onDragDone?.call(
          DropDoneDetails(
            files: [for (final path in paths) DropItemFile(path)],
            localPosition: local,
            globalPosition: position,
          ),
        );
    }
  }

  /// Ends a hover, if one is in progress, where the drag was last seen.
  void _leave() {
    if (!_hovering) return;
    _hovering = false;
    final box = context.findRenderObject();
    final local = box is RenderBox && box.attached
        ? box.globalToLocal(_lastGlobal)
        : _lastGlobal;
    widget.target.onDragExited?.call(
      DropEventDetails(localPosition: local, globalPosition: _lastGlobal),
    );
  }

  @override
  Widget build(BuildContext context) => widget.target.child;
}
