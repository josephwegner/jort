import JortToolRuntime
import JortToolContracts
import XCTest
import AppKit
import JortDocument
import JortPersistence
import JortSettings
@testable import JortAppKit

@MainActor final class InvocationGeometryTests: ToolInvocationTestCase {
  func testTrailingControlsFitNarrowWindowWithoutCoveringInput() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    window.setContentSize(NSSize(width: 320, height: 400))
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText(
      "A long line with /calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(
      tool, token: (editor.state.text as NSString).range(of: "/calc"), space: true)
    await settlePresentationAsync(editor)
    editor.textView.insertText("(10 + 20) * 40", replacementRange: editor.textView.selectedRange())
    editor.view.layoutSubtreeIfNeeded()
    await settlePresentationAsync(editor)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let run = try XCTUnwrap(editor.textView.subviews.first { $0.accessibilityLabel() == "Run" })
    let last = try XCTUnwrap(
      editor.toolPresentation.geometry(
        for: NSRange(location: 0, length: editor.state.text.utf16.count)
      ).last)
    XCTAssertGreaterThanOrEqual(run.frame.minX, last.maxX)
    XCTAssertLessThanOrEqual(run.frame.maxX, editor.textView.visibleRect.maxX)
  }

  func testMultilineOutputAtEOFHasGeometryOnEveryLine() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("write", mode: .ephemeralMultiline, output: "line 1\nline 2\nline 3")
    editor.toolPackages = [tool]
    editor.textView.insertText("/write", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 6), space: true)
    await settlePresentationAsync(editor)
    editor.toolController.submit(editor.state.invocations[0].id)
    try await pending(editor)
    let output = try XCTUnwrap(editor.state.invocations[0].output?.resolve(in: editor.state.lines))
    let frames = editor.toolPresentation.geometry(for: output)
    XCTAssertEqual(Set(frames.map { Int($0.minY) }).count, 3)
  }

  func testContextEndingAtNextLineDoesNotPaintUnownedSuffix() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("dedupe", mode: .contextual, output: "- two\n- three\n- four")
    editor.toolPackages = [tool]
    editor.textView.insertText(
      "- two\n/dedupe\na", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(
      tool, token: (editor.state.text as NSString).range(of: "/dedupe"), space: false)
    await settlePresentationAsync(editor)
    let id = editor.state.invocations[0].id
    try editor.toolController.moveBoundary(id, start: true, to: 0)
    try editor.toolController.moveBoundary(id, start: false, to: editor.state.text.utf16.count - 1)
    editor.toolController.submit(id)
    try await pending(editor)
    let suffix = NSRange(location: editor.state.text.utf16.count - 1, length: 1)
    let frame = try XCTUnwrap(editor.toolPresentation.geometry(for: suffix).first)
    XCTAssertFalse(
      editor.toolPresentation.containsDecoration(
        at: NSPoint(x: frame.minX + 3, y: frame.midY), pending: false))
  }

  func testContextMidlineBoundaryNeverPaintsFollowingGlyph() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("dedupe", mode: .contextual, output: "result")
    editor.toolPackages = [tool]
    editor.textView.insertText(
      "apple\n/dedupe\npearA", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(
      tool, token: (editor.state.text as NSString).range(of: "/dedupe"), space: false)
    await settlePresentationAsync(editor)
    let id = editor.state.invocations[0].id
    try editor.toolController.moveBoundary(id, start: true, to: 0)
    try editor.toolController.moveBoundary(id, start: false, to: editor.state.text.utf16.count - 1)
    editor.toolController.submit(id)
    try await pending(editor)
    let glyph = try XCTUnwrap(
      editor.linePresentation.glyphFrame(at: editor.state.text.utf16.count - 1))
    XCTAssertFalse(
      editor.toolPresentation.containsDecoration(
        at: NSPoint(x: glyph.minX, y: glyph.midY), pending: false))
    try editor.toolController.merge(id)
    editor.textView.history.undo()
    await settlePresentationAsync(editor)
    let restoredGlyph = try XCTUnwrap(
      editor.linePresentation.glyphFrame(at: editor.state.text.utf16.count - 1))
    XCTAssertFalse(
      editor.toolPresentation.containsDecoration(
        at: NSPoint(x: restoredGlyph.minX, y: restoredGlyph.midY), pending: false))
    let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
    editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: "/private/tmp/jort-feedback5-boundary.png"))
  }

  func testInlineResultUsesCanonicalCharacterAdvance() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText("/calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: true)
    await settlePresentationAsync(editor)
    editor.textView.insertText("3+3 ", replacementRange: editor.textView.selectedRange())
    editor.toolController.submit(editor.state.invocations[0].id)
    try await pending(editor)
    let output = try XCTUnwrap(editor.state.invocations[0].output?.resolve(in: editor.state.lines))
    XCTAssertNil(
      editor.textView.textStorage?.attribute(.kern, at: output.location - 1, effectiveRange: nil))
    editor.textView.insertText(
      "a", replacementRange: NSRange(location: editor.state.text.utf16.count, length: 0))
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let dismiss = try XCTUnwrap(
      editor.textView.subviews.first { $0.accessibilityLabel() == "Dismiss" })
    let suffix = try XCTUnwrap(
      editor.linePresentation.glyphFrame(at: editor.state.text.utf16.count - 1))
    XCTAssertLessThanOrEqual(dismiss.frame.maxX, suffix.minX - 1)
    XCTAssertFalse(
      editor.toolPresentation.containsDecoration(
        at: NSPoint(x: suffix.minX, y: suffix.midY), pending: true))
    let merge = try XCTUnwrap(editor.textView.subviews.first { $0.accessibilityLabel() == "Merge" })
    let start = try XCTUnwrap(
      editor.toolPresentation.geometry(for: NSRange(location: output.location, length: 0)).first)
    let glyphWidth = ("6" as NSString).size(withAttributes: [
      .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    ]).width
    XCTAssertGreaterThanOrEqual(merge.frame.minX, start.minX + 3 + glyphWidth)
  }

  func testUndoRestylesPendingOutputAndAlignsInlineHeights() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("dedupe", mode: .contextual, output: "apples\nbananas\nmangos\noranges")
    editor.toolPackages = [tool]
    editor.textView.insertText(
      "apples\napples\n/dedupe\nbananas\noranges", replacementRange: NSRange(location: 0, length: 0)
    )
    try editor.toolController.accept(
      tool, token: (editor.state.text as NSString).range(of: "/dedupe"), space: false)
    await settlePresentationAsync(editor)
    let id = editor.state.invocations[0].id
    try editor.toolController.moveBoundary(id, start: true, to: 0)
    try editor.toolController.moveBoundary(id, start: false, to: editor.state.text.utf16.count)
    editor.toolController.submit(id)
    try await pending(editor)
    let original = editor.state.text
    try editor.toolController.merge(id)
    editor.textView.history.undo()
    await settlePresentationAsync(editor)
    XCTAssertEqual(editor.state.text, original)
    let invocation = editor.state.invocations[0]
    let output = try XCTUnwrap(invocation.output?.resolve(in: editor.state.lines))
    XCTAssertEqual(
      editor.textView.textStorage?.attribute(.kern, at: output.location - 1, effectiveRange: nil)
        as? Int, 54)
    let tokenFrame = try XCTUnwrap(
      editor.toolPresentation.geometry(for: invocation.token.resolve(in: editor.state.lines)!).last)
    let outputFrame = try XCTUnwrap(editor.toolPresentation.geometry(for: output).first)
    XCTAssertEqual(tokenFrame.minY, outputFrame.minY, accuracy: 0.01)
    XCTAssertEqual(tokenFrame.height, outputFrame.height, accuracy: 0.01)
    let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
    editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: "/private/tmp/jort-feedback2-undo.png"))
  }

  func testConnectedUnionRemovesSharedInteriorEdges() {
    let path = ToolInvocationPresentation.union([
      NSRect(x: 50, y: 0, width: 100, height: 20), NSRect(x: 0, y: 18, width: 150, height: 20),
      NSRect(x: 0, y: 36, width: 80, height: 20),
    ])
    XCTAssertTrue(path.contains(NSPoint(x: 70, y: 19)))
    XCTAssertTrue(path.contains(NSPoint(x: 70, y: 37)))
    XCTAssertFalse(path.contains(NSPoint(x: 20, y: 5)))
    XCTAssertEqual(path.bounds, NSRect(x: 0, y: 0, width: 150, height: 56))
  }
  func testMultilineOutputAfterTrailingInputNewlineKeepsActionsInsideTextArea() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("calc", output: "First result\nSecond result")
    editor.toolPackages = [package]
    editor.textView.insertText("/calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: true)
    await settlePresentationAsync(editor)
    editor.textView.insertText("3+3\n", replacementRange: editor.textView.selectedRange())
    let id = editor.state.invocations[0].id
    editor.toolController.submit(id)
    try await pending(editor)
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let merge = try XCTUnwrap(
      editor.textView.subviews.compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "Merge"
      })
    XCTAssertGreaterThanOrEqual(merge.frame.minX, editor.textView.textContainerOrigin.x)
    XCTAssertEqual(editor.state.text, "/calc 3+3\nFirst result\nSecond result")
    let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
    editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: "/private/tmp/jort-tools-newline-pending.png"))
    try editor.toolController.merge(id)
    let storage = try XCTUnwrap(editor.textView.textStorage)
    storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) {
      value, _, _ in
      XCTAssertEqual((value as? NSParagraphStyle)?.firstLineHeadIndent ?? 0, 0)
    }
  }

  func testEmptyOutputAfterTrailingInputNewlineReservesActionsWithoutCanonicalCharacters()
    async throws
  {
    for tail in ["", "unrelated"] {
      let (editor, window) = try await editor()
      defer { window.orderOut(nil) }
      let package = package("calc", output: "")
      editor.toolPackages = [package]
      editor.textView.insertText("/calc" + tail, replacementRange: NSRange(location: 0, length: 0))
      try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: true)
      await settlePresentationAsync(editor)
      editor.textView.insertText("input\n", replacementRange: editor.textView.selectedRange())
      let id = editor.state.invocations[0].id, before = editor.state.text
      editor.toolController.submit(id)
      try await pending(editor)
      editor.refreshToolPresentation()
      await settlePresentationAsync(editor)
      let merge = try XCTUnwrap(
        editor.textView.subviews.compactMap { $0 as? NSButton }.first {
          $0.accessibilityLabel() == "Merge"
        })
      XCTAssertGreaterThanOrEqual(merge.frame.minX, editor.textView.textContainerOrigin.x)
      XCTAssertEqual(editor.state.text, before)
      try editor.toolController.merge(id)
      XCTAssertEqual(editor.state.text, tail)
    }
  }

}
