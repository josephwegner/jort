import AppKit
import JortDocument
import JortToolContracts
import JortToolRuntime
import XCTest
@testable import JortAppKit

@MainActor private final class UtilityFlowCoordinator: ToolInvocationCoordinating {
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

private struct UtilityReminderExecutor: ToolExecuting {
  func validate(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult {
    .init(output: "")
  }
  func execute(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult {
    .init(action: .init(kind: "notification.schedule", content: input.content, minutes: 1))
  }
}

@MainActor private final class DeniedUtilityReminderHost: ToolHostActionExecuting {
  var dispatches = 0
  func execute(action: ToolHostAction, identity: InvocationGeneration, input: ToolExecutionInput)
    async -> ToolExecutionResult
  {
    dispatches += 1
    return .init(
      failure: .init(
        .authorization,
        message: "Allow Jort notifications in System Settings to schedule reminders."))
  }
}

@MainActor private final class SuspendedUtilityHost: ToolHostActionExecuting {
  var dispatched: [InvocationGeneration] = []
  private var continuation: CheckedContinuation<ToolExecutionResult, Never>?
  func execute(action: ToolHostAction, identity: InvocationGeneration, input: ToolExecutionInput)
    async -> ToolExecutionResult
  {
    dispatched.append(identity)
    return await withCheckedContinuation { continuation = $0 }
  }
  func finish() {
    let pending = continuation
    continuation = nil
    pending?.resume(returning: .init(report: "Late reminder acknowledgement."))
  }
}

/// UI integration deliberately bypasses the worker and real OS actions.
@MainActor final class ToolUtilityFlowTests: ToolInvocationTestCase {
  func testInlineReminderShowsMissingMinutesAndNotificationPermissionErrors() async throws {
    let (editor, window) = try await editor()
    let host = DeniedUtilityReminderHost()
    editor.toolInvocationCoordinator = ToolInvocationCoordinator(
      executor: UtilityReminderExecutor(), hostActions: host)
    let tool = utility(arguments: [
      .init(
        name: "minutes", type: .integer, label: "Reminder delay",
        minimum: 1, maximum: 525600, required: true)
    ])
    editor.toolPackages = [tool]
    editor.textView.insertText("Buy tea /remind", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 8, length: 7), space: true)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    window.makeFirstResponder(editor.textView)
    await settlePresentationAsync(editor)

    func errors() -> [NSTextField] {
      editor.linePresentation.accessories.values.flatMap {
        ($0.view as? NSStackView)?.arrangedSubviews ?? []
      }.compactMap { $0 as? NSTextField }.filter { $0.textColor == .systemRed }
    }
    editor.toolController.submit(id)
    await settlePresentationAsync(editor)
    XCTAssertFalse(errors().isEmpty)
    XCTAssertEqual(host.dispatches, 0)
    editor.textView.insertText("1", replacementRange: editor.textView.selectedRange())
    await settlePresentationAsync(editor)
    XCTAssertTrue(errors().isEmpty)
    editor.toolController.submit(id)
    try await error(editor, id: id)
    await settlePresentationAsync(editor)
    let permission = try XCTUnwrap(
      errors().first { $0.stringValue.contains("Allow Jort notifications") })
    XCTAssertNotNil(permission.window)
    XCTAssertFalse(permission.isHiddenOrHasHiddenAncestor)
    XCTAssertEqual(host.dispatches, 1)
  }

  private func utility(arguments: [ToolArgumentDefinition] = []) -> ToolPackage {
    var tool = package("remind", mode: .contextual)
    tool.manifest.schemaVersion = 3
    tool.manifest.executor = .javascript
    tool.manifest.entryContract = 2
    tool.manifest.arguments = arguments
    tool.manifest.hostActions = ["notification.schedule"]
    return tool
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

  private func accept(
    _ tool: ToolPackage, in editor: EditorViewController, tail: String = ""
  ) async throws -> UUID {
    editor.toolPackages = [tool]
    editor.textView.insertText(
      "/remindBuy tea" + tail, replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 7), space: true)
    // Keep these fixtures on the pre-inline contract: they exercise persisted
    // argument-form recovery and the original whole-line contextual scope.
    if let accepted = editor.state.invocations.first {
      var legacy = accepted
      legacy.call = nil
      let line = try XCTUnwrap(editor.state.lines.first)
      legacy.scope = try ToolAnchoredRange(
        NSRange(location: line.location, length: line.length), lines: editor.state.lines)
      legacy.sourceHash = ToolInvocation.hash(
        (editor.state.text as NSString).substring(with: legacy.scope.resolve(in: editor.state)!))
      let before = editor.state
      let patch = DocumentPatch(
        in: before, expectedInvocations: [accepted], invocations: [.upsert(legacy)])
      try editor.apply(
        .init(
          baseRevision: before.revision, origin: .automation, undoPolicy: .none,
          mutation: .patch(patch)))
      editor.toolPresentation.requestArgumentFocus(for: accepted.id)
      editor.textView.scrollRangeToVisible(try XCTUnwrap(accepted.token.resolve(in: editor.state)))
      editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }
    await settlePresentationAsync(editor)
    return try XCTUnwrap(editor.state.invocations.first?.id)
  }

  private func complete(_ id: UUID, in editor: EditorViewController, message: String) async throws {
    let before = editor.state
    var invocation = try XCTUnwrap(before.invocations.first { $0.id == id })
    invocation.phase = .completed
    invocation.actionStatus = .acknowledged
    invocation.actionKind = "notification.schedule"
    invocation.message = message
    let patch = DocumentPatch(
      in: before, expectedInvocations: [before.invocations.first { $0.id == id }!],
      invocations: [.upsert(invocation)])
    try editor.apply(
      .init(
        baseRevision: before.revision, origin: .automation, undoPolicy: .none,
        mutation: .patch(patch)))
    await settlePresentationAsync(editor)
  }

  private func argumentForm(
    in editor: EditorViewController, file: StaticString = #filePath, line: UInt = #line
  ) throws -> ToolArgumentFormView {
    try XCTUnwrap(
      editor.view.subviews.compactMap { $0 as? ToolArgumentFormView }.first,
      "Argument form missing; selection=\(editor.textView.selectedRange()), viewport=\(editor.textView.visibleRect)",
      file: file, line: line)
  }

  private func type(
    _ value: String, into field: NSTextField, window: NSWindow,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let context =
      "Field=\(field.accessibilityLabel() ?? "unlabeled"), responder=\(String(describing: window.firstResponder)), visibleRect=\(field.visibleRect)"
    XCTAssertTrue(field.currentEditor() === window.firstResponder, context, file: file, line: line)
    let input = try XCTUnwrap(field.currentEditor() as? NSTextView, context, file: file, line: line)
    input.selectAll(nil)
    input.insertText(value, replacementRange: input.selectedRange())
  }

  func testCompletedReminderKeyboardCancelReturnDoneAndUndoPreserveSource() async throws {
    let (editor, window) = try await editor()
    var cancellations: [InvocationGeneration] = []
    editor.cancelToolReminder = { identity in
      cancellations.append(identity)
      return "Cancelled the pending reminder."
    }
    let id = try await accept(utility(), in: editor)
    try await complete(id, in: editor, message: "Reminder accepted.")
    let generation = try XCTUnwrap(editor.state.invocations.first?.generation)
    let source = editor.state.text
    editor.textView.setSelectedRange(NSRange(location: 7, length: 0))
    window.makeFirstResponder(editor.textView)

    try press("\t", code: 48, in: window)
    XCTAssertEqual((window.firstResponder as? NSButton)?.accessibilityLabel(), "Done")
    try press("\t", code: 48, in: window)
    XCTAssertEqual((window.firstResponder as? NSButton)?.accessibilityLabel(), "Cancel Reminder")
    try press("\t", code: 48, modifiers: .shift, in: window)
    XCTAssertEqual((window.firstResponder as? NSButton)?.accessibilityLabel(), "Done")
    try press("\u{1b}", code: 53, in: window)
    XCTAssertTrue(window.firstResponder === editor.textView)
    XCTAssertEqual(editor.state.text, source)

    try press("\t", code: 48, modifiers: .shift, in: window)
    XCTAssertEqual((window.firstResponder as? NSButton)?.accessibilityLabel(), "Cancel Reminder")
    try press("\r", code: 36, in: window)
    for _ in 0..<100
    where editor.state.invocations.first?.message != "Cancelled the pending reminder." {
      await Task.yield()
    }
    XCTAssertEqual(cancellations, [.init(invocationID: id, generation: generation)])
    XCTAssertEqual(editor.state.invocations.first?.message, "Cancelled the pending reminder.")
    XCTAssertEqual(editor.state.text, source)
    await settlePresentationAsync(editor)
    try press("\u{1b}", code: 53, in: window)
    try press("\t", code: 48, in: window)
    XCTAssertEqual((window.firstResponder as? NSButton)?.accessibilityLabel(), "Done")
    try press("\r", code: 36, in: window)
    XCTAssertEqual(editor.state.text, "Buy tea")
    XCTAssertTrue(editor.state.invocations.isEmpty)
    XCTAssertTrue(window.firstResponder === editor.textView)
    editor.textView.history.undo()
    await settlePresentationAsync(editor)
    XCTAssertEqual(editor.state.text, source)
    XCTAssertEqual(editor.state.invocations.first?.phase, .completed)
    XCTAssertEqual(editor.state.invocations.first?.generation, generation)
    XCTAssertEqual(cancellations.count, 1, "Undo must not replay a native action.")
  }

  func testArgumentRemountPreservesValuesOrderAndUnrelatedEditorFocus() async throws {
    let (editor, window) = try await editor()
    let definitions = [
      ToolArgumentDefinition(name: "separator", type: .string, label: "Separator", required: true),
      ToolArgumentDefinition(
        name: "minutes", type: .integer, label: "Minutes", minimum: 1, maximum: 60),
    ]
    let id = try await accept(
      utility(arguments: definitions), in: editor,
      tail: "\n" + String(repeating: "Other line\n", count: 200))
    let original = try argumentForm(in: editor)
    try type("\" · \"", into: original.fields[0].field, window: window)
    try press("\t", code: 48, in: window)
    try type("20", into: original.fields[1].field, window: window)
    try press("\u{1b}", code: 53, in: window)
    XCTAssertTrue(window.firstResponder === editor.textView)
    let source = editor.state.text
    let end = NSRange(location: source.utf16.count, length: 0)
    editor.textView.setSelectedRange(end)
    editor.textView.scrollRangeToVisible(end)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    await settlePresentationAsync(editor)
    XCTAssertNil(original.superview)

    editor.textView.scrollRangeToVisible(NSRange(location: 0, length: 7))
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    await settlePresentationAsync(editor)
    let remounted = try argumentForm(in: editor)
    XCTAssertFalse(remounted === original)
    XCTAssertTrue(window.firstResponder === editor.textView)
    XCTAssertEqual(editor.textView.selectedRange(), end)
    XCTAssertEqual(remounted.fields.map(\.name), ["separator", "minutes"])
    XCTAssertEqual(
      remounted.fields.map { $0.field.accessibilityLabel() }, ["Separator", "Minutes"])
    XCTAssertEqual(remounted.fields.map { $0.field.stringValue }, ["\" · \"", "20"])
    XCTAssertEqual(
      editor.toolController.argumentValues(for: id), ["separator": "\" · \"", "minutes": "20"])
    XCTAssertEqual(editor.state.text, source)
    editor.textView.setSelectedRange(NSRange(location: 7, length: 0))
    try press("\t", code: 48, in: window)
    XCTAssertTrue(remounted.fields[0].field.currentEditor() === window.firstResponder)
    try press("\t", code: 48, in: window)
    XCTAssertTrue(remounted.fields[1].field.currentEditor() === window.firstResponder)
  }

  func testArgumentValidationFocusesInvalidFieldAndKeyboardCorrectionSubmitsSeparateInput()
    async throws
  {
    let (editor, window) = try await editor()
    let spy = UtilityFlowCoordinator()
    editor.toolInvocationCoordinator = spy
    let definitions = [
      ToolArgumentDefinition(name: "separator", type: .string, label: "Separator", required: true),
      ToolArgumentDefinition(
        name: "minutes", type: .integer, label: "Minutes", minimum: 1, maximum: 60, required: true),
    ]
    let id = try await accept(utility(arguments: definitions), in: editor)
    let form = try argumentForm(in: editor)
    try type("\" · \"", into: form.fields[0].field, window: window)
    try press("\t", code: 48, in: window)
    try type("0", into: form.fields[1].field, window: window)
    try press("\u{1b}", code: 53, in: window)
    let source = editor.state.text
    try press("\r", code: 36, modifiers: .shift, in: window)
    await settlePresentationAsync(editor)
    XCTAssertTrue(spy.submitted.isEmpty)
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    XCTAssertTrue(form.fields[1].field.currentEditor() === window.firstResponder)
    XCTAssertNotNil(editor.toolController.warning(for: id))
    XCTAssertEqual(editor.state.text, source)
    try type("20", into: form.fields[1].field, window: window)
    try press("\u{1b}", code: 53, in: window)
    try press("\r", code: 36, modifiers: .shift, in: window)
    XCTAssertEqual(spy.submitted.count, 1)
    let input = try XCTUnwrap(spy.submitted.first)
    XCTAssertEqual(input.content, "Buy tea")
    XCTAssertEqual(input.arguments, ["separator": .string(" · "), "minutes": .integer(20)])
    XCTAssertEqual(editor.state.text, source)
  }

  func testPostDispatchCancelPreservesUnknownReceiptAndIgnoresLateHostCompletion() async throws {
    let (editor, window) = try await editor()
    let host = SuspendedUtilityHost()
    defer { host.finish() }
    let coordinator = ToolInvocationCoordinator(
      executor: UtilityReminderExecutor(), hostActions: host)
    editor.toolInvocationCoordinator = coordinator
    editor.cancelToolReminder = { _ in "Cancelled the pending reminder." }
    let id = try await accept(utility(), in: editor)
    let source = editor.state.text
    editor.toolController.submit(id)
    for _ in 0..<500 where host.dispatched.isEmpty {
      try await Task.sleep(for: .milliseconds(2))
    }
    let dispatched = try XCTUnwrap(editor.state.invocations.first { $0.id == id })
    XCTAssertEqual(dispatched.actionStatus, .dispatched)
    XCTAssertEqual(host.dispatched, [.init(invocationID: id, generation: dispatched.generation)])
    XCTAssertTrue(coordinator.hasJob(id))

    editor.toolController.cancel(id)
    await settlePresentationAsync(editor)
    let receipt = try XCTUnwrap(editor.state.invocations.first { $0.id == id })
    XCTAssertEqual(receipt.phase, .completed)
    XCTAssertEqual(receipt.actionStatus, .unknown)
    XCTAssertEqual(receipt.generation, dispatched.generation)
    XCTAssertEqual(receipt.actionKind, "notification.schedule")
    XCTAssertFalse(coordinator.hasJob(id))
    XCTAssertEqual(editor.state.text, source)
    let done = try XCTUnwrap(
      editor.textView.subviews.first {
        $0.accessibilityLabel() == "Done"
      })
    let cancelReminder = try XCTUnwrap(
      editor.textView.subviews.first {
        $0.accessibilityLabel() == "Cancel Reminder"
      })
    XCTAssertEqual(cancelReminder.frame.minX, done.frame.maxX, accuracy: 0.5)
    XCTAssertLessThanOrEqual(cancelReminder.frame.maxX, editor.textView.visibleRect.maxX)
    XCTAssertTrue(
      editor.toolPresentation.containsDecoration(
        at: NSPoint(x: cancelReminder.frame.midX, y: cancelReminder.frame.midY), pending: false))
    let labels = editor.linePresentation.accessories.values.flatMap {
      ($0.view as? NSStackView)?.arrangedSubviews ?? []
    }.compactMap { $0 as? NSTextField }
    let unknown = try XCTUnwrap(labels.first { $0.stringValue.contains("outcome is unknown") })
    XCTAssertEqual(unknown.textColor, .systemRed)
    XCTAssertTrue(unknown.accessibilityLabel()?.hasPrefix("Tool error:") == true)
    editor.textView.setSelectedRange(NSRange(location: 7, length: 0))
    window.makeFirstResponder(editor.textView)
    try press("\t", code: 48, modifiers: .shift, in: window)
    XCTAssertEqual((window.firstResponder as? NSButton)?.accessibilityLabel(), "Cancel Reminder")

    host.finish()
    await settlePresentationAsync(editor)
    let after = try XCTUnwrap(editor.state.invocations.first { $0.id == id })
    XCTAssertEqual(after.actionStatus, .unknown)
    XCTAssertEqual(after.message, receipt.message)
    XCTAssertEqual(after.generation, receipt.generation)
    XCTAssertEqual(host.dispatched.count, 1)
    XCTAssertEqual(editor.state.text, source)
  }

  func testInlineReminderControlsStayInsideCommandDecoration() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let host = SuspendedUtilityHost()
    defer { host.finish() }
    editor.toolInvocationCoordinator = ToolInvocationCoordinator(
      executor: UtilityReminderExecutor(), hostActions: host)
    editor.cancelToolReminder = { _ in "Cancelled the pending reminder." }
    let tool = utility()
    editor.toolPackages = [tool]
    editor.textView.insertText("Buy tea /remind", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 8, length: 7), space: true)
    let invocation = try XCTUnwrap(editor.state.invocations.first)
    XCTAssertNotNil(invocation.call)
    editor.toolController.submit(invocation.id)
    for _ in 0..<500 where host.dispatched.isEmpty {
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertFalse(host.dispatched.isEmpty)
    editor.toolController.cancel(invocation.id)
    await settlePresentationAsync(editor)

    for label in ["Done", "Cancel Reminder"] {
      let button = try XCTUnwrap(
        editor.textView.subviews.first {
          $0.accessibilityLabel() == label
        })
      XCTAssertLessThanOrEqual(button.frame.maxX, editor.textView.visibleRect.maxX)
      for x in [button.frame.minX + 2, button.frame.midX, button.frame.maxX - 2] {
        XCTAssertTrue(
          editor.toolPresentation.containsDecoration(
            at: NSPoint(x: x, y: button.frame.midY), pending: false), label)
      }
    }
  }

