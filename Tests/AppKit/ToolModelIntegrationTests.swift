import JortToolRuntime
import JortToolContracts
import XCTest
import AppKit
import JortDocument
import JortPersistence
import JortSettings
@testable import JortAppKit

@MainActor final class ToolModelIntegrationTests: ToolInvocationTestCase {
  func testModelExactInputMergeUndoAndUnrelatedEditingAcrossModes() async throws {
    for mode in ToolInputMode.allCases {
      let (editor, window) = try await editor()
      defer { window.orderOut(nil) }
      let package = modelPackage(mode: mode),
        fake = FakeModelProvider(.delayed("ANSWER", .milliseconds(80)))
      editor.toolInvocationCoordinator = ToolInvocationCoordinator(
        executor: ToolExecutorDispatcher(modelAvailable: { true }, provider: { fake }))
      editor.toolPackages = [package]
      editor.textView.insertText(
        "before /model after\nnext", replacementRange: NSRange(location: 0, length: 0))
      try editor.toolController.accept(
        package, token: NSRange(location: 7, length: 6), space: false)
      let invocation = try XCTUnwrap(editor.state.invocations.first), id = invocation.id
      if mode.isEphemeral {
        editor.toolController.setPrompt("秘密 prompt\nline", for: id)
      } else if mode == .contained {
        editor.textView.insertText("exact", replacementRange: editor.textView.selectedRange())
      }
      let input = try XCTUnwrap(
        editor.toolController.content(try XCTUnwrap(editor.state.invocations.first)))
      let before = editor.state.text
      editor.toolController.submit(id)
      for _ in 0..<100 where editor.state.invocations.first?.phase == .inputting {
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTAssertTrue(editor.state.invocations.first?.isLocked == true)
      editor.textView.insertText(
        "!", replacementRange: NSRange(location: editor.state.text.utf16.count, length: 0))
      try await pending(editor)
      let requests = await fake.requests
      XCTAssertEqual(requests.count, 1)
      XCTAssertEqual(requests.first?.content, input)
      XCTAssertEqual(editor.state.invocations.first?.executor, "model")
      XCTAssertTrue(editor.state.text.hasSuffix("next!"))
      XCTAssertFalse(editor.state.text.contains("秘密 prompt"))
      let pendingText = editor.state.text
      try editor.toolController.merge(id)
      XCTAssertTrue(editor.state.invocations.isEmpty)
      XCTAssertTrue(editor.state.text.contains("ANSWER"))
      editor.textView.history.undo()
      XCTAssertEqual(editor.state.text, pendingText)
      editor.textView.history.redo()
      XCTAssertTrue(editor.state.invocations.isEmpty)
      XCTAssertNotEqual(editor.state.text, before)
    }
  }
  func testDisconnectedModelStaysEditableWithoutRequest() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = modelPackage(mode: .ephemeralMultiline),
      fake = FakeModelProvider(.success("never"))
    editor.toolInvocationCoordinator = ToolInvocationCoordinator(
      executor: ToolExecutorDispatcher(provider: { fake }))
    editor.toolPackages = [package]
    editor.textView.insertText("/model", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 6), space: false)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.setPrompt("question", for: id)
    editor.toolController.submit(id)
    for _ in 0..<100 where editor.toolController.warning(for: id) == nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
    XCTAssertTrue(editor.toolController.warning(for: id)?.contains("Models Settings") == true)
    let requests = await fake.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testModelCapturedDefinitionSurvivesSettingsUpdateAndDismiss() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    var package = modelPackage(mode: .ephemeralMultiline)
    let fake = FakeModelProvider(.delayed("old result", .milliseconds(100)))
    editor.toolInvocationCoordinator = ToolInvocationCoordinator(
      executor: ToolExecutorDispatcher(modelAvailable: { true }, provider: { fake }))
    editor.toolPackages = [package]
    editor.textView.insertText("/model", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(package, token: NSRange(location: 0, length: 6), space: false)
    let id = try XCTUnwrap(editor.state.invocations.first?.id)
    editor.toolController.setPrompt("original", for: id)
    editor.toolController.submit(id)
    for _ in 0..<100 where editor.state.invocations.first?.phase == .inputting {
      try await Task.sleep(for: .milliseconds(5))
    }
    package.manifest.version = 2
    package.implementation = .model(instructions: "new instructions")
    editor.toolPackages = [package]
    try await pending(editor)
    let requests = await fake.requests
    XCTAssertEqual(requests.first?.version, 1)
    XCTAssertEqual(requests.first?.instructions, "Transform only the input.")
    try editor.toolController.dismiss(id)
    XCTAssertEqual(editor.state.text, "/model")
    XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
  }
  func testModelCancellationLateResponseAndAuthenticationFailure() async throws {
    for failure in [false, true] {
      let (editor, window) = try await editor()
      defer { window.orderOut(nil) }
      let package = modelPackage(mode: .ephemeralSingleLine)
      let fake = FakeModelProvider(failure ? .failure(.authentication) : .late("late", .seconds(1)))
      editor.toolInvocationCoordinator = ToolInvocationCoordinator(
        executor: ToolExecutorDispatcher(modelAvailable: { true }, provider: { fake }))
      editor.toolPackages = [package]
      editor.textView.insertText("/model", replacementRange: NSRange(location: 0, length: 0))
      try editor.toolController.accept(
        package, token: NSRange(location: 0, length: 6), space: false)
      let id = try XCTUnwrap(editor.state.invocations.first?.id)
      editor.toolController.setPrompt("prompt", for: id)
      editor.toolController.submit(id)
      if failure {
        try await error(editor, id: id)
        XCTAssertTrue(editor.state.invocations.first?.message?.contains("Models Settings") == true)
      } else {
        try await Task.sleep(for: .milliseconds(30))
        editor.toolController.cancel(id)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(editor.state.invocations.isEmpty)
        XCTAssertEqual(editor.state.text, "/model")
      }
    }
  }
}

