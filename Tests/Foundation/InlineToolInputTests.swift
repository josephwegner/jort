import Foundation
import XCTest
import JortDocument
import JortToolContracts

@MainActor final class InlineToolInputTests: XCTestCase {
  private func accept(
    _ text: String, contract: Int = 2, mode: ToolInputMode = .contextual,
    operation: ToolOutputOperation = .replaceInvocation
  ) throws -> DocumentCoordinator {
    let owner = try DocumentCoordinator()
    try edit(owner, NSRange(location: 0, length: 0), text)
    var manifest = ToolManifest(
      id: "dev.test.inline", name: "Inline", command: "/test", inputMode: mode)
    manifest.entryContract = contract
    manifest.schemaVersion = contract == 2 ? 3 : 1
    manifest.outputOperation = operation
    if contract == 2 { manifest.executor = .javascript }
    var lifecycle = InvocationLifecycleState(
      identity: .init(invocationID: UUID(), generation: UUID()), phase: .inputting)
    _ = lifecycle.reduce(.accept)
    let plan = try XCTUnwrap(
      ToolDocumentEffects.accept(
        try XCTUnwrap(lifecycle.pendingEffect),
        package: .init(manifest: manifest, source: "export default () => ({output:'ok'});"),
        token: (text as NSString).range(of: "/test"), space: true, in: owner.snapshot))
    try owner.apply(plan.transaction)
    return owner
  }

  private func edit(_ owner: DocumentCoordinator, _ range: NSRange, _ text: String) throws {
    try owner.apply(
      .init(
        baseRevision: owner.snapshot.revision, origin: .native,
        mutation: .replace(range: range, text: text)))
  }

  private func input(_ text: String, on owner: DocumentCoordinator) throws {
    let call = try XCTUnwrap(owner.snapshot.invocations.first?.call?.resolve(in: owner.snapshot))
    try edit(owner, NSRange(location: NSMaxRange(call), length: 0), text)
  }

  private func update(_ value: ToolInvocation, on owner: DocumentCoordinator) throws {
    let snapshot = owner.snapshot
    try owner.apply(
      .init(
        baseRevision: snapshot.revision, origin: .automation,
        mutation: .patch(
          .init(
            in: snapshot, expectedInvocations: snapshot.invocations,
            invocations: [.upsert(value)]))))
  }

  private func submit(_ owner: DocumentCoordinator, withRestoration: Bool = true) throws {
    let value = try XCTUnwrap(owner.snapshot.invocations.first)
    var submission = value
    if withRestoration { submission.restoration = .init(invocation: value, selection: value.call) }
    var lifecycle = value.lifecycle
    _ = lifecycle.reduce(.submit)
    _ = lifecycle.reduce(.validation(lifecycle.identity, error: nil))
    let plan = try ToolDocumentEffects.prepare(
      try XCTUnwrap(lifecycle.pendingEffect), in: owner.snapshot,
      expected: value, submission: submission)
    try owner.apply(plan.transaction)
  }

  @discardableResult private func perform(
    _ action: InvocationLifecycleState.Action, on owner: DocumentCoordinator
  ) throws -> ToolDocumentPlan {
    let value = try XCTUnwrap(owner.snapshot.invocations.first)
    var lifecycle = value.lifecycle
    _ = lifecycle.reduce(action)
    let plan = try ToolDocumentEffects.prepare(
      try XCTUnwrap(lifecycle.pendingEffect), in: owner.snapshot, expected: value)
    try owner.apply(plan.transaction)
    return plan
  }

  func testContextAndInlineInputAreDistinctAndExact() throws {
    let owner = try accept("  before 👩🏽‍💻 /test AFTER  ")
    try input(" question 🐈 ", on: owner)
    var value = try XCTUnwrap(owner.snapshot.invocations.first)
    XCTAssertEqual(value.inlineInput(in: owner.snapshot), " question 🐈 ")
    XCTAssertEqual(value.capturedContent(in: owner.snapshot, prompt: nil), "  before 👩🏽‍💻 ")
    // Explicitly expanded context can include text on the far side of the call.
    value.scope = try .init(
      NSRange(location: 0, length: owner.snapshot.utf16Count), snapshot: owner.snapshot)
    value.sourceHash = ToolInvocation.hash(owner.snapshot.text)
    try update(value, on: owner)
    let snapshot = owner.snapshot
    XCTAssertEqual(
      try value.contextRanges(in: snapshot).map { try snapshot.text(in: $0) },
      ["  before 👩🏽‍💻 ", " AFTER  "])
    XCTAssertEqual(value.capturedContent(in: snapshot, prompt: nil), "  before 👩🏽‍💻  AFTER  ")
    XCTAssertTrue(value.validated(in: snapshot))
  }

