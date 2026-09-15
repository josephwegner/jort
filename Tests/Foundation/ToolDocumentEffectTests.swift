import Foundation
import XCTest
import JortDocument
import JortToolContracts

@MainActor final class ToolDocumentEffectTests: XCTestCase {
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
