import XCTest
import JortDocument
@testable import JortPersistence

@MainActor final class ToolPersistenceTests: XCTestCase {
    private func pending() throws -> DocumentSnapshot {
        let model = try DocumentCoordinator()
        let plain = try model.apply(.init(baseRevision: 0, origin: .native,
            mutation: .edit(text: "/calc 3+36", range: NSRange(location: 0, length: 0), replacementLength: 10))).after
        var invocation = ToolInvocation(packageID: "dev.jort.calc", packageVersion: 1, entryContract: 1,
            inputMode: "contained", outputOperation: "replace-invocation", command: "/calc",
            token: try .init(NSRange(location: 0, length: 5), lines: plain.lines),
            scope: try .init(NSRange(location: 0, length: 9), lines: plain.lines), sourceHash: ToolInvocation.hash("/calc 3+3"))
        invocation.phase = .pending
        invocation.output = try .init(NSRange(location: 9, length: 1), lines: plain.lines)
        invocation.outputHash = ToolInvocation.hash("6")
        return DocumentSnapshot(documentID: plain.documentID, text: plain.text, revision: plain.revision,
            lines: plain.lines, invocations: [invocation])
    }
    func testPendingRoundTripsWithCanonicalTextAndLocks() throws {
        let snapshot = try pending()
        let decoded = try PersistenceFormat.decode(PersistenceFormat.encode(snapshot)).snapshot
        XCTAssertEqual(decoded, snapshot)
        XCTAssertTrue(ToolRangeEditing.intersectsLock(NSRange(location: 9, length: 0), snapshot: decoded))
        XCTAssertFalse(ToolRangeEditing.intersectsLock(NSRange(location: 10, length: 0), snapshot: decoded))
    }
    func testMissingMalformedOrMismatchedMetadataPreservesEveryCharacter() throws {
        let original = try pending()
        let encoded = try PersistenceFormat.encode(original)
        for broken: Any in ["invalid metadata", [["phase": "pending"]], []] {
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var document = try XCTUnwrap(envelope["document"] as? [String: Any])
            document["invocations"] = broken; envelope["document"] = document
            let recovered = try PersistenceFormat.decode(JSONSerialization.data(withJSONObject: envelope)).snapshot
            XCTAssertEqual(recovered.text, original.text); XCTAssertTrue(recovered.invocations.isEmpty)
        }
    }
    func testSQLiteHistoryAndRecoveryRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ToolStorage-\(UUID())")
        let snapshot = try pending(), store = SQLiteStore(directory: directory)
        let loaded = try await store.load()
        let sameDocument = DocumentSnapshot(documentID: loaded.documentID, text: snapshot.text, revision: snapshot.revision,
            lines: snapshot.lines, invocations: snapshot.invocations)
        _ = try await store.save(sameDocument)
        _ = try await store.retain(sameDocument, reason: "Tool output", timestamp: Date())
        try await store.close()
        let reopened = SQLiteStore(directory: directory)
        let restored = try await reopened.load()
        XCTAssertEqual(restored, sameDocument)
        let revisions = try await reopened.revisions(); XCTAssertEqual(revisions.count, 1)
        try await reopened.close()
    }
    func testSourceLockRejectsWholeEditAndUnrelatedTextTracksAnchors() throws {
        let snapshot = try pending(), model = try DocumentCoordinator(snapshot: snapshot)
        XCTAssertThrowsError(try model.apply(.init(baseRevision: snapshot.revision, origin: .native,
            mutation: .edit(text: "oops", range: NSRange(location: 0, length: 10), replacementLength: 4))))
        XCTAssertEqual(model.snapshot, snapshot)
        let edited = try model.apply(.init(baseRevision: snapshot.revision, origin: .native,
            mutation: .edit(text: "before " + snapshot.text, range: NSRange(location: 0, length: 0), replacementLength: 7))).after
        XCTAssertEqual(edited.invocations.count, 1)
        XCTAssertEqual(edited.invocations.first?.token.resolve(in: edited.lines)?.location, 7)
        XCTAssertTrue(edited.invocations[0].validated(in: edited))
    }

    func testToolPublicationWriteFailuresKeepTextAndMetadataTogether() async throws {
        for stage in [StoreStage.bind, .snapshot] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ToolWriteFault-\(UUID())")
            let initial = SQLiteStore(directory: directory)
            let before = try await initial.load(); try await initial.close()
            let pending = try pending()
            let expected = DocumentSnapshot(documentID: before.documentID, text: pending.text, revision: pending.revision,
                lines: pending.lines, invocations: pending.invocations)
            let failing = SQLiteStore(directory: directory, inject: { if $0 == stage { throw StoreError.injected(stage.rawValue) } })
            _ = try await failing.load()
            do { _ = try await failing.save(expected); XCTFail("Expected injected failure") } catch { }
            try await failing.close()
            let reopened = SQLiteStore(directory: directory)
            let actual = try await reopened.load()
            XCTAssertEqual(actual, stage == .bind ? before : expected)
            try await reopened.close()
        }
    }

    func testLegacyPayloadRemainsReadableAndMisplacedOutputIsRejected() throws {
        let original = try pending()
        let plain = DocumentSnapshot(documentID: original.documentID, text: original.text, revision: original.revision, lines: original.lines)
        let legacy = try PersistenceFormat.encode(plain, version: 3)
        XCTAssertEqual(try PersistenceFormat.decode(legacy).snapshot, plain)
        var misplaced = original.invocations[0]
        misplaced.output = try .init(NSRange(location: 6, length: 1), lines: plain.lines)
        misplaced.outputHash = ToolInvocation.hash("3")
        misplaced.sourceHash = ToolInvocation.hash("/calc +3")
        XCTAssertFalse(misplaced.validated(in: original))
    }
}
