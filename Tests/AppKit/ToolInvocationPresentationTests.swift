import JortToolRuntime
import JortToolContracts
import XCTest
import AppKit
import JortDocument
import JortPersistence
import JortSettings
@testable import JortAppKit

@MainActor final class ToolInvocationPresentationTests: ToolInvocationTestCase {
  func testFeedbackRendersCompletionErrorAndControlSpacing() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText("/", replacementRange: NSRange(location: 0, length: 0))
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let popup = try XCTUnwrap(
      editor.view.subviews.first { $0.accessibilityLabel() == "Tool completions" })
    XCTAssertTrue(popup.superview === editor.view)
    XCTAssertLessThan(popup.frame.width, 280)
    let completionBitmap = try XCTUnwrap(
      editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
    editor.view.cacheDisplay(in: editor.view.bounds, to: completionBitmap)
    try completionBitmap.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: "/private/tmp/jort-feedback-completion.png"))
    let completion = try XCTUnwrap(popup.subviews.first as? NSButton)
    XCTAssertTrue(completion.accessibilityPerformPress())
    XCTAssertEqual(editor.state.text, "/calc ")
    await settlePresentationAsync(editor)
    let run = try XCTUnwrap(
      editor.textView.subviews.compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "Run"
      })
    XCTAssertEqual(run.title, "⇧↵")
    editor.textView.insertText("foo", replacementRange: editor.textView.selectedRange())
    var invalid = tool
    invalid.source = "export default async function() { return {error: 'Expected a number'}; }"
    editor.toolPackages = [invalid]
    editor.toolController.submit(editor.state.invocations[0].id)
    for _ in 0..<300 where editor.state.invocations[0].phase != .error {
      try await Task.sleep(for: .milliseconds(10))
    }
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let messages = editor.linePresentation.accessories.values.flatMap {
      ($0.view as? NSStackView)?.arrangedSubviews ?? []
    }.compactMap { $0 as? NSTextField }
    let dismiss = try XCTUnwrap(
      editor.textView.subviews.compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel()?.hasPrefix("Dismiss:") == true
      })
    let textRect = try XCTUnwrap(
      editor.toolPresentation.geometry(
        for: NSRange(location: 0, length: editor.state.text.utf16.count)
      ).last)
    XCTAssertGreaterThanOrEqual(dismiss.frame.minX, textRect.maxX)
    XCTAssertTrue(messages.contains { $0.stringValue.contains("Expected a number") })
    let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
    editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: "/private/tmp/jort-feedback-error.png"))
  }

  func testScrollingRepaintsPendingOutputBeyondOriginalEOFViewport() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package(
      "write", mode: .ephemeralMultiline,
      output: String(repeating: "result\n", count: 25) + "last result")
    editor.toolPackages = [tool]
    editor.textView.insertText(
      String(repeating: "before\n", count: 30) + "/write",
      replacementRange: NSRange(location: 0, length: 0))
    let token = (editor.state.text as NSString).range(of: "/write")
    editor.textView.scrollRangeToVisible(token)
    try editor.toolController.accept(tool, token: token, space: true)
    await settlePresentationAsync(editor)
    editor.toolController.submit(editor.state.invocations[0].id)
    try await pending(editor)
    let last = (editor.state.text as NSString).range(of: "last result")
    editor.textView.scrollRangeToVisible(last)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    await settlePresentationAsync(editor)
    // A scroll/draw, with no document edit or explicit presentation refresh.
    let visible = editor.textView.visibleRect
    let bitmap = try XCTUnwrap(editor.textView.bitmapImageRepForCachingDisplay(in: visible))
    editor.textView.cacheDisplay(in: visible, to: bitmap)
    let frame = try XCTUnwrap(editor.toolPresentation.geometry(for: last).first)
    XCTAssertTrue(
      editor.toolPresentation.containsDecoration(
        at: NSPoint(x: frame.minX + 5, y: frame.midY), pending: true))
  }

  func testRenderedWrappedMultilineAndProcessingStates() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    func capture(_ name: String) async throws {
      window.setContentSize(NSSize(width: 600, height: 400))
      editor.view.layoutSubtreeIfNeeded()
      await settlePresentationAsync(editor)
      editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
      editor.refreshToolPresentation()
      await settlePresentationAsync(editor)
      let bitmap = try XCTUnwrap(
        editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
      editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(
        to: URL(fileURLWithPath: "/private/tmp/jort-tools-\(name).png"))
    }
    let package = package("calc", output: "Result line one\nResult line two")
    editor.toolPackages = [package]
    let prefix = "The orchard estimate is "
    editor.textView.insertText(
      prefix + "/calc for the fall order.", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(
      package, token: NSRange(location: prefix.utf16.count, length: 5), space: true)
    await settlePresentationAsync(editor)
    editor.textView.insertText(
      "(apples + pears) * crates_per_row\n+ extra_crates",
      replacementRange: editor.textView.selectedRange())
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    try await capture("contained-multiline")
    editor.toolController.submit(id)
    try await pending(editor)
    try await capture("multiline-pending")
    XCTAssertEqual(editor.state.lines.count, 3)
    XCTAssertTrue(editor.state.invocations[0].validated(in: editor.state))
    let persisted = try PersistenceFormat.decode(PersistenceFormat.encode(editor.state)).snapshot
    XCTAssertEqual(persisted, editor.state)
    try editor.toolController.dismiss(id)
    editor.toolController.cancel(id)
    var slow = package
    slow.source = "export default async function() { while(true) {} }"
    editor.toolPackages = [slow]
    let token = (editor.state.text as NSString).range(of: "/calc")
    try editor.toolController.accept(slow, token: token, space: false)
    await settlePresentationAsync(editor)
    let running = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.submit(running)
    for _ in 0..<300 where editor.state.invocations.first?.phase != .processing {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(editor.state.invocations.first?.phase, .processing)
    try await capture("processing")
    editor.toolController.cancel(running)
  }
  func testDecorationAttributesFollowEditsAndDisappearOnCancel() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("calc")
    editor.toolPackages = [package]
    editor.textView.insertText(
      "before /calc after", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 7, length: 5), space: true)
    await settlePresentationAsync(editor)
    let id = editor.state.invocations[0].id
    editor.textView.insertText("prefix ", replacementRange: NSRange(location: 0, length: 0))
    editor.toolController.cancel(id)
    await settlePresentationAsync(editor)
    let storage = try XCTUnwrap(editor.textView.textStorage)
    storage.enumerateAttribute(.kern, in: NSRange(location: 0, length: storage.length)) {
      value, _, _ in
      XCTAssertEqual((value as? NSNumber)?.doubleValue ?? 0, 0)
    }
    XCTAssertEqual(editor.state.text, "prefix before /calc  after")
  }

}
