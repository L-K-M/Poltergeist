import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'workspace_windows/window_host.dart';

/// The window's full-screen state behind 10 §8's View ▸ Enter Full
/// Screen on Windows and Linux. macOS renders AppKit's own item (⌃⌘F),
/// which retitles itself, so the command does not register there.
abstract interface class WindowFullScreen {
  /// Whether this platform needs the registered command.
  bool get supported;

  /// The window's last known state; the menu label reads it.
  bool get isFullScreen;

  /// Takes the window into full screen, or back out of it.
  Future<void> toggle();
}

/// window_manager's full screen for the main window (an extra window's is
/// [HostWindowFullScreen]). Each toggle
/// asks the window for its real state first, so a change made outside
/// the menu (a window-manager shortcut) never inverts it, and the
/// window's enter/leave events keep the label in step between toggles.
final class WindowManagerFullScreen
    with WindowListener
    implements WindowFullScreen {
  WindowManagerFullScreen._();

  /// The host window. One instance, so one listener, however many
  /// times the shell rebuilds its registry.
  static final instance = WindowManagerFullScreen._();

  bool _fullScreen = false;
  bool _listening = false;

  @override
  bool get supported => switch (defaultTargetPlatform) {
    TargetPlatform.linux || TargetPlatform.windows => true,
    _ => false,
  };

  @override
  bool get isFullScreen {
    _listen();
    return _fullScreen;
  }

  @override
  Future<void> toggle() async {
    _listen();
    final next = !await windowManager.isFullScreen();
    await windowManager.setFullScreen(next);
    _fullScreen = next;
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    windowManager.addListener(this);
  }

  @override
  void onWindowEnterFullScreen() => _fullScreen = true;

  @override
  void onWindowLeaveFullScreen() => _fullScreen = false;
}

/// An extra workspace window's own full screen (00 D37): window_manager
/// only knows the main window, so the runner that hosts the window takes
/// it in and out.
final class HostWindowFullScreen implements WindowFullScreen {
  HostWindowFullScreen(this._host, this._viewId, this._platform);

  final WindowHost _host;
  final int _viewId;
  final TargetPlatform _platform;

  bool _fullScreen = false;

  @override
  bool get supported => switch (_platform) {
    TargetPlatform.linux || TargetPlatform.windows => true,
    _ => false,
  };

  @override
  bool get isFullScreen => _fullScreen;

  /// Asks the window for its real state first, like
  /// [WindowManagerFullScreen.toggle], so a change made outside the menu
  /// never inverts it.
  @override
  Future<void> toggle() async {
    final next = !await _host.isFullScreen(_viewId);
    await _host.setFullScreen(_viewId, fullScreen: next);
    _fullScreen = next;
  }
}
