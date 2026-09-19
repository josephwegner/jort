import XCTest
import Foundation
import JortDocument
import JortPersistence

private actor ControlledStore: DocumentStore {
  var writes = 0
  var failing = false
  var saved = DocumentSnapshot()
  func setFailing(_ value: Bool) { failing = value }
  func load() -> DocumentSnapshot { saved }
  func recover() throws -> DocumentSnapshot { throw StoreError.invalidPayload }
  func save(_ snapshot: DocumentSnapshot) async throws -> Int64 {
    writes += 1
    try await Task.sleep(for: .milliseconds(20))
    if failing { throw StoreError.io("injected disk full") }
    saved = snapshot
    return snapshot.revision
  }
}
final class SchedulerTests: XCTestCase {
  @MainActor private func load(_ controller: PersistenceController) async throws
    -> DocumentCoordinator
  {
    let snapshot = try await withCheckedThrowingContinuation { continuation in
      controller.load { continuation.resume(with: $0) }
    }
    return try DocumentCoordinator(snapshot: snapshot, committed: true)
  }
  @MainActor func testFailureBudgetAndManualRetryLatestSnapshot() async throws {
    let store = ControlledStore()
    let controller = PersistenceController(store: store, retryDelays: [0.01, 0.01, 0.01])
    let owner = try await load(controller)
    await store.setFailing(true)
    let failures = expectation(description: "Retries exhausted")
    controller.onState = {
      if case .saveFailed(_, let failure) = $0, failure.retriesRemaining == 0 { failures.fulfill() }
    }
    try owner.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .edit(text: "keep me", range: nil, replacementLength: nil)))
    controller.changed(owner.snapshot)
    controller.flush()
    await fulfillment(of: [failures], timeout: 5)
    controller.onState = nil
    let count = await store.writes
    XCTAssertEqual(count, 4)
    try owner.apply(
      .init(
        baseRevision: 1, origin: .native,
        mutation: .edit(text: "keep newest", range: nil, replacementLength: nil)))
    try owner.apply(
      .init(
        baseRevision: 2, origin: .metadata,
        mutation: .landmark(Landmark(lineID: owner.snapshot.lines[0].id, emoji: "🌲"))))
    controller.changed(owner.snapshot)
    try await Task.sleep(for: .milliseconds(650))
    let quietCount = await store.writes
    XCTAssertEqual(quietCount, 4)
    await store.setFailing(false)
    let saved = expectation(description: "Manual retry")
    controller.onState = { if case .clean(committed: 3) = $0 { saved.fulfill() } }
    let result = expectation(description: "typed retry")
    controller.saveImmediately { outcome in
      XCTAssertEqual(outcome, .retried(3))
      result.fulfill()
    }
    await fulfillment(of: [saved, result], timeout: 5)
    let actual = await store.saved
    XCTAssertEqual(actual, owner.snapshot)
  }
  @MainActor func testRapidFlushesAndEditsDuringSaveDrainLatest() async throws {
    let store = ControlledStore()
    let persistence = PersistenceController(store: store)
    let owner = try await load(persistence)
    persistence.onCommit = { owner.markCommitted($0) }
    try owner.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .edit(text: "first", range: nil, replacementLength: nil)))
    persistence.changed(owner.snapshot)
    let finished = expectation(description: "all flush waiters")
    finished.expectedFulfillmentCount = 20
    for _ in 0..<20 {
      persistence.flush {
        XCTAssertTrue($0)
        finished.fulfill()
      }
    }
    try owner.apply(
      .init(
        baseRevision: 1, origin: .native,
        mutation: .edit(text: "second", range: nil, replacementLength: nil)))
    persistence.changed(owner.snapshot)
    await fulfillment(of: [finished], timeout: 5)
    XCTAssertEqual(owner.committedRevision, 2)
    let actual = await store.saved
    XCTAssertEqual(actual.text, "second")
  }
  @MainActor func testContinuousEditingSavesBeforeIdle() async throws {
    let store = ControlledStore(), controller = PersistenceController(store: store)
    let owner = try await load(controller)
    for index in 0..<12 {
      try owner.apply(
        .init(
          baseRevision: owner.snapshot.revision, origin: .native,
          mutation: .edit(
            text: String(repeating: "x", count: index + 1), range: nil, replacementLength: nil)))
      controller.changed(owner.snapshot)
      try await Task.sleep(for: .milliseconds(100))
    }
    let saved = await store.saved
    XCTAssertGreaterThan(saved.revision, 0)
    XCTAssertLessThanOrEqual(owner.snapshot.revision - saved.revision, 7)
  }
}
