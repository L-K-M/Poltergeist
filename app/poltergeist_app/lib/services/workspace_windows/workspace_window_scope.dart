import 'package:flutter/widgets.dart';

import 'workspace_windows.dart';

/// Where the macOS menu bar's items come from with several windows: the
/// active window's menu host publishes its items here and the windows root
/// renders the app's one `PlatformMenuBar` from them. Each window rendering
/// its own bar would fight over the one native menu bar, and a closing
/// window's bar would clear the menus the next window had just set.
typedef MenuBarSlot = ValueNotifier<List<PlatformMenuItem>>;

/// Tells a window's widgets which workspace window they are in (00 D37).
/// Absent in the single-window app, where every lookup answers as the one
/// window with every capability.
class WorkspaceWindowScope extends InheritedWidget {
  const WorkspaceWindowScope({
    super.key,
    required this.window,
    required this.active,
    this.menuBar,
    required super.child,
  });

  final WorkspaceWindow window;

  /// Whether [window] is the window the user last worked in.
  final bool active;

  /// macOS only: where the active window publishes its menus.
  final MenuBarSlot? menuBar;

  static WorkspaceWindowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WorkspaceWindowScope>();

  /// What the window around [context] supports.
  static WindowCapabilities capabilitiesOf(BuildContext context) =>
      maybeOf(context)?.window.capabilities ?? WindowCapabilities.all;

  /// Whether the window around [context] is the active one; true in the
  /// single-window app.
  static bool activeOf(BuildContext context) =>
      maybeOf(context)?.active ?? true;

  @override
  bool updateShouldNotify(WorkspaceWindowScope oldWidget) =>
      !identical(window, oldWidget.window) ||
      active != oldWidget.active ||
      !identical(menuBar, oldWidget.menuBar);
}
