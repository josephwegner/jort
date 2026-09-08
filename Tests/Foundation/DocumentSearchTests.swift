import XCTest
import JortDocument

final class DocumentSearchTests: XCTestCase {
    @MainActor private func owner(_ text: String) throws -> DocumentCoordinator {
        let owner = try DocumentCoordinator()
        try owner.apply(.init(baseRevision: 0, origin: .native, mutation: .edit(text: text, range: nil, replacementLength: nil)))
        return owner
    }
    @MainActor func testLiteralCaseAndUnicodeWordBoundaries() throws {
        let snapshot = try owner("Cat cat scatter cat_ cat2 café cafe\u{301} .*[x] 👩🏽‍💻").snapshot
        XCTAssertEqual(try DocumentSearch.scan(snapshot, query: "cat").matches.count, 5)
        XCTAssertEqual(try DocumentSearch.scan(snapshot, query: "cat", options: .init(caseSensitive: true, wholeWord: true)).matches.count, 1)
        XCTAssertEqual(try DocumentSearch.scan(snapshot, query: "cat", options: .init(wholeWord: true)).matches.count, 2)
        XCTAssertEqual(try DocumentSearch.scan(snapshot, query: "cafe", options: .init(wholeWord: true)).matches.count, 0)
        XCTAssertEqual(try DocumentSearch.scan(snapshot, query: ".*[x]").matches.count, 1)
        for query in ["👩🏽‍💻", "cafe\u{301}", "café"] {
            let match = try XCTUnwrap(DocumentSearch.scan(snapshot, query: query).matches.first)
            XCTAssertEqual((snapshot.text as NSString).substring(with: try XCTUnwrap(match.resolve(in: snapshot))), query)
        }
    }
    @MainActor func testMultilineAndShiftedAnchorsRejectChangedTextAndDocuments() throws {
        let document = try owner("header\nneedle\nnext")
        let original = document.snapshot
        let match = try XCTUnwrap(DocumentSearch.scan(original, query: "needle\nnext").matches.first)
        XCTAssertEqual(match.ordinal, 2)
        XCTAssertEqual(match.snippet, "needle")
        try document.apply(.init(baseRevision: document.snapshot.revision, origin: .native, mutation: .edit(text: "longer header\nneedle\nnext", range: nil, replacementLength: nil)))
        XCTAssertEqual(match.resolve(in: document.snapshot)?.location, 14)
        try document.apply(.init(baseRevision: document.snapshot.revision, origin: .native, mutation: .edit(text: "longer header\nother!\nnext", range: nil, replacementLength: nil)))
        XCTAssertNil(match.resolve(in: document.snapshot))
        XCTAssertNil(match.resolve(in: try owner(original.text).snapshot))
    }
    @MainActor func testEmptyLimitAndBoundedContext() throws {
        let snapshot = try owner(String(repeating: "👩🏽‍💻 needle ", count: 1_000)).snapshot
        XCTAssertTrue(try DocumentSearch.scan(snapshot, query: "").matches.isEmpty)
        let page = try DocumentSearch.scan(snapshot, query: "needle", limit: 10)
        XCTAssertEqual(page.matches.count, 10); XCTAssertTrue(page.hasMore)
        XCTAssertTrue(page.matches.allSatisfy { $0.snippet.utf16.count < 200 })
        let combining = try owner("needle " + "e" + String(repeating: "\u{301}", count: 10_000)).snapshot
        XCTAssertLessThan(try XCTUnwrap(DocumentSearch.scan(combining, query: "needle").matches.first).snippet.utf16.count, 200)
    }
    func testCancellation() async throws {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DocumentSearch.scan(DocumentSnapshot(), query: "anything")
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
    }
}
