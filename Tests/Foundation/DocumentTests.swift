import XCTest
import Foundation
@testable import JortDocument

final class DocumentTests: XCTestCase {
    @MainActor func testTransactionsRevisionAndStaleAnchor() throws {
        let owner = try DocumentCoordinator()
        let initial = owner.snapshot
        let first = try owner.apply(.init(baseRevision: 0, origin: .native, mutation: .edit(text: "hello\nworld", range: nil, replacementLength: nil)))
        XCTAssertEqual(first.after.revision, 1)
        let stale = DocumentTransaction(baseRevision: 1, origin: .automation, mutation: .insertAfter(lineID: first.after.lines[0].id, text: "output"))
        _ = try owner.apply(.init(baseRevision: 1, origin: .native, mutation: .edit(text: "hello!\nworld", range: nil, replacementLength: nil)))
        XCTAssertThrowsError(try owner.apply(stale))
        XCTAssertEqual(owner.snapshot.text, "hello!\nworld")
        let undo = try owner.apply(.init(baseRevision: 2, origin: .undo, undoPolicy: .replay, mutation: .restore(first.before)))
        XCTAssertEqual(undo.after.text, initial.text)
        XCTAssertEqual(undo.after.revision, 3)
        owner.markCommitted(2)
        XCTAssertEqual(owner.committedRevision, 2)
        XCTAssertEqual(owner.snapshot.revision, 3)
    }
    @MainActor func testLineageAndLandmarkPrototype() throws {
        let owner = try DocumentCoordinator()
        func edit(_ text: String, _ range: NSRange? = nil, _ length: Int? = nil) throws {
            try owner.apply(.init(baseRevision: owner.snapshot.revision, origin: .native, mutation: .edit(text: text, range: range, replacementLength: length)))
        }
        try edit("first\nsecond\nthird")
        let original = owner.snapshot
        let landmark = Landmark(lineID: original.lines[1].id, emoji: "🌲")
        try owner.apply(.init(baseRevision: owner.snapshot.revision, origin: .metadata, mutation: .landmark(landmark)))
        let duplicate = Landmark(lineID: original.lines[2].id, emoji: "🌲")
        try owner.apply(.init(baseRevision: owner.snapshot.revision, origin: .metadata, mutation: .landmark(duplicate)))
        try edit("above\nfirst\nsecond\nthird", NSRange(location: 0, length: 0), 6)
        XCTAssertEqual(owner.snapshot.lines[2].id, landmark.lineID)
        try edit("above\nfirst\nsec\nond\nthird")
        XCTAssertEqual(owner.snapshot.lines[2].id, landmark.lineID)
        try edit("above\nfirst\nsecond\nthird")
        XCTAssertEqual(owner.snapshot.lines[2].id, landmark.lineID)
        let withAnchor = owner.snapshot
        try edit("above\nfirst\nthird", NSRange(location: 12, length: 7), 0)
        XCTAssertTrue(owner.snapshot.isDetached(landmark))
        XCTAssertEqual(owner.snapshot.lines[2].id, duplicate.lineID)
        try owner.apply(.init(baseRevision: owner.snapshot.revision, origin: .undo, mutation: .restore(withAnchor)))
        XCTAssertFalse(owner.snapshot.isDetached(landmark))
        let changed = Landmark(id: landmark.id, lineID: landmark.lineID, emoji: "🦊")
        try owner.apply(.init(baseRevision: owner.snapshot.revision, origin: .metadata, mutation: .landmark(changed)))
        XCTAssertEqual(owner.snapshot.landmarks.first(where: { $0.id == landmark.id })?.lineID, landmark.lineID)
        XCTAssertEqual(owner.snapshot.landmarks.first(where: { $0.id == duplicate.id })?.emoji, "🌲")
    }
    @MainActor func testRandomizedTransactionsUndoRedo() throws {
        let owner = try DocumentCoordinator()
        var seed: UInt64 = 41
        func next(_ count: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int(seed >> 32) % count }
        for _ in 0..<500 {
            let before = owner.snapshot
            var characters = Array(before.text)
            let start = next(characters.count + 1), count = next(characters.count - start + 1)
            characters.replaceSubrange(start..<(start + count), with: Array(["x", "\n", "🦊", " ", "é", "\r\n"][next(6)]))
            let result = try owner.apply(.init(baseRevision: before.revision, origin: .native, mutation: .edit(text: String(characters), range: nil, replacementLength: nil)))
            try owner.snapshot.validate()
            try owner.apply(.init(baseRevision: owner.snapshot.revision, origin: .undo, mutation: .restore(before)))
            XCTAssertEqual(owner.snapshot.lines, before.lines)
            try owner.apply(.init(baseRevision: owner.snapshot.revision, origin: .redo, mutation: .restore(result.after)))
            XCTAssertEqual(owner.snapshot.lines, result.after.lines)
            XCTAssertEqual(owner.snapshot.revision, before.revision + 3)
        }
    }
    func testInvalidMetadataRejected() throws {
        let date = Date()
        let id = UUID()
        for snapshot in [
            DocumentSnapshot(text: "x", lines: [.init(location: 0, length: 1)]),
            DocumentSnapshot(text: "x", lines: [.init(location: 0, length: 2, createdAt: date, lastEditedAt: date)]),
            DocumentSnapshot(text: "x\ny", lines: [.init(id: id, location: 0, length: 2, createdAt: date, lastEditedAt: date), .init(id: id, location: 2, length: 1, createdAt: date, lastEditedAt: date)]),
            DocumentSnapshot(text: " ", lines: [.init(location: 0, length: 1, createdAt: date, lastEditedAt: date)])
        ] { XCTAssertThrowsError(try snapshot.validate()) }
    }
}
