import AppKit
import JortToolContracts
import XCTest
@testable import JortAppKit

@MainActor final class ToolArgumentFormTests: ToolInvocationTestCase {
  func testKeyboardTraversalAndEscapePreserveArguments() throws {
    let form = ToolArgumentFormView(
      definitions: [
        ToolArgumentDefinition(
          name: "separator", type: .string, label: "Separator", required: true),
        ToolArgumentDefinition(name: "label", type: .string, label: "Label"),
      ], values: ["separator": "\" · \""], description: "Join lines")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    defer {
      window.close()
      window.contentView = nil
    }
    window.contentView = form
    window.makeKeyAndOrderFront(nil)
    form.focusFirst()
    let first = form.fields[0].field
    let second = form.fields[1].field
    XCTAssertEqual(first.stringValue, "\" · \"")
    XCTAssertTrue(first.nextKeyView === second)
    XCTAssertEqual(first.accessibilityLabel(), "Separator")
    var returned = false
    form.returnToEditor = { returned = true }
    let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertTrue(
      form.control(
        first, textView: fieldEditor,
        doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertTrue(returned)
    XCTAssertEqual(first.stringValue, "\" · \"")
  }

  func testArgumentEditsAreReportedWithoutDocumentMutation() {
    let form = ToolArgumentFormView(
      definitions: [ToolArgumentDefinition(name: "minutes", type: .integer, label: "Minutes")],
      values: [:], description: "Schedule reminder")
    var values: [String: String] = [:]
    form.changed = { values[$0] = $1 }
    let field = form.fields[0].field
    field.stringValue = "20"
    form.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: field))
    XCTAssertEqual(values, ["minutes": "20"])
  }

  func testEveryFieldCanBeRevealedInAShortWindow() throws {
    let definitions = (0..<16).map { index in
      ToolArgumentDefinition(name: "argument\(index)", type: .string, label: "Argument \(index)")
    }
    let form = ToolArgumentFormView(definitions: definitions, values: [:], description: "Options")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    defer {
      window.close()
      window.contentView = nil
    }
    window.contentView = form
    window.makeKeyAndOrderFront(nil)
    form.layoutSubtreeIfNeeded()
    let last = try XCTUnwrap(form.fields.last?.field)
    form.focusArgument(named: "argument15")
    XCTAssertTrue(last.currentEditor() === window.firstResponder)
    XCTAssertGreaterThan(last.visibleRect.height, 0)
    form.focusFirst()
    XCTAssertGreaterThan(form.fields[0].field.visibleRect.height, 0)
  }
}
