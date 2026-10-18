import AppKit
import JortDocument
import JortToolContracts
import JortToolRuntime
import XCTest
@testable import JortAppKit

@MainActor private final class InlineInvocationSpy: ToolInvocationCoordinating {
  var transient = InvocationTransientState()
  var submitted: [ToolExecutionInput] = []
  func hasJob(_ id: UUID) -> Bool { false }
  func remove(_ id: UUID) {}
  func submit(
    identity: InvocationGeneration, package: ToolPackage, input: ToolExecutionInput,
    apply: @escaping @MainActor (InvocationDocumentEffect) -> Bool,
    warning: @escaping @MainActor (String) -> Void
  ) { submitted.append(input) }
}

private struct InlineFailureExecutor: ToolExecuting {
  func validate(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult {
    .init(output: "")
  }
  func execute(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult {
    .init(error: "The delimiter service is unavailable.")
  }
}

@MainActor final class InlineInvocationUXTests: ToolInvocationTestCase {
  private func splitTool() -> ToolPackage {
    var tool = package("split", mode: .contextual)
    tool.manifest.schemaVersion = 3
    tool.manifest.executor = .javascript
    tool.manifest.entryContract = 2
    tool.manifest.arguments = [
      ToolArgumentDefinition(name: "delimiter", type: .string, label: "Delimiter", required: true)
    ]
    return tool
  }

  private func acceptInline(
    _ editor: EditorViewController, tool: ToolPackage, source: String = "apples,oranges /split",
    inputs: String = ","
  ) throws -> ToolInvocation {
    editor.toolPackages = [tool]
    editor.textView.insertText(source, replacementRange: NSRange(location: 0, length: 0))
    let text = source as NSString
    let command = text.range(of: "/split")
    try editor.toolController.accept(tool, token: command, space: true)
    editor.textView.insertText(inputs, replacementRange: editor.textView.selectedRange())
    return try XCTUnwrap(editor.state.invocations.first)
  }

  private func press(
    _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
    in window: NSWindow
  ) throws {
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    try XCTUnwrap(window.firstResponder).keyDown(with: event)
  }

  func testInlineCallSubmitsOnlyContextAndParsesTypedArguments() async throws {
    let (editor, _) = try await editor()
    let spy = InlineInvocationSpy()
    editor.toolInvocationCoordinator = spy
    let invocation = try acceptInline(editor, tool: splitTool())
    let call = try XCTUnwrap(invocation.call?.resolve(in: editor.state))
    XCTAssertEqual((editor.state.text as NSString).substring(with: call), "/split ,")
    XCTAssertEqual(invocation.inlineInput(in: editor.state), ",")
    XCTAssertEqual(invocation.contextRanges(in: editor.state).map(\.location), [0])
    XCTAssertFalse(invocation.contextRanges(in: editor.state).contains(call))

    editor.toolController.submit(invocation.id)
    let input = try XCTUnwrap(spy.submitted.first)
    XCTAssertEqual(input.content, "apples,oranges ")
    XCTAssertEqual(input.arguments, ["delimiter": .string(",")])
  }

  func testNewInlineCallDoesNotPresentLegacyArgumentPopover() async throws {
    let (editor, _) = try await editor()
    _ = try acceptInline(editor, tool: splitTool())
    await settlePresentationAsync(editor)
    XCTAssertFalse(editor.view.subviews.contains { $0 is ToolArgumentFormView })
  }

  func testInlineArgumentValidationKeepsInputCaretAndDoesNotSubmit() async throws {
    let (editor, window) = try await editor()
    let spy = InlineInvocationSpy()
    editor.toolInvocationCoordinator = spy
    let invocation = try acceptInline(
      editor, tool: splitTool(), source: "apples /split", inputs: "")
    // Real users submit after the call and help have already been rendered.
    // A transient validation error must refresh without a document revision.
    await settlePresentationAsync(editor)
    let revision = editor.state.revision
    editor.toolController.submit(invocation.id)
    await settlePresentationAsync(editor)
    XCTAssertEqual(editor.state.revision, revision)
    XCTAssertTrue(spy.submitted.isEmpty)
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    XCTAssertTrue(window.firstResponder === editor.textView)
    let warning = try XCTUnwrap(editor.toolController.warning(for: invocation.id))
    let labels = editor.linePresentation.accessories.values.flatMap {
      ($0.view as? NSStackView)?.arrangedSubviews ?? []
    }.compactMap { $0 as? NSTextField }
    let error = try XCTUnwrap(labels.first { $0.stringValue.contains(warning) })
    XCTAssertEqual(error.textColor, .systemRed)
    XCTAssertEqual(error.accessibilityLabel(), "Tool error: \(warning)")
    XCTAssertNotNil(error.window)
    XCTAssertFalse(error.isHiddenOrHasHiddenAncestor)
    XCTAssertGreaterThan(error.bounds.height, 0)
  }

  func testContextHandleTabCycleEscapeAndPlainArrowNavigation() async throws {
    let (editor, window) = try await editor()
    let invocation = try acceptInline(editor, tool: splitTool())
    await settlePresentationAsync(editor)
    let call = try XCTUnwrap(invocation.call?.resolve(in: editor.state))
    editor.textView.setSelectedRange(NSRange(location: NSMaxRange(call), length: 0))
    window.makeFirstResponder(editor.textView)

    try press("\t", code: 48, in: window)
    XCTAssertEqual((window.firstResponder as? NSView)?.accessibilityLabel(), "Context start")
    try press("\u{f703}", code: 124, in: window)
    XCTAssertEqual((window.firstResponder as? NSView)?.accessibilityLabel(), "Context start")
    XCTAssertEqual(editor.state.invocations.first?.scope.resolve(in: editor.state)?.location, 1)
    try press("\t", code: 48, in: window)
    XCTAssertEqual((window.firstResponder as? NSView)?.accessibilityLabel(), "Context end")
    try press("\t", code: 48, in: window)
    XCTAssertEqual((window.firstResponder as? NSView)?.accessibilityLabel(), "Context start")
    try press("\t", code: 48, modifiers: .shift, in: window)
    XCTAssertEqual((window.firstResponder as? NSView)?.accessibilityLabel(), "Context end")
    try press("\t", code: 48, modifiers: .shift, in: window)
    XCTAssertEqual((window.firstResponder as? NSView)?.accessibilityLabel(), "Context start")
    try press("\t", code: 48, in: window)
    XCTAssertEqual((window.firstResponder as? NSView)?.accessibilityLabel(), "Context end")
    try press("\u{1b}", code: 53, in: window)
    XCTAssertTrue(window.firstResponder === editor.textView)
    XCTAssertEqual(editor.state.invocations.first?.id, invocation.id)
    XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: NSMaxRange(call), length: 0))
    try press("\t", code: 48, in: window)
    XCTAssertEqual((window.firstResponder as? NSView)?.accessibilityLabel(), "Context start")
    try press("\r", code: 36, in: window)
    XCTAssertTrue(window.firstResponder === editor.textView)
    XCTAssertEqual(editor.state.invocations.first?.id, invocation.id)
    XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: NSMaxRange(call), length: 0))
    XCTAssertEqual(editor.state.invocations.first?.inlineInput(in: editor.state), ",")
    try press("\t", code: 48, in: window)
    XCTAssertEqual((window.firstResponder as? NSView)?.accessibilityLabel(), "Context start")
    try press("\u{1b}", code: 53, in: window)
    try press("\u{f702}", code: 123, in: window)
    XCTAssertEqual(editor.textView.selectedRange().location, NSMaxRange(call) - 1)
  }

  func testNativeShiftSelectionDoesNotMoveContextBoundaries() async throws {
    let (editor, window) = try await editor()
    let invocation = try acceptInline(editor, tool: splitTool())
    await settlePresentationAsync(editor)
    let call = try XCTUnwrap(invocation.call?.resolve(in: editor.state))
    let scope = invocation.scope
    editor.textView.setSelectedRange(NSRange(location: NSMaxRange(call), length: 0))
    window.makeFirstResponder(editor.textView)

    try press("\u{f702}", code: 123, modifiers: .shift, in: window)
    XCTAssertEqual(
      editor.textView.selectedRange(), NSRange(location: NSMaxRange(call) - 1, length: 1))
    try press("\u{f702}", code: 123, modifiers: [.option, .shift], in: window)
    XCTAssertGreaterThan(editor.textView.selectedRange().length, 1)
    XCTAssertTrue(window.firstResponder === editor.textView)
    XCTAssertEqual(editor.state.invocations.first?.scope, scope)
    XCTAssertEqual(editor.state.text, "apples,oranges /split ,")
  }

  func testReturnClampsCallBeforeNewNote() async throws {
    let (editor, window) = try await editor()
    let invocation = try acceptInline(editor, tool: splitTool())
    await settlePresentationAsync(editor)
    let call = try XCTUnwrap(invocation.call?.resolve(in: editor.state))
    editor.textView.setSelectedRange(NSRange(location: NSMaxRange(call), length: 0))
    window.makeFirstResponder(editor.textView)
    try press("\r", code: 36, in: window)
    editor.textView.insertText("A separate note", replacementRange: editor.textView.selectedRange())

    let after = try XCTUnwrap(editor.state.invocations.first)
    XCTAssertEqual(after.id, invocation.id)
    XCTAssertEqual(after.phase, .inputting)
    XCTAssertEqual(after.call?.resolve(in: editor.state), call)
    XCTAssertEqual(after.inlineInput(in: editor.state), ",")
    XCTAssertEqual(editor.state.text, "apples,oranges /split ,\nA separate note")
  }

  func testTabFocusesOffscreenContextStartAndReturnsToCall() async throws {
    let (editor, window) = try await editor()
    let invocation = try acceptInline(
      editor, tool: splitTool(),
      source: String(repeating: "Long context line\n", count: 200) + "apples,oranges /split")
    try editor.toolController.moveBoundary(invocation.id, start: true, to: 0)
    let call = try XCTUnwrap(editor.state.invocations.first?.call?.resolve(in: editor.state))
    let caret = NSRange(location: NSMaxRange(call), length: 0)
    editor.textView.setSelectedRange(caret)
    editor.textView.scrollRangeToVisible(caret)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    await settlePresentationAsync(editor)
    window.makeFirstResponder(editor.textView)
    XCTAssertGreaterThan(editor.textView.visibleRect.minY, 0)

    try press("\t", code: 48, in: window)
    await settlePresentationAsync(editor)
    let start = try XCTUnwrap(window.firstResponder as? NSView)
    XCTAssertEqual(start.accessibilityLabel(), "Context start")
    XCTAssertTrue(
      start.convert(start.bounds, to: editor.textView).intersects(editor.textView.visibleRect))
    try press("\t", code: 48, in: window)
    await settlePresentationAsync(editor)
    XCTAssertEqual((window.firstResponder as? NSView)?.accessibilityLabel(), "Context end")
    try press("\t", code: 48, in: window)
    await settlePresentationAsync(editor)
    XCTAssertEqual((window.firstResponder as? NSView)?.accessibilityLabel(), "Context start")
    try press("\u{1b}", code: 53, in: window)
    XCTAssertTrue(window.firstResponder === editor.textView)
    XCTAssertEqual(editor.textView.selectedRange(), caret)
  }

  func testEditingInvalidInlineArgumentClearsWarningBeforeResubmission() async throws {
    let (editor, window) = try await editor()
    let spy = InlineInvocationSpy()
    editor.toolInvocationCoordinator = spy
    let invocation = try acceptInline(editor, tool: splitTool(), inputs: "")
    window.makeFirstResponder(editor.textView)
    editor.toolController.submit(invocation.id)
    await settlePresentationAsync(editor)
    XCTAssertNotNil(editor.toolController.warning(for: invocation.id))
    XCTAssertTrue(spy.submitted.isEmpty)

    let call = try XCTUnwrap(editor.state.invocations.first?.call?.resolve(in: editor.state))
    editor.textView.setSelectedRange(NSRange(location: NSMaxRange(call), length: 0))
    editor.textView.insertText(",", replacementRange: editor.textView.selectedRange())
    await settlePresentationAsync(editor)
    XCTAssertNil(editor.toolController.warning(for: invocation.id))
    XCTAssertEqual(editor.state.invocations.first?.inlineInput(in: editor.state), ",")
    XCTAssertTrue(spy.submitted.isEmpty)
    editor.toolController.submit(invocation.id)
    XCTAssertEqual(spy.submitted.count, 1)
    XCTAssertEqual(spy.submitted.first?.arguments, ["delimiter": .string(",")])
  }

  func testEditingInlineCallClearsExecutionErrorBeforeRetry() async throws {
    let (editor, window) = try await editor()
    editor.toolInvocationCoordinator = ToolInvocationCoordinator(executor: InlineFailureExecutor())
    let invocation = try acceptInline(editor, tool: splitTool())
    editor.toolController.submit(invocation.id)
    try await error(editor, id: invocation.id)
    XCTAssertEqual(
      editor.state.invocations.first?.message, "The delimiter service is unavailable.")

    let call = try XCTUnwrap(editor.state.invocations.first?.call?.resolve(in: editor.state))
    window.makeFirstResponder(editor.textView)
    editor.textView.setSelectedRange(NSRange(location: NSMaxRange(call), length: 0))
    editor.textView.insertText(";", replacementRange: editor.textView.selectedRange())
    await settlePresentationAsync(editor)

    XCTAssertEqual(editor.state.invocations.first?.inlineInput(in: editor.state), ",;")
    XCTAssertNil(editor.state.invocations.first?.message)
  }

  func testLegacyBundledModelsReconcileInputtingAndPendingAcrossBundleUpgrade() async throws {
    let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Jort/Resources/Tools")
    for name in ["ask", "rewrite"] {
      for reconcilePending in [false, true] {
        let current = try ToolPackage.load(from: bundled.appendingPathComponent(name))
        XCTAssertEqual(current.manifest.version, 2)
        XCTAssertEqual(current.manifest.entryContract, 2)
        XCTAssertEqual(current.manifest.executorType, .model)
        var legacy = current
        legacy.manifest.schemaVersion = 2
        legacy.manifest.entryContract = 1
        legacy.manifest.version = 1
        legacy.manifest.inputMode = name == "ask" ? .ephemeralMultiline : .contextual
        legacy.manifest.arguments = nil
        let (editor, window) = try await editor()
        defer { window.orderOut(nil) }
        let fake = FakeModelProvider(.success("Legacy answer"))
        editor.toolInvocationCoordinator = ToolInvocationCoordinator(
          executor: ToolExecutorDispatcher(modelAvailable: { true }, provider: { fake }))
        editor.toolPackages = [legacy]
        let command = legacy.manifest.command
        editor.textView.insertText(command, replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(
          legacy, token: NSRange(location: 0, length: command.utf16.count), space: true)
        let accepted = try XCTUnwrap(editor.state.invocations.first)
        let expectedInput: String
        if name == "ask" {
          expectedInput = "Legacy question\nsecond line"
          editor.toolController.setPrompt(expectedInput, for: accepted.id)
        } else {
          expectedInput = "Legacy source text"
          editor.textView.insertText(
            expectedInput, replacementRange: editor.textView.selectedRange())
        }
        XCTAssertNil(editor.state.invocations.first?.call)
        XCTAssertEqual(editor.state.invocations.first?.executor, "model")
        XCTAssertEqual(
          editor.toolController.content(try XCTUnwrap(editor.state.invocations.first)),
          expectedInput)
        if reconcilePending {
          editor.toolController.submit(accepted.id)
          try await pending(editor, id: accepted.id)
        }
        let textBeforeReconcile = editor.state.text
        editor.toolPackages = [current]
        editor.toolController.reconcilePackages()
        let reconciled = try XCTUnwrap(editor.state.invocations.first)
        XCTAssertEqual(editor.state.invocations.count, 1)
        XCTAssertEqual(reconciled.id, accepted.id)
        XCTAssertEqual(reconciled.entryContract, 1)
        XCTAssertEqual(reconciled.packageVersion, 1)
        XCTAssertEqual(reconciled.inputMode, legacy.manifest.inputMode.rawValue)
        XCTAssertEqual(reconciled.executor, "model")
        XCTAssertNil(reconciled.call)
        XCTAssertEqual(editor.state.text, textBeforeReconcile)
        XCTAssertEqual(reconciled.phase, reconcilePending ? .pending : .inputting)
        if !reconcilePending {
          XCTAssertEqual(editor.toolController.content(reconciled), expectedInput)
          editor.toolController.submit(accepted.id)
          try await pending(editor, id: accepted.id)
        }
        let requests = await fake.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.content, expectedInput)
        XCTAssertEqual(requests.first?.version, 1)
        let result = try XCTUnwrap(editor.state.invocations.first)
        XCTAssertEqual(result.id, accepted.id)
        XCTAssertEqual(result.phase, .pending)
        XCTAssertEqual(result.entryContract, 1)
        XCTAssertEqual(result.packageVersion, 1)
        XCTAssertEqual(result.inputMode, legacy.manifest.inputMode.rawValue)
        XCTAssertNil(result.call)
        XCTAssertTrue(editor.state.text.contains("Legacy answer"))
      }
    }
  }

  func testModelInstructionRemainsSeparateFromSelectedContext() async throws {
    let (editor, _) = try await editor()
    let spy = InlineInvocationSpy()
    editor.toolInvocationCoordinator = spy
    var tool = modelPackage(mode: .contextual)
    tool.manifest.schemaVersion = 3
    tool.manifest.entryContract = 2
    tool.manifest.arguments = []
    editor.toolPackages = [tool]
    let source = "source words /model"
    editor.textView.insertText(source, replacementRange: NSRange(location: 0, length: 0))
    let command = (source as NSString).range(of: "/model")
    try editor.toolController.accept(tool, token: command, space: true)
    editor.textView.insertText(
      "summarize briefly", replacementRange: editor.textView.selectedRange())
    let invocation = try XCTUnwrap(editor.state.invocations.first)
    editor.toolController.submit(invocation.id)
    let input = try XCTUnwrap(spy.submitted.first)
    XCTAssertEqual(input.content, "source words ")
    XCTAssertEqual(input.instruction, "summarize briefly")
  }
}
