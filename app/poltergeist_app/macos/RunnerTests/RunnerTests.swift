import Cocoa
import FlutterMacOS
import XCTest
@testable import Poltergeist

class RunnerTests: XCTestCase {

  func testMenuChecksUseIDsAndLeaveOtherItemsUntouched() {
    let menu = NSMenu()
    let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    view.submenu = submenu
    menu.addItem(view)
    let hidden = NSMenuItem(title: "Hidden", action: nil, keyEquivalent: ".")
    hidden.tag = 17
    submenu.addItem(hidden)
    let provided = NSMenuItem(title: "Full Screen", action: nil, keyEquivalent: "")
    provided.tag = 18
    provided.state = .on
    submenu.addItem(provided)

    MenuChecks.apply(["17": true], to: menu)
    XCTAssertEqual(hidden.state, .on)
    XCTAssertEqual(provided.state, .on)
    MenuChecks.apply(["17": false], to: menu)
    XCTAssertEqual(hidden.state, .off)
    XCTAssertEqual(provided.state, .on)

    // Delayed state for a replaced menu cannot change the current menu.
    MenuChecks.apply(["9": true], to: menu)
    XCTAssertEqual(hidden.state, .off)
    XCTAssertEqual(provided.state, .on)
  }

}
