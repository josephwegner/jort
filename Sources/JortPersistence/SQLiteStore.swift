import Foundation
import SQLite3
import Darwin
import JortDocument

public protocol DocumentStore: Sendable {
    func load() async throws -> DocumentSnapshot
    func save(_ snapshot: DocumentSnapshot) async throws -> Int64
    func recover() async throws -> DocumentSnapshot
}
public enum StoreStage: String, CaseIterable, Sendable {
    case backup, create, write, validate, replace, snapshot, bind, close
    case checkpointWrite, checkpointFileSync, checkpointRename, checkpointDirectorySync, checkpointVerify, checkpointManifest, checkpointPublished
}

/// Connection and filesystem state never leave this actor.
public actor SQLiteStore: DocumentStore {
    public let directory: URL
    private var ownership: StoreLock?
    private var connection: Connection?
    private let inject: @Sendable (StoreStage) throws -> Void
    public init(directory: URL, inject: @escaping @Sendable (StoreStage) throws -> Void = { _ in }) {
        self.directory = directory; self.inject = inject
    }
    private var active: URL { directory.appendingPathComponent("Store", isDirectory: true) }
    private func own() throws { if ownership == nil { ownership = try StoreLock(directory: directory) } }
    public func close() throws {
        try connection?.close(); connection = nil; ownership = nil
    }
    public func load() throws -> DocumentSnapshot {
        try own()
        if connection != nil { return try connection!.read().snapshot }
        let source = FileManager.default.fileExists(atPath: active.path) ? active : directory
        let db = source.appendingPathComponent("Jort.sqlite")
        let state: DocumentSnapshot
        if FileManager.default.fileExists(atPath: db.path) {
            // Inspect a private copy, so future versions and failed migrations never modify source WAL/SHM.
            let copy = directory.appendingPathComponent(".Inspect-\(UUID())")
            defer { try? FileManager.default.removeItem(at: copy) }
            try copyFiles(from: source, to: copy)
            let reader = try Connection(directory: copy, create: false)
            defer { try? reader.close() }
            let loaded = try reader.read()
            state = loaded.snapshot
            if loaded.sqlVersion != PersistenceFormat.sqliteVersion || loaded.payloadVersion != PersistenceFormat.payloadVersion || source != active {
                try install(state, preserving: source, prefix: "PreMigration")
            }
        } else {
            // Unknown version-zero schemas are never treated as new databases.
            guard source != active, !FileManager.default.fileExists(atPath: source.appendingPathComponent("Recovery.json").path) else { throw StoreError.invalidPayload }
            state = DocumentSnapshot()
            try install(state, preserving: nil, prefix: "Initial")
        }
        connection = try Connection(directory: active, create: false)
        try connection!.configureWrites()
        return state
    }
    public func save(_ snapshot: DocumentSnapshot) throws -> Int64 {
        try own()
        guard let connection else { throw StoreError.io("Store has not loaded safely") }
        let data = try PersistenceFormat.encode(snapshot)
        try connection.write(data, inject: inject)
        guard try connection.read().snapshot == snapshot else { throw StoreError.invalidPayload }
        try inject(.snapshot)
        // This failure deliberately remains a failed save, even after SQLite commits.
        try RecoveryCheckpoints(directory: active, inject: inject).publish(data, snapshot: snapshot)
        return snapshot.revision
    }
    public func recover() throws -> DocumentSnapshot {
        try own()
        try connection?.close(); connection = nil
        let source = FileManager.default.fileExists(atPath: active.path) ? active : directory
        let snapshot = try RecoveryCheckpoints(directory: source, inject: inject).recover()
        try install(snapshot, preserving: source, prefix: "Damaged")
        connection = try Connection(directory: active, create: false)
        try connection!.configureWrites()
        return snapshot
    }
    private func copyFiles(from source: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["Jort.sqlite", "Jort.sqlite-wal", "Jort.sqlite-shm", "Recovery.json"] + RecoveryCheckpoints.names {
            let file = source.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw StoreError.malformedSchema }
                try FileManager.default.copyItem(at: file, to: target.appendingPathComponent(name))
            }
        }
    }
    private func install(_ snapshot: DocumentSnapshot, preserving source: URL?, prefix: String) throws {
        guard ownership != nil else { throw StoreError.ownership }
        // Originals are not opened or moved during preparation. WAL companions stay together.
        if let source {
            try inject(.backup)
            try copyFiles(from: source, to: directory.appendingPathComponent("\(prefix)-\(UUID())"))
        }
        let stage = directory.appendingPathComponent(".Replacement-\(UUID())")
        var swapped = false
        defer { if !swapped { try? FileManager.default.removeItem(at: stage) } }
        try inject(.create)
        let writer = try Connection(directory: stage, create: true)
        do {
            try inject(.write)
            let data = try PersistenceFormat.encode(snapshot)
            try writer.write(data, inject: inject)
            try RecoveryCheckpoints(directory: stage, inject: inject).publish(data, snapshot: snapshot)
            try inject(.close)
            try writer.close()
        } catch { try? writer.close(); throw error }
        try inject(.validate)
        let reader = try Connection(directory: stage, create: false)
        let decoded = try reader.read()
        try reader.close()
        guard decoded.snapshot == snapshot, decoded.sqlVersion == PersistenceFormat.sqliteVersion,
              try RecoveryCheckpoints(directory: stage, inject: inject).recover() == snapshot else { throw StoreError.invalidPayload }
        try inject(.replace)
        // A directory swap atomically replaces SQLite + WAL + SHM + recovery snapshot as one unit.
        if FileManager.default.fileExists(atPath: active.path) {
            guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, active.path, UInt32(RENAME_SWAP)) == 0 else { throw StoreError.io("atomic swap: \(errno)") }
            swapped = true // The old canonical directory remains at stage, in addition to its diagnostic backup.
        } else {
            guard Darwin.rename(stage.path, active.path) == 0 else { throw StoreError.io("atomic install: \(errno)") }
        }
        let parent = Darwin.open(directory.path, O_RDONLY)
        guard parent >= 0 else { throw StoreError.io("store directory open: \(errno)") }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw StoreError.io("store directory sync: \(errno)") }
    }
}

