import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The `poltergeist/window` method channel's name. The Swift side lives
/// in `MainFlutterWindow.swift`.
const windowChannelName = 'poltergeist/window';

/// Whether macOS currently shows the unified toolbar band (D32 §3) that
/// the shell header draws under, as the runner reports it.
///
/// The band exists only while the window is windowed. In full screen
/// AppKit would keep the toolbar permanently visible in an opaque strip
/// above the content, covering the header, so the runner hides the
/// toolbar for the duration and the titlebar only slides in with the
/// menu bar. The runner reports each switch as the transition *begins*
/// (AppKit's will-enter and will-exit edges), so the layout changes with
/// the toolbar instead of snapping after the animation.
///
/// The value starts true, the windowed layout, and stays true when no
/// runner answers the channel (every platform but macOS).
final class MacosToolbarBandChannel extends ValueNotifier<bool> {
  MacosToolbarBandChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(windowChannelName),
      super(true) {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;

  /// Asks the runner for the band's state, which a window restored
  /// straight into full screen changed before the handler was set.
  Future<void> start() async {
    try {
      final visible = await _channel.invokeMethod<bool>('isToolbarBandVisible');
      if (visible != null) value = visible;
    } on MissingPluginException {
      // No runner side (not macOS): the windowed layout stands.
    }
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'toolbarBandChanged') {
      throw MissingPluginException();
    }
    final visible = call.arguments;
    if (visible is! bool) {
      throw PlatformException(
        code: 'BAD_ARGS',
        message: 'toolbarBandChanged needs a bool argument',
      );
    }
    value = visible;
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
