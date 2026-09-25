import Cocoa
import FlutterMacOS

/// The workspace windows' host (00 D37): serves `poltergeist/windows` on the
/// app's engine (the protocol is the library doc of
/// lib/services/workspace_windows/window_host.dart).
///
/// Every extra window holds a FlutterViewController made for the app's own
/// engine, so it renders in the same isolate as the main window and shares
/// its state; the engine takes it as a new view once
/// `PoltergeistEnableMultiView` has let it (PoltergeistMultiView.m says why
/// that is not the engine's own method). Closing one only reports
/// `closeRequested`; Dart drops the window's widgets and then asks for
/// `destroy`, and releasing the controller removes its view from the engine.
///
/// An extra window has a standard titlebar: the unified toolbar and its
/// click passthrough (macos_window_utils) serve the main window only, and so
/// do Quick Look's panel, drag-out, and drop-in, which the Dart side leaves
/// out for it.
final class WorkspaceWindowsHost: NSObject, NSWindowDelegate {
  private static let channelName = "poltergeist/windows"

  /// The workspace's minimum content size (`_minimumContentSize` in
  /// lib/services/desktop_window_lifecycle.dart), which window_manager
  /// applies to the main window.
  private static let minimumContentSize = NSSize(width: 720, height: 480)
  private static let defaultContentSize = NSSize(width: 1180, height: 760)

  /// How far a new window sits from the one it opens over.
  private static let cascadeOffset: CGFloat = 24

  /// The engine's implicit view: the main window.
  private static let mainViewId: Int64 = 0

  private weak var mainWindow: NSWindow?
  private let engine: FlutterEngine
  private let channel: FlutterMethodChannel
  private let available: Bool

  /// The extra windows by view id. Each owns its controller as its
  /// content view controller.
  private var windows: [Int64: NSWindow] = [:]

  init(mainWindow: NSWindow, engine: FlutterEngine) {
    self.mainWindow = mainWindow
    self.engine = engine
    channel = FlutterMethodChannel(
      name: Self.channelName, binaryMessenger: engine.binaryMessenger)
    available = PoltergeistEnableMultiView(engine)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    // Every key window change, the main window's included: its delegate is
    // window_manager's, so a notification rather than a delegate method.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyWindowChanged(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil)
  }

  /// Closes every extra window for good. The main window calls this as it
  /// closes, so the app still quits with its last window.
  func closeAll() {
    for window in Array(windows.values) {
      window.close()
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(available)
    case "create":
      create(result: result)
    case "destroy", "activate", "hide", "isFullScreen", "setFullScreen":
      let arguments = call.arguments as? [String: Any]
      guard let viewId = (arguments?["viewId"] as? NSNumber)?.int64Value,
        let window = window(for: viewId)
      else {
        result(FlutterError(
          code: "BAD_ARGS", message: "no window has that view id", details: nil))
        return
      }
      switch call.method {
      case "destroy":
        // The main window's view cannot leave the engine; window_manager
        // closes that window, as the app quits. A programmatic close does
        // not ask windowShouldClose.
        if window !== mainWindow {
          window.close()
        }
      case "activate":
        // Shows it again if it was hidden, and makes it key either way.
        window.makeKeyAndOrderFront(nil)
      case "hide":
        window.orderOut(nil)
      case "isFullScreen":
        result(window.styleMask.contains(.fullScreen))
        return
      default:
        guard let fullScreen = arguments?["fullScreen"] as? Bool else {
          result(FlutterError(
            code: "BAD_ARGS", message: "setFullScreen needs a fullScreen bool",
            details: nil))
          return
        }
        if window.styleMask.contains(.fullScreen) != fullScreen {
          window.toggleFullScreen(nil)
        }
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func create(result: FlutterResult) {
    guard available else {
      result(FlutterError(
        code: "CREATE_FAILED", message: "this engine takes no more views",
        details: nil))
      return
    }
    // The same subclass as the main window's, for the same reason: closing
    // a window tears its controller down, which is what the accessibility
    // guard exists for (docs/macos-accessibility-crash.md in Séance).
    let controller = PoltergeistFlutterViewController(
      engine: engine, nibName: nil, bundle: nil)
    let viewId = controller.viewIdentifier

    // The size and place of the window it opens over.
    let reference = workspaceWindow(NSApp.keyWindow) ?? mainWindow
    let contentSize =
      reference.map { $0.contentRect(forFrameRect: $0.frame).size }
      ?? Self.defaultContentSize

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "Poltergeist"
    // Poltergeist has its own per-pane tabs (02 §9), as MainFlutterWindow
    // says: no window tabs.
    window.tabbingMode = .disallowed
    window.contentViewController = controller
    window.setContentSize(contentSize)
    window.contentMinSize = Self.minimumContentSize
    // Owned by `windows`; released on close, which removes its view.
    window.isReleasedWhenClosed = false
    window.delegate = self
    if let reference {
      window.setFrameTopLeftPoint(NSPoint(
        x: reference.frame.minX + Self.cascadeOffset,
        y: reference.frame.maxY - Self.cascadeOffset))
    } else {
      window.center()
    }
    windows[viewId] = window
    window.makeKeyAndOrderFront(nil)
    result(NSNumber(value: viewId))
  }

  private func window(for viewId: Int64) -> NSWindow? {
    viewId == Self.mainViewId ? mainWindow : windows[viewId]
  }

  private func viewId(of window: NSWindow) -> Int64? {
    if window === mainWindow {
      return Self.mainViewId
    }
    return windows.first { $0.value === window }?.key
  }

  /// [window] when it is one of the workspace windows (not Settings, not a
  /// panel).
  private func workspaceWindow(_ window: NSWindow?) -> NSWindow? {
    guard let window, viewId(of: window) != nil else { return nil }
    return window
  }

  @objc private func keyWindowChanged(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      let viewId = viewId(of: window)
    else { return }
    channel.invokeMethod("activated", arguments: ["viewId": NSNumber(value: viewId)])
  }

  /// The close button, ⌘W from the system menu, File ▸ Close: Dart decides,
  /// and destroys the window once its widgets are gone (or quits, for the
  /// last window). A programmatic `close()` does not ask.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let viewId = viewId(of: sender), sender !== mainWindow else {
      return true
    }
    channel.invokeMethod(
      "closeRequested", arguments: ["viewId": NSNumber(value: viewId)])
    return false
  }

  func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow,
      closing !== mainWindow,
      let viewId = viewId(of: closing)
    else { return }
    windows[viewId] = nil
    closing.delegate = nil
    // Released after AppKit has finished closing it rather than from inside
    // its own close, as the Settings window does: that drops the last
    // reference to the controller, whose dealloc invalidates its text
    // fields and removes its view from the engine.
    DispatchQueue.main.async {
      closing.contentViewController = nil
    }
  }
}
