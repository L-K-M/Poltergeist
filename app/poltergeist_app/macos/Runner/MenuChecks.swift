import Cocoa
import FlutterMacOS

/// Supplements Flutter's menu plugin, which does not expose NSMenuItem.state.
/// Menu item tags are Flutter's serialized IDs, so this does not depend on
/// localized labels, menu positions or the currently active workspace.
final class MenuChecks {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "poltergeist/menu_checks", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "setChecked" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let states = call.arguments as? [String: Bool] else {
        result(FlutterError(
          code: "INVALID_ARGUMENTS",
          message: "setChecked requires menu item IDs and Boolean states.",
          details: nil))
        return
      }
      if let menu = NSApp.mainMenu {
        Self.apply(states, to: menu)
      }
      result(nil)
    }
  }

  /// Only matching generated IDs change. An older Flutter menu push can
  /// finish after a newer push, whose different IDs must keep their state.
  static func apply(_ states: [String: Bool], to menu: NSMenu) {
    for item in menu.items {
      if let checked = states[String(item.tag)] {
        item.state = checked ? .on : .off
      }
      if let submenu = item.submenu {
        apply(states, to: submenu)
      }
    }
  }
}
