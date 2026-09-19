import Foundation
import JortDocument

public struct SaveFailure: Equatable, Sendable {
  public let error: StoreError
  public let retriesRemaining: Int
}
public enum PersistenceState: Equatable, Sendable {
  case loading, loadBlockedFuture, ownershipConflict
  case clean(committed: Int64), dirty(revision: Int64)
  case writing(revision: Int64, failure: SaveFailure?)
  case retryScheduled(revision: Int64, attempt: Int, failure: SaveFailure)
  case saveFailed(revision: Int64, failure: SaveFailure)
  case loadFailed(StoreError)
  public var failure: SaveFailure? {
    switch self {
    case .writing(_, let failure): return failure
    case .retryScheduled(_, _, let failure), .saveFailed(_, let failure): return failure
    default: return nil
    }
  }
  public var requiresAttention: Bool {
    switch self {
    case .loadBlockedFuture, .ownershipConflict, .loadFailed: return true
    default: return failure != nil
    }
  }
  public var permitsRetry: Bool {
    switch self {
    case .clean, .dirty, .writing, .retryScheduled, .saveFailed: return true
    default: return false
    }
  }
}
@MainActor public final class PersistenceController {
  private let store: any DocumentStore
  private let retryDelays: [TimeInterval]
  private let autosaveDelay: TimeInterval
  private var scheduled: Task<Void, Never>?
  private var pending: DocumentSnapshot?
  private var writing = false
  private var failures = 0
  private var ready = false
  private var purgeBarrier = false
  private var historyGeneration = 0
  public private(set) var purgePhase: PurgePhase?
  public private(set) var purgeResult: PurgeResult?
  public private(set) var maintenanceWarning: MaintenanceWarning?
  public var onMaintenance: (@MainActor () -> Void)?
  public var canPurge: Bool { ready && !purgeBarrier && store is SQLiteStore }
  public var canSave: Bool { ready && !purgeBarrier }
  public var pendingRevision: Int64? { pending?.revision }
  public var requiresHistoryRetry: Bool {
    if case .failed = history?.state { return true }
    return false
  }
  public var canRetryCleanup: Bool { purgePhase == .incomplete && purgeBarrier }
  private var purgeBoundary: DocumentSnapshot?
  private var loadedSnapshot: DocumentSnapshot?
  public private(set) var history: HistoryCoordinator?
  public private(set) var historyRecoveryIncomplete = false
  public private(set) var recoveryDisposition: RecoveryDisposition = .none
  public var onHistoryState: (@MainActor () -> Void)?
  public func openHistory() async throws -> any HistoryStore {
    guard ready, !purgeBarrier, let store = store as? any HistoryStore, let initial = loadedSnapshot
    else {
      throw StoreError.io("History is unavailable")
    }
    let generation = historyGeneration
    if try await store.revisions(before: nil, limit: 1).isEmpty {
      guard !purgeBarrier, generation == historyGeneration else {
        throw StoreError.io("History maintenance in progress")
      }
      _ = try await store.retain(
        initial, reason: "Initial state", timestamp: Date(), milestone: false)
    }
    return store
  }
  public func preserveBeforeRestore(_ snapshot: DocumentSnapshot) async throws {
    guard ready, !purgeBarrier, let store = store as? any HistoryStore, let initial = loadedSnapshot
    else {
      throw StoreError.io("History is unavailable")
    }
    if history == nil {
      history = HistoryCoordinator(store: store, initial: initial)
      history?.onState = { [weak self] _ in self?.onHistoryState?() }
    }
    history?.changed(snapshot)
    guard await history?.flush(reason: .beforeRestore) == true else {
      throw StoreError.io("Could not preserve the current state")
    }
  }
  public var historyMessage: String? {
    if case .failed = history?.state {
      return
        "History could not be retained. Your current document is saved separately. Retry with ⌘S."
    }
    if case .budgetExceeded = history?.state {
      return "History exceeds its budget because recent revisions or milestones are protected."
    }
    return historyRecoveryIncomplete
      ? "Some history could not be recovered. Original files have been preserved." : nil
  }
  private var waiters: [@MainActor (Bool) -> Void] = []
  public private(set) var committedRevision: Int64?
  public private(set) var status: PersistenceState = .loading {
    didSet { onState?(status) }
  }
  public var onState: (@MainActor (PersistenceState) -> Void)?
  public var onCommit: (@MainActor (Int64) -> Void)?
  public init(directory: URL) {
    store = SQLiteStore(directory: directory)
    retryDelays = [1, 2, 3]
    autosaveDelay = 0.5
  }
  public init(
    store: any DocumentStore, retryDelays: [TimeInterval] = [1, 2, 3],
    autosaveDelay: TimeInterval = 0.5
  ) {
    self.autosaveDelay = autosaveDelay
    self.store = store
    self.retryDelays = retryDelays
  }
  public func load(completion: @escaping @MainActor (Result<DocumentSnapshot, StoreError>) -> Void)
  {
    guard !ready else { return }
    status = .loading
    Task {
      do {
        let snapshot: DocumentSnapshot
        do { snapshot = try await store.load() } catch let error as StoreError
          where error.recoverableCorruption
        { snapshot = try await store.recover() }
        ready = true
        pending = snapshot
        committedRevision = snapshot.revision
        loadedSnapshot = snapshot
        if let sqlite = store as? SQLiteStore {
          historyRecoveryIncomplete = await sqlite.historyRecoveryWasIncomplete()
          recoveryDisposition = await sqlite.recoveryDisposition
          maintenanceWarning = await sqlite.maintenanceWarning
          if await sqlite.purgeWasAbandoned {
            purgePhase = .incomplete
            purgeResult = .failed(.io("Purge was not performed; original data remains"))
          }
          if await sqlite.purgePending {
            purgeBarrier = true
            purgeBoundary = snapshot
            purgePhase = .incomplete
          }
          onHistoryState?()
        }
        status = .clean(committed: snapshot.revision)
        completion(.success(snapshot))
      } catch {
        if let sqlite = store as? SQLiteStore {
          recoveryDisposition = await sqlite.recoveryDisposition
        }
        let failure = Self.normalize(error)
        switch failure {
        case .unsupportedVersion: status = .loadBlockedFuture
        case .ownership: status = .ownershipConflict
        default: status = .loadFailed(failure)
        }
        completion(.failure(failure))
      }
    }
  }
  public func changed(_ snapshot: DocumentSnapshot, historyReason: HistoryBoundary? = nil) {
    guard ready else { return }
    pending = snapshot
    if purgeBarrier { return }
    if history == nil, let store = store as? any HistoryStore, let initial = loadedSnapshot {
      history = HistoryCoordinator(store: store, initial: initial)
      history?.onState = { [weak self] _ in self?.onHistoryState?() }
    }
    history?.changed(snapshot, reason: historyReason)
    if failures > retryDelays.count {
      if let failure = status.failure {
        status = .saveFailed(revision: snapshot.revision, failure: failure)
      }
      return
    }
    if status.failure == nil { status = .dirty(revision: snapshot.revision) }
    if scheduled == nil && !writing { schedule(after: autosaveDelay) }
  }
  private func schedule(after delay: TimeInterval) {
    scheduled?.cancel()
    scheduled = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self else { return }
      self.scheduled = nil
      self.flush()
    }
  }
  public var canCleanRejectedRecovery: Bool {
    guard !ready, case .loadFailed = status, case .rejected(let rejected) = recoveryDisposition
    else { return false }
    return rejected.contains { $0.reason != .missing && $0.reason != .unsupportedVersion }
  }
  public func cleanupRejectedRecovery() async -> [RemainingCopy] {
    guard canCleanRejectedRecovery, let sqlite = store as? SQLiteStore else { return [] }
    return await sqlite.cleanupRejectedRecovery()
  }

  public func clearHistoryAndRecoveryData() async -> PurgeResult {
    guard canPurge, let sqlite = store as? SQLiteStore, let boundary = pending else {
      return .unavailable
    }
    purgeBarrier = true
    historyGeneration += 1
    purgeBoundary = boundary
    purgePhase = .preparing
    purgeResult = nil
    scheduled?.cancel()
    scheduled = nil
    onMaintenance?()
    await history?.suspendForPurge()
    history = nil
    if writing {
      await withCheckedContinuation { continuation in waiters.append { _ in continuation.resume() }
      }
    }
    let generation = historyGeneration
    let result = await sqlite.purge(boundary) { [weak self] phase in
      Task { @MainActor in
        guard let self, self.purgeBarrier, self.purgeResult == nil,
          self.historyGeneration == generation
        else { return }
        let order: [PurgePhase] = [.preparing, .swapping, .cleaning]
        guard let next = order.firstIndex(of: phase),
          let current = self.purgePhase.flatMap({ order.firstIndex(of: $0) }), next >= current
        else { return }
        self.purgePhase = phase
        self.onMaintenance?()
      }
    }
    return completePurge(result, boundary: boundary, pendingOnDisk: await sqlite.purgePending)
  }
  public func retryCleanup() async -> PurgeResult {
    guard canRetryCleanup, let sqlite = store as? SQLiteStore, let boundary = purgeBoundary else {
      return .unavailable
    }
    purgePhase = .cleaning
    onMaintenance?()
    let result = await sqlite.retryPurgeCleanup()
    return completePurge(result, boundary: boundary, pendingOnDisk: await sqlite.purgePending)
  }
  private func completePurge(_ result: PurgeResult, boundary: DocumentSnapshot, pendingOnDisk: Bool)
    -> PurgeResult
  {
    purgeResult = result
    if result == .completed {
      failures = 0
      committedRevision = boundary.revision
      status = .clean(committed: boundary.revision)
      onCommit?(boundary.revision)
      loadedSnapshot = boundary
      historyRecoveryIncomplete = false
      maintenanceWarning = nil
      purgePhase = .completed
    } else {
      purgePhase = .incomplete
    }
    // Before-swap failures can resume ordinary saving; post-swap failures keep edits queued.
    purgeBarrier = pendingOnDisk
    if !purgeBarrier {
      if let pending, pending != boundary || result != .completed { changed(pending) }
      if pending?.revision == committedRevision { status = .clean(committed: committedRevision!) }
    }
    onMaintenance?()
    onHistoryState?()
    return result
  }

  public func saveImmediately(completion: @escaping @MainActor (ImmediateSaveOutcome) -> Void) {
    guard ready, !purgeBarrier, let snapshot = pending else {
      completion(.unavailable)
      return
    }
    let coalescing = writing
    let retrying = status.failure != nil
    if !writing, committedRevision == snapshot.revision, !retrying {
      if requiresHistoryRetry { Task { _ = await history?.flush(reason: .retry) } }
      completion(.clean(snapshot.revision))
      return
    }
    if retrying { failures = 0 }
    flush { [weak self] success in
      guard let self, !self.purgeBarrier else {
        completion(.unavailable)
        return
      }
      if success, let revision = self.committedRevision {
        completion(
          retrying ? .retried(revision) : coalescing ? .coalesced(revision) : .saved(revision))
        if retrying { Task { _ = await self.history?.flush(reason: .retry) } }
      } else {
        completion(.failed(self.status.failure?.error ?? .io("Save unavailable")))
      }
    }
  }
  public func retry() {
    failures = 0
    flush { [weak self] saved in
      if saved { Task { _ = await self?.history?.flush(reason: .retry) } }
    }
  }
  public func flushLifecycle(
    reason: HistoryBoundary, completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    flush { [weak self] saved in
      Task {
        guard let self else {
          completion?(false)
          return
        }
        if saved { _ = await self.history?.flush(reason: reason) }
        // Editing can continue while history awaits its storage actor.
        if saved, self.pending?.revision != self.committedRevision {
          self.flushLifecycle(reason: reason, completion: completion)
          return
        }
        completion?(saved)
      }
    }
  }
  public func flush(completion: (@MainActor (Bool) -> Void)? = nil) {
    if let completion { waiters.append(completion) }
    scheduled?.cancel()
    scheduled = nil
    guard ready, !purgeBarrier, let snapshot = pending else {
      finish(false)
      return
    }
    guard !writing else { return }
    guard committedRevision != snapshot.revision else {
      finish(true)
      return
    }
    writing = true
    status = .writing(revision: snapshot.revision, failure: status.failure)
    Task {
      do {
        let revision = try await store.save(snapshot)
        guard revision == snapshot.revision else {
          throw StoreError.io("Committed revision did not match snapshot")
        }
        writing = false
        committedRevision = revision
        failures = 0
        onCommit?(revision)
        if purgeBarrier {
          finish(true)
        } else if pending?.revision != revision {
          flush()
        } else {
          status = .clean(committed: revision)
          finish(true)
        }
      } catch {
        writing = false
        failures += 1
        let remaining = max(0, retryDelays.count - failures + 1)
        let failure = SaveFailure(error: Self.normalize(error), retriesRemaining: remaining)
        let revision = pending?.revision ?? snapshot.revision
        status = .saveFailed(revision: revision, failure: failure)
        if remaining > 0 && !purgeBarrier {
          status = .retryScheduled(revision: revision, attempt: failures, failure: failure)
          schedule(after: retryDelays[failures - 1])
        }
        finish(false)
      }
    }
  }
  private func finish(_ success: Bool) {
    let callbacks = waiters
    waiters.removeAll()
    for callback in callbacks { callback(success) }
  }
  public func saveRecoveryCopy(
    snapshot: DocumentSnapshot, to url: URL,
    completion: @escaping @MainActor (Result<Void, StoreError>) -> Void
  ) {
    Task {
      let result = await Task.detached {
        do {
          try PersistenceFormat.encode(snapshot).write(to: url, options: .atomic)
          return Result<Void, StoreError>.success(())
        } catch { return .failure(Self.normalize(error)) }
      }.value
      completion(result)
    }
  }
  nonisolated private static func normalize(_ error: Error) -> StoreError {
    (error as? StoreError) ?? .io(String(describing: error))
  }
}
