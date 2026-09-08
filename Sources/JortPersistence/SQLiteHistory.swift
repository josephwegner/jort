import Foundation
import SQLite3
import JortDocument

public protocol HistoryStore: Sendable {
    func revisions(before sequence: Int64?, limit: Int) async throws -> [HistoryEntry]
    func revision(sequence: Int64) async throws -> HistoryRevision
    func retain(_ snapshot: DocumentSnapshot, reason: String, timestamp: Date, milestone: Bool) async throws -> HistoryEntry
    func historySettings() async throws -> HistorySettings
    func setHistorySettings(_ settings: HistorySettings) async throws
    func pruneHistory() async throws -> HistoryPruneResult
}

extension SQLiteStore: HistoryStore {
    public func revisions(before sequence: Int64? = nil, limit: Int = 100) throws -> [HistoryEntry] {
        try historyConnection().historyEntries(before: sequence, limit: limit)
    }

    public func revision(sequence: Int64) throws -> HistoryRevision {
        let connection = try historyConnection()
        let revision = try connection.historyRevision(sequence: sequence)
        guard revision.snapshot.documentID == (try connection.read()).snapshot.documentID else { throw StoreError.invalidPayload }
        return revision
    }

    public func retain(_ snapshot: DocumentSnapshot, reason: String, timestamp: Date = Date(),
                       milestone: Bool = false) throws -> HistoryEntry {
        let connection = try historyConnection()
        guard snapshot.documentID == (try connection.read()).snapshot.documentID else { throw StoreError.invalidPayload }
        let (payload, metadata) = try HistoryRevisionFormat.encode(snapshot, reason: reason,
            timestamp: timestamp, milestone: milestone)
        if let latest = try connection.historyEntries(before: nil, limit: 1).first,
           latest.metadata?.stateHash == metadata.stateHash,
           // A matching hash alone must never authorize skipping the pre-restore save.
           let verified = try? connection.historyRevision(sequence: latest.sequence),
           verified.metadata.stateHash == metadata.stateHash {
            if milestone && !verified.metadata.milestone {
                let (protectedPayload, protectedMetadata) = try HistoryRevisionFormat.encode(verified.snapshot,
                    reason: verified.metadata.reason, timestamp: verified.metadata.timestamp,
                    milestone: true, id: verified.metadata.id)
                return try connection.insertHistory(payload: protectedPayload, metadata: protectedMetadata,
                    replacing: latest.sequence) { try self.historyInjection($0) }
            }
            return latest
        }
        return try connection.insertHistory(payload: payload, metadata: metadata) { stage in
            try self.historyInjection(stage)
        }
    }

    public func historySettings() throws -> HistorySettings {
        try historyConnection().readHistorySettings()
    }

    public func setHistorySettings(_ settings: HistorySettings) throws {
        try settings.validate()
        try historyConnection().writeHistorySettings(settings)
    }

    public func pruneHistory() throws -> HistoryPruneResult {
        try historyConnection().pruneHistory { try self.historyInjection($0) }
    }
}

/// SQLite mechanics stay on SQLiteStore's executor. Current-state reads deliberately
/// do not traverse these tables, so a corrupt historical envelope cannot block launch.
extension Connection {
    func createHistorySchema() throws {
        try execute("""
            CREATE TABLE history_revisions (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                metadata BLOB NOT NULL,
                metadata_hash TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE TABLE history_settings (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);
            """)
        try writeHistorySettings(HistorySettings())
    }

