import XCTest
import JortDocument
import JortPersistence

final class StartupPersistenceTests: StoreTestCase {
  @MainActor func testLoadingAndFailureRejectPublication() async throws {
    for failure: StoreError? in [nil, .io("unavailable"), .unsupportedVersion, .ownership] {
      let store = StartupLoadStore()
      let persistence = PersistenceController(store: store)
      let loaded = expectation(description: "load resolution")
      persistence.load { _ in loaded.fulfill() }
      let draft = try DocumentCoordinator(snapshot: DocumentSnapshot())
      try draft.apply(
        .init(
          baseRevision: 0, origin: .native,
          mutation: .edit(text: "draft", range: nil, replacementLength: nil)))
      persistence.changed(draft.snapshot)
      XCTAssertEqual(persistence.status, .loading)
      XCTAssertNil(persistence.history)
      let baseline = DocumentSnapshot()
      await store.resolve(failure.map { .failure($0) } ?? .success(baseline))
      await fulfillment(of: [loaded], timeout: 5)
      if failure != nil { persistence.changed(draft.snapshot) }
      let flushed = expectation(description: "flush")
      persistence.flush {
        XCTAssertEqual($0, failure == nil)
        flushed.fulfill()
      }
      await fulfillment(of: [flushed], timeout: 5)
      persistence.retry()
      XCTAssertNil(persistence.history)
      let writes = await store.writes
      XCTAssertTrue(writes.isEmpty)
      XCTAssertEqual(persistence.committedRevision, failure == nil ? baseline.revision : nil)
    }
  }
  @MainActor func testBoundariesAndStoredMetadata() throws {
    let boundaries = ["", "\n", "\r\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"]
    for end in boundaries {
      for start in boundaries {
        let stored = try DocumentCoordinator(snapshot: DocumentSnapshot())
        try stored.apply(
          .init(
            baseRevision: 0, origin: .native,
            mutation: .edit(text: start + "stored\r\ntail", range: nil, replacementLength: nil)))
        let tail = stored.snapshot.lines.last!
        try stored.apply(
          .init(
            baseRevision: stored.snapshot.revision, origin: .metadata,
            mutation: .landmark(Landmark(lineID: tail.id, emoji: "🌲"))))
        let before = stored.snapshot
        let draft = "early" + end
        let prefix = StartupMerge.prefix(draft: draft, stored: before.text)
        XCTAssertEqual(prefix, draft + (end.isEmpty && start.isEmpty ? "\n" : ""))
        let result = try stored.apply(
          .init(
            baseRevision: before.revision, origin: .startupMerge,
            mutation: .edit(
              text: prefix + before.text, range: NSRange(location: 0, length: 0),
              replacementLength: prefix.utf16.count)))
        XCTAssertEqual(result.after.documentID, before.documentID)
        XCTAssertEqual(result.after.revision, before.revision + 1)
        XCTAssertEqual(Array(result.after.text.utf16), Array((prefix + before.text).utf16))
        XCTAssertEqual(result.after.landmarks, before.landmarks)
        XCTAssertEqual(result.after.lines.last?.id, tail.id)
        XCTAssertEqual(result.after.lines.last?.createdAt, tail.createdAt)
        XCTAssertEqual(result.after.lines.last?.lastEditedAt, tail.lastEditedAt)
        if start.isEmpty {
          XCTAssertEqual(
            result.after.lines.suffix(before.lines.count).map(\.id), before.lines.map(\.id))
        }
      }
    }
    XCTAssertEqual(StartupMerge.prefix(draft: "", stored: "stored"), "")
    XCTAssertEqual(StartupMerge.prefix(draft: "early", stored: ""), "early")
  }
  @MainActor func testNewerEditRemainsAuthoritativeWhileStartupSaveIsInFlight() async throws {
    let store = StartupLoadStore()
    let persistence = PersistenceController(store: store)
    let baseline = DocumentSnapshot()
    await store.resolve(.success(baseline))
    let loaded = expectation(description: "loaded")
    persistence.load { _ in loaded.fulfill() }
    await fulfillment(of: [loaded], timeout: 5)
    let owner = try DocumentCoordinator(snapshot: baseline, committed: true)
    owner.onTransaction = { persistence.changed($0.after) }
    persistence.onCommit = { owner.markCommitted($0) }
    let merged = try owner.apply(
      .init(
        baseRevision: baseline.revision, origin: .startupMerge,
        mutation: .edit(text: "early", range: NSRange(location: 0, length: 0), replacementLength: 5)
      )
    ).after
    await store.delaySaves()
    let saved = expectation(description: "latest saved")
    persistence.flush {
      XCTAssertTrue($0)
      saved.fulfill()
    }
    await store.waitForSave()
    try owner.apply(
      .init(
        baseRevision: merged.revision, origin: .native,
        mutation: .edit(
          text: "early and later", range: NSRange(location: 5, length: 0), replacementLength: 10)))
    let latest = owner.snapshot
    XCTAssertEqual(persistence.committedRevision, baseline.revision)
    await store.releaseSave()
    await fulfillment(of: [saved], timeout: 5)
    XCTAssertEqual(owner.snapshot, latest)
    XCTAssertEqual(owner.committedRevision, latest.revision)
    let writes = await store.writes
    XCTAssertEqual(writes, [merged, latest])
  }

