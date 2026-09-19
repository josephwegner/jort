import JortToolRuntime
import JortToolContracts
import XCTest
import AppKit
import JortDocument
import JortPersistence
import JortSettings
@testable import JortAppKit

@MainActor final class ToolInvocationIntegrationTests: ToolInvocationTestCase {
  func testCompletedGenerationRejectsRepeatSubmitAndPreservesDismissUndo() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("test", output: "RESULT")
    editor.toolPackages = [tool]
    editor.textView.insertText("/test", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    let initial = try XCTUnwrap(editor.state.invocations.first)
    XCTAssertEqual(initial.phase, .inputting)
    editor.toolController.submit(initial.id)
    editor.toolController.submit(initial.id)
    try await pending(editor)
    let completed = editor.state
    XCTAssertEqual(completed.invocations.count, 1)
    XCTAssertEqual(completed.text, "/testRESULT")
    editor.toolController.submit(initial.id)
    XCTAssertEqual(editor.state, completed)
    try editor.toolController.dismiss(initial.id)
    XCTAssertEqual(editor.state.text, "/test")
    XCTAssertEqual(editor.state.invocations.first, initial)
    editor.textView.history.undo()
    XCTAssertEqual(editor.state.text, completed.text)
    XCTAssertEqual(editor.state.invocations, completed.invocations)
  }

  func testCompletionEscapePreservesTypedTextAndEditorFocus() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    editor.toolPackages = [package("calc")]
    window.makeFirstResponder(editor.textView)
    key("/", code: 44, in: editor, window: window)
    key("ca", code: 0, in: editor, window: window)
    await settlePresentationAsync(editor)
    XCTAssertNotNil(editor.view.subviews.first { $0.accessibilityLabel() == "Tool completions" })

    editor.textView.cancelOperation(nil)
    await settlePresentationAsync(editor)

