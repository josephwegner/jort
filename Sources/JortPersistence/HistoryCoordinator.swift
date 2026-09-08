import Foundation
import JortDocument

public enum HistoryState: Equatable, Sendable {
    case healthy, failed(StoreError), budgetExceeded(Int64)
}

public enum HistoryBoundary: String, Sendable {
    case idle = "Typing paused"
    case landmark = "Landmark changed"
    case restore = "Restored revision"
    case bulk = "Bulk change"
    case deactivation = "Window deactivated"
    case windowClosed = "Window closed"
    case shutdown = "Clean shutdown"
    case retry = "Retry"
    case beforeRestore = "Before restore"
}

/// Schedules immutable boundaries; serialization and pruning belong to HistoryStore.
@MainActor public final class HistoryCoordinator {
    private let store: any HistoryStore
    private let initial: DocumentSnapshot
    private var latest: DocumentSnapshot
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var idle: Task<Void, Never>?
    private var tail: Task<Bool, Never>?
    private var settingsTask: Task<HistorySettings, Error>?
    private var seeded = false
    public private(set) var state: HistoryState = .healthy { didSet { onState?(state) } }
    public var onState: (@MainActor (HistoryState) -> Void)?

    public init(store: any HistoryStore, initial: DocumentSnapshot,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.store = store; self.initial = initial; latest = initial
        self.now = now; self.sleep = sleep
    }

    public func changed(_ snapshot: DocumentSnapshot, reason: HistoryBoundary? = nil) {
        latest = snapshot
        idle?.cancel()
        if let reason { _ = enqueue(snapshot, reason: reason); return }
        if settingsTask == nil { settingsTask = Task { try await store.historySettings() } }
        let settings = settingsTask!
        idle = Task { [weak self, sleep] in
            do {
                let policy = try await settings.value
                try Task.checkCancellation()
                try await sleep(policy.idleInterval)
                try Task.checkCancellation()
                guard let self else { return }
                _ = self.enqueue(self.latest, reason: .idle)
            } catch is CancellationError { }
            catch { self?.state = .failed(Self.normalize(error)); self?.settingsTask = nil }
        }
    }

    /// Waits through preceding semantic boundaries, including work already in flight.
    @discardableResult public func flush(reason: HistoryBoundary = .deactivation) async -> Bool {
        idle?.cancel(); idle = nil
        return await enqueue(latest, reason: reason).value
    }

    private func enqueue(_ snapshot: DocumentSnapshot, reason: HistoryBoundary) -> Task<Bool, Never> {
        let previous = tail, timestamp = now()
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return false }
            do {
                if !seeded {
                    if try await store.revisions(before: nil, limit: 1).isEmpty {
                        _ = try await store.retain(initial, reason: "Initial state", timestamp: timestamp, milestone: false)
                    }
                    seeded = true
                }
                _ = try await store.retain(snapshot, reason: reason.rawValue, timestamp: timestamp, milestone: reason == .beforeRestore)
                let result = try await store.pruneHistory()
                state = result.exceedsBudget ? .budgetExceeded(result.retainedBytes) : .healthy
                return true
            } catch { state = .failed(Self.normalize(error)); return false }
        }
        tail = task
        return task
    }

    private static func normalize(_ error: Error) -> StoreError { (error as? StoreError) ?? .io(String(describing: error)) }
}
