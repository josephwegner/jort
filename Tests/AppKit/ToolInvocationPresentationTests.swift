import JortToolRuntime
import JortToolContracts
import XCTest
import AppKit
import JortDocument
import JortPersistence
import JortSettings
@testable import JortAppKit

@MainActor final class ToolInvocationPresentationTests: ToolInvocationTestCase {
  func testInlineHelpExplainsPurposeAndRelevantInputsWithoutKeyboardOrColorInstructions() {
    var lorem = package("lorem").manifest
    lorem.description = "Generate paragraphs of lorem ipsum text"
    lorem.arguments = [
      ToolArgumentDefinition(
        name: "paragraphs", type: .integer, label: "Paragraphs",
        description: "Enter how many paragraphs.",
        defaultValue: .integer(1), minimum: 1, maximum: 100)
    ]
    XCTAssertEqual(
      ToolInvocationPresentation.inlineHelp(for: lorem, hasInlineCall: true),
      "Generate paragraphs of lorem ipsum text. Enter how many paragraphs (1–100; default 1).")

    lorem.arguments = [
      ToolArgumentDefinition(
        name: "count", type: .integer, label: "Count",
        description: "Enter 10 characters.", defaultValue: .integer(5), minimum: 1, maximum: 10)
    ]
    XCTAssertEqual(
      ToolInvocationPresentation.inlineHelp(for: lorem, hasInlineCall: true),
      "Generate paragraphs of lorem ipsum text. Enter 10 characters (1–10; default 5).")

    var generator = package("uuid").manifest
    generator.description = "Generate a UUID"
    XCTAssertEqual(
      ToolInvocationPresentation.inlineHelp(for: generator, hasInlineCall: true),
      "Generate a UUID.")

    var contextual = package("split", mode: .contextual).manifest
    contextual.description = "Split the selected text into lines"
    contextual.arguments = [
      ToolArgumentDefinition(name: "delimiter", type: .string, label: "Delimiter", required: true)
    ]
    XCTAssertEqual(
      ToolInvocationPresentation.inlineHelp(for: contextual, hasInlineCall: true),
      "Split the selected text into lines. Enter delimiter.")

    contextual.arguments = [
      ToolArgumentDefinition(
        name: "separator", type: .string, label: "Separator", defaultValue: .string(""))
    ]
    XCTAssertEqual(
      ToolInvocationPresentation.inlineHelp(for: contextual, hasInlineCall: true),
      "Split the selected text into lines. Enter separator (default \"\").")

    var model = package("summarize", mode: .contextual).manifest
    model.executor = .model
    model.description = "Summarize the selected text"
    model.arguments = [
      ToolArgumentDefinition(
        name: "length", type: .enum, label: "Length",
        defaultValue: .string("medium"), choices: ["short", "medium", "long"])
    ]
    XCTAssertEqual(
      ToolInvocationPresentation.inlineHelp(for: model, hasInlineCall: true),
      "Summarize the selected text. Choose length (short, medium, long; default medium). Add a question or instruction if needed."
    )

    model.arguments?[0].description = "Choose the default region."
    XCTAssertEqual(
      ToolInvocationPresentation.inlineHelp(for: model, hasInlineCall: true),
      "Summarize the selected text. Choose the default region (default medium). Add a question or instruction if needed."
    )

    model.arguments = [
      ToolArgumentDefinition(
        name: "length", type: .enum, label: "Summary format",
        description:
          "Choose default for concise prose, short for one paragraph, or 1–20 for that many bullet points.",
        defaultValue: .string("default"), choices: ["default", "short"] + (1...20).map(String.init))
    ]
    XCTAssertEqual(
      ToolInvocationPresentation.inlineHelp(for: model, hasInlineCall: true),
      "Summarize the selected text. Choose default for concise prose, short for one paragraph, or 1–20 for that many bullet points. Add a question or instruction if needed."
    )

    var ask = package("ask").manifest
    ask.executor = .model
    ask.description = "Answer a question"
    XCTAssertEqual(
      ToolInvocationPresentation.inlineHelp(for: ask, hasInlineCall: true),
      "Answer a question. Enter your question.")
  }

  func testInlineHelpAppearsAsReadableAccessibleSubtext() async throws {
    let (editor, _) = try await editor()
    var tool = package("lorem")
    tool.manifest.schemaVersion = 3
    tool.manifest.executor = .javascript
    tool.manifest.entryContract = 2
    tool.manifest.description = "Generate paragraphs of lorem ipsum text."
    tool.manifest.arguments = [
      ToolArgumentDefinition(
        name: "paragraphs", type: .integer, label: "Number of paragraphs",
        description: "Enter how many paragraphs.",
        defaultValue: .integer(1), minimum: 1, maximum: 100)
    ]
    editor.toolPackages = [tool]
    editor.textView.insertText("/lorem", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 6), space: true)
    await settlePresentationAsync(editor)

