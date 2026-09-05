import XCTest
import Foundation
import SQLite3
import JortDocument
import JortPersistence

final class MigrationTests: XCTestCase {
    private func fixture(_ version: Int) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v\(version)", withExtension: "sqlite"))
    }
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("Migration-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path
    }
    private func execute(_ path: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw StoreError.io("fixture open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.io("fixture SQL") }
    }
    func testAllReleasedFixturesMigrateAndReopen() async throws {
        for version in [1, 2] {
            let root = try root(), source = try fixture(version)
            let canonical = root.appendingPathComponent("Jort.sqlite")
            try FileManager.default.copyItem(at: source, to: canonical)
            let bytes = try Data(contentsOf: canonical)
            let store = SQLiteStore(directory: root)
            let loaded = try await store.load()
            XCTAssertEqual(loaded.text, "fixture")
            XCTAssertEqual(loaded.revision, 3)
            XCTAssertEqual(loaded.lines[0].id.uuidString, "11111111-1111-1111-1111-111111111111")
            XCTAssertEqual(try Data(contentsOf: canonical), bytes)
            try await store.close()
            let reopened = SQLiteStore(directory: root)
            let restored = try await reopened.load()
            XCTAssertEqual(restored, loaded)
            try await reopened.close()
        }
    }
    func testMigrationFailureLeavesLegacyReadable() async throws {
        for step in [StoreStage.backup, .create, .write, .bind, .validate, .replace, .close] {
            let root = try root(), canonical = root.appendingPathComponent("Jort.sqlite")
            try FileManager.default.copyItem(at: fixture(1), to: canonical)
            let bytes = try Data(contentsOf: canonical)
            let store = SQLiteStore(directory: root, inject: { if $0 == step { throw StoreError.injected(step.rawValue) } })
            do { _ = try await store.load(); XCTFail("Expected failure") } catch { }
            try await store.close()
            XCTAssertEqual(try Data(contentsOf: canonical), bytes)
            let retry = SQLiteStore(directory: root)
            let migrated = try await retry.load()
            XCTAssertEqual(migrated.text, "fixture")
            try await retry.close()
        }
    }
    func testFutureSQLPayloadAndUnknownSchemaAreUnchanged() async throws {
        for sql in ["PRAGMA user_version=99", "UPDATE current_state SET payload=CAST('{\"formatVersion\":99}' AS BLOB)", "PRAGMA user_version=0", "DROP TABLE current_state; CREATE TABLE current_state(id INTEGER, payload BLOB)"] {
            let root = try root(), canonical = root.appendingPathComponent("Jort.sqlite")
            try FileManager.default.copyItem(at: fixture(1), to: canonical)
            try execute(canonical, sql)
            let bytes = try Data(contentsOf: canonical)
            let store = SQLiteStore(directory: root)
            do { _ = try await store.load(); XCTFail("Expected refusal") } catch { }
            try await store.close()
            XCTAssertEqual(try Data(contentsOf: canonical), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Store").path))
        }
    }
}
