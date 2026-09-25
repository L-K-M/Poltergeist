// The workspace windows' wire (00 D37): what the Dart side asks the runner
// to do with native windows, and what the runner reports back.
//
// Every workspace window is a view on the app's one Flutter engine, so the
// windows share one isolate and every model in it. The runner hosts them
// (macos/Runner/WorkspaceWindows.swift, linux/runner/workspace_windows.cc,
// windows/runner/workspace_windows.cpp) and answers on
// [workspaceWindowsChannel]: `create` adds a native window whose Flutter view
// renders on the same engine and answers with the view's id, and the view id
// names the window in every other call. The app's first window is the
// engine's implicit view, id [mainWindowViewId]; window_manager still owns
// its geometry and close interception, and the host only shows, hides, and
// raises it.
import 'dart:async';

import 'package:flutter/services.dart';

/// The app's first window: the engine's implicit view.
const int mainWindowViewId = 0;

/// On the app's engine; the runner that hosts the windows serves it.
const MethodChannel workspaceWindowsChannel = MethodChannel(
  'poltergeist/windows',
);

/// Dart → runner. Each crosses as its [name].
enum WindowHostMethod {
  isAvailable,
  create,
  destroy,
  activate,
  hide,
  isFullScreen,
  setFullScreen,
}

/// Runner → Dart. Each crosses as its [name].
enum WindowHostEvent { activated, closeRequested }

/// The keys of the argument maps, both directions.
enum WindowHostKey { viewId, engineId, fullScreen }

/// What the runner reports about the windows it hosts.
abstract interface class WindowHostListener {
  /// A window became the key/active window, the main window included.
  void onWindowActivated(int viewId);

  /// The user asked an extra window to close (its close button, the
  /// window menu, Alt+F4). The window stays up until Dart destroys it.
  /// The main window's close goes through window_manager instead.
  void onWindowCloseRequested(int viewId);
}

/// The native side of the workspace windows.
abstract interface class WindowHost {
  /// Whether the runner can host more windows than the main one: false on
  /// phones, in tests, and in a runner without the host.
  Future<bool> isAvailable();

  /// Opens a new native window whose view renders on this engine, and
  /// answers with the view's id. It becomes the active window. Throws a
  /// [WindowHostException] when the runner could not create it.
  Future<int> create();

  /// Closes an extra window for good. Its view leaves the engine with it.
  Future<void> destroy(int viewId);

  /// Shows [viewId]'s window if it is hidden and makes it the active one.
  Future<void> activate(int viewId);

  /// Hides [viewId]'s window without destroying it (the main window, whose
  /// view cannot leave the engine).
  Future<void> hide(int viewId);

  Future<bool> isFullScreen(int viewId);

  Future<void> setFullScreen(int viewId, {required bool fullScreen});

  /// Where the runner's reports go; null stops them.
  set listener(WindowHostListener? listener);
}

/// A native window the runner could not create or reach.
final class WindowHostException implements Exception {
  const WindowHostException(this.message);

  final String message;

  @override
  String toString() => 'WindowHostException: $message';
}

/// The production host over [workspaceWindowsChannel].
final class MethodChannelWindowHost implements WindowHost {
  MethodChannelWindowHost({
    this._channel = workspaceWindowsChannel,
    int? Function()? engineId,
  }) : _engineId = engineId ?? _currentEngineId;

  final MethodChannel _channel;

  /// The Windows runner reaches the engine by the id the framework
  /// reports: its C++ wrapper does not expose the engine handle.
  final int? Function() _engineId;

  WindowHostListener? _listener;

  static int? _currentEngineId() =>
      ServicesBinding.instance.platformDispatcher.engineId;

  @override
  set listener(WindowHostListener? listener) {
    _listener = listener;
    _channel.setMethodCallHandler(listener == null ? null : _handle);
  }

  @override
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>(
            WindowHostMethod.isAvailable.name,
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<int> create() async {
    final Object? viewId;
    try {
      viewId = await _channel.invokeMethod<Object>(
        WindowHostMethod.create.name,
        {WindowHostKey.engineId.name: _engineId()},
      );
    } on PlatformException catch (error) {
      throw WindowHostException(error.message ?? error.code);
    } on MissingPluginException {
      throw const WindowHostException('no window host');
    }
    if (viewId is! int) {
      throw const WindowHostException('the runner answered no view id');
    }
    return viewId;
  }

  @override
  Future<void> destroy(int viewId) => _invoke(WindowHostMethod.destroy, viewId);

  @override
  Future<void> activate(int viewId) =>
      _invoke(WindowHostMethod.activate, viewId);

  @override
  Future<void> hide(int viewId) => _invoke(WindowHostMethod.hide, viewId);

  @override
  Future<bool> isFullScreen(int viewId) async =>
      await _channel.invokeMethod<bool>(WindowHostMethod.isFullScreen.name, {
        WindowHostKey.viewId.name: viewId,
      }) ??
      false;

  @override
  Future<void> setFullScreen(int viewId, {required bool fullScreen}) =>
      _channel.invokeMethod<void>(WindowHostMethod.setFullScreen.name, {
        WindowHostKey.viewId.name: viewId,
        WindowHostKey.fullScreen.name: fullScreen,
      });

  Future<void> _invoke(WindowHostMethod method, int viewId) => _channel
      .invokeMethod<void>(method.name, {WindowHostKey.viewId.name: viewId});

  Future<Object?> _handle(MethodCall call) async {
    final listener = _listener;
    final arguments = call.arguments;
    final viewId = arguments is Map
        ? arguments[WindowHostKey.viewId.name]
        : null;
    if (listener == null || viewId is! int) return null;
    if (call.method == WindowHostEvent.activated.name) {
      listener.onWindowActivated(viewId);
    } else if (call.method == WindowHostEvent.closeRequested.name) {
      listener.onWindowCloseRequested(viewId);
    } else {
      throw MissingPluginException();
    }
    return null;
  }
}

/// No runner host: one window, and nothing to report.
final class UnavailableWindowHost implements WindowHost {
  const UnavailableWindowHost();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<int> create() async =>
      throw const WindowHostException('no window host');

  @override
  Future<void> destroy(int viewId) async {}

  @override
  Future<void> activate(int viewId) async {}

  @override
  Future<void> hide(int viewId) async {}

  @override
  Future<bool> isFullScreen(int viewId) async => false;

  @override
  Future<void> setFullScreen(int viewId, {required bool fullScreen}) async {}

  @override
  set listener(WindowHostListener? listener) {}
}