extension ToolModelIntegrationTests {
  func testModelPendingAndInflightRelaunchNeverRequestsAgain() async throws {
    for pending in [true, false] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ModelRecovery-\(UUID())")
      removeAfterStoresClose(directory)
      let tool = modelPackage(mode: .ephemeralMultiline),
        fake = FakeModelProvider(.success("MUST NOT RUN"))
      var snapshot = try persistedPendingSnapshot(
        package: tool, packageVersion: 1, output: pending ? "PERSISTED" : "")
      var invocations = snapshot.invocations
      invocations[0].executor = "model"
      if !pending {
        invocations[0].phase = .processing
        invocations[0].output = nil
        invocations[0].outputHash = nil
      }
      let store = ownStore(SQLiteStore(directory: directory)), initial = try await store.load()
      _ = try await store.save(
        DocumentSnapshot(
          documentID: initial.documentID, text: snapshot.text,
          revision: snapshot.revision, lines: snapshot.lines, invocations: invocations))
      try await store.close()
      let (editor, window) = try await editor(directory: directory)
      defer { window.orderOut(nil) }
      editor.toolInvocationCoordinator = ToolInvocationCoordinator(
        executor: ToolExecutorDispatcher(modelAvailable: { true }, provider: { fake }))
      editor.toolPackages = [tool]
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertEqual(editor.state.invocations.first?.phase, pending ? .pending : .error)
      if !pending {
        XCTAssertEqual(editor.state.invocations.first?.message, "Execution was interrupted.")
      }
      XCTAssertEqual(editor.state.text, pending ? "/modelPERSISTED" : "/model")
      let requests = await fake.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }
}

extension ToolModelIntegrationTests {
  func testModelLargeDocumentSubmissionPublicationAndCancellationMeasurements() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let package = modelPackage(mode: .contextual),
      fake = FakeModelProvider(.delayed("RESULT", .milliseconds(10)))
    editor.toolInvocationCoordinator = ToolInvocationCoordinator(
      executor: ToolExecutorDispatcher(modelAvailable: { true }, provider: { fake }))
    editor.toolPackages = [package]
    editor.textView.insertText(
      "/model\n" + CrawlLargeDocument.text, replacementRange: NSRange(location: 0, length: 0))
    var submissions: [Double] = [], publications: [Double] = [], cancellations: [Double] = []
    func clock() -> Double { ProcessInfo.processInfo.systemUptime }
    for _ in 0..<6 {
      try editor.toolController.accept(
        package, token: NSRange(location: 0, length: 6), space: false)
      let id = try XCTUnwrap(editor.state.invocations.first?.id)
      try editor.toolController.moveBoundary(id, start: false, to: 100)
      let start = clock()
      editor.toolController.submit(id)
      submissions.append(clock() - start)
      try await pending(editor)
      publications.append(clock() - start)
      try editor.toolController.dismiss(id)
      editor.toolController.submit(id)
      let cancelStart = clock()
      editor.toolController.cancel(id)
      cancellations.append(clock() - cancelStart)
      XCTAssertTrue(editor.state.invocations.isEmpty)
    }
    func p95(_ values: [Double]) -> Double { values.sorted().last! * 1000 }
    print(
      "PERF Model CrawlLargeDocument ms p95: submit=\(p95(submissions)), delayed-submit+publish=\(p95(publications)), cancel=\(p95(cancellations))"
    )
    XCTAssertEqual(editor.state.text, "/model\n" + CrawlLargeDocument.text)
    let requests = await fake.requests
    XCTAssertTrue(requests.allSatisfy { $0.content.utf16.count < 100 })
  }
}
