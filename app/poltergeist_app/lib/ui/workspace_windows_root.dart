import 'dart:ui'
    show
        Display,
        DisplayCornerRadii,
        DisplayFeature,
        FlutterView,
        GestureSettings,
        PlatformDispatcher,
        Scene,
        SemanticsUpdate,
        ViewConstraints,
        ViewPadding;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../services/workspace_windows/workspace_window_scope.dart';
import '../services/workspace_windows/workspace_windows.dart';

/// The desktop app's root (00 D38): one [View] per open workspace window,
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

  /// macOS: the extra windows' views, keyed by window serial and kept
  /// while the window is open (a [View] must keep its view).
  final _silentViews = <int, FlutterView>{};

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

  FlutterView? _view(WorkspaceWindow window) {
    final view =
        widget.viewFor?.call(window.viewId) ??
        WidgetsBinding.instance.platformDispatcher.view(id: window.viewId);
    if (view == null ||
        window.isMain ||
        defaultTargetPlatform != TargetPlatform.macOS) {
      return view;
    }
    // macOS: Flutter 3.47's embedder hands every view's semantics update
    // to the main window's accessibility bridge (its multi-view TODO), so
    // an extra window's tree would overwrite the main window's for
    // VoiceOver and every other accessibility client. The extra window
    // sends none; it has no accessibility of its own on macOS until the
    // embedder routes updates by view.
    return _silentViews[window.serial] ??= _SemanticsSilentView(view);
  }

  @override
  Widget build(BuildContext context) {
    final open = {for (final window in widget.windows.windows) window.serial};
    _silentViews.removeWhere((serial, _) => !open.contains(serial));
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

/// A view that renders like [_view] but drops its semantics updates.
final class _SemanticsSilentView implements FlutterView {
  _SemanticsSilentView(this._view);

  final FlutterView _view;

  @override
  int get viewId => _view.viewId;

  @override
  PlatformDispatcher get platformDispatcher => _view.platformDispatcher;

  @override
  Display get display => _view.display;

  @override
  double get devicePixelRatio => _view.devicePixelRatio;

  @override
  ViewConstraints get physicalConstraints => _view.physicalConstraints;

  @override
  Size get physicalSize => _view.physicalSize;

  @override
  ViewPadding get viewInsets => _view.viewInsets;

  @override
  ViewPadding get viewPadding => _view.viewPadding;

  @override
  ViewPadding get systemGestureInsets => _view.systemGestureInsets;

  @override
  ViewPadding get padding => _view.padding;

  @override
  GestureSettings get gestureSettings => _view.gestureSettings;

  @override
  List<DisplayFeature> get displayFeatures => _view.displayFeatures;

  @override
  DisplayCornerRadii? get displayCornerRadii => _view.displayCornerRadii;

  @override
  void render(Scene scene, {Size? size}) => _view.render(scene, size: size);

  /// The update is not handed on, so it is released here.
  @override
  void updateSemantics(SemanticsUpdate update) => update.dispose();

  @override
  String toString() => _view.toString();
}
