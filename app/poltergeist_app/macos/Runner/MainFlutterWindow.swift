import Cocoa
import FlutterMacOS
import macos_window_utils

class MainFlutterWindow: NSWindow {
  private var trashChannel: FlutterMethodChannel?
  private var filesChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    // Poltergeist has its own per-pane tab model (02 §9): the system must
    // never offer window tabs alongside it — automatic for all windows,
    // and disallowed for this window even when triggered explicitly.
    NSWindow.allowsAutomaticWindowTabbing = false
    tabbingMode = .disallowed

    let windowFrame = self.frame
    let macOSWindowUtilsViewController = MacOSWindowUtilsViewController()
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
      guard call.method == "openWithApplication",
            let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String,
            let bundleIdentifier = arguments["bundleIdentifier"] as? String else {
        result(FlutterMethodNotImplemented)
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

    super.awakeFromNib()
  }
}
