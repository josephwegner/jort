import Foundation
import JortDocument

@MainActor final class DocumentSearchModel {
  private var task: Task<Void, Never>?
  private var request = UUID()
  private(set) var results: [SearchMatch] = []
  private(set) var hasMore = false
  private(set) var message = "Enter text to search this document"
  var onChange: (() -> Void)?

  func search(snapshot: DocumentSnapshot, query: String, options: SearchOptions, limit: Int = 1_000)
  {
    cancel()
    let token = UUID()
    request = token
    results = []
    hasMore = false
    message = query.isEmpty ? "Enter text to search this document" : "Searching…"
    onChange?()
    guard !query.isEmpty else { return }
    task = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(100))
        let worker = Task.detached(priority: .userInitiated) {
          try DocumentSearch.scan(snapshot, query: query, options: options, limit: limit)
        }
        let page = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: {
          worker.cancel()
        }
        try Task.checkCancellation()
        guard let self, self.request == token else { return }
        results = page.matches
        hasMore = page.hasMore
        message =
          results.isEmpty
          ? "No matches"
          : "\(results.count)\(hasMore ? "+" : "") \(results.count == 1 && !hasMore ? "match" : "matches")"
        onChange?()
      } catch is CancellationError {} catch {
        guard let self, self.request == token else { return }
        message = "Search could not complete"
        onChange?()
      }
    }
  }
  func cancel() {
    task?.cancel()
    task = nil
    request = UUID()
  }
}