  func testDefaultParagraphSkipsBlanksAndStopsAtPreviousBlank() throws {
    for newline in ["\n", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
      let prefix = "older" + newline + newline
      let context = "paragraph 👨‍👩‍👧‍👦" + newline + "second" + newline + newline + "  "
      let owner = try accept(prefix + context + "/test tail")
      let value = try XCTUnwrap(owner.snapshot.invocations.first)
      XCTAssertEqual(value.capturedContent(in: owner.snapshot, prompt: nil), context)
      XCTAssertEqual(value.inlineInput(in: owner.snapshot), "")
      XCTAssertEqual(value.scope.resolve(in: owner.snapshot)?.location, prefix.utf16.count)
    }
  }

  func testReturnFreezesCallAndDefaultScopeWhileNotesContinue() throws {
    for newline in ["\n", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
      let owner = try accept("context /test")
      try input("query 🧑‍🚀" + newline + "notes", on: owner)
      var value = try XCTUnwrap(owner.snapshot.invocations.first)
      XCTAssertEqual(value.inlineInput(in: owner.snapshot), "query 🧑‍🚀")
      XCTAssertEqual(
        value.scope.resolve(in: owner.snapshot).map(NSMaxRange),
        value.call?.resolve(in: owner.snapshot).map(NSMaxRange))
      try edit(owner, NSRange(location: owner.snapshot.utf16Count, length: 0), " continued")
      try edit(owner, NSRange(location: 0, length: 0), "👋\r\n")
      value = try XCTUnwrap(owner.snapshot.invocations.first)
      XCTAssertEqual(value.inlineInput(in: owner.snapshot), "query 🧑‍🚀")
      XCTAssertFalse(
        try owner.snapshot.text(in: XCTUnwrap(value.scope.resolve(in: owner.snapshot))).contains(
          "notes"))
      try input("!", on: owner)
      value = try XCTUnwrap(owner.snapshot.invocations.first)
      XCTAssertEqual(value.inlineInput(in: owner.snapshot), "query 🧑‍🚀!")
      XCTAssertTrue(value.validated(in: owner.snapshot))
    }
  }

  func testPublicationCodableDismissMergeAndUndoAtNewlineSeams() throws {
    for mode in [ToolInputMode.contextual, .contained] {
      let owner = try accept("/test\r\nnotes", mode: mode)
      try input("👩‍🚀 query", on: owner)
      let editable = owner.snapshot
      try submit(owner)
      let plan = try perform(
        .result(
          owner.snapshot.invocations[0].lifecycle.identity,
          output: "\r\nRESULT 🐈\r\n"), on: owner)
      let pending = owner.snapshot
      let value = try XCTUnwrap(pending.invocations.first)
      XCTAssertEqual(value.inlineInput(in: pending), "👩‍🚀 query")
      XCTAssertEqual(
        value.call?.resolve(in: pending), editable.invocations[0].call?.resolve(in: editable))
      XCTAssertEqual(
        value.output?.resolve(in: pending)?.location,
        value.call?.resolve(in: pending).map(NSMaxRange))
      XCTAssertTrue(value.validated(in: pending))
      XCTAssertEqual(
        value.capturedContent(in: pending, prompt: nil),
        editable.invocations[0].capturedContent(in: editable, prompt: nil))
      if mode == .contained { XCTAssertEqual(value.contextRanges(in: pending), []) }
      let decoded = try JSONDecoder().decode(ToolInvocation.self, from: JSONEncoder().encode(value))
      XCTAssertEqual(decoded, value)
      XCTAssertTrue(decoded.validated(in: pending))
      let undo = try XCTUnwrap(plan.undoSnapshot)
      XCTAssertEqual(undo.text, editable.text)
      XCTAssertEqual(undo.invocations[0].call, editable.invocations[0].call)
      XCTAssertTrue(undo.invocations[0].validated(in: undo))
      // A prefix edit exercises both pending and restoration rebasing.
      try edit(owner, NSRange(location: 0, length: 0), "prefix 🦊\r\n")
      try perform(.dismiss, on: owner)
      XCTAssertEqual(owner.snapshot.text, "prefix 🦊\r\n" + editable.text)
      XCTAssertEqual(owner.snapshot.invocations[0].inlineInput(in: owner.snapshot), "👩‍🚀 query")
      XCTAssertTrue(owner.snapshot.invocations[0].validated(in: owner.snapshot))
      let merger = try DocumentCoordinator(snapshot: pending)
      try perform(.merge, on: merger)
      XCTAssertEqual(merger.snapshot.text, "\r\nRESULT 🐈\r\n\r\nnotes")
      XCTAssertTrue(merger.snapshot.invocations.isEmpty)
      try merger.apply(
        .init(
          baseRevision: merger.snapshot.revision, origin: .undo,
          undoPolicy: .replay, mutation: .restore(pending)))
      XCTAssertEqual(merger.snapshot.invocations[0].call, value.call)
    }
  }

