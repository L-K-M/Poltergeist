import Cocoa
import FlutterMacOS
import Quartz
import macos_window_utils

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

class MainFlutterWindow: NSWindow {
  private var trashChannel: FlutterMethodChannel?
  private var filesChannel: FlutterMethodChannel?
  private var quickLookChannel: FlutterMethodChannel?
  private var dragOutChannel: DragOutChannel?

  /// The panel's current item set — only ever produced LOCAL paths
  /// (remote previews are materialized into the §5.3 cache first).
  fileprivate var quickLookItems: [QuickLookPreviewItem] = []
  fileprivate var quickLookIndex = 0

  override func awakeFromNib() {
    // Poltergeist has its own per-pane tab model (02 §9): the system must
    // never offer window tabs alongside it — automatic for all windows,
    // and disallowed for this window even when triggered explicitly.
    NSWindow.allowsAutomaticWindowTabbing = false
    tabbingMode = .disallowed

    let windowFrame = self.frame
    // The accessibility-lifecycle guard (ported from Séance; see
    // PoltergeistFlutterViewController.m): Flutter 3.47 destroys the
    // accessibility tree before detaching native text fields, which can
    // crash text input while any accessibility client (VoiceOver, window
    // managers, writing tools) is active.
    let macOSWindowUtilsViewController = MacOSWindowUtilsViewController(
      flutterViewController: PoltergeistFlutterViewController()
    )
    self.contentViewController = macOSWindowUtilsViewController
    self.setFrame(windowFrame, display: true)

    MainFlutterWindowManipulator.start(mainFlutterWindow: self)
    RegisterGeneratedPlugins(
      registry: macOSWindowUtilsViewController.flutterViewController
    )

    // D15 trash (03 §7.1): FileManager.trashItem delivers to the OS
    // Trash and returns the trashed URL — the Put Back anchor. Put Back
    // itself is Finder's best-effort behavior, not ours. The call runs
    // off the platform thread so a large trash cannot stall the UI;
    // FlutterResult is safe to invoke from any thread.
    trashChannel = FlutterMethodChannel(
      name: "poltergeist/trash",
      binaryMessenger: macOSWindowUtilsViewController.flutterViewController.engine.binaryMessenger
    )
    trashChannel?.setMethodCallHandler { call, result in
      guard call.method == "trash" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String,
            !path.isEmpty else {
        result(FlutterError(
          code: "TRASH_BAD_ARGS",
          message: "the trash call needs a 'path' string argument",
          details: nil
        ))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        var trashedUrl: NSURL?
        do {
          try FileManager.default.trashItem(
            at: URL(fileURLWithPath: path),
            resultingItemURL: &trashedUrl
          )
          if let trashedPath = trashedUrl?.path {
            result(["trashedPath": trashedPath])
          } else {
            result(nil)
          }
        } catch {
          result(FlutterError(
            code: "TRASH_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }

    // External editors (06 §4.3): the ported seance/files channel —
    // pickApplication (NSOpenPanel rooted at /Applications; the panel
    // navigates freely, so /System/Applications and ~/Applications stay
    // selectable) and openWithApplication (NSWorkspace.open by bundle
    // id). Results marshal on the main queue; errors surface as
    // FlutterError.
    filesChannel = FlutterMethodChannel(
      name: "poltergeist/files",
      binaryMessenger: macOSWindowUtilsViewController.flutterViewController.engine.binaryMessenger
    )
    filesChannel?.setMethodCallHandler { call, result in
      if call.method == "pickApplication" {
        let panel = NSOpenPanel()
        panel.title =
          (call.arguments as? [String: Any])?["title"] as? String
            ?? "Choose an editor application"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        // .applicationBundle is the non-deprecated equivalent of the
        // legacy allowedFileTypes = ["app"] filter.
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
          guard response == .OK, let url = panel.url else {
            result(nil)
            return
          }
          guard let bundle = Bundle(url: url),
                let bundleIdentifier = bundle.bundleIdentifier else {
            result(FlutterError(
              code: "INVALID_APPLICATION",
              message: "The selected item is not an application bundle.",
              details: nil))
            return
          }
          let info = bundle.infoDictionary
          let displayName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
          result([
            "displayName": displayName,
            "bundleIdentifier": bundleIdentifier,
          ])
        }
        return
      }
      guard call.method == "openWithApplication" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // Malformed args are a wiring bug on the Dart side — report them
      // as such rather than looking like an unregistered handler.
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String,
            let bundleIdentifier = arguments["bundleIdentifier"] as? String else {
        result(FlutterError(
          code: "INVALID_ARGUMENTS",
          message: "openWithApplication requires 'path' and 'bundleIdentifier'.",
          details: nil))
        return
      }
      guard let application = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleIdentifier) else {
        result(FlutterError(
          code: "APPLICATION_NOT_FOUND",
          message: "The configured editor application is not installed.",
          details: nil))
        return
      }
      NSWorkspace.shared.open(
        [URL(fileURLWithPath: path)],
        withApplicationAt: application,
        configuration: NSWorkspace.OpenConfiguration()) { _, error in
          if let error = error {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "OPEN_FAILED",
                message: error.localizedDescription,
                details: nil))
            }
          } else {
            DispatchQueue.main.async { result(nil) }
          }
        }
    }

    // Quick Look (06 §5.1): `poltergeist/quicklook` drives
    // QLPreviewPanel — show/update/hide/isVisible plus the `closed`
    // edge the Dart session listens for (the panel can close itself
    // on Esc, the ✕, or focus loss; every route must notify).
    quickLookChannel = FlutterMethodChannel(
      name: "poltergeist/quicklook",
      binaryMessenger: macOSWindowUtilsViewController.flutterViewController.engine.binaryMessenger
    )
    quickLookChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "isAvailable":
        result(true)
      case "isVisible":
        result(QLPreviewPanel.sharedPreviewPanelExists()
          && (QLPreviewPanel.shared()?.isVisible ?? false))
      case "showPreview", "updatePreview":
        guard let arguments = call.arguments as? [String: Any],
              let paths = arguments["paths"] as? [String],
              let index = arguments["index"] as? Int,
              !paths.isEmpty else {
          result(FlutterError(
            code: "QL_BAD_ARGS",
            message: "showPreview/updatePreview need 'paths' and 'index'.",
            details: nil))
          return
        }
        self.quickLookItems = paths.map { QuickLookPreviewItem(path: $0) }
        self.quickLookIndex = max(0, min(index, paths.count - 1))
        self.presentQuickLook()
        result(nil)
      case "hidePreview":
        if QLPreviewPanel.sharedPreviewPanelExists() {
          QLPreviewPanel.shared()?.orderOut(nil)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // OS drag-out (00 D14's 2026-09-25 amendment): `poltergeist/dragout`
    // hands a pane row drag that left the window to an AppKit dragging
    // session (local file URLs, remote file promises). See
    // DragOutChannel.swift.
    dragOutChannel = DragOutChannel(
      flutterViewController: macOSWindowUtilsViewController.flutterViewController
    )

    super.awakeFromNib()
  }

  /// Orders the panel front over this window, or re-keys the visible
  /// one to the current item set. Ordering front is what makes the
  /// panel query the responder chain — our `acceptsPreviewPanelControl`
  /// below hands it this window as its controller.
  private func presentQuickLook() {
    guard let panel = QLPreviewPanel.shared() else { return }
    if panel.isVisible {
      panel.dataSource = self
      panel.delegate = self
      panel.reloadData()
      panel.currentPreviewItemIndex = quickLookIndex
      panel.refreshCurrentPreviewItem()
    } else {
      // beginPreviewPanelControl sets the data source; the index lands
      // once the panel exists.
      panel.makeKeyAndOrderFront(nil)
      panel.currentPreviewItemIndex = quickLookIndex
    }
  }

  // -- QLPreviewPanel control (03 §7.1's channel surface) -------------

  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    true
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    panel.currentPreviewItemIndex = quickLookIndex
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
    panel.delegate = nil
    // Every close route funnels here — the session drops its
    // quickLookActive state on this edge (06 §5.1).
    quickLookChannel?.invokeMethod("closed", arguments: nil)
  }
}

extension MainFlutterWindow: QLPreviewPanelDataSource {
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    quickLookItems.count
  }

  func previewPanel(
    _ panel: QLPreviewPanel!,
    previewItemAt index: Int
  ) -> QLPreviewItem! {
    quickLookItems[index]
  }
}

extension MainFlutterWindow: QLPreviewPanelDelegate {
  /// The ✕ / Esc close on the panel itself — the `closed` edge rides
  /// endPreviewPanelControl, so this only lets the close proceed.
  func windowShouldClose(_ sender: NSWindow!) -> Bool {
    true
  }
}
