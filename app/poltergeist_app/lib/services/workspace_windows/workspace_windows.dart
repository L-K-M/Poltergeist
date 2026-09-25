// The app's workspace windows (00 D37): which ones are open, which one the
// user is working in, and the open, close, and quit rules between them.
//
// Every window is a view on the app's one Flutter engine, rendered by
// `WorkspaceWindowsRoot` with its own `PoltergeistApp` (its own navigator,
// shell, and workspace) over the app's shared models: the stores, the
// engine session, the transfer queue. What is per window is only what a
// window shows. The first window is the engine's implicit view, which cannot
// leave the engine, so closing it while other windows stay open hides it
// and drops its workspace; the next New Window shows it again with a fresh
// one.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ScaffoldMessengerState;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../session_state.dart';
import '../window_full_screen.dart';
import '../workspace_controller.dart';
import 'window_host.dart';

enum WorkspaceWindowKind {
  /// The engine's implicit view: window_manager's window, which carries the
  /// plugins that only know one window (OS drop-in, drag-out, the macOS
  /// unified toolbar and Quick Look panel).
  main,

  /// A window the runner created on the same engine.
  extra,
}

/// The per-window platform integrations that only the main window has
/// today (see [WorkspaceWindowKind.main]); an extra window's shell leaves
/// them out rather than letting them act on the main window.
@immutable
final class WindowCapabilities {
  const WindowCapabilities({
    required this.unifiedToolbar,
    required this.osDropIn,
    required this.nativeQuickLook,
  });

  /// The single-window app: everything.
  static const all = WindowCapabilities(
    unifiedToolbar: true,
    osDropIn: true,
    nativeQuickLook: true,
  );

  /// An extra window: a native titlebar above the content, no drop-in
  /// from other apps, and Quick Look in the window.
  static const extra = WindowCapabilities(
    unifiedToolbar: false,
    osDropIn: false,
    nativeQuickLook: false,
  );

  /// macOS: the header draws under the empty unified toolbar, whose
  /// click passthrough (macos_window_utils) serves the main window only.
  final bool unifiedToolbar;

  /// Files dropped from other apps (desktop_drop) arrive here. The plugin
  /// listens on the main window and reports positions in its coordinates,
  /// so any other window must refuse them.
  final bool osDropIn;

  /// macOS: Space opens the system Quick Look panel, which the main window
  /// controls; elsewhere the in-window overlay serves.
  final bool nativeQuickLook;
}

/// What a window's shell registers with its window, so the app can reach
/// the workspace the window shows.
abstract interface class WorkspaceWindowContent {
  /// The window's workspace, or null between rebuilds.
  WorkspaceController? get workspace;

  /// Puts keyboard focus where a freshly opened window wants it (the
  /// active pane's listing). Called when the window becomes active with
  /// nothing focused in it yet.
  void claimDefaultFocus();
}

/// One open workspace window.
final class WorkspaceWindow {
  WorkspaceWindow._({
    required this.viewId,
    required this.kind,
    required this.serial,
    required this.restoredSession,
    required this.capabilities,
    required this.fullScreen,
    required this._owner,
  }) : navigatorKey = GlobalKey<NavigatorState>(
         debugLabel: 'window $serial navigator',
       ),
       scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>(
         debugLabel: 'window $serial messenger',
       ),
       focusScope = FocusScopeNode(debugLabel: 'window $serial');

  final int viewId;
  final WorkspaceWindowKind kind;

  /// Unique for the app's lifetime: the key of the window's widget
  /// subtree, so a main window shown again mounts afresh.
  final int serial;

  /// The session this window opens with; null opens the default layout
  /// (a local home tab in each pane).
  final SessionState? restoredSession;

  final WindowCapabilities capabilities;

  /// The window's own full screen on Linux and Windows, for an extra
  /// window; null for the main window, whose command uses window_manager.
  final WindowFullScreen? fullScreen;

  final GlobalKey<NavigatorState> navigatorKey;
  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey;

  /// Everything the window shows sits under this scope, so activating the
  /// window can put focus back where it was in it.
  final FocusScopeNode focusScope;

  final WorkspaceWindows _owner;
  WorkspaceWindowContent? _content;

  bool get isMain => kind == WorkspaceWindowKind.main;

  /// Whether this is the window the app launched with, rather than one
  /// opened (or shown again) since: work already queued at launch is its
  /// to reveal.
  bool get isLaunchWindow => serial == 0;

  /// Whether this is the window the user last worked in: the one whose
  /// menus the macOS menu bar shows, whose navigator app-wide prompts use,
  /// and whose activity panel opens for new transfers.
  bool get isActive => identical(_owner.activeWindow, this);

  /// Whether a window can be opened from here (the runner hosts them).
  bool get canOpenWindows => _owner.canOpenWindows;

  /// New Window.
  Future<void> openWindow() => _owner.openWindow();

