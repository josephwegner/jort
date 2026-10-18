import AppKit
import JortDocument
import JortToolContracts
import XCTest
@testable import JortAppKit

@MainActor private final class ExecutionShortcutCoordinator: ToolInvocationCoordinating {
  var transient = InvocationTransientState()
  var submitted: [ToolExecutionInput] = []

  func hasJob(_ id: UUID) -> Bool { false }
  func remove(_ id: UUID) {}
  func submit(
    identity: InvocationGeneration, package: ToolPackage, input: ToolExecutionInput,
    apply: @escaping @MainActor (InvocationDocumentEffect) -> Bool,
    warning: @escaping @MainActor (String) -> Void
  ) {
    submitted.append(input)
  }
}

@MainActor final class ExecutionShortcutTests: ToolInvocationTestCase {
  private func bundled(_ name: String) throws -> ToolPackage {
    let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Jort/Resources/Tools")
    return try ToolPackage.load(from: tools.appendingPathComponent(name))
  }

  func testReturnRunsNoParameterGeneratorsWhenSelectingCompletion() async throws {
    for name in ["now", "today", "time", "daily", "date"] {
      let (editor, window) = try await editor()
      defer { window.orderOut(nil) }
      var tool = try bundled(name)
      tool.source = "export default async function() { return {output: 'RESULT'}; }"
      tool.manifest.capturedData = nil
      editor.toolPackages = [tool]
      window.makeFirstResponder(editor.textView)
      key("/", code: 44, in: editor, window: window)
      key(name, code: 0, in: editor, window: window)
      await settlePresentationAsync(editor)
      key("\r", code: 36, in: editor, window: window)
      try await pending(editor)
      XCTAssertEqual(editor.state.text, "/\(name) RESULT")
    }
  }

  func testReturnDoesNotRunToolsThatNeedInputOrContext() async throws {
    for name in ["lorem", "random", "calc", "upper", "remind", "ask"] {
      let (editor, window) = try await editor()
      defer { window.orderOut(nil) }
      let spy = ExecutionShortcutCoordinator()
      editor.toolInvocationCoordinator = spy
      editor.toolPackages = [try bundled(name)]
      window.makeFirstResponder(editor.textView)
      key("/", code: 44, in: editor, window: window)
      key(name, code: 0, in: editor, window: window)
      await settlePresentationAsync(editor)
      key("\r", code: 36, in: editor, window: window)
      await settlePresentationAsync(editor)
      XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
      XCTAssertTrue(spy.submitted.isEmpty, name)
    }
  }

  private func pressShiftReturn(in editor: EditorViewController, window: NSWindow) {
    key("\r", code: 36, modifiers: .shift, in: editor, window: window)
  }

  func testExactNowAndDailyCompletionsAcceptAndSubmitInOneShortcut() async throws {
    for command in ["now", "daily"] {
      let (editor, window) = try await editor()
      defer { window.orderOut(nil) }
      editor.toolPackages = [package(command, output: "RESULT")]
      window.makeFirstResponder(editor.textView)

      key("/", code: 44, in: editor, window: window)
      key(command, code: 0, in: editor, window: window)
      await settlePresentationAsync(editor)
      XCTAssertNotNil(editor.view.subviews.first { $0.accessibilityLabel() == "Tool completions" })

      pressShiftReturn(in: editor, window: window)
      try await pending(editor)
      XCTAssertEqual(editor.state.text, "/\(command) RESULT")
      XCTAssertEqual(editor.state.invocations.first?.phase, .pending)
      XCTAssertEqual(editor.state.invocations.count, 1)
    }
  }

  func testShortcutFindsExactNowCompletionWhenAnotherCandidateIsSelected() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let longer = package("now-extra", output: "WRONG")
    let now = package("now", output: "RIGHT")
    editor.toolPackages = [longer, now]
    window.makeFirstResponder(editor.textView)

    key("/", code: 44, in: editor, window: window)
    key("now", code: 0, in: editor, window: window)
    await settlePresentationAsync(editor)
    let completion = try XCTUnwrap(
      editor.view.subviews.first { $0.accessibilityLabel() == "Tool completions" })
    XCTAssertTrue(
      (completion.subviews.first as? NSButton)?.accessibilityLabel()?.hasPrefix("/now-extra")
        == true)

    pressShiftReturn(in: editor, window: window)
    try await pending(editor)
    XCTAssertEqual(editor.state.text, "/now RIGHT")
    XCTAssertEqual(editor.state.invocations.first?.packageID, now.manifest.id)
  }

  func testShortcutSubmitsAcceptedInputAndPreservesNormalReturnNoteTaking() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let coordinator = ExecutionShortcutCoordinator()
    editor.toolInvocationCoordinator = coordinator
    let tool = package("now")
    editor.toolPackages = [tool]
    editor.textView.insertText("/now", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 4), space: true)

    key("note", code: 0, in: editor, window: window)
    key("\r", code: 36, in: editor, window: window)
    XCTAssertEqual(editor.state.text, "/now note\n")
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)

    pressShiftReturn(in: editor, window: window)
    XCTAssertEqual(coordinator.submitted.count, 1)
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
  }

  func testShortcutMergesOnlyWhenCaretIsInsidePendingOutput() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("now", output: "RESULT")
    editor.toolPackages = [tool]
    editor.textView.insertText("/now", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 4), space: true)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.submit(id)
    try await pending(editor, id: id)
    let pending = try XCTUnwrap(editor.state.invocations.first)
    let output = try XCTUnwrap(pending.output?.resolve(in: editor.state))

    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    pressShiftReturn(in: editor, window: window)
    XCTAssertEqual(editor.state.invocations.first?.phase, .pending)

    editor.textView.setSelectedRange(NSRange(location: output.location, length: 0))
    pressShiftReturn(in: editor, window: window)
    XCTAssertTrue(editor.state.invocations.isEmpty)
    XCTAssertEqual(editor.state.text, "RESULT")

    pressShiftReturn(in: editor, window: window)
    XCTAssertEqual(editor.state.text, "RESULT")
  }

  func testShortcutDoesNothingForSubmittedAndProcessingInvocations() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("now")
    editor.toolPackages = [tool]
    editor.textView.insertText("/now", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 4), space: true)

    for phase in [ToolInvocationPhase.submitted, .processing] {
      let before = editor.state
      var invocation = try XCTUnwrap(before.invocations.first)
      invocation.phase = phase
      let patch = DocumentPatch(
        in: before, expectedInvocations: [before.invocations[0]], invocations: [.upsert(invocation)]
      )
      try editor.apply(
        .init(
          baseRevision: before.revision, origin: .automation, undoPolicy: .none,
          mutation: .patch(patch)))
      editor.textView.setSelectedRange(NSRange(location: 0, length: 0))

      let running = editor.state
      pressShiftReturn(in: editor, window: window)
      XCTAssertEqual(editor.state, running)
    }
  }
}
