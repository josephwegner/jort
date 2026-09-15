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
    editor.textView.insertText("(10 + 20) * 40", replacementRange: editor.textView.selectedRange())
    editor.view.layoutSubtreeIfNeeded()
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.refreshToolPresentation()
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
    editor.toolController.submit(editor.state.invocations[0].id)
    try await pending(editor)
    let output = try XCTUnwrap(editor.state.invocations[0].output?.resolve(in: editor.state.lines))
    let frames = editor.toolPresentation.geometry(for: output)
    XCTAssertEqual(Set(frames.map { Int($0.minY) }).count, 3)
  }

  func testAccessiblePendingButtonsOverrideTextViewCursor() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText("/calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: true)
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
    editor.toolController.submit(editor.state.invocations[0].id)
    try await pending(editor)
    let last = (editor.state.text as NSString).range(of: "last result")
    editor.textView.scrollRangeToVisible(last)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    // A scroll/draw, with no document edit or explicit presentation refresh.
    let visible = editor.textView.visibleRect
    let bitmap = try XCTUnwrap(editor.textView.bitmapImageRepForCachingDisplay(in: visible))
    editor.textView.cacheDisplay(in: visible, to: bitmap)
    let frame = try XCTUnwrap(editor.toolPresentation.geometry(for: last).first)
    XCTAssertTrue(
      editor.toolPresentation.containsDecoration(
        at: NSPoint(x: frame.minX + 5, y: frame.midY), pending: true))
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
    editor.toolController.submit(editor.state.invocations[0].id)
    try await pending(editor)
    try editor.toolController.accept(
      write, token: (editor.state.text as NSString).range(of: "/write"), space: true)
    // Rebuild inline controls while preserving the existing prompt.
    editor.refreshToolPresentation()
    editor.refreshToolPresentation()
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

  func testInlineResultUsesCanonicalCharacterAdvance() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText("/calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: true)
    editor.textView.insertText("3+3 ", replacementRange: editor.textView.selectedRange())
    editor.toolController.submit(editor.state.invocations[0].id)
    try await pending(editor)
    let output = try XCTUnwrap(editor.state.invocations[0].output?.resolve(in: editor.state.lines))
    XCTAssertNil(
      editor.textView.textStorage?.attribute(.kern, at: output.location - 1, effectiveRange: nil))
    editor.textView.insertText(
      "a", replacementRange: NSRange(location: editor.state.text.utf16.count, length: 0))
    editor.refreshToolPresentation()
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
    editor.textView.scrollRangeToVisible(token)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.refreshToolPresentation()
    let prompt = try XCTUnwrap(
      editor.view.subviews.first { $0.accessibilityLabel() == "Tool prompt form" })
    let anchor = try XCTUnwrap(editor.toolPresentation.geometry(for: token).first)
    let documentFrame = editor.textView.convert(prompt.frame, from: editor.view)
    XCTAssertLessThanOrEqual(documentFrame.maxY, anchor.minY)
    XCTAssertTrue(editor.textView.visibleRect.contains(documentFrame))
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
    let id = editor.state.invocations[0].id
    try editor.toolController.moveBoundary(id, start: true, to: 0)
    try editor.toolController.moveBoundary(id, start: false, to: editor.state.text.utf16.count)
    editor.toolController.submit(id)
    try await pending(editor)
    let original = editor.state.text
    try editor.toolController.merge(id)
    editor.textView.history.undo()
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
  func testRenderedWrappedMultilineAndProcessingStates() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    func capture(_ name: String) throws {
      window.setContentSize(NSSize(width: 600, height: 400))
      editor.view.layoutSubtreeIfNeeded()
      editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
      editor.refreshToolPresentation()
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
    editor.textView.insertText(
      "(apples + pears) * crates_per_row\n+ extra_crates",
      replacementRange: editor.textView.selectedRange())
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    try capture("contained-multiline")
    editor.toolController.submit(id)
    try await pending(editor)
    try capture("multiline-pending")
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
    let running = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.submit(running)
    for _ in 0..<300 where editor.state.invocations.first?.phase != .processing {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(editor.state.invocations.first?.phase, .processing)
    try capture("processing")
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
    let id = editor.state.invocations[0].id
    editor.textView.insertText("prefix ", replacementRange: NSRange(location: 0, length: 0))
    editor.toolController.cancel(id)
    let storage = try XCTUnwrap(editor.textView.textStorage)
    storage.enumerateAttribute(.kern, in: NSRange(location: 0, length: storage.length)) {
      value, _, _ in
      XCTAssertEqual((value as? NSNumber)?.doubleValue ?? 0, 0)
    }
    XCTAssertEqual(editor.state.text, "prefix before /calc  after")
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
    window.setContentSize(NSSize(width: 360, height: 400))
    editor.view.layoutSubtreeIfNeeded()
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.refreshToolPresentation()
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
    XCTAssertTrue(
      prompt.isHidden
        || !editor.textView.convert(prompt.frame, from: editor.view).intersects(
          editor.textView.visibleRect)
    )
  }

  func testMultilineOutputAfterTrailingInputNewlineKeepsActionsInsideTextArea() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("calc", output: "First result\nSecond result")
    editor.toolPackages = [package]
    editor.textView.insertText("/calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: true)
    editor.textView.insertText("3+3\n", replacementRange: editor.textView.selectedRange())
    let id = editor.state.invocations[0].id
    editor.toolController.submit(id)
    try await pending(editor)
    editor.refreshToolPresentation()
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
      editor.textView.insertText("input\n", replacementRange: editor.textView.selectedRange())
      let id = editor.state.invocations[0].id, before = editor.state.text
      editor.toolController.submit(id)
      try await pending(editor)
      editor.refreshToolPresentation()
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
      func capture(_ phase: String) throws {
        editor.view.layoutSubtreeIfNeeded()
        editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshToolPresentation()
        let bitmap = try XCTUnwrap(
          editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
        editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
          to: URL(fileURLWithPath: "/private/tmp/jort-tools-\(mode.rawValue)-\(phase).png"))
      }
      try capture("input")
      editor.toolController.submit(id)
      try await pending(editor)
      try capture("pending")
      let actions = (editor.textView.accessibilityChildren() ?? []).compactMap { $0 as? NSButton }
      XCTAssertEqual(Set(actions.compactMap { $0.accessibilityLabel() }), ["Merge", "Dismiss"])
      XCTAssertEqual(editor.textView.accessibilityValue() as? String, editor.state.text)
      let dismiss = try XCTUnwrap(actions.first { $0.accessibilityLabel() == "Dismiss" })
      XCTAssertTrue(dismiss.accessibilityPerformPress())
      XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    }
  }

}
