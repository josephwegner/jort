import AppKit
import XCTest
@testable import JortAppKit

@MainActor final class PresentationPolicyTests: XCTestCase {
  func testApplicationThemeIsInheritedByIndependentWindowsAndPrompts() {
    ApplicationTheme.install()
    let windows = (0..<2).map { _ in
      NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
    }
    for window in windows {
      window.isReleasedWhenClosed = false
      window.animationBehavior = .none
      let prompt = ToolPromptView()
      window.contentView?.addSubview(prompt)
      XCTAssertNil(window.appearance)
      XCTAssertNil(prompt.appearance)
      XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
      XCTAssertEqual(prompt.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
      window.orderOut(nil)
    }
  }
  func testMissingLocalizationHasUsefulLocaleIndependentFallback() {
    XCTAssertEqual(
      LocalizedCopy.text("test.missing", fallback: "Readable fallback"), "Readable fallback")
    XCTAssertEqual(LocalizedCopy.text("InvocationViews.run", fallback: "Run"), "Run")
  }

  func testSingleLinePromptErrorKeepsInputAboveRunControls() throws {
    let prompt = ToolPromptView()
    prompt.multiline = false
    prompt.setError("Tool service is unavailable.")
    XCTAssertEqual(prompt.preferredHeight, 106)
    prompt.frame = NSRect(x: 0, y: 0, width: 320, height: prompt.preferredHeight)
    prompt.layoutSubtreeIfNeeded()

    let scroll = try XCTUnwrap(prompt.subviews.compactMap { $0 as? NSScrollView }.first)
    let buttons = prompt.subviews.compactMap { $0 as? ToolActionButton }
    XCTAssertEqual(buttons.count, 2)
    XCTAssertLessThan(scroll.frame.maxY, try XCTUnwrap(buttons.map(\.frame.minY).min()))
    XCTAssertEqual(prompt.input.string, "")
  }
}
