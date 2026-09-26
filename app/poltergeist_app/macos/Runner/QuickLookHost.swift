import Cocoa
import FlutterMacOS
import Quartz

/// One produced local path handed to QLPreviewPanel (06 §5.1) — the
/// session only ever passes preview-cache hits or pane-local files.
private final class QuickLookPreviewItem: NSObject, QLPreviewItem {
  let previewItemURL: URL?
  let previewItemTitle: String?

  init(path: String) {
    previewItemURL = URL(fileURLWithPath: path)
    previewItemTitle = URL(fileURLWithPath: path).lastPathComponent
  }
}

/// Quick Look (06 §5.1) for every workspace window (00 D39):
/// `poltergeist/quicklook` drives the app's one QLPreviewPanel —
/// show/update/hide/isVisible plus the `closed` edge the Dart session
/// listens for (the panel can close itself on Esc, the ✕, or focus loss;
/// every route must notify). The protocol is the doc of
/// `MethodChannelQuickLook` in lib/services/quick_look_channel.dart.
///
/// The panel asks the key window's responder chain for a controller, so
/// every workspace window answers `acceptsPreviewPanelControl` and hands
/// the panel to this host: the main window (MainFlutterWindow) and each
/// extra one (WorkspaceWindow in WorkspaceWindows.swift). Whichever
/// window's session last showed something owns the panel; the items are
/// its, whichever workspace window is key.
final class QuickLookHost: NSObject {
  private static let channelName = "poltergeist/quicklook"

  private let channel: FlutterMethodChannel

  /// The panel's current item set — only ever produced LOCAL paths
  /// (remote previews are materialized into the §5.3 cache first).
  private var items: [QuickLookPreviewItem] = []
  private var index = 0

  /// The view whose session owns the panel: it last showed something.
  private var owner: Int64?

  /// Whether a workspace window controls the panel. The panel moves from
  /// one to the next as the key window changes, ending the old control
  /// before beginning the new; a control that ended with no other begun
  /// by the next turn of the run loop means the panel closed.
  private var controlled = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    // A caller that names no view is the main window's, as before there
    // were windows.
    let viewId = (arguments?["viewId"] as? NSNumber)?.int64Value ?? 0
    switch call.method {
    case "isAvailable":
      result(true)
    case "isVisible":
      result(owner == viewId && QLPreviewPanel.sharedPreviewPanelExists()
        && (QLPreviewPanel.shared()?.isVisible ?? false))
    case "showPreview", "updatePreview":
      guard let paths = arguments?["paths"] as? [String],
            let index = arguments?["index"] as? Int,
            !paths.isEmpty else {
        result(FlutterError(
          code: "QL_BAD_ARGS",
          message: "showPreview/updatePreview need 'paths' and 'index'.",
          details: nil))
        return
      }
      // Another window's session had the panel: it has it no longer.
      if let previous = owner, previous != viewId {
        sendClosed(previous)
      }
      owner = viewId
      items = paths.map { QuickLookPreviewItem(path: $0) }
      self.index = max(0, min(index, paths.count - 1))
      present()
      result(nil)
    case "hidePreview":
      // Only the owner closes the panel: another window's Esc must not
      // close what this one shows.
      if owner == viewId, QLPreviewPanel.sharedPreviewPanelExists() {
        QLPreviewPanel.shared()?.orderOut(nil)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func sendClosed(_ viewId: Int64) {
    channel.invokeMethod("closed", arguments: ["viewId": NSNumber(value: viewId)])
  }

  /// Orders the panel front over the key window, or re-keys the visible
  /// one to the current item set. Ordering front is what makes the panel
  /// query the responder chain, where a workspace window hands it this
  /// host.
  private func present() {
    guard let panel = QLPreviewPanel.shared() else { return }
    if panel.isVisible {
      panel.dataSource = self
      panel.delegate = self
      panel.reloadData()
      panel.currentPreviewItemIndex = index
      panel.refreshCurrentPreviewItem()
    } else {
      // beginControl sets the data source; the index lands once the panel
      // exists.
      panel.makeKeyAndOrderFront(nil)
      panel.currentPreviewItemIndex = index
    }
  }

  // -- QLPreviewPanel control, for the workspace windows to forward ----

  func acceptsControl(_ panel: QLPreviewPanel!) -> Bool {
    true
  }

  func beginControl(_ panel: QLPreviewPanel!) {
    controlled = true
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    panel.currentPreviewItemIndex = index
  }

  func endControl(_ panel: QLPreviewPanel!) {
    controlled = false
    panel.dataSource = nil
    panel.delegate = nil
    // Every close route funnels here — the session drops its
    // quickLookActive state on this edge (06 §5.1) — and so does the key
    // window moving between two workspace windows, which begins another
    // control at once.
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.controlled, let owner = self.owner else { return }
      self.owner = nil
      self.sendClosed(owner)
    }
  }
}

extension QuickLookHost: QLPreviewPanelDataSource {
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    items.count
  }

  func previewPanel(
    _ panel: QLPreviewPanel!,
    previewItemAt index: Int
  ) -> QLPreviewItem! {
    items[index]
  }
}

extension QuickLookHost: QLPreviewPanelDelegate {
  /// The ✕ / Esc close on the panel itself — the `closed` edge rides
  /// endControl, so this only lets the close proceed.
  func windowShouldClose(_ sender: NSWindow!) -> Bool {
    true
  }
}