    func validateHistorySchema() throws {
        for (table, expected) in [
            ("history_revisions", ["sequence:INTEGER:0:1", "metadata:BLOB:1:0", "metadata_hash:TEXT:1:0", "payload:BLOB:1:0"]),
            ("history_settings", ["id:INTEGER:0:1", "payload:BLOB:1:0"])
        ] {
            let statement = try prepare("PRAGMA table_info(\(table))")
            defer { sqlite3_finalize(statement) }
            var shape: [String] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                guard let name = sqlite3_column_text(statement, 1), let type = sqlite3_column_text(statement, 2) else {
                    throw StoreError.malformedSchema
                }
                shape.append("\(String(cString: name)):\(String(cString: type)):\(sqlite3_column_int(statement, 3)):\(sqlite3_column_int(statement, 5))")
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw failure(step) }
            guard shape == expected else { throw StoreError.malformedSchema }
        }
        let definitions = try prepare("SELECT name,sql FROM sqlite_master WHERE type='table' AND name IN ('history_revisions','history_settings')")
        defer { sqlite3_finalize(definitions) }
        var step = sqlite3_step(definitions)
        while step == SQLITE_ROW {
            guard let name = sqlite3_column_text(definitions, 0), let definition = sqlite3_column_text(definitions, 1) else {
                throw StoreError.malformedSchema
            }
            let sql = String(cString: definition).lowercased().filter { !$0.isWhitespace }
            let required = String(cString: name) == "history_revisions"
                ? "sequenceintegerprimarykeyautoincrement" : "idintegerprimarykeycheck(id=1)"
            guard sql.contains(required) else { throw StoreError.malformedSchema }
            step = sqlite3_step(definitions)
        }
        guard step == SQLITE_DONE else { throw failure(step) }
    }

    func historyEntries(before sequence: Int64?, limit: Int) throws -> [HistoryEntry] {
        guard (1...500).contains(limit), sequence == nil || sequence! > 0 else { throw StoreError.invalidPayload }
        let sql = "SELECT sequence,metadata,metadata_hash,length(payload) FROM history_revisions" +
            (sequence == nil ? "" : " WHERE sequence < ?") + " ORDER BY sequence DESC LIMIT ?"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let sequence { try check(sqlite3_bind_int64(statement, 1, sequence)) }
        try check(sqlite3_bind_int(statement, sequence == nil ? 1 : 2, Int32(limit)))
        var entries: [HistoryEntry] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let metadata = try? historyMetadata(statement, column: 1, hashColumn: 2)
            entries.append(HistoryEntry(sequence: sqlite3_column_int64(statement, 0), metadata: metadata,
                storedBytes: Int(sqlite3_column_int64(statement, 3)) + Int(sqlite3_column_bytes(statement, 1))))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw failure(step) }
        return entries
    }

    func historyRevision(sequence: Int64) throws -> HistoryRevision {
        guard sequence > 0 else { throw StoreError.invalidPayload }
        let statement = try prepare("SELECT metadata,metadata_hash,payload FROM history_revisions WHERE sequence=?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, sequence))
        let step = sqlite3_step(statement)
        guard step != SQLITE_DONE else { throw StoreError.invalidPayload }
        guard step == SQLITE_ROW else { throw failure(step) }
        let metadata = try historyMetadata(statement, column: 0, hashColumn: 1)
        let payload = try historyBlob(statement, column: 2, maximum: HistoryRevisionFormat.maximumBytes)
        let revision = try HistoryRevisionFormat.decode(payload)
        guard revision.metadata == metadata else { throw StoreError.invalidPayload }
        return revision
    }

    func insertHistory(payload: Data, metadata: HistoryRevisionMetadata,
                       replacing existingSequence: Int64? = nil,
                       preservingSequence: Int64? = nil,
                       inject: (StoreStage) throws -> Void) throws -> HistoryEntry {
        let encodedMetadata = try HistoryRevisionFormat.encodeJSON(metadata)
        try execute("BEGIN IMMEDIATE")
        do {
            let sql = existingSequence == nil
                ? (preservingSequence == nil
                    ? "INSERT INTO history_revisions(metadata,metadata_hash,payload) VALUES(?,?,?) RETURNING sequence"
                    : "INSERT INTO history_revisions(metadata,metadata_hash,payload,sequence) VALUES(?,?,?,?) RETURNING sequence")
                : "UPDATE history_revisions SET metadata=?,metadata_hash=?,payload=? WHERE sequence=? RETURNING sequence"
            let statement = try prepare(sql)
            let sequence: Int64
            do {
                try bindHistoryBlob(encodedMetadata, to: statement, column: 1)
                let digest = PersistenceFormat.checksum(encodedMetadata)
                try digest.withCString { value in
                    try check(sqlite3_bind_text(statement, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
                }
                try bindHistoryBlob(payload, to: statement, column: 3)
                if let existingSequence { try check(sqlite3_bind_int64(statement, 4, existingSequence)) }
                if let preservingSequence { try check(sqlite3_bind_int64(statement, 4, preservingSequence)) }
                try inject(.historyWrite)
                let row = sqlite3_step(statement)
                guard row == SQLITE_ROW else { throw failure(row) }
                sequence = sqlite3_column_int64(statement, 0)
                let done = sqlite3_step(statement)
                guard done == SQLITE_DONE else { throw failure(done) }
            } catch { sqlite3_finalize(statement); throw error }
            try check(sqlite3_finalize(statement))
            try inject(.historyVerify)
            guard try historyRevision(sequence: sequence).metadata == metadata else { throw StoreError.invalidPayload }
            try inject(.historyCommit)
            try execute("COMMIT")
            return HistoryEntry(sequence: sequence, metadata: metadata, storedBytes: payload.count + encodedMetadata.count)
        } catch {
            let primary = error
            do { try execute("ROLLBACK") } catch { NSLog("Jort history rollback secondary error: %@", String(describing: error)) }
            throw primary
        }
    }

    func readHistorySettings() throws -> HistorySettings {
        let statement = try prepare("SELECT payload FROM history_settings WHERE id=1")
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE { throw StoreError.invalidPayload }
            throw failure(step)
        }
        do {
            let settings = try JSONDecoder().decode(HistorySettings.self,
                from: historyBlob(statement, column: 0, maximum: 4096))
            try settings.validate()
            return settings
        } catch let error as StoreError { throw error }
        catch { throw StoreError.invalidPayload }
    }

    func writeHistorySettings(_ settings: HistorySettings) throws {
        try settings.validate()
        let statement = try prepare("INSERT INTO history_settings(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        try bindHistoryBlob(HistoryRevisionFormat.encodeJSON(settings), to: statement, column: 1)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else { throw failure(step) }
    }

    private func historyMetadata(_ statement: OpaquePointer, column: Int32, hashColumn: Int32) throws -> HistoryRevisionMetadata {
        let data = try historyBlob(statement, column: column, maximum: 4096)
        guard let hash = sqlite3_column_text(statement, hashColumn),
              String(cString: hash) == PersistenceFormat.checksum(data) else { throw StoreError.invalidPayload }
        do {
            let metadata = try JSONDecoder().decode(HistoryRevisionMetadata.self, from: data)
            try HistoryRevisionFormat.validate(metadata)
            return metadata
        } catch let error as StoreError { throw error }
        catch { throw StoreError.invalidPayload }
    }

    private func historyBlob(_ statement: OpaquePointer, column: Int32, maximum: Int) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= maximum, sqlite3_column_type(statement, column) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, column) else { throw StoreError.invalidPayload }
        return Data(bytes: bytes, count: count)
    }

    private func bindHistoryBlob(_ data: Data, to statement: OpaquePointer, column: Int32) throws {
        guard data.count <= HistoryRevisionFormat.maximumBytes else { throw StoreError.sizeLimit }
        try data.withUnsafeBytes { bytes in
            try check(sqlite3_bind_blob(statement, column, bytes.baseAddress, Int32(data.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
        }
    }
}
