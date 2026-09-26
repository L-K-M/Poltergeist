import 'dart:ui' show FlutterView;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../services/workspace_windows/workspace_window_scope.dart';
import '../services/workspace_windows/workspace_windows.dart';

/// The desktop app's root (00 D39): one [View] per open workspace window,
/// each rendering the app [buildWindow] builds for it, over the one
/// engine and isolate every window shares.
///
/// A window's view comes from the runner, so a window only renders once
/// the engine has added its view; the runner's `create` reply and the
/// engine's view announcement arrive in either order.
class WorkspaceWindowsRoot extends StatefulWidget {
  const WorkspaceWindowsRoot({
    super.key,
    required this.windows,
    required this.buildWindow,
    this.viewFor,
  });

  final WorkspaceWindows windows;

  /// The app for one window: its `PoltergeistApp`.
  final Widget Function(WorkspaceWindow window) buildWindow;

  /// Looks a view up by id; null reads the engine's views. A test seam.
  final FlutterView? Function(int viewId)? viewFor;

  @override
  State<WorkspaceWindowsRoot> createState() => _WorkspaceWindowsRootState();
}

class _WorkspaceWindowsRootState extends State<WorkspaceWindowsRoot>
    with WidgetsBindingObserver {
  /// macOS: the one native menu bar, fed by the active window.
  MenuBarSlot? _menuBar;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.windows.addListener(_changed);
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      _menuBar = MenuBarSlot(const []);
    }
  }

  @override
  void didUpdateWidget(WorkspaceWindowsRoot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.windows, widget.windows)) return;
    oldWidget.windows.removeListener(_changed);
    widget.windows.addListener(_changed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.windows.removeListener(_changed);
    _menuBar?.dispose();
    super.dispose();
  }

  /// A view came or went: the engine reports both as a metrics change.
  @override
  void didChangeMetrics() => _changed();

  void _changed() {
    if (mounted) setState(() {});
  }

  FlutterView? _view(WorkspaceWindow window) =>
      widget.viewFor?.call(window.viewId) ??
      WidgetsBinding.instance.platformDispatcher.view(id: window.viewId);

  @override
  Widget build(BuildContext context) {
    final views = ViewCollection(
      views: [
        for (final window in widget.windows.windows)
          if (_view(window) case final view?)
            View(
              key: ValueKey(window.serial),
              view: view,
              child: WorkspaceWindowScope(
                window: window,
                active: window.isActive,
                menuBar: _menuBar,
                child: FocusScope(
                  node: window.focusScope,
                  child: widget.buildWindow(window),
                ),
              ),
            ),
      ],
    );
    final menuBar = _menuBar;
    if (menuBar == null) return views;
    return ValueListenableBuilder<List<PlatformMenuItem>>(
      valueListenable: menuBar,
      builder: (context, menus, child) =>
          PlatformMenuBar(menus: menus, child: child),
      child: views,
    );
  }
}
