import Cocoa
import FlutterMacOS
import macos_window_utils

class MainFlutterWindow: NSWindow {
  private var trashChannel: FlutterMethodChannel?

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

    super.awakeFromNib()
  }
}
