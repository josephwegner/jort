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
  private var suspended = false
  private var idlePending: DocumentSnapshot?
  private var rejectedRevision: Int64?
  private let maximumQueuedBoundaries: Int
  public private(set) var queuedBoundaryCount = 0
  public private(set) var state: HistoryState = .healthy { didSet { onState?(state) } }
  public var onState: (@MainActor (HistoryState) -> Void)?

  public init(
    store: any HistoryStore, initial: DocumentSnapshot, maximumQueuedBoundaries: Int = 32,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
  ) {
    self.store = store
    self.maximumQueuedBoundaries = max(1, maximumQueuedBoundaries)
    self.initial = initial
    latest = initial
    self.now = now
    self.sleep = sleep
  }

  public func changed(_ snapshot: DocumentSnapshot, reason: HistoryBoundary? = nil) {
    let measurement = DocumentInstrumentation.begin(
      "HistoryNotification", revision: snapshot.revision)
    defer { DocumentInstrumentation.end(measurement) }
    guard !suspended, snapshot.documentID == latest.documentID,
      snapshot.revision >= latest.revision
    else { return }
    latest = snapshot
    idle?.cancel()
    if let reason {
      _ = enqueue(snapshot, reason: reason, coalescible: reason == .idle)
      return
    }
    if settingsTask == nil { settingsTask = Task { try await store.historySettings() } }
    let settings = settingsTask!
    idle = Task { [weak self, sleep] in
      do {
        let policy = try await settings.value
        try Task.checkCancellation()
        try await sleep(policy.idleInterval)
        try Task.checkCancellation()
        guard let self else { return }
        _ = self.enqueue(self.latest, reason: .idle, coalescible: true)
      } catch is CancellationError {} catch {
        self?.state = .failed(Self.normalize(error))
        self?.settingsTask = nil
      }
    }
  }

  /// Waits through preceding semantic boundaries, including work already in flight.
  @discardableResult public func flush(reason: HistoryBoundary = .deactivation) async -> Bool {
    guard !suspended else { return false }
    idle?.cancel()
    idle = nil
    return await enqueue(latest, reason: reason).value
  }

  /// Discard queued boundaries and drain any already-entered store operation.
  public func suspendForPurge() async {
    suspended = true
    idle?.cancel()
    idle = nil
    idlePending = nil
    _ = await tail?.value
  }

  private func enqueue(
    _ snapshot: DocumentSnapshot, reason: HistoryBoundary, coalescible: Bool = false
  ) -> Task<Bool, Never> {
    if coalescible, queuedBoundaryCount > 0, let tail {
      idlePending = snapshot
      return tail
    }
    guard queuedBoundaryCount < maximumQueuedBoundaries else {
      // Never silently drop an explicit restore/milestone boundary: its caller
      // receives failure and cannot proceed with restoration until a retry succeeds.
      rejectedRevision = snapshot.revision
      state = .failed(.io("History is busy. Retry after pending boundaries finish."))
      return Task { false }
    }
    if let idlePending, idlePending.revision <= snapshot.revision { self.idlePending = nil }
    queuedBoundaryCount += 1
    let previous = tail, timestamp = now()
    let task = Task { [weak self] in
      _ = await previous?.value
      guard let self else { return false }
      defer { self.finishedBoundary() }
      guard !self.suspended else { return false }
      do {
        if !seeded {
          if try await store.revisions(before: nil, limit: 1).isEmpty {
            _ = try await store.retain(
              initial, reason: "Initial state", timestamp: timestamp, milestone: false)
          }
          seeded = true
        }
        _ = try await store.retain(
          snapshot, reason: reason.rawValue, timestamp: timestamp,
          milestone: reason == .beforeRestore)
        let result = try await store.pruneHistory()
        if rejectedRevision == nil || snapshot.revision >= rejectedRevision! {
          rejectedRevision = nil
          state = result.exceedsBudget ? .budgetExceeded(result.retainedBytes) : .healthy
        }
        return true
      } catch {
        state = .failed(Self.normalize(error))
        return false
      }
    }
    tail = task
    return task
  }
  private func finishedBoundary() {
    queuedBoundaryCount -= 1
    guard queuedBoundaryCount == 0, !suspended, let pending = idlePending else { return }
    idlePending = nil
    _ = enqueue(pending, reason: .idle)
  }

  private static func normalize(_ error: Error) -> StoreError {
    (error as? StoreError) ?? .io(String(describing: error))
  }
}
