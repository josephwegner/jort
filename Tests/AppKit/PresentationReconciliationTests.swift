import AppKit
import XCTest
import JortDocument
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
      let recorder = DocumentWorkRecorder()
      DocumentInstrumentation.$recorder.withValue(recorder) {
        editor.toolPresentation.invalidateStyles()
        _ = editor.toolPresentation.reconcileStyles()
        editor.toolPresentation.reconcileControls()
      }
      XCTAssertNil(recorder.snapshot[.flattenCalls])
      XCTAssertNil(recorder.snapshot[.completeValidations])
      XCTAssertEqual(editor.toolPresentation.measuredInvocationCount, 1)
      XCTAssertLessThan(editor.linePresentation.largestMeasuredRange, 1000)
      XCTAssertEqual(editor.linePresentation.targetedLayoutRequests, targeted)
    }
  }
  func testUpwardScrollingAcrossInvocationKeepsViewportAndSelection() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("span", mode: .contextual, output: "result")
    editor.toolPackages = [tool]
    let source =
      String(repeating: "before context\n", count: 180)
      + String(repeating: "wrapped command prefix ", count: 24) + "/span\n"
      + String(repeating: "after context\n", count: 180)
    editor.textView.insertText(source, replacementRange: NSRange(location: 0, length: 0))
    let token = (editor.state.text as NSString).range(of: "/span")
    try editor.toolController.accept(tool, token: token, space: false)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    try editor.toolController.moveBoundary(id, start: true, to: 0)
    try editor.toolController.moveBoundary(id, start: false, to: editor.state.utf16Count)
    await settlePresentationAsync(editor)
    let lineID = try XCTUnwrap(editor.state.invocations.first?.token.start.lineID)
    let help = try XCTUnwrap(editor.linePresentation.accessories[lineID]?.view)

    func scrollAcrossBlock(expectHelp: Bool) async throws {
      editor.textView.scrollRangeToVisible(token)
      editor.linePresentation.prepareViewportLayout()
      await settlePresentationAsync(editor)
      let frame = try XCTUnwrap(editor.linePresentation.canonicalRects(for: token).first)
      let selection = editor.textView.selectedRange()
      let initialTargeted = editor.linePresentation.targetedLayoutRequests
      for delta in [CGFloat(360), 180, -20, -160, 120, -60] {
        editor.scroll.contentView.scroll(to: NSPoint(x: 0, y: frame.minY + delta))
        editor.scroll.reflectScrolledClipView(editor.scroll.contentView)
        let scrolledY = editor.scroll.contentView.bounds.minY
        await settlePresentationAsync(editor)
        XCTAssertEqual(editor.scroll.contentView.bounds.minY, scrolledY, accuracy: 1)
        XCTAssertEqual(editor.textView.selectedRange(), selection)
        XCTAssertEqual(editor.linePresentation.targetedLayoutRequests, initialTargeted)
        if expectHelp {
          XCTAssertTrue(editor.linePresentation.accessories[lineID]?.view === help)
        }
      }
    }

    try await scrollAcrossBlock(expectHelp: true)
    editor.toolController.submit(id)
    try await pending(editor, id: id)
    try await scrollAcrossBlock(expectHelp: false)
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
