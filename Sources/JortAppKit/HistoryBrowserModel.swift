import Foundation
import JortDocument
import JortPersistence

@MainActor final class HistoryBrowserModel {
  let store: any HistoryStore
  private(set) var entries: [HistoryEntry] = []
  private(set) var selected: HistoryRevision?
  private(set) var selectedSequence: Int64?
  private(set) var baseline: HistoryRevision?
  private(set) var comparison: HistoryComparison?
  private(set) var unavailable = Set<Int64>()
  private(set) var message = "Loading history…"
  private(set) var loading = false
  private(set) var hasMore = true
  var onChange: (() -> Void)?
  private var listTask: Task<Void, Never>?
  private var selectionTask: Task<Void, Never>?
  private var active = true
  enum Summary {
    case changes(added: Int, removed: Int), initial, unavailable
  }
  private(set) var summaries: [Int64: Summary] = [:]
  private var summaryTask: Task<Void, Never>?
  private var visibleSequences: [Int64] = []

  /// Only compare visible rows. Cache counts, never decoded documents or full diffs.
  func requestSummaries(_ sequences: [Int64]) {
    guard active, sequences != visibleSequences else { return }
    visibleSequences = sequences
    summaryTask?.cancel()
    summaryTask = Task { [weak self, store] in
      for sequence in sequences {
        guard let self, active, !Task.isCancelled else { return }
        if summaries[sequence] != nil { continue }
        do {
          let current = try await store.revision(sequence: sequence)
          try Task.checkCancellation()
          if let earlier = try await store.revisions(before: sequence, limit: 1).first {
            let old = try await store.revision(sequence: earlier.sequence)
            try Task.checkCancellation()
            let worker = Task.detached(priority: .utility) {
              try HistoryComparison.compare(old.snapshot, current.snapshot)
            }
            let diff = try await withTaskCancellationHandler {
              try await worker.value
            } onCancel: {
              worker.cancel()
            }
            try Task.checkCancellation()
            summaries[sequence] = .changes(added: diff.added, removed: diff.removed)
          } else {
            summaries[sequence] = .initial
          }
        } catch {
          guard !Task.isCancelled else { return }
          summaries[sequence] = .unavailable
        }
        onChange?()
      }
    }
  }

  init(store: any HistoryStore) { self.store = store }

  func loadMore() {
    guard active, listTask == nil, hasMore else { return }
    let before = entries.last?.sequence
    listTask = Task { [weak self, store] in
      do {
        let page = try await store.revisions(before: before, limit: 100)
        try Task.checkCancellation()
        guard let self, active else { return }
        entries.append(contentsOf: page)
        hasMore = page.count == 100
        listTask = nil
        if entries.isEmpty { message = "No retained revisions yet." }
        if selectedSequence == nil, let first = entries.first { select(first.sequence) }
        onChange?()
      } catch {
        guard let self, active, !Task.isCancelled else { return }
        message = "History could not be loaded. Close and try again."
        listTask = nil
        onChange?()
      }
    }
  }

  func select(_ sequence: Int64) {
    guard active else { return }
    selectionTask?.cancel()
    selectedSequence = sequence
    selected = nil
    baseline = nil
    comparison = nil
    loading = true
    message = "Verifying revision…"
    onChange?()
    selectionTask = Task { [weak self, store] in
      do {
        let revision = try await store.revision(sequence: sequence)
        try Task.checkCancellation()
        guard let self, active else { return }
        selected = revision
        loading = false
        message = "Looking for a comparison…"
        onChange?()
        let earlier = try await store.revisions(before: sequence, limit: 1).first
        try Task.checkCancellation()
        if let earlier, let old = try? await store.revision(sequence: earlier.sequence) {
          try Task.checkCancellation()
          let work = Task.detached(priority: .userInitiated) {
            try HistoryComparison.compare(old.snapshot, revision.snapshot)
          }
          let diff = try await withTaskCancellationHandler {
            try await work.value
          } onCancel: {
            work.cancel()
          }
          try Task.checkCancellation()
          baseline = old
          comparison = diff
          summaries[sequence] = .changes(added: diff.added, removed: diff.removed)
          message = "Compared with \(Self.date(old.metadata.timestamp))"
        } else {
          message = "No earlier verified snapshot is available for comparison."
        }
        onChange?()
      } catch {
        guard let self, active, !Task.isCancelled else { return }
        loading = false
        if selected == nil {
          unavailable.insert(sequence)
          message = "This revision is unavailable. It cannot be previewed or restored."
        } else {
          message = "Comparison unavailable. The complete snapshot can still be restored."
        }
        onChange?()
      }
    }
  }

  func cancel() {
    active = false
    listTask?.cancel()
    selectionTask?.cancel()
    summaryTask?.cancel()
    onChange = nil
  }

  static func date(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}
