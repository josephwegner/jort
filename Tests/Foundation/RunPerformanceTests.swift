import XCTest
import Foundation
import JortDocument
import JortPersistence

final class RunPerformanceTests: StoreTestCase {
  @MainActor func testCrawlLargeDocumentDistributions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RunPerformance-\(UUID())")
    removeAfterStoresClose(root)
    let store = ownStore(SQLiteStore(directory: root))
    let initial = try await store.load()
    let owner = try DocumentCoordinator(snapshot: initial)
    try owner.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .edit(text: CrawlLargeDocument.text, range: nil, replacementLength: nil)))
    let baseline = owner.snapshot
    _ = try await store.retain(baseline, reason: "Baseline", timestamp: Date(), milestone: false)
    var search: [Double] = [], creation: [Double] = [], browse: [Double] = [],
      decode: [Double] = [], comparison: [Double] = [], restore: [Double] = [], prune: [Double] = []
    func clock() -> Double { ProcessInfo.processInfo.systemUptime }
    for iteration in 0..<12 {
      let snapshot = owner.snapshot
      let scanTime = try await Task.detached {
        let start = ProcessInfo.processInfo.systemUptime
        let page = try DocumentSearch.scan(
          snapshot, query: iteration.isMultiple(of: 2) ? "thought" : "absent text")
        if iteration.isMultiple(of: 2) { XCTAssertEqual(page.matches.count, 1_000) }
        return ProcessInfo.processInfo.systemUptime - start
      }.value
      search.append(scanTime)
      try owner.apply(
        .init(
          baseRevision: owner.snapshot.revision, origin: .native,
          mutation: .edit(
            text: baseline.text + "\nRevision \(iteration)", range: nil, replacementLength: nil)))
      let changed = owner.snapshot
      var start = clock()
      let entry = try await store.retain(
        changed, reason: "Benchmark", timestamp: Date(), milestone: false)
      creation.append(clock() - start)
      start = clock()
      _ = try await store.revisions(before: nil, limit: 100)
      browse.append(clock() - start)
      start = clock()
      let selected = try await store.revision(sequence: entry.sequence)
      decode.append(clock() - start)
      let compareTime = try await Task.detached {
        let start = ProcessInfo.processInfo.systemUptime
        _ = try HistoryComparison.compare(baseline, selected.snapshot)
        return ProcessInfo.processInfo.systemUptime - start
      }.value
      comparison.append(compareTime)
      start = clock()
      try owner.apply(
        .init(baseRevision: owner.snapshot.revision, origin: .restore, mutation: .restore(baseline))
      )
      _ = try await store.save(owner.snapshot)
      restore.append(clock() - start)
      try await store.setHistorySettings(HistorySettings(byteBudget: 1, minimumRecentCount: 2))
      start = clock()
      _ = try await store.pruneHistory()
      prune.append(clock() - start)
    }
    func p95(_ samples: [Double]) -> Double {
      samples.sorted()[Int(ceil(Double(samples.count) * 0.95)) - 1] * 1_000
    }
    print(
      "PERF Run CrawlLargeDocument ms p95: search=\(p95(search)) (+100ms debounce), retain=\(p95(creation)), list=\(p95(browse)), decode=\(p95(decode)), compare=\(p95(comparison)), restore+save=\(p95(restore)), prune=\(p95(prune))"
    )
    if ProcessInfo.processInfo.environment["JORT_PERFORMANCE_ENFORCE"] == "1" {
      XCTAssertLessThan(p95(search) + 100, 200)
    }
    try await store.close()
  }
}