  func testExpandedContextPublicationAndReplaceContextUseEnvelope() throws {
    let owner = try accept("before /test after", operation: .replaceContext)
    try input("query", on: owner)
    var value = owner.snapshot.invocations[0]
    value.scope = try .init(
      NSRange(location: 0, length: owner.snapshot.utf16Count), snapshot: owner.snapshot)
    value.sourceHash = ToolInvocation.hash(owner.snapshot.text)
    try update(value, on: owner)
    try submit(owner)
    try perform(
      .result(owner.snapshot.invocations[0].lifecycle.identity, output: "\nRESULT\n"), on: owner)
    XCTAssertTrue(owner.snapshot.invocations[0].validated(in: owner.snapshot))
    let pending = owner.snapshot
    XCTAssertEqual(
      pending.invocations[0].capturedContent(in: pending, prompt: nil), "before  after")
    XCTAssertEqual(
      try pending.invocations[0].contextRanges(in: pending).map { try pending.text(in: $0) },
      ["before ", " after"])
    try perform(.dismiss, on: owner)
    XCTAssertEqual(
      owner.snapshot.invocations[0].capturedContent(in: owner.snapshot, prompt: nil),
      "before  after")
    let merger = try DocumentCoordinator(snapshot: pending)
    try perform(.merge, on: merger)
    XCTAssertEqual(merger.snapshot.text, "\nRESULT\n")
  }

  func testDoneRemovesWholeCallAndPreservesNotes() throws {
    let owner = try accept("before /test\r\nnotes")
    try input("query", on: owner)
    try submit(owner)
    try perform(.report(owner.snapshot.invocations[0].lifecycle.identity, message: "ok"), on: owner)
    try perform(.done, on: owner)
    XCTAssertEqual(owner.snapshot.text, "before \r\nnotes")
    XCTAssertTrue(owner.snapshot.invocations.isEmpty)
  }

  func testEmptyAndInlineOutputAtEOFWithoutRestoration() throws {
    for output in ["", "answer", "\nanswer\n"] {
      let owner = try accept("before /test")
      try input("query", on: owner)
      let editable = owner.snapshot
      try submit(owner, withRestoration: false)
      try perform(
        .result(owner.snapshot.invocations[0].lifecycle.identity, output: output), on: owner)
      let pending = owner.snapshot
      XCTAssertTrue(pending.invocations[0].validated(in: pending))
      XCTAssertEqual(pending.invocations[0].capturedContent(in: pending, prompt: nil), "before ")
      try perform(.dismiss, on: owner)
      XCTAssertEqual(owner.snapshot.text, editable.text)
      XCTAssertEqual(owner.snapshot.invocations[0].inlineInput(in: owner.snapshot), "query")
      XCTAssertTrue(owner.snapshot.invocations[0].validated(in: owner.snapshot))
    }
  }

  func testCallBoundsAndSubmissionGuard() throws {
    let owner = try accept("before /test\r\nnotes")
    try input("query", on: owner)
    let snapshot = owner.snapshot, value = snapshot.invocations[0]
    let token = try XCTUnwrap(value.token.resolve(in: snapshot))
    for range in [
      NSRange(location: 0, length: NSMaxRange(token)),
      NSRange(location: token.location, length: token.length - 1),
      NSRange(location: token.location, length: snapshot.utf16Count - token.location),
    ] {
      var invalid = value
      invalid.call = try .init(range, snapshot: snapshot)
      XCTAssertFalse(invalid.validated(in: snapshot))
    }
    var newline = value
    newline.scope = try .init(NSRange(location: 0, length: snapshot.utf16Count), snapshot: snapshot)
    newline.call = try .init(
      NSRange(
        location: token.location,
        length: snapshot.utf16Count - token.location), snapshot: snapshot)
    newline.sourceHash = ToolInvocation.hash(snapshot.text)
    XCTAssertFalse(newline.validated(in: snapshot))
    var lifecycle = value.lifecycle
    _ = lifecycle.reduce(.submit)
    _ = lifecycle.reduce(.validation(lifecycle.identity, error: nil))
    var changed = value
    changed.call = value.token
    XCTAssertThrowsError(
      try ToolDocumentEffects.prepare(
        XCTUnwrap(lifecycle.pendingEffect), in: snapshot, expected: value, submission: changed))
  }

