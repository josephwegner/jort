import XCTest
import JortDocument

final class HistoryComparisonTests: XCTestCase {
    @MainActor func testToolMetadataOnlyChangesRemainVisibleAndCanonical() throws {
        let owner = try DocumentCoordinator()
        try owner.apply(.init(baseRevision: 0, origin: .native, mutation: .edit(text: "/calc 3+36", range: nil, replacementLength: nil)))
        let plain = owner.snapshot
        var invocation = ToolInvocation(packageID: "dev.jort.calc", packageVersion: 1, entryContract: 1,
            inputMode: "contained", outputOperation: "replace-invocation", command: "/calc",
            token: try .init(NSRange(location: 0, length: 5), lines: plain.lines),
            scope: try .init(NSRange(location: 0, length: 9), lines: plain.lines), sourceHash: ToolInvocation.hash("/calc 3+3"))
        invocation.phase = .pending
        invocation.output = try .init(NSRange(location: 9, length: 1), lines: plain.lines)
        invocation.outputHash = ToolInvocation.hash("6")
        let annotated = DocumentSnapshot(documentID: plain.documentID, text: plain.text, revision: plain.revision,
            lines: plain.lines, landmarks: plain.landmarks, invocations: [invocation])
        let diff = try HistoryComparison.compare(plain, annotated)
        XCTAssertTrue(diff.metadataChanged)
        XCTAssertEqual(diff.lines.first { $0.kind == .added }?.tools.first?.label, "/calc · Pending merge")
        XCTAssertEqual(diff.lines.first { $0.kind == .added }?.tools.first?.containsOutput, true)
        XCTAssertEqual(diff.lines.filter { $0.kind != .removed }.map(\.text).joined(), plain.text)
        XCTAssertEqual(diff.lines.filter { $0.kind != .added }.map(\.text).joined(), plain.text)
    }
    @MainActor func testChangesReconstructBothSnapshotsIncludingUnicodeAndLandmarks() throws {
        let owner = try DocumentCoordinator()
        try owner.apply(.init(baseRevision: 0, origin: .native, mutation: .edit(text: "one\n👩🏽‍💻 café\nthree\n", range: nil, replacementLength: nil)))
        let before = owner.snapshot
        try owner.apply(.init(baseRevision: 1, origin: .native, mutation: .edit(text: "one\nupdated 🦊\nthree\nlast", range: nil, replacementLength: nil)))
        try owner.apply(.init(baseRevision: 2, origin: .metadata, mutation: .landmark(Landmark(lineID: owner.snapshot.lines[2].id, emoji: "🌲"))))
        let diff = try HistoryComparison.compare(before, owner.snapshot)
        XCTAssertEqual(diff.lines.filter { $0.kind != .added }.map(\.text).joined(), before.text)
        XCTAssertEqual(diff.lines.filter { $0.kind != .removed }.map(\.text).joined(), owner.snapshot.text)
        XCTAssertTrue(diff.lines.contains { $0.emoji == "🌲" && $0.kind == .added })
        XCTAssertTrue(diff.metadataChanged)
    }

    @MainActor func testIdenticalStateHasOnlyContext() throws {
        let owner = try DocumentCoordinator()
        try owner.apply(.init(baseRevision: 0, origin: .native, mutation: .edit(text: "same\nsame\n", range: nil, replacementLength: nil)))
        let diff = try HistoryComparison.compare(owner.snapshot, owner.snapshot)
        XCTAssertEqual(diff.added, 0); XCTAssertEqual(diff.removed, 0)
        XCTAssertFalse(diff.metadataChanged)
        XCTAssertEqual(diff.lines.compactMap(\.newOrdinal), [1, 2, 3])
    }

    @MainActor func testCancellationAndDocumentMismatch() async throws {
        let snapshot = DocumentSnapshot()
        let task = Task.detached {
            try await Task.sleep(for: .milliseconds(10))
            return try HistoryComparison.compare(snapshot, snapshot)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch is CancellationError { }
        XCTAssertThrowsError(try HistoryComparison.compare(snapshot, DocumentSnapshot()))
    }

    func testLargeReorderedDocumentRemainsReconstructable() throws {
        let count = 10_000, date = Date(timeIntervalSinceReferenceDate: 100), id = UUID()
        let ids = (0..<count).map { _ in UUID() }
        func snapshot(_ order: [Int]) -> DocumentSnapshot {
            var text = "", lines: [LineMeta] = []
            for (index, value) in order.enumerated() {
                let line = "Line \(value)" + (index == order.count - 1 ? "" : "\n")
                lines.append(LineMeta(id: ids[value], location: text.utf16.count, length: line.utf16.count, createdAt: date, lastEditedAt: date))
                text += line
            }
            return DocumentSnapshot(documentID: id, text: text, lines: lines)
        }
        let old = snapshot(Array(0..<count)), new = snapshot(Array((0..<count).reversed()))
        let diff = try HistoryComparison.compare(old, new)
        XCTAssertEqual(diff.lines.filter { $0.kind != .added }.map(\.text).joined(), old.text)
        XCTAssertEqual(diff.lines.filter { $0.kind != .removed }.map(\.text).joined(), new.text)
        XCTAssertLessThanOrEqual(diff.lines.count, count * 2)
    }
}