private final class Connection {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL, create: Bool) throws {
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let flags = create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READWRITE
        let result = sqlite3_open_v2(directory.appendingPathComponent("Jort.sqlite").path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else { let error = failure(result); sqlite3_close_v2(db); db = nil; throw error }
        do {
            try check(sqlite3_busy_timeout(db, 250))
            if create {
                try execute("BEGIN IMMEDIATE")
                try execute("CREATE TABLE current_state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)")
                try execute("PRAGMA user_version=3")
                try execute("COMMIT")
            }
        } catch { sqlite3_close_v2(db); db = nil; throw error }
    }
    deinit { if let db { sqlite3_close_v2(db) } }
    func close() throws {
        guard let db else { return }
        try check(sqlite3_close(db)); self.db = nil
    }
    func configureWrites() throws { try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON") }
    private func failure(_ code: Int32) -> StoreError { .sqlite(code & 0xff, db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite closed") }
    private func check(_ result: Int32) throws { if result != SQLITE_OK { throw failure(result) } }
    private func execute(_ sql: String) throws { try check(sqlite3_exec(db, sql, nil, nil, nil)) }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        guard let statement else { throw StoreError.malformedSchema }; return statement
    }
    func read() throws -> (snapshot: DocumentSnapshot, sqlVersion: Int, payloadVersion: Int) {
        let version = try prepare("PRAGMA user_version")
        let result = sqlite3_step(version)
        guard result == SQLITE_ROW else { sqlite3_finalize(version); throw failure(result) }
        let sqlVersion = Int(sqlite3_column_int(version, 0)); try check(sqlite3_finalize(version))
        guard sqlVersion <= PersistenceFormat.sqliteVersion else { throw StoreError.unsupportedVersion }
        guard (1...PersistenceFormat.sqliteVersion).contains(sqlVersion) else { throw StoreError.malformedSchema }
        let schema = try prepare("SELECT sql FROM sqlite_master WHERE type='table' AND name='current_state'")
        guard sqlite3_step(schema) == SQLITE_ROW, let definition = sqlite3_column_text(schema, 0) else { sqlite3_finalize(schema); throw StoreError.malformedSchema }
        let sql = String(cString: definition).lowercased().filter { !$0.isWhitespace }
        try check(sqlite3_finalize(schema))
        guard sql.contains("idintegerprimarykeycheck(id=1)"), sql.contains("payloadblobnotnull") else { throw StoreError.malformedSchema }
        let columns = try prepare("PRAGMA table_info(current_state)")
        var shape: [String] = []
        var step = sqlite3_step(columns)
        while step == SQLITE_ROW {
            guard let name = sqlite3_column_text(columns, 1), let type = sqlite3_column_text(columns, 2) else { sqlite3_finalize(columns); throw StoreError.malformedSchema }
            shape.append("\(String(cString: name).lowercased()):\(String(cString: type).uppercased()):\(sqlite3_column_int(columns, 3)):\(sqlite3_column_int(columns, 5))")
            step = sqlite3_step(columns)
        }
        guard step == SQLITE_DONE else { sqlite3_finalize(columns); throw failure(step) }
        try check(sqlite3_finalize(columns))
        guard shape == ["id:INTEGER:0:1", "payload:BLOB:1:0"] else { throw StoreError.malformedSchema }
        let statement = try prepare("SELECT payload FROM current_state WHERE id=1")
        defer {
            let code = sqlite3_finalize(statement)
            if code != SQLITE_OK { NSLog("Jort finalize secondary error: %d", code) }
        }
        let row = sqlite3_step(statement)
        if row == SQLITE_DONE { return (DocumentSnapshot(), sqlVersion, sqlVersion) }
        guard row == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure(row) }
        let size = Int(sqlite3_column_bytes(statement, 0))
        guard size <= PersistenceFormat.maximumBytes else { throw StoreError.sizeLimit }
        let payload = try PersistenceFormat.decode(Data(bytes: bytes, count: size))
        return (payload.snapshot, sqlVersion, payload.version)
    }
    func write(_ data: Data, inject: @Sendable (StoreStage) throws -> Void) throws {
        guard data.count <= PersistenceFormat.maximumBytes, data.count <= Int(Int32.max) else { throw StoreError.sizeLimit }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT INTO current_state(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload")
            do {
                try inject(.bind)
                try data.withUnsafeBytes { bytes in try check(sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(data.count), transient)) }
                let result = sqlite3_step(statement)
                guard result == SQLITE_DONE else { throw failure(result) }
            } catch { sqlite3_finalize(statement); throw error }
            try check(sqlite3_finalize(statement))
            try execute("COMMIT")
        } catch {
            let primary = error
            do { try execute("ROLLBACK") } catch { NSLog("Jort rollback secondary error: %@", String(describing: error)) }
            throw primary
        }
    }
}
