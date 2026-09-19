import AppKit
import XCTest
@testable import JortAppKit

@MainActor final class PresentationReconciliationTests: ToolInvocationTestCase {
  func testBurstKeepsNativeTypingSynchronousAndGeometryBounded() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    editor.textView.insertText(
      String(repeating: "line\n", count: 10_000), replacementRange: NSRange(location: 0, length: 0))
    await settlePresentationAsync(editor)
    let before = editor.presentationCoordinator.state.passes
    for _ in 0..<20 {
      editor.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
      editor.presentationCoordinator.invalidate(.viewport)
    }
    XCTAssertTrue(editor.state.text.hasPrefix(String(repeating: "x", count: 20)))
    XCTAssertEqual(editor.presentationCoordinator.state.passes, before)
    let selection = editor.textView.selectedRange()
    await settlePresentationAsync(editor)
    XCTAssertEqual(editor.textView.selectedRange(), selection)
    XCTAssertLessThan(editor.presentationCoordinator.state.passes - before, 6)
    XCTAssertLessThan(editor.linePresentation.fragmentVisits, 100)
    XCTAssertEqual(
      editor.linePresentation.snapshot.epoch, editor.presentationCoordinator.committedEpoch)
    XCTAssertEqual(PresentationGeometry.overscanPoints, 0)
    for offset in [0, 20_000, 40_000, 0] {
      editor.textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
      window.setContentSize(NSSize(width: offset == 0 ? 600 : 480, height: 400))
      await settlePresentationAsync(editor)
      XCTAssertLessThan(editor.linePresentation.fragmentVisits, 100)
      XCTAssertLessThan(editor.linePresentation.snapshot.bands.count, 100)
    }
  }
  func testLargeContextMeasuresOnlyVisibleSegments() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("span", mode: .contextual)
    editor.toolPackages = [tool]
    editor.textView.insertText(
      "/span\n" + String(repeating: "line\n", count: 10_000),
      replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: false)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    try editor.toolController.moveBoundary(id, start: false, to: editor.state.text.utf16.count)
    await settlePresentationAsync(editor)
    let targeted = editor.linePresentation.targetedLayoutRequests
    for offset in [0, 20_000, 40_000] {
      editor.textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
      await settlePresentationAsync(editor)
      XCTAssertEqual(editor.toolPresentation.measuredInvocationCount, 1)
      XCTAssertLessThan(editor.linePresentation.largestMeasuredRange, 1000)
      XCTAssertEqual(editor.linePresentation.targetedLayoutRequests, targeted)
    }
  }
  func testStableControlsAndStaleGenerationActions() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("stable", output: "result")
    editor.toolPackages = [tool]
    editor.textView.insertText("/stable", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 7), space: false)
    await settlePresentationAsync(editor)
    let run = try XCTUnwrap(
      editor.toolPresentation.accessibilityChildren().compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "Run"
      })
    editor.presentationCoordinator.invalidate([.viewport, .accessibility])
    await settlePresentationAsync(editor)
    XCTAssertTrue(
      editor.toolPresentation.accessibilityChildren().contains { ($0 as AnyObject) === run })
    XCTAssertTrue(run.accessibilityPerformPress())
    try await pending(editor)
    let pending = editor.state
    _ = run.accessibilityPerformPress()
    XCTAssertEqual(editor.state, pending)
    await settlePresentationAsync(editor)
    XCTAssertEqual(
      editor.toolPresentation.accessibilityChildren().compactMap {
        ($0 as? NSButton)?.accessibilityLabel()
      }, ["Merge", "Dismiss"])
  }
  func testMarkedTextDefersStylesWithoutChangingComposition() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    editor.textView.setMarkedText(
      "かな", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: 0, length: 0))
    let marked = editor.textView.markedRange()
    let revision = editor.state.revision
    editor.presentationCoordinator.invalidate([.document, .layout, .lifecycle])
    await settlePresentationAsync(editor)
    XCTAssertEqual(editor.textView.markedRange(), marked)
    XCTAssertEqual(editor.state.revision, revision)
    editor.textView.unmarkText()
    await settlePresentationAsync(editor)
    XCTAssertFalse(editor.textView.hasMarkedText())
    XCTAssertEqual(editor.state.text, "かな")
  }
}