  func testRestoredStringArgumentsRoundTripThroughControllerParser() async throws {
    let (editor, _) = try await editor()
    let spy = UtilityFlowCoordinator()
    editor.toolInvocationCoordinator = spy
    let strings = [
      "url": "https://example.com/a/b?path=/docs#part",
      "escapes": "\\n \\r \\t \\\\ \"quoted\"",
      "controls": "first\nsecond\r\t\u{8}\u{c}\u{1}é",
      "empty": "",
    ]
    let definitions = strings.keys.sorted().map {
      ToolArgumentDefinition(name: $0, type: .string, label: $0, required: true)
    }
    let id = try await accept(utility(arguments: definitions), in: editor)
    let before = editor.state
    let original = try XCTUnwrap(before.invocations.first { $0.id == id })
    var restored = original
    restored.capturedArguments = strings.mapValues { .string($0) }
    let patch = DocumentPatch(
      in: before, expectedInvocations: [original], invocations: [.upsert(restored)])
    try editor.apply(
      .init(
        baseRevision: before.revision, origin: .automation, undoPolicy: .none,
        mutation: .patch(patch)))
    let raw = editor.toolController.argumentValues(for: id)
    for definition in definitions {
      let value = try XCTUnwrap(raw[definition.name])
      XCTAssertEqual(
        try ToolArguments.parse(value, definitions: [definition]),
        [definition.name: .string(try XCTUnwrap(strings[definition.name]))])
    }
    editor.toolController.submit(id)
    XCTAssertEqual(spy.submitted.count, 1)
    let input = try XCTUnwrap(spy.submitted.first)
    XCTAssertEqual(input.arguments, restored.capturedArguments)
    XCTAssertEqual(input.content, "Buy tea")
    XCTAssertEqual(editor.state.text, before.text)
  }
}
