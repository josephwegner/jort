import Foundation
import XCTest
import JortDocument
import JortToolContracts

@MainActor final class ToolDocumentEffectTests: XCTestCase {
  private func acceptedUtility(
    command: String, content: String,
    mode: ToolInputMode = .contextual
  ) throws -> DocumentCoordinator {
    let owner = try DocumentCoordinator()
    let before = try owner.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .replace(range: NSRange(location: 0, length: 0), text: command + content))
    ).after
    var manifest = ToolManifest(
      id: "dev.test.utility", name: "Utility", command: command,
      inputMode: mode)
    manifest.schemaVersion = 3
    manifest.entryContract = 2
    manifest.executor = .javascript
    let identity = InvocationGeneration(invocationID: UUID(), generation: UUID())
    var lifecycle = InvocationLifecycleState(identity: identity, phase: .inputting)
    _ = lifecycle.reduce(.accept)
    let plan = try XCTUnwrap(
      ToolDocumentEffects.accept(
        try XCTUnwrap(lifecycle.pendingEffect),
        package: .init(manifest: manifest, source: "export default () => ({report:'ok'});"),
        token: NSRange(location: 0, length: command.utf16.count), space: true, in: before))
    try owner.apply(plan.transaction)
    return owner
  }

  @discardableResult private func perform(
    _ action: InvocationLifecycleState.Action,
    on owner: DocumentCoordinator
  ) throws -> ToolDocumentPlan {
    let invocation = try XCTUnwrap(owner.snapshot.invocations.first)
    var lifecycle = invocation.lifecycle
    _ = lifecycle.reduce(action)
    let plan = try ToolDocumentEffects.prepare(
      try XCTUnwrap(lifecycle.pendingEffect),
      in: owner.snapshot, expected: invocation)
    try owner.apply(plan.transaction)
    return plan
  }

  private func submitUtility(_ owner: DocumentCoordinator) throws {
    let invocation = try XCTUnwrap(owner.snapshot.invocations.first)
    var lifecycle = invocation.lifecycle
    _ = lifecycle.reduce(.submit)
    _ = lifecycle.reduce(.validation(lifecycle.identity, error: nil))
    let plan = try ToolDocumentEffects.prepare(
      try XCTUnwrap(lifecycle.pendingEffect),
      in: owner.snapshot, expected: invocation)
    try owner.apply(plan.transaction)
  }

  func testReportDoneAndUndoPreserveExactUnicodeContentAndCompletedFeedback() throws {
    let source = "  family 👨‍👩‍👧‍👦\r\nsecond line"
    let owner = try acceptedUtility(command: "/count", content: source)
    XCTAssertEqual(
      owner.snapshot.invocations[0].capturedContent(in: owner.snapshot, prompt: nil),
      String(source.prefix(while: { $0 != "\r\n" })))
    try submitUtility(owner)
    let identity = owner.snapshot.invocations[0].lifecycle.identity
    try perform(.report(identity, message: "Five words"), on: owner)
    let completed = owner.snapshot
    XCTAssertEqual(completed.text, "/count " + source)
    XCTAssertEqual(completed.invocations[0].phase, .completed)
    XCTAssertEqual(completed.invocations[0].message, "Five words")
    XCTAssertNil(completed.invocations[0].output)
    let encoded = try JSONEncoder().encode(completed.invocations)
    XCTAssertEqual(
      try JSONDecoder().decode([ToolInvocation].self, from: encoded), completed.invocations)
    try perform(.done, on: owner)
    XCTAssertEqual(owner.snapshot.text, source)
    XCTAssertTrue(owner.snapshot.invocations.isEmpty)
    try owner.apply(
      .init(
        baseRevision: owner.snapshot.revision, origin: .undo,
        undoPolicy: .replay, mutation: .restore(completed)))
    XCTAssertEqual(owner.snapshot.invocations[0].message, "Five words")
    var restored = owner.snapshot.invocations[0].lifecycle
    XCTAssertTrue(restored.reduce(.restored(hasLiveJob: false)).isEmpty)
  }

  func testDailyLandmarkExistsOnlyAfterMergeAndTextMetadataUndoTogether() throws {
    let owner = try acceptedUtility(command: "/daily", content: "", mode: .contained)
    try submitUtility(owner)
    let identity = owner.snapshot.invocations[0].lifecycle.identity
    let text = "# Sat, Sept 12\n\n"
    try perform(
      .landmarkResult(identity, output: text, landmark: .init(line: 0, emoji: "📅")), on: owner)
    let pending = owner.snapshot
    XCTAssertTrue(pending.landmarks.isEmpty)
    try perform(.merge, on: owner)
    let merged = owner.snapshot
    XCTAssertEqual(merged.text, text)
    XCTAssertEqual(merged.landmarks.count, 1)
    XCTAssertEqual(merged.landmarks[0].lineID, merged.lines[0].id)
    XCTAssertEqual(merged.landmarks[0].emoji, "📅")
    try owner.apply(
      .init(
        baseRevision: merged.revision, origin: .undo,
        undoPolicy: .replay, mutation: .restore(pending)))
    XCTAssertEqual(owner.snapshot.text, pending.text)
    XCTAssertTrue(owner.snapshot.landmarks.isEmpty)
    try owner.apply(
      .init(
        baseRevision: owner.snapshot.revision, origin: .redo,
        undoPolicy: .replay, mutation: .restore(merged)))
    XCTAssertEqual(owner.snapshot.landmarks, merged.landmarks)
    XCTAssertEqual(owner.snapshot.text, text)
  }

  func testInterruptedActionRestoresUnknownAndCancelledExportStaysEditable() throws {
    for cancelled in [false, true] {
      let owner = try acceptedUtility(command: "/export", content: "exact source")
      try submitUtility(owner)
      let identity = owner.snapshot.invocations[0].lifecycle.identity
      try perform(
        .hostAction(identity, .init(kind: "file.export", content: "exact source")), on: owner)
      XCTAssertEqual(owner.snapshot.invocations[0].actionStatus, .dispatched)
      if cancelled {
        try perform(.hostFailed(identity, message: "Save cancelled", cancelled: true), on: owner)
        XCTAssertEqual(owner.snapshot.invocations[0].phase, .inputting)
        XCTAssertEqual(owner.snapshot.invocations[0].actionStatus, .cancelled)
      } else {
        try perform(.restored(hasLiveJob: false), on: owner)
        XCTAssertEqual(owner.snapshot.invocations[0].phase, .completed)
        XCTAssertEqual(owner.snapshot.invocations[0].actionStatus, .unknown)
        XCTAssertTrue(owner.snapshot.invocations[0].message?.contains("unknown") == true)
      }
      XCTAssertEqual(owner.snapshot.text, "/export exact source")
    }
  }
  func testMultipleReplacementsAreAtomicAndBounded() throws {
    let owner = try DocumentCoordinator()
    try owner.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .replace(
          range: NSRange(location: 0, length: 0),
          text: String(repeating: "short line\n", count: 10_000))))
    let before = owner.snapshot
    let replacements = try [
      DocumentPatch.Replacement(range: NSRange(location: 1, length: 1), text: "NEW", in: before),
      DocumentPatch.Replacement(range: NSRange(location: 50_000, length: 2), text: "x", in: before),
    ]
    let invalid = DocumentPatch(
      in: before, replacements: replacements,
      landmarks: [.upsert(Landmark(lineID: before.lines[0].id, emoji: "not emoji"))])
    XCTAssertThrowsError(
      try owner.apply(
        .init(
          baseRevision: before.revision, origin: .automation,
          mutation: .patch(invalid))))
    XCTAssertEqual(owner.snapshot, before)
    let overlap = DocumentPatch(in: before, replacements: [replacements[0], replacements[0]])
    XCTAssertThrowsError(
      try owner.apply(
        .init(
          baseRevision: before.revision, origin: .automation,
          mutation: .patch(overlap))))
    XCTAssertEqual(owner.snapshot, before)
    var publications = 0
    owner.onTransaction = { _ in publications += 1 }
    let recorder = DocumentWorkRecorder()
    let after = try DocumentInstrumentation.$recorder.withValue(recorder) {
      try owner.apply(
        .init(
          baseRevision: before.revision, origin: .automation,
          mutation: .patch(DocumentPatch(in: before, replacements: replacements)))
      ).after
    }
    XCTAssertEqual(publications, 1)
    XCTAssertEqual(after.revision, before.revision + 1)
    XCTAssertNil(recorder.snapshot[.flattenCalls])
    XCTAssertNil(recorder.snapshot[.completeValidations])
    XCTAssertLessThan(recorder.snapshot[.visitedLines, default: 0], 1024)
    var expected = before.text
    for replacement in replacements.reversed() {
      expected = (expected as NSString).replacingCharacters(
        in: replacement.range, with: replacement.text)
    }
    XCTAssertEqual(after.text, expected)
    try after.validate()
  }

  private func submitted() throws -> DocumentSnapshot {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(
        forResource: "tool-invocations-pre-extraction", withExtension: "json"))
    let invocation = try JSONDecoder().decode([ToolInvocation].self, from: Data(contentsOf: url))[1]
    return DocumentSnapshot(
      text: "/calc 3+3",
      lines: [
        .init(
          id: invocation.token.start.lineID, location: 0, length: 9,
          createdAt: Date(timeIntervalSinceReferenceDate: 12345),
          lastEditedAt: Date(timeIntervalSinceReferenceDate: 12345))
      ],
      invocations: [invocation])
  }
  private func publication(_ invocation: ToolInvocation) throws -> InvocationDocumentEffect {
    var lifecycle = invocation.lifecycle
    _ = lifecycle.reduce(.result(lifecycle.identity, output: "6"))
    return try XCTUnwrap(lifecycle.pendingEffect)
  }
  func testPublicationMergeDismissAndUndoPlansPreserveCanonicalRecords() throws {
    let before = try submitted(), invocation = before.invocations[0]
    let effect = try publication(invocation)
    let plan = try ToolDocumentEffects.prepare(effect, in: before, expected: invocation)
    let document = try DocumentCoordinator(snapshot: before)
    let pending = try document.apply(plan.transaction).after
    XCTAssertEqual(pending.text, "/calc 3+36")
    XCTAssertEqual(pending.invocations[0].phase, .pending)
    XCTAssertTrue(pending.invocations[0].validated(in: pending))
    XCTAssertEqual(plan.undoSnapshot?.text, before.text)
    XCTAssertEqual(plan.undoSnapshot?.invocations[0].phase, .inputting)
    for action in [InvocationLifecycleState.Action.merge, .dismiss] {
      var state = pending.invocations[0].lifecycle
      _ = state.reduce(action)
      let effect = try XCTUnwrap(state.pendingEffect)
      let mutation = try ToolDocumentEffects.prepare(
        effect, in: pending, expected: pending.invocations[0])
      let owner = try DocumentCoordinator(snapshot: pending)
      let after = try owner.apply(mutation.transaction).after
      if action == .merge {
        XCTAssertEqual(after.text, "6")
        XCTAssertTrue(after.invocations.isEmpty)
      } else {
        XCTAssertEqual(after.text, before.text)
        XCTAssertEqual(after.invocations[0].phase, .inputting)
      }
    }
  }
  func testStaleGenerationHashAnchorAndRevisionRejectWithoutMutation() throws {
    let before = try submitted(), invocation = before.invocations[0]
    let owner = try DocumentCoordinator(snapshot: before)
    for corruption in 0..<3 {
      var stale = invocation
      if corruption == 0 { stale.generation = UUID() }
      if corruption == 1 { stale.sourceHash = "stale" }
      if corruption == 2 { stale.token.start.offset = 1 }
      XCTAssertThrowsError(
        try ToolDocumentEffects.prepare(publication(stale), in: before, expected: stale))
      XCTAssertEqual(owner.snapshot, before)
    }
    let plan = try ToolDocumentEffects.prepare(
      publication(invocation), in: before, expected: invocation)
    _ = try owner.apply(
      .init(
        baseRevision: before.revision, origin: .native,
        mutation: .edit(
          text: "prefix " + before.text, range: .init(location: 0, length: 0), replacementLength: 7)
      ))
    let edited = owner.snapshot
    XCTAssertThrowsError(try owner.apply(plan.transaction))
    XCTAssertEqual(owner.snapshot, edited)
  }
}