    XCTAssertEqual(editor.state.text, "/ca")
    XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 3, length: 0))
    XCTAssertTrue(window.firstResponder === editor.textView)
    XCTAssertNil(editor.view.subviews.first { $0.accessibilityLabel() == "Tool completions" })
    XCTAssertTrue(editor.state.invocations.isEmpty)
  }

  func testNativeReturnAfterCompletionAcceptanceInsertsNewlineWithoutSubmitting() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    editor.toolPackages = [package("calc")]
    window.makeFirstResponder(editor.textView)
    key("/", code: 44, in: editor, window: window)
    key("ca", code: 0, in: editor, window: window)
    await settlePresentationAsync(editor)
    key("\r", code: 36, in: editor, window: window)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)

    key("typed", code: 0, in: editor, window: window)
    key("\r", code: 36, in: editor, window: window)

    XCTAssertEqual(editor.state.text, "/calc typed\n")
    XCTAssertEqual(editor.state.invocations.first?.id, id)
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    XCTAssertEqual(editor.toolController.content(editor.state.invocations[0]), "typed\n")
  }

  func testLeavingContainedInputKeepsExistingContentOwnership() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText("/calc tail", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: true)
    await settlePresentationAsync(editor)
    editor.textView.insertText("owned", replacementRange: editor.textView.selectedRange())
    let invocation = try XCTUnwrap(editor.state.invocations.first)

    editor.textView.setSelectedRange(NSRange(location: editor.state.text.utf16.count, length: 0))
    editor.textView.insertText("!", replacementRange: editor.textView.selectedRange())

    XCTAssertEqual(editor.state.text, "/calc owned tail!")
    XCTAssertEqual(
      editor.toolController.content(
        try XCTUnwrap(editor.state.invocations.first { $0.id == invocation.id })), "owned")
    XCTAssertEqual(editor.state.invocations.first?.sourceHash, ToolInvocation.hash("/calc owned"))
  }

  func testEditingCommandTokenInvalidatesMetadataWithoutTextLoss() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText(
      "before /calc input after", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(
      tool, token: (editor.state.text as NSString).range(of: "/calc"), space: false)
    await settlePresentationAsync(editor)
    let before = editor.state.text
    let token = (before as NSString).range(of: "/calc")

    editor.textView.insertText(
      "X", replacementRange: NSRange(location: token.location + 1, length: 1))

    XCTAssertEqual(
      editor.state.text,
      (before as NSString).replacingCharacters(
        in: NSRange(location: token.location + 1, length: 1), with: "X"))
    XCTAssertEqual(editor.textView.string, editor.state.text)
    XCTAssertTrue(editor.state.invocations.isEmpty)
  }

  func testFastToolPublishesWithoutProcessingChrome() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("fast", output: "RESULT")
    editor.toolPackages = [tool]
    editor.textView.insertText("/fast", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    let id = editor.state.invocations[0].id
    var phases: [ToolInvocationPhase] = []
    editor.coordinator.onTransaction = { result in
      phases.append(contentsOf: result.after.invocations.filter { $0.id == id }.map(\.phase))
    }

    editor.toolController.submit(id)
    try await pending(editor)

    XCTAssertFalse(phases.contains(.processing), "Observed phases: \(phases)")
    XCTAssertFalse(editor.textView.subviews.contains { $0 is NSProgressIndicator })
    XCTAssertTrue(editor.textView.subviews.contains { $0.accessibilityLabel() == "Merge" })
  }

  func testSameLineInvocationsKeepIndependentFocusControlsAndActions() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let first = package("one", output: "ONE"), second = package("two", output: "TWO")
    editor.toolPackages = [first, second]
    editor.textView.insertText(
      "/one left /two right", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(
      first, token: (editor.state.text as NSString).range(of: "/one"), space: false)
    await settlePresentationAsync(editor)
    try editor.toolController.accept(
      second, token: (editor.state.text as NSString).range(of: "/two"), space: false)
    await settlePresentationAsync(editor)
    let ids = editor.state.invocations.map(\.id)
    XCTAssertEqual(editor.textView.subviews.filter { $0.accessibilityLabel() == "Run" }.count, 2)

    for invocation in editor.state.invocations {
      let scope = try XCTUnwrap(invocation.scope.resolve(in: editor.state.lines))
      editor.textView.setSelectedRange(NSRange(location: NSMaxRange(scope), length: 0))
      XCTAssertEqual(editor.toolController.focused()?.id, invocation.id)
    }
    editor.toolController.submit(ids[0])
    try await pending(editor, id: ids[0])
    XCTAssertEqual(editor.state.invocations.first { $0.id == ids[1] }?.phase, .inputting)
    XCTAssertEqual(editor.textView.subviews.filter { $0.accessibilityLabel() == "Run" }.count, 1)
    XCTAssertEqual(editor.textView.subviews.filter { $0.accessibilityLabel() == "Merge" }.count, 1)
    try editor.toolController.merge(ids[0])
    XCTAssertTrue(editor.state.text.contains("ONE"))
    XCTAssertTrue(editor.state.text.contains("/two"))
    editor.toolController.submit(ids[1])
    try await pending(editor, id: ids[1])
    try editor.toolController.dismiss(ids[1])
    XCTAssertTrue(editor.state.text.contains("/two"))
    XCTAssertFalse(editor.state.text.contains("TWO"))
  }

  func testContextualEmptyValidationIsTransientAndDoesNotExecute() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    var tool = package("context", mode: .contextual, output: "EXECUTED")
    tool.manifest.outputOperation = .replaceContext
    editor.toolPackages = [tool]
    editor.textView.insertText("/context", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 8), space: false)
    await settlePresentationAsync(editor)
    let id = editor.state.invocations[0].id, before = editor.state
    editor.textView.history.removeAllActions()

    editor.toolController.submit(id)

    XCTAssertEqual(
      editor.toolController.warning(for: id), "Enter content within the tool’s input limit.")
    XCTAssertEqual(editor.state, before)
    XCTAssertFalse(editor.textView.history.canUndo)
    XCTAssertFalse(editor.state.text.contains("EXECUTED"))
    editor.textView.insertText("source ", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertNil(editor.toolController.warning(for: id))
  }

  func testEditorInputByteAndOutputLineCapsPublishNoPartialOutput() async throws {
    for cap in ["input", "output"] {
      let (editor, window) = try await editor()
      defer { window.orderOut(nil) }
      var tool = package("limit", output: "first\nsecond\nthird")
      if cap == "input" {
        tool.manifest.maximumInputBytes = 4
      } else {
        tool.manifest.maximumOutputLines = 2
      }
      editor.toolPackages = [tool]
      editor.textView.insertText("/limit", replacementRange: NSRange(location: 0, length: 0))
      try editor.toolController.accept(tool, token: NSRange(location: 0, length: 6), space: true)
      await settlePresentationAsync(editor)
      if cap == "input" {
        editor.textView.insertText("🌲a", replacementRange: editor.textView.selectedRange())
      }
      let id = editor.state.invocations[0].id, before = editor.state.text
      editor.toolController.submit(id)
      if cap == "input" {
        XCTAssertEqual(
          editor.toolController.warning(for: id), "Enter content within the tool’s input limit.")
        XCTAssertEqual(editor.state.invocations[0].phase, .inputting)
      } else {
        try await error(editor, id: id)
        XCTAssertEqual(editor.state.invocations[0].message, "Output exceeds the tool limit.")
      }
      XCTAssertEqual(editor.state.text, before)
      XCTAssertNil(editor.state.invocations[0].output)
      XCTAssertFalse(editor.state.text.contains("first"))
    }
  }

  func testPendingRelaunchRestoresActionsWithoutReexecution() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ToolRelaunch-\(UUID())")
    removeAfterStoresClose(directory)
    let tool = package("test", output: "REEXECUTED")
    let snapshot = try persistedPendingSnapshot(
      package: tool, packageVersion: 1, output: "PERSISTED")
    let store = ownStore(SQLiteStore(directory: directory))
    let initial = try await store.load()
    _ = try await store.save(
      DocumentSnapshot(
        documentID: initial.documentID, text: snapshot.text,
        revision: snapshot.revision, lines: snapshot.lines, invocations: snapshot.invocations))
    try await store.close()

    let (editor, window) = try await editor(directory: directory)
    defer { window.orderOut(nil) }
    editor.toolPackages = [tool]
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(editor.state.text, "/testPERSISTED")
    XCTAssertEqual(editor.state.invocations.first?.phase, .pending)
    XCTAssertEqual(
      Set(editor.textView.subviews.compactMap { $0.accessibilityLabel() }), ["Merge", "Dismiss"])
    XCTAssertFalse(editor.state.text.contains("REEXECUTED"))
  }

  func testRelaunchMapsOlderCompatiblePackageWithoutReexecution() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ToolRelaunch-\(UUID())")
    removeAfterStoresClose(directory)
    var tool = package("test", output: "REEXECUTED")
    tool.manifest.version = 2
    tool.manifest.compatibleVersions = [1]
    let snapshot = try persistedPendingSnapshot(
      package: tool, packageVersion: 1, output: "PERSISTED")
    let store = ownStore(SQLiteStore(directory: directory))
    let initial = try await store.load()
    _ = try await store.save(
      DocumentSnapshot(
        documentID: initial.documentID, text: snapshot.text,
        revision: snapshot.revision, lines: snapshot.lines, invocations: snapshot.invocations))
    try await store.close()

    let (editor, window) = try await editor(directory: directory)
    defer { window.orderOut(nil) }
    editor.toolPackages = [tool]
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(editor.state.text, "/testPERSISTED")
    XCTAssertEqual(editor.state.invocations.first?.packageVersion, 2)
    XCTAssertEqual(editor.state.invocations.first?.phase, .pending)
    XCTAssertFalse(editor.state.text.contains("REEXECUTED"))
  }

  func testPendingDeletionConfirmationPartialTextUndoAndEscape() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc", output: "RESULT")
    editor.toolPackages = [tool]
    editor.textView.insertText(
      "prefix /calc suffix", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 7, length: 5), space: true)
    await settlePresentationAsync(editor)
    let id = editor.state.invocations[0].id
    editor.toolController.submit(id)
    try await pending(editor)
    let before = editor.state
    let selection = NSRange(location: 8, length: 2)
    editor.textView.setSelectedRange(selection)
    editor.textView.deleteBackward(nil)
    let sheet = try XCTUnwrap(window.attachedSheet)
    XCTAssertEqual(editor.state, before)
    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(editor.state, before)
    try editor.toolController.deletePending(in: selection, expectedRevision: before.revision)
    XCTAssertEqual(
      editor.state.text, (before.text as NSString).replacingCharacters(in: selection, with: ""))
    XCTAssertTrue(editor.state.invocations.isEmpty)
    editor.textView.history.undo()
    XCTAssertEqual(editor.state.text, before.text)
    XCTAssertEqual(editor.state.invocations.first?.phase, .pending)
    let output = try XCTUnwrap(editor.state.invocations[0].output?.resolve(in: editor.state.lines))
    editor.textView.setSelectedRange(NSRange(location: output.location + 2, length: 0))
    XCTAssertTrue(editor.toolPresentation.escape())
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    XCTAssertEqual(editor.state.text, "prefix /calc  suffix")
  }

  func testDeleteMultiplePendingCallsAndRejectProcessingIntersection() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("calc")
    editor.toolPackages = [tool]
    editor.textView.insertText("/calc\n/calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    editor.toolController.submit(editor.state.invocations[0].id)
    try await pending(editor)
    let second = (editor.state.text as NSString).range(of: "/calc", options: .backwards)
    try editor.toolController.accept(tool, token: second, space: false)
    await settlePresentationAsync(editor)
    let id = try XCTUnwrap(editor.state.invocations.last?.id)
    editor.toolController.submit(id)
    for _ in 0..<300 where editor.state.invocations.contains(where: { $0.phase != .pending }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    // This direct adapter call has no separate native event to close publication’s undo group.
    // Isolate the deletion inverse; publication chronology has dedicated integration coverage.
    editor.textView.history.removeAllActions()
    let before = editor.state, all = NSRange(location: 0, length: editor.state.text.utf16.count)
    XCTAssertEqual(ToolRangeEditing.intersectingLocks(all, snapshot: before).count, 2)
    try editor.toolController.deletePending(in: all, expectedRevision: before.revision)
    XCTAssertEqual(editor.state.text, "")
    XCTAssertTrue(editor.state.invocations.isEmpty)
    editor.textView.history.undo()
    XCTAssertEqual(editor.state.text, before.text)
    XCTAssertEqual(editor.state.invocations.count, 2)
    var mixed = editor.state.invocations
    mixed[1].phase = .processing
    mixed[1].output = nil
    mixed[1].outputHash = nil
    let snapshot = DocumentSnapshot(
      documentID: editor.state.documentID, text: editor.state.text, revision: editor.state.revision,
      lines: editor.state.lines, landmarks: editor.state.landmarks, invocations: mixed)
    try editor.apply(
      .init(baseRevision: editor.state.revision, origin: .automation, mutation: .tools(snapshot)))
    let locked = editor.state
    try editor.toolController.deletePending(in: all, expectedRevision: locked.revision)
    XCTAssertEqual(editor.state, locked)
  }

  func testContextKeyboardWorksBeforeDraggingAndControlsDoNotOverlap() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("dedupe", mode: .contextual)
    editor.toolPackages = [tool]
    editor.textView.insertText(
      "above\n/dedupe\nbelow", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 6, length: 7), space: false)
    await settlePresentationAsync(editor)
    let endHandle = try XCTUnwrap(
      editor.textView.subviews.first { $0.accessibilityLabel() == "Context end" })
    let run = try XCTUnwrap(editor.textView.subviews.first { $0.accessibilityLabel() == "Run" })
    XCTAssertFalse(endHandle.frame.intersects(run.frame), "\(endHandle.frame) vs \(run.frame)")
    let tokenFrame = try XCTUnwrap(
      editor.toolPresentation.geometry(for: NSRange(location: 6, length: 7)).last)
    XCTAssertGreaterThanOrEqual(run.frame.minX, tokenFrame.maxX)
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "",
      charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126)!
    XCTAssertTrue(editor.textView.performKeyEquivalent(with: event))
    XCTAssertEqual(editor.state.invocations[0].scope.resolve(in: editor.state.lines)?.location, 0)
    XCTAssertTrue(window.firstResponder === editor.textView)
  }

  func testContainedTrailingEmptyLineRemainsInsideWrapperAndTrimsOneSpace() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("uuid")
    editor.toolPackages = [tool]
    editor.textView.insertText("/uuid", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 5), space: true)
    await settlePresentationAsync(editor)
    editor.textView.insertText(" test\n", replacementRange: editor.textView.selectedRange())
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    XCTAssertEqual(editor.toolController.content(editor.state.invocations[0]), " test\n")
    XCTAssertEqual(editor.state.text, "/uuid  test\n")
    let caret = try XCTUnwrap(
      editor.toolPresentation.geometry(for: editor.textView.selectedRange()).first)
    let run = try XCTUnwrap(
      editor.textView.subviews.compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "Run"
      })
    XCTAssertGreaterThan(caret.minY, 10)
    XCTAssertEqual(run.frame.minY, caret.minY, accuracy: 1)
    let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
    editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: "/private/tmp/jort-feedback2-newline.png"))
  }

  func testEphemeralHasOnlyPopoverSubmitAndNormalizesOneLeadingSpace() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("write", mode: .ephemeralMultiline)
    editor.toolPackages = [tool]
    editor.textView.insertText("/write", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 6), space: true)
    await settlePresentationAsync(editor)
    XCTAssertFalse(
      editor.textView.subviews.contains { ($0 as? NSButton)?.accessibilityLabel() == "Run" })
    let prompt = try XCTUnwrap(
      editor.view.subviews.first { $0.accessibilityLabel() == "Tool prompt form" })
    XCTAssertTrue(prompt.subviews.contains { ($0 as? NSButton)?.accessibilityLabel() == "Run" })
    editor.toolController.setPrompt("  write an email", for: editor.state.invocations[0].id)
    XCTAssertEqual(editor.toolController.content(editor.state.invocations[0]), " write an email")
  }
  func testContainedCanonicalPublicationLockMergeAndUndo() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("calc")
    editor.toolPackages = [package]
    editor.textView.insertText(
      "I need /calc apples", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 7, length: 5), space: true)
    await settlePresentationAsync(editor)
    XCTAssertEqual(editor.state.invocations.count, 1, "After accept: \(editor.state)")
    XCTAssertEqual(editor.textView.selectedRange().location, 13)
    XCTAssertEqual(editor.textView.selectedRange().length, 0)
    XCTAssertEqual(editor.state.text, "I need /calc  apples")
    XCTAssertEqual(editor.textView.string, editor.state.text)
    editor.textView.insertText("3+3", replacementRange: editor.textView.selectedRange())
    XCTAssertEqual(editor.state.invocations.count, 1, "After typing: \(editor.state)")
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    XCTAssertEqual(editor.toolController.content(editor.state.invocations[0]), "3+3")
    editor.toolController.submit(id)
    try await pending(editor)
    XCTAssertFalse(
      editor.textView(
        editor.textView, shouldChangeTextIn: NSRange(location: 8, length: 1), replacementString: "X"
      ))
    XCTAssertEqual(editor.state.text, "I need /calc 3+36 apples")
    XCTAssertTrue(editor.state.invocations[0].validated(in: editor.state))
    window.setContentSize(NSSize(width: 600, height: 400))
    editor.view.layoutSubtreeIfNeeded()
    await settlePresentationAsync(editor)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
    editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: "/private/tmp/jort-tools-pending.png"))
    try editor.toolController.merge(id)
    XCTAssertEqual(editor.state.text, "I need 6 apples")
    XCTAssertTrue(editor.state.invocations.isEmpty)
    editor.textView.history.undo()
    XCTAssertEqual(editor.state.invocations.first?.phase, .pending)
  }
  func testContextExcludesOnlyTokenAndDismissRestores() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("dedupe", mode: .contextual, output: "done")
    editor.toolPackages = [package]
    editor.textView.insertText(
      "apples /dedupe pears\nnext", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 7, length: 7), space: false)
    await settlePresentationAsync(editor)
    let invocation = try XCTUnwrap(editor.state.invocations.first)
    XCTAssertEqual(editor.toolController.content(invocation), "apples  pears")
    let before = editor.state.text
    editor.toolController.submit(invocation.id)
    try await pending(editor)
    XCTAssertEqual(editor.state.text, "apples /dedupedone pears\nnext")
    try editor.toolController.dismiss(invocation.id)
    XCTAssertEqual(editor.state.text, before)
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    editor.toolController.submit(invocation.id)
    try await pending(editor)
    try editor.toolController.merge(invocation.id)
    XCTAssertEqual(editor.state.text, "done\nnext")
  }
  func testEmptyOutputAndEphemeralPromptNeverPersist() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("write", mode: .ephemeralMultiline, output: "")
    editor.toolPackages = [package]
    editor.textView.insertText("/write", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 6), space: true)
    await settlePresentationAsync(editor)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.setPrompt("Secret prompt", for: id)
    XCTAssertFalse(
      String(data: try PersistenceFormat.encode(editor.state), encoding: .utf8)!.contains(
        "Secret prompt"))
    editor.toolController.submit(id)
    try await pending(editor)
    XCTAssertEqual(editor.state.text, "/write ")
    try editor.toolController.merge(id)
    XCTAssertEqual(editor.state.text, " ")
  }
  func testMultilineContainedAndTwoConcurrentInvocations() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("calc")
    editor.toolPackages = [package]
    editor.textView.insertText("/calc end /calc", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: true)
    await settlePresentationAsync(editor)
    editor.textView.insertText("first\nsecond", replacementRange: editor.textView.selectedRange())
    XCTAssertEqual(editor.state.invocations.count, 1)
    XCTAssertEqual(editor.state.lines.count, 2)
    let last = (editor.state.text as NSString).range(of: "/calc", options: .backwards)
    try editor.toolController.accept(package, token: last, space: false)
    await settlePresentationAsync(editor)
    XCTAssertEqual(editor.state.invocations.count, 2)
    let ids = editor.state.invocations.map(\.id)
    for id in ids { editor.toolController.submit(id) }
    for _ in 0..<500 {
      if editor.state.invocations.allSatisfy({ $0.phase == .pending }) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(editor.state.invocations.allSatisfy { $0.phase == .pending })
    XCTAssertTrue(editor.state.invocations.allSatisfy { $0.validated(in: editor.state) })
    for id in ids { try editor.toolController.merge(id) }
    XCTAssertEqual(editor.state.text, "6 end 6")
  }
  func testValidationCancelAndPackageChangeDoNotPublishLateOutput() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    var package = package("test")
    package.source =
      "export async function validate(input) { return {error: 'Please revise'}; } export default async function() { return {output:'never'}; }"
    editor.toolPackages = [package]
    editor.textView.insertText("/test", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.submit(id)
    for _ in 0..<500 where editor.toolController.warning(for: id) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    XCTAssertEqual(editor.toolController.warning(for: id), "Please revise")
    XCTAssertNil(editor.state.invocations.first?.message)
    XCTAssertEqual(editor.state.text, "/test")
    editor.toolController.cancel(id)
    XCTAssertTrue(editor.state.invocations.isEmpty)
    package.source = "export default async function() { while(true) {} }"
    editor.toolPackages = [package]
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    let runningID = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.submit(runningID)
    for _ in 0..<500 where editor.state.invocations.first?.phase == .inputting {
      try await Task.sleep(for: .milliseconds(10))
    }
    editor.toolController.cancel(runningID)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(editor.state.text, "/test")
    XCTAssertTrue(editor.state.invocations.isEmpty)
  }

  func testValidationWarningIsTransientUsesCapturedInputAndClearsOnlyForInvocationChanges()
    async throws
  {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let uuid = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let clock = ISO8601DateFormatter().string(from: date)
    var package = package("test")
    package.source = """
      export async function validate(input) {
        return input.clock === '\(clock)' && input.uuid === '\(uuid.uuidString.lowercased())'
          ? {error: 'Revise captured input'} : {error: 'Input was recaptured'};
      }
      export default async function(input) { return {output: input.clock + '|' + input.uuid}; }
      """
    editor.toolPackages = [package]
    editor.toolController.executionInputFactory = {
      ToolExecutionInput(content: $0, date: date, uuid: uuid)
    }
    editor.textView.insertText(
      "/test\nunrelated", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    let id = editor.state.invocations[0].id
    editor.textView.history.removeAllActions()
    let before = editor.state
    editor.toolController.submit(id)
    for _ in 0..<500 where editor.toolController.warning(for: id) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(editor.toolController.warning(for: id), "Revise captured input")
    XCTAssertEqual(editor.state, before)
    XCTAssertFalse(editor.textView.history.canUndo)
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    XCTAssertEqual(editor.toolController.warning(for: id), "Revise captured input")
    editor.textView.insertText(
      "!", replacementRange: NSRange(location: editor.state.text.utf16.count, length: 0))
    XCTAssertEqual(editor.toolController.warning(for: id), "Revise captured input")
    editor.toolController.submit(id)
    XCTAssertNil(editor.toolController.warning(for: id))
    for _ in 0..<500 where editor.toolController.warning(for: id) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    editor.textView.insertText("x", replacementRange: NSRange(location: 5, length: 0))
    XCTAssertNil(editor.toolController.warning(for: id))
    editor.toolController.cancel(id)
    XCTAssertNil(editor.toolController.warning(for: id))

    var success = package
    success.source = """
      export async function validate(input) {
        return input.clock === '\(clock)' && input.uuid === '\(uuid.uuidString.lowercased())'
          ? {output: ''} : {error: 'Input was recaptured'};
      }
      export default async function(input) { return {output: input.clock + '|' + input.uuid}; }
      """
    editor.toolPackages = [success]
    let token = (editor.state.text as NSString).range(of: "/test")
    try editor.toolController.accept(success, token: token, space: false)
    await settlePresentationAsync(editor)
    let successID = editor.state.invocations[0].id
    editor.toolController.submit(successID)
    try await pending(editor)
    XCTAssertTrue(editor.state.text.contains("\(clock)|\(uuid.uuidString.lowercased())"))
  }

  func testPendingAndErrorDismissRestorePreSubmitMetadataSelectionAndViewport() async throws {
    for fails in [false, true] {
      let (editor, window) = try await editor()
      defer { window.orderOut(nil) }
      var package = package("test", output: "RESULT")
      if fails { package.source = "export default async function() { return {error:'failed'}; }" }
      editor.toolPackages = [package]
      editor.textView.insertText(
        String(repeating: "line\n", count: 30) + "/test tail",
        replacementRange: NSRange(location: 0, length: 0))
      let token = (editor.state.text as NSString).range(of: "/test")
      try editor.toolController.accept(package, token: token, space: false)
      await settlePresentationAsync(editor)
      let id = editor.state.invocations[0].id
      editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
      editor.textView.scrollRangeToVisible(token)
      editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
      let selection = (editor.state.text as NSString).range(of: "tail")
      editor.textView.setSelectedRange(selection)
      let viewport = editor.scroll.contentView.bounds.origin
      let original = editor.state.invocations[0]
      editor.toolController.submit(id)
      if fails {
        for _ in 0..<500 where editor.state.invocations[0].phase != .error {
          try await Task.sleep(for: .milliseconds(10))
        }
      } else {
        try await pending(editor)
      }
      editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
      editor.scroll.contentView.scroll(to: .zero)
      try editor.toolController.dismiss(id)
      XCTAssertEqual(editor.state.invocations[0], original)
      XCTAssertEqual(editor.textView.selectedRange(), selection)
      XCTAssertEqual(editor.scroll.contentView.bounds.origin.y, viewport.y, accuracy: 1)
    }
  }

  func testImmediatePublicationUndoRestoresPreSubmitMetadataSelectionAndViewport() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("test", output: "RESULT")
    editor.toolPackages = [package]
    editor.textView.insertText(
      String(repeating: "line\n", count: 30) + "/test tail",
      replacementRange: NSRange(location: 0, length: 0))
    let token = (editor.state.text as NSString).range(of: "/test")
    try editor.toolController.accept(package, token: token, space: false)
    await settlePresentationAsync(editor)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.textView.scrollRangeToVisible(token)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let selection = (editor.state.text as NSString).range(of: "tail")
    editor.textView.setSelectedRange(selection)
    let viewport = editor.scroll.contentView.bounds.origin
    let original = editor.state.invocations[0]
    editor.textView.history.removeAllActions()
    editor.toolController.submit(original.id)
    try await pending(editor)
    editor.textView.history.undo()
    XCTAssertEqual(editor.state.invocations[0], original)
    XCTAssertEqual(editor.textView.selectedRange(), selection)
    XCTAssertEqual(editor.scroll.contentView.bounds.origin.y, viewport.y, accuracy: 1)
  }
  func testKeyboardCompletionAcceptanceSubmissionAndPlainPaste() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    editor.toolPackages = [package("calc")]
    func key(_ characters: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
      editor.textView.keyDown(with: event)
    }
    window.makeFirstResponder(editor.textView)
    key("/", code: 44)
    key("ca")
    key("\r", code: 36)
    XCTAssertEqual(editor.state.text, "/calc ")
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    XCTAssertEqual(editor.toolController.content(editor.state.invocations[0]), "")
    key("3+3")
    key("\r", code: 36, modifiers: .shift)
    try await pending(editor)
    XCTAssertEqual(editor.state.text, "/calc 3+36")
    let actions = (editor.textView.accessibilityChildren() ?? []).compactMap {
      ($0 as? NSButton)?.accessibilityLabel()
    }
    XCTAssertTrue(actions.contains("Merge"))
    XCTAssertTrue(actions.contains("Dismiss"))
    let id = editor.state.invocations[0].id
    try editor.toolController.dismiss(id)
    editor.toolController.cancel(id)
    editor.textView.setSelectedRange(NSRange(location: editor.state.text.utf16.count, length: 0))
    editor.toolPresentation.abandonCompletion()
    editor.textView.isPasting = true
    editor.textView.insertText(" /calc", replacementRange: editor.textView.selectedRange())
    editor.textView.isPasting = false
    key(" ", code: 49)
    XCTAssertTrue(editor.state.invocations.isEmpty)
  }
  func testPackageMappingPreservesCompletedOutputAndContext() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    var package = package("dedupe", mode: .contextual, output: "result")
    editor.toolPackages = [package]
    editor.textView.insertText(
      "source /dedupe tail", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 7, length: 7), space: false)
    await settlePresentationAsync(editor)
    let id = editor.state.invocations[0].id
    editor.toolController.submit(id)
    try await pending(editor)
    package.manifest.version = 2
    package.manifest.compatibleVersions = [1]
    editor.toolPackages = [package]
    XCTAssertEqual(editor.state.invocations[0].packageVersion, 2)
    XCTAssertEqual(editor.state.invocations[0].phase, .pending)
    package.manifest.version = 3
    package.manifest.compatibleVersions = nil
    editor.toolPackages = [package]
    XCTAssertEqual(editor.state.text, "source result tail")
    XCTAssertTrue(editor.state.invocations.isEmpty)
  }

  func testEphemeralDismissRestoresPromptAndTransfersFocus() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("write", mode: .ephemeralMultiline, output: "Customer email")
    editor.toolPackages = [package]
    editor.textView.insertText("/write", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 6), space: false)
    await settlePresentationAsync(editor)
    let id = editor.state.invocations[0].id
    let input = try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertFalse(input === editor.textView)
    input.insertText(
      "Write about new SKUs\nKeep it concise", replacementRange: input.selectedRange())
    XCTAssertEqual(editor.toolController.prompt(for: id), input.string)
    editor.toolController.submit(id)
    try await pending(editor)
    XCTAssertTrue(window.firstResponder === editor.textView)
    try editor.toolController.dismiss(id)
    await settlePresentationAsync(editor)
    let restored = try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertFalse(restored === editor.textView)
    XCTAssertEqual(restored.string, "Write about new SKUs\nKeep it concise")
    restored.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertTrue(editor.state.invocations.isEmpty)
    XCTAssertNil(editor.toolController.prompt(for: id))
    XCTAssertEqual(editor.state.text, "/write")
  }

  func testInsertAtInvocationKeepsContextAndEmptyReplaceContext() async throws {
    for empty in [false, true] {
      let (editor, window) = try await editor()
      defer { window.orderOut(nil) }
      var package = package("test", mode: .contextual, output: empty ? "" : "RESULT")
      package.manifest.outputOperation = empty ? .replaceContext : .insertAtInvocation
      editor.toolPackages = [package]
      editor.textView.insertText(
        "before /test after\nnext", replacementRange: NSRange(location: 0, length: 0))
      try editor.toolController.accept(
        package, token: NSRange(location: 7, length: 5), space: false)
      await settlePresentationAsync(editor)
      let id = editor.state.invocations[0].id
      editor.toolController.submit(id)
      try await pending(editor)
      try editor.toolController.merge(id)
      XCTAssertEqual(editor.state.text, empty ? "\nnext" : "before RESULT after\nnext")
      editor.textView.history.undo()
      XCTAssertEqual(editor.state.invocations.first?.phase, .pending)
      editor.textView.history.redo()
      XCTAssertEqual(editor.state.text, empty ? "\nnext" : "before RESULT after\nnext")
    }
  }

  func testCrawlLargeDocumentToolPipelineDistributions() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("test", mode: .contextual, output: "RESULT")
    editor.toolPackages = [package]
    editor.textView.insertText(
      "/test\n" + CrawlLargeDocument.text, replacementRange: NSRange(location: 0, length: 0))
    var parse: [Double] = [], geometry: [Double] = [], movement: [Double] = [],
      lifecycle: [Double] = [], commit: [Double] = []
    func clock() -> Double { ProcessInfo.processInfo.systemUptime }
    for _ in 0..<6 {
      var start = clock()
      try editor.toolController.accept(
        package, token: NSRange(location: 0, length: 5), space: false)
      await settlePresentationAsync(editor)
      parse.append(clock() - start)
      let id = editor.state.invocations[0].id
      start = clock()
      try editor.toolController.moveBoundary(id, start: false, to: editor.state.text.utf16.count)
      movement.append(clock() - start)
      start = clock()
      editor.refreshToolPresentation()
      await settlePresentationAsync(editor)
      geometry.append(clock() - start)
      // A bounded prefix fits the execution cap while retaining the large document.
      try editor.toolController.moveBoundary(id, start: false, to: 100)
      start = clock()
      editor.toolController.submit(id)
      try await pending(editor)
      lifecycle.append(clock() - start)
      start = clock()
      try editor.toolController.dismiss(id)
      commit.append(clock() - start)
      editor.toolController.cancel(id)
    }
    func p95(_ values: [Double]) -> Double {
      values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] * 1000
    }
    print(
      "PERF Tools CrawlLargeDocument ms p95: recognition+accept=\(p95(parse)), geometry=\(p95(geometry)), full-context-movement=\(p95(movement)), submit+publish=\(p95(lifecycle)), dismiss-commit=\(p95(commit))"
    )
    XCTAssertEqual(editor.state.text, "/test\n" + CrawlLargeDocument.text)
  }

  func testIMECommitBoundaryMatchingAndLockedPlainCopy() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    editor.toolPackages = [package("calc")]
    window.makeFirstResponder(editor.textView)
    editor.textView.setMarkedText(
      "/calc", selectedRange: NSRange(location: 5, length: 0),
      replacementRange: NSRange(location: 0, length: 0))
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    XCTAssertTrue(editor.state.invocations.isEmpty)
    XCTAssertFalse(
      editor.textView.subviews.contains { ($0 as? NSButton)?.accessibilityLabel() == "/calc  calc" }
    )
    editor.textView.unmarkText()
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let accept = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: " ",
      charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
    editor.textView.keyDown(with: accept)
    XCTAssertEqual(editor.state.invocations.count, 1)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.submit(id)
    try await pending(editor)
    editor.textView.setSelectedRange(NSRange(location: 0, length: editor.state.text.utf16.count))
    editor.textView.copy(nil)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), editor.state.text)
    XCTAssertTrue(
      NSPasteboard.general.types?.allSatisfy {
        [.string, NSPasteboard.PasteboardType("NSStringPboardType")].contains($0)
      } == true)
    let before = editor.state
    editor.textView.insertText("replacement", replacementRange: editor.textView.selectedRange())
    XCTAssertEqual(editor.state, before)
    XCTAssertEqual(editor.textView.string, before.text)
    try editor.toolController.dismiss(id)
    editor.toolController.cancel(id)
    editor.textView.setSelectedRange(NSRange(location: editor.state.text.utf16.count, length: 0))
    editor.textView.insertText("(", replacementRange: editor.textView.selectedRange())
    editor.textView.insertText("/", replacementRange: editor.textView.selectedRange())
    editor.textView.insertText("calc", replacementRange: editor.textView.selectedRange())
    editor.textView.keyDown(with: accept)
    XCTAssertTrue(editor.state.invocations.isEmpty)
  }

  func testContextHandlesClampPendingOutputAndComposedCharacters() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let contained = package("calc", output: "RESULT"),
      contextual = package("sort", mode: .contextual)
    editor.toolPackages = [contained, contextual]
    editor.textView.insertText(
      "/calc\n🦊 before /sort after", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(
      contained, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    let first = editor.state.invocations[0].id
    editor.toolController.submit(first)
    try await pending(editor)
    let token = (editor.state.text as NSString).range(of: "/sort")
    try editor.toolController.accept(contextual, token: token, space: false)
    await settlePresentationAsync(editor)
    let context = try XCTUnwrap(editor.state.invocations.first { $0.id != first })
    let original = try XCTUnwrap(context.scope.resolve(in: editor.state.lines))
    try editor.toolController.moveBoundary(context.id, start: true, to: original.location + 1)
    XCTAssertEqual(
      editor.state.invocations.first { $0.id == context.id }?.scope.resolve(in: editor.state.lines)?
        .location, original.location)
    try editor.toolController.moveBoundary(context.id, start: true, to: 0)
    XCTAssertEqual(
      editor.state.invocations.first { $0.id == context.id }?.scope.resolve(in: editor.state.lines)?
        .location, 11)
    XCTAssertTrue(editor.state.invocations.allSatisfy { $0.validated(in: editor.state) })
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let handles = editor.textView.subviews.filter { $0.accessibilityRole() == .slider }
    XCTAssertEqual(
      Set(handles.compactMap { $0.accessibilityLabel() }), ["Context start", "Context end"])
    let end = try XCTUnwrap(handles.first { $0.accessibilityLabel() == "Context end" })
    let click = NSEvent.mouseEvent(
      with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    end.mouseDown(with: click)
    let originalEnd = NSMaxRange(
      try XCTUnwrap(
        editor.state.invocations.first { $0.id == context.id }?.scope.resolve(
          in: editor.state.lines)))
    let left = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.option, .shift], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "",
      charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!
    end.keyDown(with: left)
    XCTAssertTrue(window.firstResponder === end)
    end.keyDown(with: left)
    XCTAssertTrue(window.firstResponder === end)
    XCTAssertEqual(
      editor.state.invocations.first { $0.id == context.id }?.scope.resolve(in: editor.state.lines)
        .map(NSMaxRange), originalEnd - 2)
    XCTAssertTrue(end.accessibilityPerformIncrement())
    XCTAssertEqual(
      editor.state.invocations.first { $0.id == context.id }?.scope.resolve(in: editor.state.lines)
        .map(NSMaxRange), originalEnd - 1)
    XCTAssertTrue(end.accessibilityPerformDecrement())
  }

  func testPublicationUndoRespectsUnrelatedEditChronology() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("calc")
    editor.toolPackages = [package]
    editor.textView.insertText("/calc tail", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: true)
    await settlePresentationAsync(editor)
    editor.textView.insertText("3+3", replacementRange: editor.textView.selectedRange())
    let id = editor.state.invocations[0].id, input = editor.state.text
    editor.textView.history.removeAllActions()
    editor.toolController.submit(id)
    try await pending(editor)
    let published = editor.state.text
    try await Task.sleep(for: .milliseconds(20))
    editor.textView.insertText(
      "!", replacementRange: NSRange(location: editor.state.text.utf16.count, length: 0))
    try await Task.sleep(for: .milliseconds(20))
    editor.textView.history.undo()
    XCTAssertEqual(editor.state.text, published)
    XCTAssertEqual(editor.state.invocations.first?.phase, .pending)
    editor.textView.history.undo()
    XCTAssertEqual(editor.state.text, input)
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    editor.textView.history.redo()
    XCTAssertEqual(editor.state.text, published)
    XCTAssertEqual(editor.state.invocations.first?.phase, .pending)
  }

  func testPublicationAndMergeKeepSelectedSurroundingText() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = package("calc", output: "First result\nSecond result")
    editor.toolPackages = [package]
    editor.textView.insertText(
      "/calc tail\nlast", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: false)
    await settlePresentationAsync(editor)
    let id = editor.state.invocations[0].id, lastLineID = editor.state.lines.last?.id
    let selected = (editor.state.text as NSString).range(of: "tail")
    editor.textView.setSelectedRange(selected)
    let viewport = editor.textView.enclosingScrollView?.contentView.bounds.origin
    editor.toolController.submit(id)
    try await pending(editor)
    XCTAssertEqual(
      (editor.state.text as NSString).substring(with: editor.textView.selectedRange()), "tail")
    try editor.toolController.merge(id)
    XCTAssertEqual(
      (editor.state.text as NSString).substring(with: editor.textView.selectedRange()), "tail")
    XCTAssertEqual(editor.state.lines.last?.id, lastLineID)
    XCTAssertEqual(editor.textView.enclosingScrollView?.contentView.bounds.origin, viewport)
    editor.textView.history.undo()
    XCTAssertEqual(
      (editor.state.text as NSString).substring(with: editor.textView.selectedRange()), "tail")
  }

  func testPackageRemovalFallbacksPreserveCanonicalContentInEveryMode() async throws {
    for mode in [ToolInputMode.contained, .contextual, .ephemeralMultiline] {
      for output in ["", "RESULT"] {
        let (editor, window) = try await editor()
        defer { window.orderOut(nil) }
        let package = package("test", mode: mode, output: output)
        editor.toolPackages = [package]
        editor.textView.insertText(
          "before /test after\nnext", replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(
          package, token: NSRange(location: 7, length: 5), space: false)
        await settlePresentationAsync(editor)
        if mode == .contained {
          editor.textView.insertText("input", replacementRange: editor.textView.selectedRange())
        }
        let id = editor.state.invocations[0].id, input = editor.state.text
        if mode.isEphemeral { editor.toolController.setPrompt("Not canonical", for: id) }
        editor.toolPackages = []
        XCTAssertEqual(editor.state.text, input)
        XCTAssertTrue(editor.state.invocations.isEmpty)
        editor.toolPackages = [package]
        try editor.toolController.accept(
          package, token: NSRange(location: 7, length: 5), space: false)
        await settlePresentationAsync(editor)
        let running = editor.state.invocations[0].id
        if mode == .contained {
          editor.textView.insertText("owned", replacementRange: editor.textView.selectedRange())
        }
        if mode.isEphemeral { editor.toolController.setPrompt("Not canonical", for: running) }
        editor.toolController.submit(running)
        try await pending(editor)
        editor.toolPackages = []
        XCTAssertTrue(editor.state.invocations.isEmpty)
        // The previous contained input was orphaned by removal, so it is unrelated now.
        XCTAssertEqual(
          editor.state.text,
          "before " + output + (mode == .contained ? "input" : "") + " after\nnext")
      }
    }
  }
}
