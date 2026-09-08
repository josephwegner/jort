import Foundation
import SQLite3

public struct HistoryPruneResult: Equatable, Sendable {
    public let removedCount: Int
    public let retainedBytes: Int64
    public let exceedsBudget: Bool
}

extension Connection {
    func pruneHistory(inject: (StoreStage) throws -> Void) throws -> HistoryPruneResult {
        let settings = try readHistorySettings()
        try execute("BEGIN IMMEDIATE")
        do {
            var entries: [HistoryEntry] = []
            var before: Int64?
            while true {
                let page = try historyEntries(before: before, limit: 500)
                if page.isEmpty { break }
                entries.append(contentsOf: page)
                before = page.last?.sequence
            }
            var bytes: Int64 = 0
            for entry in entries {
                let (total, overflow) = bytes.addingReportingOverflow(Int64(entry.storedBytes))
                guard !overflow, entry.storedBytes >= 0 else { throw StoreError.invalidPayload }
                bytes = total
            }
            var removed = 0
            // Unknown metadata is protected: we cannot establish that it is not a milestone.
            for entry in entries.dropFirst(settings.minimumRecentCount).reversed() where bytes > Int64(settings.byteBudget) {
                guard let metadata = entry.metadata, !metadata.milestone else { continue }
                let statement = try prepare("DELETE FROM history_revisions WHERE sequence=?")
                do {
                    try check(sqlite3_bind_int64(statement, 1, entry.sequence))
                    let step = sqlite3_step(statement)
                    guard step == SQLITE_DONE else { throw failure(step) }
                } catch { sqlite3_finalize(statement); throw error }
                try check(sqlite3_finalize(statement))
                bytes -= Int64(entry.storedBytes)
                removed += 1
            }
            try inject(.historyPrune)
            try execute("COMMIT")
            return HistoryPruneResult(removedCount: removed, retainedBytes: bytes,
                exceedsBudget: bytes > Int64(settings.byteBudget))
        } catch {
            let primary = error
            do { try execute("ROLLBACK") } catch { NSLog("Jort pruning rollback secondary error: %@", String(describing: error)) }
            throw primary
        }
    }
}