    let help = try XCTUnwrap(
      editor.linePresentation.accessories.values.flatMap {
        ($0.view as? NSStackView)?.arrangedSubviews ?? []
      }.compactMap { $0 as? NSTextField }.first {
        $0.stringValue.contains("Generate paragraphs of lorem ipsum text.")
      })
    XCTAssertEqual(
      help.stringValue,
      "/lorem: Generate paragraphs of lorem ipsum text. Enter how many paragraphs (1–100; default 1)."
    )
    XCTAssertEqual(help.accessibilityLabel(), help.stringValue)
  }

  func testNativeActionDisclosureStaysInRunAccessibilityWithoutExtraWarningRow()
    async throws
  {
    let (editor, _) = try await editor()
    var tool = package("tidy", mode: .contextual)
    tool.manifest.schemaVersion = 3
    tool.manifest.entryContract = 2
    tool.manifest.executor = .javascript
    tool.manifest.description = "Tidy up a thought"
    tool.manifest.hostActions = ["clipboard.rich", "file.export", "notification.schedule"]
    editor.toolPackages = [tool]
    editor.textView.insertText("Note /tidy", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 5, length: 5), space: true)
    await settlePresentationAsync(editor)
    let labels = editor.linePresentation.accessories.values.flatMap {
      ($0.view as? NSStackView)?.arrangedSubviews ?? []
    }.compactMap { $0 as? NSTextField }
    XCTAssertFalse(labels.contains { $0.stringValue.contains("This tool may") })
    XCTAssertFalse(labels.contains { $0.textColor == .systemOrange })
    let run = try XCTUnwrap(
      editor.textView.subviews.first {
        $0.accessibilityLabel()?.hasPrefix("Run:") == true
      })
    let disclosure = try XCTUnwrap(run.accessibilityLabel())
    XCTAssertTrue(disclosure.contains("replace clipboard contents"))
    XCTAssertTrue(disclosure.contains("destination you choose"))
    XCTAssertTrue(disclosure.contains("local notification"))
    XCTAssertEqual(editor.state.text, "Note /tidy ")
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    XCTAssertNil(ToolInvocationPresentation.actionDisclosure(for: package("plain").manifest))
  }

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
    for _ in 0..<300 where editor.state.invocations[0].message != "Expected a number" {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(editor.state.invocations[0].phase, .inputting)
    XCTAssertEqual(editor.state.invocations[0].message, "Expected a number")
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let messages = editor.linePresentation.accessories.values.flatMap {
      ($0.view as? NSStackView)?.arrangedSubviews ?? []
    }.compactMap { $0 as? NSTextField }
    let retry = try XCTUnwrap(
      editor.textView.subviews.compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "Run"
      })
    let textRect = try XCTUnwrap(
      editor.toolPresentation.geometry(
        for: NSRange(location: 0, length: editor.state.text.utf16.count)
      ).last)
    XCTAssertGreaterThanOrEqual(retry.frame.minX, textRect.maxX)
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

  func testRemovingFinalInvocationRequestsRedraw() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("calc")
    editor.toolPackages = [package]
    editor.textView.insertText("/calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.submit(id)
    try await pending(editor, id: id)
    let output = try XCTUnwrap(editor.state.invocations[0].output?.resolve(in: editor.state))
    let frame = try XCTUnwrap(editor.toolPresentation.geometry(for: output).first)
    let point = NSPoint(x: frame.minX + 5, y: frame.midY)
    XCTAssertTrue(editor.toolPresentation.containsDecoration(at: point, pending: true))
    let mergeButton = try XCTUnwrap(
      editor.textView.subviews.compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "Merge"
      })
    XCTAssertTrue(window.makeFirstResponder(mergeButton))

    editor.textView.displayIfNeeded()
    var draws = 0
    editor.textView.onToolDraw = { _ in draws += 1 }
    let passesBeforeMerge = editor.presentationCoordinator.state.passes
    try editor.toolController.merge(id)
    XCTAssertTrue(editor.state.invocations.isEmpty)
    XCTAssertFalse(editor.toolPresentation.containsDecoration(at: point, pending: true))
    XCTAssertNil(mergeButton.superview)
    XCTAssertTrue(window.firstResponder === editor.textView)
    XCTAssertEqual(editor.presentationCoordinator.state.passes, passesBeforeMerge)

    // Merging the final invocation clears presentation data and must replace
    // the previously drawn decoration immediately.
    editor.textView.displayIfNeeded()
    XCTAssertGreaterThan(draws, 0)
    await settlePresentationAsync(editor)
  }

  func testUndoRemovesInvocationDecorationImmediately() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText("/calc", replacementRange: NSRange(location: 0, length: 0))
    editor.textView.history.removeAllActions()
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    let token = try XCTUnwrap(editor.state.invocations.first?.token.resolve(in: editor.state))
    let frame = try XCTUnwrap(editor.toolPresentation.geometry(for: token).first)
    let point = NSPoint(x: frame.minX + 5, y: frame.midY)
    XCTAssertTrue(editor.toolPresentation.containsDecoration(at: point, pending: false))

    let passesBeforeUndo = editor.presentationCoordinator.state.passes
    editor.textView.history.undo()
    XCTAssertTrue(editor.state.invocations.isEmpty)
    XCTAssertFalse(editor.toolPresentation.containsDecoration(at: point, pending: false))
    XCTAssertEqual(editor.presentationCoordinator.state.passes, passesBeforeUndo)
  }

  func testDeletingOneInvocationRetiresShiftedDecorationUntilRebuild() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText("/calc and /calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    let firstID = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.submit(firstID)
    try await pending(editor, id: firstID)
    let secondToken = (editor.state.text as NSString).range(of: "/calc", options: .backwards)
    try editor.toolController.accept(tool, token: secondToken, space: false)
    await settlePresentationAsync(editor)
    let secondID = try XCTUnwrap(editor.state.invocations.last?.id)
    editor.toolController.submit(secondID)
    try await pending(editor, id: secondID)

    func point(for id: UUID) throws -> NSPoint {
      let invocation = try XCTUnwrap(editor.state.invocations.first { $0.id == id })
      let output = try XCTUnwrap(invocation.output?.resolve(in: editor.state))
      let frame = try XCTUnwrap(editor.toolPresentation.geometry(for: output).first)
      return NSPoint(x: frame.minX + 5, y: frame.midY)
    }
    let firstPoint = try point(for: firstID), secondPoint = try point(for: secondID)
    XCTAssertTrue(editor.toolPresentation.containsDecoration(at: firstPoint, pending: true))
    XCTAssertTrue(editor.toolPresentation.containsDecoration(at: secondPoint, pending: true))

    let passesBeforeDelete = editor.presentationCoordinator.state.passes
    try editor.toolController.deletePending(
      in: NSRange(location: 1, length: 1), expectedRevision: editor.state.revision)
    XCTAssertEqual(editor.state.invocations.map(\.id), [secondID])
    XCTAssertFalse(editor.toolPresentation.containsDecoration(at: firstPoint, pending: true))
    XCTAssertFalse(editor.toolPresentation.containsDecoration(at: secondPoint, pending: true))
    XCTAssertEqual(editor.presentationCoordinator.state.passes, passesBeforeDelete)
    await settlePresentationAsync(editor)
    XCTAssertTrue(
      editor.toolPresentation.containsDecoration(at: try point(for: secondID), pending: true))
  }

  func testConfirmedDeleteRemovesDecorationInsideTransactionCallback() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText("/calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.submit(id)
    try await pending(editor, id: id)
    let output = try XCTUnwrap(editor.state.invocations[0].output?.resolve(in: editor.state))
    let frame = try XCTUnwrap(editor.toolPresentation.geometry(for: output).first)
    let point = NSPoint(x: frame.minX + 5, y: frame.midY)
    XCTAssertTrue(editor.toolPresentation.containsDecoration(at: point, pending: true))

    let previousOnTransaction = editor.coordinator.onTransaction
    defer { editor.coordinator.onTransaction = previousOnTransaction }
    var observedRemoval = false
    let passesBeforeDelete = editor.presentationCoordinator.state.passes
    editor.coordinator.onTransaction = { result in
      previousOnTransaction?(result)
      guard result.before.invocations.contains(where: { $0.id == id }),
        result.after.invocations.isEmpty
      else { return }
      observedRemoval = true
      XCTAssertFalse(editor.toolPresentation.containsDecoration(at: point, pending: true))
      XCTAssertEqual(editor.presentationCoordinator.state.passes, passesBeforeDelete)
    }

    editor.textView.setSelectedRange(NSRange(location: 1, length: 1))
    editor.textView.deleteBackward(nil)
    let sheet = try XCTUnwrap(window.attachedSheet)
    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    for _ in 0..<100 where !observedRemoval {
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(observedRemoval)
    XCTAssertTrue(editor.state.invocations.isEmpty)
  }

  func testEmptyPresentationDoesNotRequestRedraw() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    editor.textView.displayIfNeeded()
    var draws = 0
    editor.textView.onToolDraw = { _ in draws += 1 }

    editor.toolPresentation.reconcileControls()
    editor.textView.displayIfNeeded()

    XCTAssertEqual(draws, 0)
  }

}
