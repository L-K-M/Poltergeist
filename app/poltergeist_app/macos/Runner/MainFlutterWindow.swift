import Cocoa
import FlutterMacOS
import macos_window_utils

class MainFlutterWindow: NSWindow {
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

    super.awakeFromNib()
  }
}