  @MainActor func testHistoryUsesLoadedBaselineAndCannotOpenAfterLoadFailure() async throws {
    for fail in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      removeAfterStoresClose(root)
      let disk = ownStore(SQLiteStore(directory: root))
      let initial = try await disk.load()
      let gate = StartupLoadStore()
      let store = StartupHistoryStore(gate: gate, disk: disk)
      let controller = PersistenceController(store: store)
      let loaded = expectation(description: "history load")
      controller.load { _ in loaded.fulfill() }
      controller.changed(DocumentSnapshot())
      XCTAssertNil(controller.history)
      await gate.resolve(fail ? .failure(.io("unavailable")) : .success(initial))
      await fulfillment(of: [loaded], timeout: 5)
      let owner = try DocumentCoordinator(snapshot: initial)
      try owner.apply(
        .init(
          baseRevision: initial.revision, origin: .startupMerge,
          mutation: .edit(
            text: "startup", range: NSRange(location: 0, length: 0), replacementLength: 7)))
      controller.changed(owner.snapshot)
      if fail {
        controller.retry()
        do {
          _ = try await controller.openHistory()
          XCTFail("Opened failed history")
        } catch {}
        do {
          try await controller.preserveBeforeRestore(owner.snapshot)
          XCTFail("Retained failed history")
        } catch {}
        XCTAssertNil(controller.history)
      } else {
        XCTAssertNotNil(controller.history)
        let flushed = expectation(description: "history flushed")
        controller.flushLifecycle(reason: .shutdown) {
          XCTAssertTrue($0)
          flushed.fulfill()
        }
        await fulfillment(of: [flushed], timeout: 5)
      }
      let entries = try await disk.revisions()
      XCTAssertEqual(entries.count, fail ? 0 : 2)
      let saved = try await disk.load()
      XCTAssertEqual(saved, fail ? initial : owner.snapshot)
      if !fail {
        let oldest = try await disk.revision(sequence: entries.last!.sequence)
        XCTAssertEqual(oldest.snapshot, initial)
      }
    }
  }

}

private actor StartupHistoryStore: DocumentStore, HistoryStore {
  let gate: StartupLoadStore
  let disk: SQLiteStore
  init(gate: StartupLoadStore, disk: SQLiteStore) {
    self.gate = gate
    self.disk = disk
  }
  func load() async throws -> DocumentSnapshot { try await gate.load() }
  func recover() async throws -> DocumentSnapshot { try await gate.recover() }
  func save(_ snapshot: DocumentSnapshot) async throws -> Int64 { try await disk.save(snapshot) }
  func revisions(before sequence: Int64?, limit: Int) async throws -> [HistoryEntry] {
    try await disk.revisions(before: sequence, limit: limit)
  }
  func revision(sequence: Int64) async throws -> HistoryRevision {
    try await disk.revision(sequence: sequence)
  }
  func retain(_ snapshot: DocumentSnapshot, reason: String, timestamp: Date, milestone: Bool)
    async throws -> HistoryEntry
  {
    try await disk.retain(snapshot, reason: reason, timestamp: timestamp, milestone: milestone)
  }
  func historySettings() async throws -> HistorySettings { try await disk.historySettings() }
  func setHistorySettings(_ settings: HistorySettings) async throws {
    try await disk.setHistorySettings(settings)
  }
  func pruneHistory() async throws -> HistoryPruneResult { try await disk.pruneHistory() }
}
