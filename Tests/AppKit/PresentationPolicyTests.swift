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
}
