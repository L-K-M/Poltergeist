import Cocoa
import FlutterMacOS
import Quartz

/// The workspace windows' host (00 D39): serves `poltergeist/windows` on the
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
/// An extra window gets from here what the main window gets from its
/// plugins: the unified toolbar band the header draws under, with clicks
/// over the header's controls passed through to Flutter
/// (`poltergeist/titlebar`, lib/services/workspace_windows/window_titlebar.dart;
/// macos_window_utils serves the main window), drops from other apps
/// (DropInView; desktop_drop serves the main window), drags out
/// (DragOutChannel, which asks here for the window's controller), and
/// control of the Quick Look panel (QuickLookHost).
final class WorkspaceWindowsHost: NSObject, NSWindowDelegate {
  private static let channelName = "poltergeist/windows"
  private static let titlebarChannelName = "poltergeist/titlebar"
  private static let dropInChannelName = "poltergeist/dropin"

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
  private let titlebarChannel: FlutterMethodChannel
  /// Only reports: nothing calls in.
  private let dropInChannel: FlutterMethodChannel
  private weak var quickLook: QuickLookHost?
  private let available: Bool

  /// The extra windows by view id. Each owns its controller as its
  /// content view controller.
  private var windows: [Int64: WorkspaceWindow] = [:]

  init(
    mainWindow: NSWindow,
    engine: FlutterEngine,
    quickLook: QuickLookHost?,
    dragOut: DragOutChannel?
  ) {
    self.mainWindow = mainWindow
    self.engine = engine
    self.quickLook = quickLook
    channel = FlutterMethodChannel(
      name: Self.channelName, binaryMessenger: engine.binaryMessenger)
    titlebarChannel = FlutterMethodChannel(
      name: Self.titlebarChannelName, binaryMessenger: engine.binaryMessenger)
    dropInChannel = FlutterMethodChannel(
      name: Self.dropInChannelName, binaryMessenger: engine.binaryMessenger)
    available = PoltergeistEnableMultiView(engine)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    titlebarChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handleTitlebar(call, result: result)
    }
    dragOut?.controllerForView = { [weak self] viewId in
      self?.windows[viewId]?.contentViewController as? FlutterViewController
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

    let window = WorkspaceWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    window.title = "Poltergeist"
    // Poltergeist has its own per-pane tabs (02 §9), as MainFlutterWindow
    // says: no window tabs.
    window.tabbingMode = .disallowed
    window.viewId = viewId
    window.quickLook = quickLook
    window.titlebarChannel = titlebarChannel
    window.installToolbarBand()
    window.contentViewController = controller
    // Over the Flutter view, as desktop_drop lays its overlay over the
    // main window's.
    controller.view.addSubview(DropInView(
      frame: controller.view.bounds, channel: dropInChannel, viewId: viewId))
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

  /// `poltergeist/titlebar`: an extra window's toolbar band and the
  /// passthrough rectangles over its header's controls.
  private func handleTitlebar(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    guard let viewId = (arguments?["viewId"] as? NSNumber)?.int64Value,
      let window = windows[viewId]
    else {
      result(FlutterError(
        code: "BAD_ARGS", message: "no extra window has that view id", details: nil))
      return
    }
    switch call.method {
    case "isToolbarBandVisible":
      result(!window.inFullScreen)
    case "updatePassthrough":
      guard let id = arguments?["id"] as? String,
        let x = (arguments?["x"] as? NSNumber)?.doubleValue,
        let y = (arguments?["y"] as? NSNumber)?.doubleValue,
        let width = (arguments?["width"] as? NSNumber)?.doubleValue,
        let height = (arguments?["height"] as? NSNumber)?.doubleValue
      else {
        result(FlutterError(
          code: "BAD_ARGS", message: "updatePassthrough needs an id and a rectangle",
          details: nil))
        return
      }
      window.setPassthrough(id: id, rect: NSRect(x: x, y: y, width: width, height: height))
      result(nil)
    case "removePassthrough":
      guard let id = arguments?["id"] as? String else {
        result(FlutterError(
          code: "BAD_ARGS", message: "removePassthrough needs an id", details: nil))
        return
      }
      window.removePassthrough(id: id)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func window(for viewId: Int64) -> NSWindow? {
    viewId == Self.mainViewId ? mainWindow : windows[viewId] as NSWindow?
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

/// An extra workspace window: the main window's titlebar geometry and
/// Quick Look control, served for it here rather than by the plugins that
/// only know the main window.
final class WorkspaceWindow: NSWindow {
  var viewId: Int64 = 0
  weak var quickLook: QuickLookHost?
  var titlebarChannel: FlutterMethodChannel?

  /// In full screen, or entering it: set on AppKit's will-enter and
  /// will-exit edges, as MainFlutterWindow does, so the toolbar and the
  /// Flutter layout switch as a transition starts.
  private(set) var inFullScreen = false

  /// The rectangles whose clicks go to Flutter, by the id Dart gave them.
  private var passthroughs: [String: TitlebarPassthroughView] = [:]
  private var passthroughContainer: NSView?

  /// A toolbar set later takes the current visibility too.
  override var toolbar: NSToolbar? {
    didSet { toolbar?.isVisible = !inFullScreen }
  }

  /// The main window's titlebar (D32 §3, set up for it by
  /// desktop_window_lifecycle.dart through macos_window_utils): a
  /// transparent titlebar over the full-size content, no title, and an
  /// empty unified toolbar that makes the band 52 pt tall, so the traffic
  /// lights sit centered on the header Flutter draws beneath.
  func installToolbarBand() {
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    let band = NSToolbar(identifier: "PoltergeistWorkspaceToolbar")
    band.allowsUserCustomization = false
    band.allowsExtensionItems = false
    toolbar = band
    toolbarStyle = .unified
    NotificationCenter.default.addObserver(
      self, selector: #selector(willEnterFullScreen(_:)),
      name: NSWindow.willEnterFullScreenNotification, object: self)
    NotificationCenter.default.addObserver(
      self, selector: #selector(willExitFullScreen(_:)),
      name: NSWindow.willExitFullScreenNotification, object: self)
  }

  @objc private func willEnterFullScreen(_ notification: Notification) {
    setInFullScreen(true)
  }

  @objc private func willExitFullScreen(_ notification: Notification) {
    setInFullScreen(false)
  }

  /// In full screen AppKit keeps a toolbar visible in an opaque strip of
  /// its own above the content, which would cover the header: the band
  /// hides for the duration, and Dart drops its reservation.
  private func setInFullScreen(_ value: Bool) {
    guard value != inFullScreen else { return }
    inFullScreen = value
    toolbar?.isVisible = !value
    titlebarChannel?.invokeMethod(
      "toolbarBandChanged",
      arguments: ["viewId": NSNumber(value: viewId), "visible": !value])
  }

  /// Hands clicks in [rect] (the view's logical pixels, top-left origin)
  /// to Flutter. The band claims clicks for window drag and double-click
  /// zoom; these rectangles sit over the header's controls.
  func setPassthrough(id: String, rect: NSRect) {
    let container = passthroughContainer ?? makePassthroughContainer()
    let flipped = NSRect(
      x: rect.minX, y: frame.height - rect.minY - rect.height,
      width: rect.width, height: rect.height)
    let local = container.convert(flipped, from: nil)
    if let view = passthroughs[id] {
      view.frame = local
      return
    }
    let view = TitlebarPassthroughView(frame: local)
    container.addSubview(view)
    passthroughs[id] = view
  }

  func removePassthrough(id: String) {
    passthroughs.removeValue(forKey: id)?.removeFromSuperview()
  }

  /// A titlebar accessory the size of the band, which the passthrough
  /// views sit in: above the toolbar, so they get the clicks first.
  private func makePassthroughContainer() -> NSView {
    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .top
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    accessory.view = container
    addTitlebarAccessoryViewController(accessory)
    passthroughContainer = container
    return container
  }

  // -- QLPreviewPanel control: the one panel's host (QuickLookHost) ----

  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    quickLook?.acceptsControl(panel) ?? false
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    quickLook?.beginControl(panel)
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    quickLook?.endControl(panel)
  }
}

/// A rectangle of the toolbar band whose clicks go to the window's Flutter
/// view rather than to the titlebar, as macos_window_utils' passthrough
/// views do for the main window.
private final class TitlebarPassthroughView: NSView {
  private var flutter: FlutterViewController? {
    window?.contentViewController as? FlutterViewController
  }

  override func mouseDown(with event: NSEvent) {
    // A transparent titlebar ignores mouseDownCanMoveWindow, so the window
    // stays put for the click by being unmovable for its length.
    guard let window else { return }
    let movable = window.isMovable
    window.isMovable = false
    defer { window.isMovable = movable }
    flutter?.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    flutter?.mouseUp(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    flutter?.mouseDragged(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    flutter?.rightMouseDown(with: event)
  }

  override func rightMouseUp(with event: NSEvent) {
    flutter?.rightMouseUp(with: event)
  }

  override var mouseDownCanMoveWindow: Bool {
    false
  }
}
