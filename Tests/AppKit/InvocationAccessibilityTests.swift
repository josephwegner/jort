import JortToolRuntime
import JortToolContracts
import XCTest
import AppKit
import JortDocument
import JortPersistence
import JortSettings
@testable import JortAppKit

@MainActor final class InvocationAccessibilityTests: ToolInvocationTestCase {
  func testAccessiblePendingButtonsOverrideTextViewCursor() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText("/calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: true)
    await settlePresentationAsync(editor)
    editor.toolController.submit(editor.state.invocations[0].id)
    try await pending(editor)
    editor.textView.resetCursorRects()
    for label in ["Merge", "Dismiss"] {
      let button = try XCTUnwrap(
        editor.textView.subviews.compactMap { $0 as? NSButton }.first {
          $0.accessibilityLabel() == label
        })
      XCTAssertEqual(button.accessibilityRole(), .button)
      XCTAssertTrue(button.isEnabled)
      let point = editor.textView.convert(
        NSPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
      let event = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
          pressure: 0))
      NSCursor.iBeam.set()
      editor.textView.mouseMoved(with: event)
      XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
    }
    let dismiss = try XCTUnwrap(
      editor.textView.subviews.compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "Dismiss"
      })
    XCTAssertTrue(dismiss.accessibilityPerformPress())
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
  }

  func testEphemeralOverlayWinsHitTestingOverRebuiltPendingActions() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let calc = package("calc"), write = package("write", mode: .ephemeralMultiline)
    editor.toolPackages = [calc, write]
    editor.textView.insertText(
      String(repeating: "\n", count: 8) + "/calc\n\n\n/write",
      replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(
      calc, token: (editor.state.text as NSString).range(of: "/calc"), space: true)
    await settlePresentationAsync(editor)
    editor.toolController.submit(editor.state.invocations[0].id)
    try await pending(editor)
    try editor.toolController.accept(
      write, token: (editor.state.text as NSString).range(of: "/write"), space: true)
    await settlePresentationAsync(editor)
    // Rebuild inline controls while preserving the existing prompt.
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let prompt = try XCTUnwrap(
      editor.view.subviews.first { $0.accessibilityLabel() == "Tool prompt form" })
    let merge = try XCTUnwrap(editor.textView.subviews.first { $0.accessibilityLabel() == "Merge" })
    let frame = editor.view.convert(merge.frame, from: editor.textView)
    let point = NSPoint(x: frame.midX, y: frame.midY)
    XCTAssertTrue(
      prompt.frame.contains(point), "Fixture must place the pending control underneath the prompt")
    let hit = try XCTUnwrap(editor.view.hitTest(point))
    XCTAssertTrue(hit === prompt || hit.isDescendant(of: prompt))
    let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
    editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: "/private/tmp/jort-feedback5-overlay.png"))
  }

  func testEphemeralPromptFlipsAboveBottomAnchor() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("write", mode: .ephemeralMultiline)
    editor.toolPackages = [tool]
    editor.textView.insertText(
      String(repeating: "line\n", count: 12) + "/write",
      replacementRange: NSRange(location: 0, length: 0))
    let token = (editor.state.text as NSString).range(of: "/write")
    try editor.toolController.accept(tool, token: token, space: true)
    await settlePresentationAsync(editor)
    editor.textView.scrollRangeToVisible(token)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let prompt = try XCTUnwrap(
      editor.view.subviews.first { $0.accessibilityLabel() == "Tool prompt form" })
    let anchor = try XCTUnwrap(editor.toolPresentation.geometry(for: token).first)
    let documentFrame = editor.textView.convert(prompt.frame, from: editor.view)
    XCTAssertLessThanOrEqual(documentFrame.maxY, anchor.minY)
    XCTAssertTrue(editor.textView.visibleRect.contains(documentFrame))
  }

  func testEphemeralPromptFitsNarrowWindowAndFollowsAnchorOffscreen() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("write", mode: .ephemeralMultiline)
    editor.toolPackages = [package]
    let text = "A customer email /write\n" + String(repeating: "Document line\n", count: 200)
    editor.textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    editor.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    try editor.toolController.accept(
      package, token: (text as NSString).range(of: "/write"), space: false)
    await settlePresentationAsync(editor)
    window.setContentSize(NSSize(width: 360, height: 400))
    editor.view.layoutSubtreeIfNeeded()
    await settlePresentationAsync(editor)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let input = try XCTUnwrap(window.firstResponder as? NSTextView)
    let prompt = try XCTUnwrap(input.enclosingScrollView?.superview)
    XCTAssertLessThanOrEqual(
      editor.textView.convert(prompt.frame, from: editor.view).maxX,
      editor.textView.visibleRect.maxX + 1)
    XCTAssertFalse(prompt.isHidden)
    editor.textView.scrollRangeToVisible(
      NSRange(location: editor.state.text.utf16.count, length: 0))
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    XCTAssertFalse(prompt.isHidden)
    XCTAssertTrue(window.firstResponder === input)

  }

  func testRenderedContextAndEphemeralStateMatrixWithAccessibleActions() async throws {
    for mode in [ToolInputMode.contextual, .ephemeralSingleLine, .ephemeralMultiline] {
      let (editor, window) = try await editor()
      defer { window.orderOut(nil) }
      let package = package(
        "test", mode: mode, output: "Subject: New SKUs\nNew products are now available.")
      editor.toolPackages = [package]
      editor.textView.insertText(
        "Above the command\n/test\nBelow the command",
        replacementRange: NSRange(location: 0, length: 0))
      try editor.toolController.accept(
        package, token: (editor.state.text as NSString).range(of: "/test"), space: false)
      await settlePresentationAsync(editor)
      let id = editor.state.invocations[0].id
      if mode == .contextual {
        try editor.toolController.moveBoundary(id, start: true, to: 0)
        try editor.toolController.moveBoundary(id, start: false, to: editor.state.text.utf16.count)
        XCTAssertEqual(
          editor.toolController.content(editor.state.invocations[0]),
          "Above the command\n\nBelow the command")
      } else {
        let input = try XCTUnwrap(window.firstResponder as? NSTextView)
        input.insertText(
          "Write a concise customer email about new SKUs", replacementRange: input.selectedRange())
        if mode == .ephemeralSingleLine {
          input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
          XCTAssertFalse(input.string.contains("\n"))
        }
      }
      func capture(_ phase: String) async throws {
        editor.view.layoutSubtreeIfNeeded()
        await settlePresentationAsync(editor)
        editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshToolPresentation()
        await settlePresentationAsync(editor)
        let bitmap = try XCTUnwrap(
          editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
        editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
          to: URL(fileURLWithPath: "/private/tmp/jort-tools-\(mode.rawValue)-\(phase).png"))
      }
      try await capture("input")
      editor.toolController.submit(id)
      try await pending(editor)
      try await capture("pending")
      let actions = (editor.textView.accessibilityChildren() ?? []).compactMap { $0 as? NSButton }
      XCTAssertEqual(Set(actions.compactMap { $0.accessibilityLabel() }), ["Merge", "Dismiss"])
      XCTAssertEqual(editor.textView.accessibilityValue() as? String, editor.state.text)
      let dismiss = try XCTUnwrap(actions.first { $0.accessibilityLabel() == "Dismiss" })
      XCTAssertTrue(dismiss.accessibilityPerformPress())
      XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    }
  }
}