extension ToolDocumentEffectTests {
  func testCompletionIsAnAcknowledgedDocumentOperationAcrossInputModes() throws {
    for mode in ToolInputMode.allCases {
      let owner = try DocumentCoordinator()
      let before = try owner.apply(
        .init(
          baseRevision: 0, origin: .native,
          mutation: .edit(text: "/te", range: .init(location: 0, length: 0), replacementLength: 3))
      ).after
      let identity = InvocationGeneration(invocationID: UUID(), generation: UUID())
      var lifecycle = InvocationLifecycleState(identity: identity, phase: .inputting)
      _ = lifecycle.reduce(.accept)
      let effect = try XCTUnwrap(lifecycle.pendingEffect)
      let package = ToolPackage(
        manifest: .init(id: "dev.test.accept", name: "Test", command: "/test", inputMode: mode),
        source: "export default () => ({output:''});")
      XCTAssertThrowsError(
        try ToolDocumentEffects.accept(
          effect, package: package,
          token: .init(location: 99, length: 1), space: true, in: before))
      XCTAssertEqual(owner.snapshot, before)
      let plan = try XCTUnwrap(
        ToolDocumentEffects.accept(
          effect, package: package,
          token: .init(location: 0, length: 3), space: true, in: before))
      let accepted = try owner.apply(plan.transaction).after
      _ = lifecycle.reduce(.acknowledge(effect, accepted: true))
      XCTAssertEqual(accepted.text, "/test ")
      XCTAssertEqual(accepted.invocations[0].id, identity.invocationID)
      XCTAssertEqual(accepted.invocations[0].generation, identity.generation)
      XCTAssertEqual(
        accepted.invocations[0].capturedContent(in: accepted, prompt: "  secret"),
        mode.isEphemeral ? " secret" : "")
    }
  }
}