  func testInputReplacementDeletionAndContainedCapture() throws {
    let owner = try accept("/test tail", mode: .contained)
    try input("👩🏽‍💻 plus", on: owner)
    let query = (owner.snapshot.text as NSString).range(of: "👩🏽‍💻")
    try edit(owner, query, "🦊")
    var value = owner.snapshot.invocations[0]
    XCTAssertEqual(value.capturedContent(in: owner.snapshot, prompt: nil), "🦊 plus")
    XCTAssertEqual(value.inlineInput(in: owner.snapshot), "🦊 plus")
    let suffix = (owner.snapshot.text as NSString).range(of: " plus")
    try edit(owner, suffix, "")
    value = owner.snapshot.invocations[0]
    XCTAssertEqual(value.inlineInput(in: owner.snapshot), "🦊")
    XCTAssertTrue(value.validated(in: owner.snapshot))
    try input("\r\nnew note", on: owner)
    value = owner.snapshot.invocations[0]
    XCTAssertEqual(value.capturedContent(in: owner.snapshot, prompt: nil), "🦊")
    XCTAssertTrue(owner.snapshot.text.hasSuffix("new note tail"))
  }

  func testRestorationWithoutCallDecodesAndMalformedCallIsRejected() throws {
    let owner = try accept("before /test")
    try input("query", on: owner)
    var value = owner.snapshot.invocations[0]
    value.restoration = .init(invocation: value)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    object.removeValue(forKey: "call")
    var restoration = try XCTUnwrap(object["restoration"] as? [String: Any])
    restoration.removeValue(forKey: "call")
    object["restoration"] = restoration
    let decoded = try JSONDecoder().decode(
      ToolInvocation.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(decoded.call)
    XCTAssertNil(decoded.restoration?.call)
    XCTAssertTrue(decoded.validated(in: owner.snapshot))
    value.restoration?.call = try .init(NSRange(location: 0, length: 1), snapshot: owner.snapshot)
    XCTAssertFalse(value.validated(in: owner.snapshot))
    let legacy = try accept("paragraph\n\n/test tail", contract: 1)
    XCTAssertEqual(
      legacy.snapshot.invocations[0].capturedContent(in: legacy.snapshot, prompt: nil), " tail")
  }

  func testLegacyContractOneAndAbsentCallRemainByteExact() throws {
    let owner = try accept("before /test tail\r\nnotes", contract: 1)
    let value = owner.snapshot.invocations[0]
    XCTAssertNil(value.call)
    XCTAssertNil(value.inlineInput(in: owner.snapshot))
    XCTAssertEqual(value.capturedContent(in: owner.snapshot, prompt: nil), "before   tail")
    XCTAssertEqual(
      value.contextRanges(in: owner.snapshot),
      [try XCTUnwrap(value.scope.resolve(in: owner.snapshot))])
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    object.removeValue(forKey: "call")
    let decoded = try JSONDecoder().decode(
      ToolInvocation.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(decoded.call)
    XCTAssertTrue(decoded.validated(in: owner.snapshot))
    try submit(owner)
    try perform(.result(owner.snapshot.invocations[0].lifecycle.identity, output: "OUT"), on: owner)
    XCTAssertEqual(owner.snapshot.text, "before /testOUT  tail\r\nnotes")
    try perform(.merge, on: owner)
    XCTAssertEqual(owner.snapshot.text, "before OUT  tail\r\nnotes")
    let modern = try accept("/test tail")
    var oldModern = modern.snapshot.invocations[0]
    oldModern.call = nil
    oldModern.scope = try .init(
      NSRange(location: 0, length: modern.snapshot.utf16Count), snapshot: modern.snapshot)
    oldModern.sourceHash = ToolInvocation.hash(modern.snapshot.text)
    XCTAssertEqual(oldModern.capturedContent(in: modern.snapshot, prompt: nil), " tail")
    for mode in [ToolInputMode.ephemeralSingleLine, .ephemeralMultiline] {
      let ephemeral = try accept("/test", mode: mode)
      XCTAssertNil(ephemeral.snapshot.invocations[0].call)
    }
  }
}
