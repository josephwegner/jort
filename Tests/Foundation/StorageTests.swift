import XCTest
import Foundation
import SQLite3
import JortDocument
@testable import JortPersistence

final class StorageTests: XCTestCase {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JortTest-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func snapshot() -> DocumentSnapshot {
        DocumentSnapshot(text: "Persist 🦊\n", revision: 7, lines: [LineMeta(location: 0, length: 11, createdAt: Date(timeIntervalSinceReferenceDate: 100), lastEditedAt: Date(timeIntervalSinceReferenceDate: 100)), LineMeta(location: 11, length: 0)])
    }
    func testRoundTripAndRecoveryEveryStage() async throws {
        for stage in [StoreStage.backup, .create, .write, .validate, .replace, .close] {
            let root = try temp()
            let original = SQLiteStore(directory: root)
            _ = try await original.load()
            let expected = snapshot()
            _ = try await original.save(expected)
            try await original.close()
            let canonical = root.appendingPathComponent("Store/Jort.sqlite")
            let damage = Data("not a SQLite database".utf8)
            try damage.write(to: canonical)
            let broken = SQLiteStore(directory: root, inject: { if $0 == stage { throw StoreError.injected(stage.rawValue) } })
            do { _ = try await broken.recover(); XCTFail("Expected \(stage)") } catch { }
            XCTAssertEqual(try Data(contentsOf: canonical), damage)
            try await broken.close()
            let retry = SQLiteStore(directory: root)
            let recovered = try await retry.recover()
            XCTAssertEqual(recovered, expected)
            try await retry.close()
            let reopened = SQLiteStore(directory: root)
            let restored = try await reopened.load()
            XCTAssertEqual(restored, expected)
            try await reopened.close()
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("Damaged-") })
        }
    }
    func testSnapshotAndBindFailureDoNotClaimSuccess() async throws {
        for stage in [StoreStage.bind, .snapshot] {
            let root = try temp(), normal = SQLiteStore(directory: try temp())
            _ = try await normal.load(); try await normal.close()
            let initial = SQLiteStore(directory: root); let before = try await initial.load(); try await initial.close()
            let broken = SQLiteStore(directory: root, inject: { if $0 == stage { throw StoreError.injected(stage.rawValue) } })
            _ = try await broken.load()
            do { _ = try await broken.save(snapshot()); XCTFail("Must fail") } catch { }
            try await broken.close()
            let reopened = SQLiteStore(directory: root); let actual = try await reopened.load()
            XCTAssertEqual(actual.revision, stage == .bind ? before.revision : 7)
            try await reopened.close()
        }
    }
    func testSingleOwnerAndDifferentDirectories() async throws {
        let root = try temp(), first = SQLiteStore(directory: try temp())
        let a = SQLiteStore(directory: root), b = SQLiteStore(directory: root)
        _ = try await a.load(); _ = try await first.load()
        do { _ = try await b.load(); XCTFail("Second owner") } catch { XCTAssertEqual(error as? StoreError, .ownership) }
        do { _ = try await b.recover(); XCTFail("Second recovery owner") } catch { XCTAssertEqual(error as? StoreError, .ownership) }
        try await a.close()
        _ = try await b.load()
        try await b.close(); try await first.close()
    }
    func testFormatVersionsAndSize() throws {
        let expected = snapshot()
        let data = try PersistenceFormat.encode(expected)
        let decoded = try PersistenceFormat.decode(data).snapshot
        XCTAssertEqual(decoded, expected)
        XCTAssertThrowsError(try PersistenceFormat.decode(Data("{\"formatVersion\":99}".utf8))) { XCTAssertEqual($0 as? StoreError, .unsupportedVersion) }
        XCTAssertThrowsError(try PersistenceFormat.decode(Data(repeating: 0, count: PersistenceFormat.maximumBytes + 1))) { XCTAssertEqual($0 as? StoreError, .sizeLimit) }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var document = try XCTUnwrap(json["document"] as? [String: Any]); document.removeValue(forKey: "landmarks"); json["document"] = document
        XCTAssertThrowsError(try PersistenceFormat.decode(JSONSerialization.data(withJSONObject: json)))
        json["formatVersion"] = 2
        XCTAssertEqual(try PersistenceFormat.decode(JSONSerialization.data(withJSONObject: json)).snapshot.landmarks, [])
    }
    func testBusyAndReadOnlyFailuresPreserveRetryableStore() async throws {
        let root = try temp(), store = SQLiteStore(directory: root)
        _ = try await store.load()
        var external: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("Store/Jort.sqlite").path, &external), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(external, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        do { _ = try await store.save(snapshot()); XCTFail("Expected busy") }
        catch { guard case StoreError.sqlite(5, _) = error else { return XCTFail("Unexpected \(error)") } }
        XCTAssertEqual(sqlite3_exec(external, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(external), SQLITE_OK)
        let value = snapshot()
        let revision = try await store.save(value); XCTAssertEqual(revision, value.revision)
        let folder = root.appendingPathComponent("Store")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        do { _ = try await store.save(value); XCTFail("Expected recovery-snapshot write failure") } catch { }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        _ = try await store.save(value)
        try await store.close()
    }
    func testOversizedSaveKeepsLastCommittedState() async throws {
        let root = try temp(), store = SQLiteStore(directory: root)
        let before = try await store.load()
        let count = PersistenceFormat.maximumBytes + 1
        let date = Date()
        let huge = DocumentSnapshot(text: String(repeating: "x", count: count), revision: 1, lines: [LineMeta(location: 0, length: count, createdAt: date, lastEditedAt: date)])
        do { _ = try await store.save(huge); XCTFail("Expected size limit") }
        catch { XCTAssertEqual(error as? StoreError, .sizeLimit) }
        let actual = try await store.load(); XCTAssertEqual(actual, before)
        try await store.close()
    }

}
