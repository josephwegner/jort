import XCTest
import JortDocument
@testable import JortPersistence

@MainActor final class ToolPersistenceTests: StoreTestCase {
  private func pending() throws -> DocumentSnapshot {
    let model = try DocumentCoordinator()
    let plain = try model.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .edit(
          text: "/calc 3+36", range: NSRange(location: 0, length: 0), replacementLength: 10))
    ).after
    var invocation = ToolInvocation(
      packageID: "dev.jort.calc", packageVersion: 1, entryContract: 1,
      inputMode: "contained", outputOperation: "replace-invocation", command: "/calc",
      token: try .init(NSRange(location: 0, length: 5), lines: plain.lines),
      scope: try .init(NSRange(location: 0, length: 9), lines: plain.lines),
      sourceHash: ToolInvocation.hash("/calc 3+3"))
    invocation.phase = .pending
    invocation.output = try .init(NSRange(location: 9, length: 1), lines: plain.lines)
    invocation.outputHash = ToolInvocation.hash("6")
    return DocumentSnapshot(
      documentID: plain.documentID, text: plain.text, revision: plain.revision,
      lines: plain.lines, invocations: [invocation])
  }
  func testStartupPrefixPreservesPendingInvocationAndStoredLineMetadata() throws {
    let before = try pending()
    for draft in ["early", "early\r\n", "early\u{85}", "early\u{2028}", "early\u{2029}"] {
      let owner = try DocumentCoordinator(snapshot: before)
      let prefix = StartupMerge.prefix(draft: draft, stored: before.text)
      let after = try owner.apply(
        .init(
          baseRevision: before.revision, origin: .startupMerge,
          mutation: .edit(
            text: prefix + before.text, range: NSRange(location: 0, length: 0),
            replacementLength: prefix.utf16.count))
      ).after
      XCTAssertEqual(after.documentID, before.documentID)
      XCTAssertEqual(after.invocations, before.invocations)
      XCTAssertEqual(after.lines.last?.id, before.lines.last?.id)
      XCTAssertEqual(after.lines.last?.createdAt, before.lines.last?.createdAt)
      XCTAssertTrue(after.invocations[0].validated(in: after))
      XCTAssertEqual(
        after.invocations[0].token.resolve(in: after.lines)?.location, prefix.utf16.count)
    }
  }
  func testPendingRoundTripsWithCanonicalTextAndLocks() throws {
    let snapshot = try pending()
    let decoded = try PersistenceFormat.decode(PersistenceFormat.encode(snapshot)).snapshot
    XCTAssertEqual(decoded, snapshot)
    XCTAssertTrue(
      ToolRangeEditing.intersectsLock(NSRange(location: 9, length: 0), snapshot: decoded))
    XCTAssertFalse(
      ToolRangeEditing.intersectsLock(NSRange(location: 10, length: 0), snapshot: decoded))
  }
  func testMissingMalformedOrMismatchedMetadataPreservesEveryCharacter() throws {
    let original = try pending()
    let encoded = try PersistenceFormat.encode(original)
    for broken: Any in ["invalid metadata", [["phase": "pending"]], []] {
      var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      var document = try XCTUnwrap(envelope["document"] as? [String: Any])
      document["invocations"] = broken
      envelope["document"] = document
      let recovered = try PersistenceFormat.decode(JSONSerialization.data(withJSONObject: envelope))
        .snapshot
      XCTAssertEqual(recovered.text, original.text)
      XCTAssertTrue(recovered.invocations.isEmpty)
    }
  }
  func testSQLiteHistoryAndRecoveryRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ToolStorage-\(UUID())")
    removeAfterStoresClose(directory)
    let snapshot = try pending(), store = ownStore(SQLiteStore(directory: directory))
    let loaded = try await store.load()
    let sameDocument = DocumentSnapshot(
      documentID: loaded.documentID, text: snapshot.text, revision: snapshot.revision,
      lines: snapshot.lines, invocations: snapshot.invocations)
    _ = try await store.save(sameDocument)
    _ = try await store.retain(sameDocument, reason: "Tool output", timestamp: Date())
    try await store.close()
    let reopened = ownStore(SQLiteStore(directory: directory))
    let restored = try await reopened.load()
    XCTAssertEqual(restored, sameDocument)
    let revisions = try await reopened.revisions()
    XCTAssertEqual(revisions.count, 1)
    try await reopened.close()
  }
  func testSourceLockRejectsWholeEditAndUnrelatedTextTracksAnchors() throws {
    let snapshot = try pending(), model = try DocumentCoordinator(snapshot: snapshot)
    XCTAssertThrowsError(
      try model.apply(
        .init(
          baseRevision: snapshot.revision, origin: .native,
          mutation: .edit(
            text: "oops", range: NSRange(location: 0, length: 10), replacementLength: 4))))
    XCTAssertEqual(model.snapshot, snapshot)
    let edited = try model.apply(
      .init(
        baseRevision: snapshot.revision, origin: .native,
        mutation: .edit(
          text: "before " + snapshot.text, range: NSRange(location: 0, length: 0),
          replacementLength: 7))
    ).after
    XCTAssertEqual(edited.invocations.count, 1)
    XCTAssertEqual(edited.invocations.first?.token.resolve(in: edited.lines)?.location, 7)
    XCTAssertTrue(edited.invocations[0].validated(in: edited))
  }

  func testToolPublicationWriteFailuresKeepTextAndMetadataTogether() async throws {
    for stage in [StoreStage.bind, .snapshot] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ToolWriteFault-\(UUID())")
      removeAfterStoresClose(directory)
      let initial = ownStore(SQLiteStore(directory: directory))
      let before = try await initial.load()
      try await initial.close()
      let pending = try pending()
      let expected = DocumentSnapshot(
        documentID: before.documentID, text: pending.text, revision: pending.revision,
        lines: pending.lines, invocations: pending.invocations)
      let failing = ownStore(
        SQLiteStore(
          directory: directory,
          inject: { if $0 == stage { throw StoreError.injected(stage.rawValue) } }))
      _ = try await failing.load()
      do {
        _ = try await failing.save(expected)
        XCTFail("Expected injected failure")
      } catch {}
      try await failing.close()
      let reopened = ownStore(SQLiteStore(directory: directory))
      let actual = try await reopened.load()
      XCTAssertEqual(actual, stage == .bind ? before : expected)
      try await reopened.close()
    }
  }

  func testLegacyPayloadRemainsReadableAndMisplacedOutputIsRejected() throws {
    let original = try pending()
    let plain = DocumentSnapshot(
      documentID: original.documentID, text: original.text, revision: original.revision,
      lines: original.lines)
    let legacy = try PersistenceFormat.encode(plain, version: 3)
    XCTAssertEqual(try PersistenceFormat.decode(legacy).snapshot, plain)
    var misplaced = original.invocations[0]
    misplaced.output = try .init(NSRange(location: 6, length: 1), lines: plain.lines)
    misplaced.outputHash = ToolInvocation.hash("3")
    misplaced.sourceHash = ToolInvocation.hash("/calc +3")
    XCTAssertFalse(misplaced.validated(in: original))
  }

  func testRestorationRoundTripsAndOlderInvocationPayloadDefaultsSafely() throws {
    var snapshot = try pending()
    var invocation = snapshot.invocations[0]
    var original = invocation
    original.phase = .inputting
    original.output = nil
    original.outputHash = nil
    invocation.restoration = ToolInvocationRestoration(
      invocation: original,
      selection: try .init(NSRange(location: 6, length: 3), lines: snapshot.lines),
      viewportLineID: snapshot.lines[0].id, viewportOffset: 17.5)
    snapshot = DocumentSnapshot(
      documentID: snapshot.documentID, text: snapshot.text,
      revision: snapshot.revision, lines: snapshot.lines, invocations: [invocation])
    let decoded = try PersistenceFormat.decode(PersistenceFormat.encode(snapshot)).snapshot
    XCTAssertEqual(decoded, snapshot)
    XCTAssertEqual(decoded.invocations[0].restoration?.invocation(id: original.id), original)

    let legacy = try PersistenceFormat.decode(PersistenceFormat.encode(try pending())).snapshot
    XCTAssertEqual(legacy.invocations.count, 1)
    XCTAssertNil(legacy.invocations.first?.restoration)
  }

  func testLegacyInputtingMessageDecodesAsTransientPresentationState() throws {
    let model = try DocumentCoordinator()
    let plain = try model.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .edit(text: "/test", range: NSRange(location: 0, length: 0), replacementLength: 5)
      )
    ).after
    var invocation = ToolInvocation(
      packageID: "dev.jort.test", packageVersion: 1, entryContract: 1,
      inputMode: "contained", outputOperation: "replace-invocation", command: "/test",
      token: try .init(NSRange(location: 0, length: 5), lines: plain.lines),
      scope: try .init(NSRange(location: 0, length: 5), lines: plain.lines),
      sourceHash: ToolInvocation.hash("/test"))
    invocation.message = "Old validation warning"
    let snapshot = DocumentSnapshot(
      documentID: plain.documentID, text: plain.text, revision: plain.revision,
      lines: plain.lines, invocations: [invocation])
    let decoded = try PersistenceFormat.decode(PersistenceFormat.encode(snapshot)).snapshot
    XCTAssertNil(decoded.invocations[0].message)
    XCTAssertEqual(decoded.text, snapshot.text)
  }
}