  /// Close Window, the same path as the window's close button.
  Future<void> close() => _owner.closeWindow(this);

  /// Quit: every window closes with the app.
  Future<void> quitApplication() => _owner.quitApplication();

  /// Whether a window other than this one has a live binding to
  /// [serverId]: closing this window's last tab on a server must not
  /// disconnect it under another window (03 §3.2's last-binding rule,
  /// across windows).
  bool serverBoundElsewhere(String serverId) =>
      _owner._serverBoundOutside(this, serverId);

  void attachContent(WorkspaceWindowContent content) => _content = content;

  void detachContent(WorkspaceWindowContent content) {
    if (identical(_content, content)) _content = null;
  }

  void _restoreFocus() {
    if (focusScope.focusedChild != null) {
      focusScope.requestFocus();
      return;
    }
    _content?.claimDefaultFocus();
  }

  void _dispose() => focusScope.dispose();
}

/// The app's open workspace windows and the rules between them.
final class WorkspaceWindows extends ChangeNotifier
    implements WindowHostListener {
  WorkspaceWindows({
    required this._host,
    required this._quitApplication,
    Future<void> Function()? afterFrame,
    TargetPlatform? platform,
    this._onError,
  }) : _afterFrame = afterFrame ?? _endOfFrame,
       _platform = platform ?? defaultTargetPlatform;

  final WindowHost _host;
  final Future<void> Function() _quitApplication;

  /// Resolves once the frame that dropped a closing window's subtree has
  /// been built: the view must stop rendering before its native window
  /// goes.
  final Future<void> Function() _afterFrame;
  final TargetPlatform _platform;
  final void Function(Object, StackTrace)? _onError;

  final _windows = <WorkspaceWindow>[];

  /// Most recently activated last.
  final _activation = <WorkspaceWindow>[];
  int _serials = 0;
  bool _hostAvailable = false;
  bool _started = false;
  bool _disposed = false;

  /// Serializes opening and closing, which both await the runner: two
  /// quick New Windows must not both reuse the hidden main window.
  Future<void> _tail = Future.value();

  late final GlobalKey<NavigatorState> navigatorKey =
      _ActiveWindowKey<NavigatorState>(
        () => activeWindow?.navigatorKey,
        'active window navigator',
      );

  late final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      _ActiveWindowKey<ScaffoldMessengerState>(
        () => activeWindow?.scaffoldMessengerKey,
        'active window messenger',
      );

  /// Bounded: frames stop while the app is hidden, and a close must not
  /// wait for one forever. Without the frame the view is only destroyed
  /// while its subtree is still mounted, which the engine tolerates.
  static Future<void> _endOfFrame() => SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 1), onTimeout: () {});

  /// The open windows, in the order they opened. The main window is
  /// absent while it is hidden.
  List<WorkspaceWindow> get windows => List.unmodifiable(_windows);

  /// The window the user last worked in, or the first open one.
  WorkspaceWindow? get activeWindow {
    for (final window in _activation.reversed) {
      if (_windows.contains(window)) return window;
    }
    return _windows.firstOrNull;
  }

  /// Whether New Window can open one: the runner hosts extra windows.
  bool get canOpenWindows => _hostAvailable;

  WorkspaceWindow? windowForView(int viewId) {
    for (final window in _windows) {
      if (window.viewId == viewId) return window;
    }
    return null;
  }

  /// Opens the main window with [session] and asks whether the runner can
  /// host more. The main window is already on screen (window_manager shows
  /// it); this only records it.
  Future<void> start({SessionState? session}) async {
    if (_started) return;
    _started = true;
    _host.listener = this;
    try {
      _hostAvailable = await _host.isAvailable();
    } on Object catch (error, stack) {
      _report(error, stack);
      _hostAvailable = false;
    }
    if (_disposed) return;
    final main = _newWindow(
      mainWindowViewId,
      WorkspaceWindowKind.main,
      session,
    );
    _windows.add(main);
    _activation.add(main);
    notifyListeners();
  }

  /// Reopens the windows the last session had open beside the first one.
  /// Each opens active, as a new window does, so the last one is active
  /// when they are all up: the runners show a new window when its first
  /// frame lands, which may be after any activation Dart could ask for
  /// here, and would then take the activation back.
  Future<void> restoreWindows(List<SessionState> sessions) async {
    for (final session in sessions) {
      await openWindow(session: session);
    }
  }

  /// New Window: shows the hidden main window again, fresh, or asks the
  /// runner for another one. The new window becomes the active one.
  Future<void> openWindow({SessionState? session}) =>
      _serialized(() => _openWindow(session));

  Future<void> _openWindow(SessionState? session) async {
    if (!_hostAvailable || _disposed) return;

    if (windowForView(mainWindowViewId) == null) {
      final main = _newWindow(
        mainWindowViewId,
        WorkspaceWindowKind.main,
        session,
      );
      _windows.add(main);
      _activate(main);
      notifyListeners();
      // Its first frame before it shows, so it never shows the workspace
      // it had when it was closed.
      await _afterFrame();
      await _host.activate(mainWindowViewId);
      return;
    }

    final int viewId;
    try {
      viewId = await _host.create();
    } on Object catch (error, stack) {
      _report(error, stack);
      return;
    }
    if (_disposed) return;
    final window = _newWindow(viewId, WorkspaceWindowKind.extra, session);
    _windows.add(window);
    // The runner already made it key; its report may have arrived before
    // this reply, when there was no window to credit it to.
    _activate(window);
    notifyListeners();
  }

  /// Close Window and an extra window's close button: closes [window], or
  /// quits the app when it is the last one open (the quit guard and the
  /// exit flush decide that, as for Quit).
  Future<void> closeWindow(WorkspaceWindow window) =>
      _serialized(() => _closeWindow(window));

  Future<void> _closeWindow(WorkspaceWindow window) async {
    if (!_windows.contains(window) || _disposed) return;
    if (_windows.length == 1) {
      await _quitApplication();
      return;
    }

    _windows.remove(window);
    _activation.remove(window);
    notifyListeners();
    // The subtree goes in this frame; the view after it.
    await _afterFrame();
    try {
      if (window.isMain) {
        await _host.hide(mainWindowViewId);
      } else {
        await _host.destroy(window.viewId);
      }
    } on Object catch (error, stack) {
      _report(error, stack);
    }
    window._dispose();
    final next = activeWindow;
    if (next != null && !_disposed) await _host.activate(next.viewId);
  }

  /// The main window's close button, as window_manager reports it. True
  /// when it was only this window that closed; false when the app should
  /// quit (it is the only window open), which the caller's quit path does.
  Future<bool> closeMainWindowInstead() async {
    final main = windowForView(mainWindowViewId);
    if (main == null || _windows.length == 1 || _disposed) return false;
    await closeWindow(main);
    return true;
  }

  /// Quit: every window closes with the app, after the quit guard.
  Future<void> quitApplication() => _quitApplication();

  @override
  void onWindowActivated(int viewId) {
    final window = windowForView(viewId);
    if (window == null || _disposed) return;
    final changed = !window.isActive;
    _activate(window);
    if (changed) notifyListeners();
    window._restoreFocus();
  }

  @override
  void onWindowCloseRequested(int viewId) {
    final window = windowForView(viewId);
    if (window == null) return;
    unawaited(closeWindow(window));
  }

  @override
  void dispose() {
    _disposed = true;
    _host.listener = null;
    for (final window in _windows) {
      window._dispose();
    }
    _windows.clear();
    _activation.clear();
    super.dispose();
  }

  WorkspaceWindow _newWindow(
    int viewId,
    WorkspaceWindowKind kind,
    SessionState? session,
  ) {
    final extra = kind == WorkspaceWindowKind.extra;
    return WorkspaceWindow._(
      viewId: viewId,
      kind: kind,
      serial: _serials++,
      restoredSession: session,
      capabilities: extra ? WindowCapabilities.extra : WindowCapabilities.all,
      fullScreen: extra ? HostWindowFullScreen(_host, viewId, _platform) : null,
      owner: this,
    );
  }

  void _activate(WorkspaceWindow window) {
    _activation
      ..remove(window)
      ..add(window);
  }

  bool _serverBoundOutside(WorkspaceWindow window, String serverId) {
    for (final other in _windows) {
      if (identical(other, window)) continue;
      if (other._content?.workspace?.bindsServer(serverId) ?? false) {
        return true;
      }
    }
    return false;
  }

  Future<void> _serialized(Future<void> Function() operation) {
    final run = _tail.then((_) => operation());
    _tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return run.catchError((Object error, StackTrace stack) {
      _report(error, stack);
    });
  }

  void _report(Object error, StackTrace stack) {
    final sink = _onError;
    if (sink != null) {
      sink(error, stack);
      return;
    }
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack),
    );
  }
}

/// A key that is never mounted: it answers for the active window's key.
///
/// The app-wide dialog owners (the engine session's prompts, the quit
/// guard, the server editor's trust prompts) each take one navigator key
/// and read `currentContext` when they show something. With several
/// windows the right navigator is the one in the window the user is
/// working in, and it changes, so they get this instead of any one
/// window's key.
final class _ActiveWindowKey<T extends State<StatefulWidget>>
    extends LabeledGlobalKey<T> {
  _ActiveWindowKey(this._resolve, String label) : super(label);

  final GlobalKey<T>? Function() _resolve;

  @override
  BuildContext? get currentContext => _resolve()?.currentContext;

  @override
  Widget? get currentWidget => _resolve()?.currentWidget;

  @override
  T? get currentState => _resolve()?.currentState;
}
