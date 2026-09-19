import XCTest
import AppKit
import Darwin
import JortDocument
import JortPersistence
@testable import JortAppKit

@MainActor class EditorTestCase: StoreTestCase {
  func editor(waitForStartup: Bool = true) throws -> (EditorViewController, NSWindow) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorTest-\(UUID())")
    removeAfterStoresClose(root)
    let controller = EditorViewController(persistence: ownPersistence(directory: root))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    addTeardownBlock { @MainActor in
      window.close()
      window.contentViewController = nil
    }
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 600, height: 400))
    window.makeKeyAndOrderFront(nil)
    if waitForStartup {
      let loaded = expectation(
        for: NSPredicate { _, _ in controller.startupPhase == .ready }, evaluatedWith: nil)
      wait(for: [loaded], timeout: 5)
    }
    XCTAssertTrue(controller.textView.isEditable)
    XCTAssertTrue(controller.textView.isSelectable)
    XCTAssertTrue(controller.textView.acceptsFirstResponder)
    window.makeFirstResponder(controller.textView)
    XCTAssertTrue(window.firstResponder === controller.textView)
    controller.textView.history.groupsByEvent = false
    return (controller, window)
  }
  func insert(_ text: String, range: NSRange, into controller: EditorViewController) {
    controller.textView.history.beginUndoGrouping()
    controller.textView.insertText(text, replacementRange: range)
    controller.textView.history.endUndoGrouping()
  }
}
