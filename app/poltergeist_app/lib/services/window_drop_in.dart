/// Files dropped from other apps onto an extra workspace window (00 D39).
///
/// `desktop_drop` serves the main window: its runners register a drop
/// target on the first Flutter view only, and report positions without
/// saying which view they are in, so every `DropTarget` in every window
/// would hit-test them as its own. The workspace windows' runners register
/// a drop target on each extra window's view instead and report its drags
/// here, each tagged with the view it happened in. `WindowDropTarget`
/// (lib/ui/panes/window_drop_target.dart) picks between the two by the view
/// it sits in.
///
/// ## Channel protocol: `poltergeist/dropin`
///
/// Runner → Dart only, `StandardMethodCodec`, on the engine's default
/// messenger. Every call's argument is a map carrying `viewId` (int, the
/// extra window's view). Positions are `[x, y]` doubles in the view's
/// logical pixels, origin top-left, the space of `PointerEvent.position`.
///
/// | method    | other keys                              | meaning |
/// |-----------|-----------------------------------------|---------|
/// | `entered` | `position`                              | a drag carrying files came over the view |
/// | `updated` | `position`                              | it moved |
/// | `exited`  |                                         | it left, or was cancelled |
/// | `dropped` | `position`, `paths` (`List<String>`)    | it was released over the view; `paths` are the local paths it carried (a runner that cannot read a path leaves it out) |
///
/// Replies are ignored. The runners offer the OS a copy, as desktop_drop
/// does: a cross-application drop carries no move the app could honour
/// (00 D14).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The channel the workspace windows' runners report extra-window drops on.
const MethodChannel windowDropInChannel = MethodChannel('poltergeist/dropin');

/// Runner → Dart. Each crosses as its [name].
enum WindowDropInMethod { entered, updated, exited, dropped }

/// The keys of the argument maps.
enum WindowDropInKey { viewId, position, paths }

/// One report about a drag over an extra window's view.
sealed class WindowDropEvent {
  const WindowDropEvent();
}

/// A drag carrying files is over the view at [position]: it just came in
/// ([entered]) or it moved.
final class WindowDropHover extends WindowDropEvent {
  const WindowDropHover(this.position, {required this.entered});

  final Offset position;
  final bool entered;
}

/// The drag left the view, or the OS cancelled it.
final class WindowDropExit extends WindowDropEvent {
  const WindowDropExit();
}

/// The drag was released at [position] carrying [paths].
final class WindowDropDone extends WindowDropEvent {
  const WindowDropDone(this.position, this.paths);

  final Offset position;
  final List<String> paths;
}

typedef WindowDropListener = void Function(WindowDropEvent event);

/// Decodes `poltergeist/dropin` and hands each report to the listeners of
/// the view it names.
final class WindowDropIn {
  WindowDropIn([this._channel = windowDropInChannel]);

  /// The app's one decoder: the channel has one handler.
  static final instance = WindowDropIn();

  final MethodChannel _channel;
  final _listeners = <int, List<WindowDropListener>>{};

  void addListener(int viewId, WindowDropListener listener) {
    if (_listeners.isEmpty) _channel.setMethodCallHandler(_handle);
    (_listeners[viewId] ??= []).add(listener);
  }

  void removeListener(int viewId, WindowDropListener listener) {
    final listeners = _listeners[viewId];
    if (listeners == null || !listeners.remove(listener)) return;
    if (listeners.isEmpty) _listeners.remove(viewId);
    if (_listeners.isEmpty) _channel.setMethodCallHandler(null);
  }

  Future<Object?> _handle(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map) return null;
    final viewId = arguments[WindowDropInKey.viewId.name];
    if (viewId is! int) return null;
    final event = _decode(call.method, arguments);
    if (event == null) return null;
    // A copy: a listener may remove itself (a drop that rebuilds its pane).
    for (final listener in [...?_listeners[viewId]]) {
      listener(event);
    }
    return null;
  }

  static WindowDropEvent? _decode(String method, Map<Object?, Object?> map) {
    if (method == WindowDropInMethod.exited.name) return const WindowDropExit();
    final position = _offset(map[WindowDropInKey.position.name]);
    if (position == null) return null;
    if (method == WindowDropInMethod.entered.name) {
      return WindowDropHover(position, entered: true);
    }
    if (method == WindowDropInMethod.updated.name) {
      return WindowDropHover(position, entered: false);
    }
    if (method == WindowDropInMethod.dropped.name) {
      final paths = map[WindowDropInKey.paths.name];
      if (paths is! List) return null;
      return WindowDropDone(position, [
        for (final path in paths)
          if (path is String && path.isNotEmpty) path,
      ]);
    }
    return null;
  }

  static Offset? _offset(Object? value) {
    if (value is Float64List && value.length == 2) {
      return Offset(value[0], value[1]);
    }
    if (value is! List || value.length != 2) return null;
    final [x, y] = value;
    if (x is! num || y is! num) return null;
    return Offset(x.toDouble(), y.toDouble());
  }
}
