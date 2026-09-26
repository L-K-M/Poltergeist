// An extra workspace window's macOS titlebar (00 D39): the same unified
// toolbar band the main window has, served by the workspace windows' host
// (macos/Runner/WorkspaceWindows.swift) rather than by macos_window_utils,
// whose toolbar calls act on the main window only.
//
// The band claims clicks for window drag and double-click zoom, so the
// header's controls ask the host to hand clicks over their rectangles to
// Flutter (`WindowToolbarPassthrough`, lib/ui/shell/), as
// `MacosToolbarPassthrough` does for the main window. In full screen the
// host hides the band, as MainFlutterWindow does, and reports it.
//
// ## Channel protocol: `poltergeist/titlebar` (macOS)
//
// `StandardMethodCodec` on the engine's messenger; every argument is a map
// carrying `viewId`, an extra window's view. Rectangles are the view's
// logical pixels, origin top-left.
//
// Dart → runner:
// * `isToolbarBandVisible` → bool: whether the window shows the band now.
// * `updatePassthrough` {`id`: String, `x`, `y`, `width`, `height`:
//   double}: clicks inside the rectangle go to Flutter. `id` names the
//   rectangle within its window; a second call moves it.
// * `removePassthrough` {`id`}: stop.
//
// Runner → Dart:
// * `toolbarBandChanged` {`visible`: bool}: sent as a full-screen
//   transition begins.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel windowTitlebarChannel = MethodChannel(
  'poltergeist/titlebar',
);

/// Dart → runner. Each crosses as its [name].
enum WindowTitlebarMethod {
  isToolbarBandVisible,
  updatePassthrough,
  removePassthrough,
}

/// Runner → Dart. Each crosses as its [name].
enum WindowTitlebarEvent { toolbarBandChanged }

/// The keys of the argument maps, both directions.
enum WindowTitlebarKey { viewId, id, x, y, width, height, visible }

/// The extra windows' titlebars, by view.
final class WindowTitlebars {
  WindowTitlebars([this._channel = windowTitlebarChannel]);

  /// The app's one: the channel has one handler.
  static final instance = WindowTitlebars();

  final MethodChannel _channel;
  final _bands = <int, ValueNotifier<bool>>{};

  /// Whether [viewId]'s window shows the band: true windowed, false in
  /// full screen (the value `MacosToolbarBandChannel` gives the main
  /// window). Asks the runner once, for a window that opened in full
  /// screen.
  ValueListenable<bool> bandFor(int viewId) {
    final existing = _bands[viewId];
    if (existing != null) return existing;
    if (_bands.isEmpty) _channel.setMethodCallHandler(_handle);
    final band = _bands[viewId] = ValueNotifier(true);
    _channel
        .invokeMethod<bool>(WindowTitlebarMethod.isToolbarBandVisible.name, {
          WindowTitlebarKey.viewId.name: viewId,
        })
        .then(
          (visible) {
            if (visible != null) band.value = visible;
          },
          // No runner side, or the window is already gone: the windowed
          // layout stands.
          onError: (Object _) {},
        );
    return band;
  }

  /// Hands clicks inside [rect] in [viewId]'s window to Flutter.
  Future<void> updatePassthrough(int viewId, String id, Rect rect) =>
      _invoke(WindowTitlebarMethod.updatePassthrough, {
        WindowTitlebarKey.viewId.name: viewId,
        WindowTitlebarKey.id.name: id,
        WindowTitlebarKey.x.name: rect.left,
        WindowTitlebarKey.y.name: rect.top,
        WindowTitlebarKey.width.name: rect.width,
        WindowTitlebarKey.height.name: rect.height,
      });

  Future<void> removePassthrough(int viewId, String id) => _invoke(
    WindowTitlebarMethod.removePassthrough,
    {WindowTitlebarKey.viewId.name: viewId, WindowTitlebarKey.id.name: id},
  );

  Future<void> _invoke(
    WindowTitlebarMethod method,
    Map<String, Object?> arguments,
  ) async {
    try {
      await _channel.invokeMethod<void>(method.name, arguments);
    } on MissingPluginException {
      // Not macOS: there is no band to pass through.
    } on PlatformException {
      // The window closed under a late update: nothing to pass through.
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != WindowTitlebarEvent.toolbarBandChanged.name) {
      throw MissingPluginException();
    }
    final arguments = call.arguments;
    if (arguments is! Map) return null;
    final viewId = arguments[WindowTitlebarKey.viewId.name];
    final visible = arguments[WindowTitlebarKey.visible.name];
    if (viewId is! int || visible is! bool) return null;
    _bands[viewId]?.value = visible;
    return null;
  }
}
