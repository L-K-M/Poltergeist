import 'package:flutter/material.dart';

/// The height of the titlebar band the empty unified NSToolbar claims on
/// macOS (D32 §3; `DesktopWindowLifecycle` installs the toolbar). The
/// macOS `PoltergeistChrome.headerHeight` matches it, so the
/// traffic lights sit centered on the shell header.
const double macosToolbarBandHeight = 52;

/// Reserves the macOS toolbar band for everything the root navigator
/// shows: pushed routes (the built-in editor), dialogs, sheets, popup
/// menus, and the root overlay's top toasts.
///
/// The band takes every mouse-down for window drag and double-click
/// zoom, except where a `MacosToolbarPassthrough` view hands the click
/// back to Flutter, and only the shell header registers those. Adding
/// the band to `MediaQuery` padding moves every other surface's
/// interactive chrome below it the way a status bar inset would: an
/// `AppBar` grows by the padding and paints its background up into the
/// band, and `showDialog`'s safe area, popup-menu layout, and the toast
/// column's `SafeArea` all keep clear of it. The empty band above them
/// then drags and zooms the window natively, as a titlebar should.
///
/// The shell takes the band back with [ClaimMacosToolbarBand]: its
/// header is the one surface meant to draw under it. Other platforms
/// have no band, so both widgets are no-ops there.
class ReserveMacosToolbarBand extends StatelessWidget {
  const ReserveMacosToolbarBand({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.macOS) return child;
    return _shiftTop(context, macosToolbarBandHeight, child);
  }
}

/// Takes the band [ReserveMacosToolbarBand] added back out for the
/// workspace shell, which draws its header under the band and wraps the
/// header's controls in `MacosToolbarPassthrough`. Without this the
/// shell's safe area would push the whole window content down a band,
/// and every scroll view in it would pad its top by 52 pt.
///
/// While an opaque route (the editor) covers the shell, the offstage
/// header's passthrough views stay registered with the window. Clicks
/// on those rects reach Flutter over the covering route's empty band
/// padding, where nothing is interactive, so the only cost is that the
/// window cannot be dragged from those few spots until the route pops.
class ClaimMacosToolbarBand extends StatelessWidget {
  const ClaimMacosToolbarBand({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.macOS) return child;
    return _shiftTop(context, -macosToolbarBandHeight, child);
  }
}

Widget _shiftTop(BuildContext context, double delta, Widget child) {
  final data = MediaQuery.of(context);
  double shifted(double top) => (top + delta).clamp(0, double.infinity);
  return MediaQuery(
    data: data.copyWith(
      padding: data.padding.copyWith(top: shifted(data.padding.top)),
      viewPadding: data.viewPadding.copyWith(
        top: shifted(data.viewPadding.top),
      ),
    ),
    child: child,
  );
}
