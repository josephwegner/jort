import Foundation
import SQLite3

enum StoreError: LocalizedError {
    case message(String)
    case unsupportedVersion
    case sqlite(Int32, String)
    var errorDescription: String? {
        switch self {
        case .message(let message), .sqlite(_, let message): return message
        case .unsupportedVersion: return "This store was created by a newer version of Jort. Its files have not been changed."
        }
    }
    var isCorruption: Bool {
        if case .sqlite(let code, _) = self { return code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
        return false
    }
}

protocol DocumentStore: AnyObject {
    func load() throws -> DocumentState?
    func save(_ state: DocumentState) throws
    func recover() throws -> DocumentState
}

/// Accessed only on PersistenceController's serial utility queue.
final class SQLiteStore: DocumentStore {
    let directory: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var databaseURL: URL { directory.appendingPathComponent("Jort.sqlite") }
    var recoveryURL: URL { directory.appendingPathComponent("Recovery.json") }

    init(directory: URL) { self.directory = directory }
    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> StoreError {
        .sqlite(db.map { sqlite3_errcode($0) } ?? SQLITE_CANTOPEN, db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open local storage.")
    }
    func open() throws {
        if db != nil { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let failure = error(); sqlite3_close(db); db = nil; throw failure
        }
        do {
            sqlite3_busy_timeout(db, 250)
            try checkVersion()
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
            try execute("CREATE TABLE IF NOT EXISTS current_state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL); PRAGMA user_version=1;")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    private func checkVersion() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        guard sqlite3_column_int(statement, 0) <= 1 else { throw StoreError.unsupportedVersion }
    }
    func load() throws -> DocumentState? {
        try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM current_state WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw error() }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        let state = try JSONDecoder().decode(DocumentState.self, from: data)
        try state.validate()
        return state
    }
    func save(_ state: DocumentState) throws {
        try open()
        let data = try JSONEncoder().encode(state)
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO current_state(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", -1, &statement, nil) == SQLITE_OK else { throw error() }
            defer { sqlite3_finalize(statement) }
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        // A separately atomic safe snapshot also permits recovery when SQLite is damaged.
        try data.write(to: recoveryURL, options: .atomic)
    }
    func recover() throws -> DocumentState {
        sqlite3_close(db); db = nil
        let backup = directory.appendingPathComponent("Damaged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in ["Jort.sqlite", "Jort.sqlite-wal", "Jort.sqlite-shm"] {
            let source = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: backup.appendingPathComponent(name))
            }
        }
        // Never replace a damaged store without a validated recovery snapshot.
        let state = try JSONDecoder().decode(DocumentState.self, from: Data(contentsOf: recoveryURL))
        try state.validate()
        for name in ["Jort.sqlite", "Jort.sqlite-wal", "Jort.sqlite-shm"] {
            let source = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
        }
        try save(state)
        return state
    }
}
