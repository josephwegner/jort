import Foundation
import XCTest
import JortDocument
@testable import JortPersistence

/// Each injection is armed only after fixture setup, independently of ordinary saves.
final class MaintenanceFault: @unchecked Sendable {
  private let lock = NSLock()
  private var stage: StoreStage?
  private var hits = 0
  private var failAt = 1
  func arm(_ stage: StoreStage?, at hit: Int = 1) {
    lock.withLock {
      self.stage = stage
      hits = 0
      failAt = hit
    }
  }
  func call(_ stage: StoreStage) throws {
    try lock.withLock {
      if self.stage == stage {
        hits += 1
        if hits == failAt { throw StoreError.injected(stage.rawValue) }
      }
    }
  }
}

/// A selected persistence operation can be held without blocking the main actor.
final class MaintenanceGate: @unchecked Sendable {
  private let lock = NSLock()
  private var stage: StoreStage?
  private let entered = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)
  func arm(_ stage: StoreStage) { lock.withLock { self.stage = stage } }
  func visit(_ stage: StoreStage) throws {
    let shouldBlock = lock.withLock {
      guard self.stage == stage else { return false }
      self.stage = nil
      return true
    }
    guard shouldBlock else { return }
    entered.signal()
    guard release.wait(timeout: .now() + 15) == .success else {
      throw StoreError.injected("gate timeout")
    }
  }
  func waitForEntry() async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: self.entered.wait(timeout: .now() + 5) == .success)
      }
    }
  }
  func resume() { release.signal() }
}

@MainActor final class PrivateDataControlsTests: StoreTestCase {
  let secret = "PRE_BOUNDARY_PRIVATE_SENTINEL_5a84f2"
  func root() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrivateData-\(UUID())")
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    removeAfterStoresClose(value)
    return value
  }
  func snapshot(_ text: String, id: UUID, revision: Int64) -> DocumentSnapshot {
    let time = Date(timeIntervalSince1970: 100)
    return DocumentSnapshot(
      documentID: id, text: text, revision: revision,
      lines: [LineMeta(location: 0, length: text.utf16.count, createdAt: time, lastEditedAt: time)])
  }
  func fixture(root: URL, fault: MaintenanceFault = MaintenanceFault()) async throws -> (
    SQLiteStore, DocumentSnapshot
  ) {
    let store = ownStore(SQLiteStore(directory: root, inject: fault.call))
    let initial = try await store.load()
    let large = snapshot(
      String(repeating: secret, count: 4096), id: initial.documentID, revision: 1)
    _ = try await store.save(large)
    let old = snapshot(secret, id: initial.documentID, revision: 2)
    _ = try await store.save(old)
    _ = try await store.retain(old, reason: "Milestone", timestamp: Date(), milestone: true)
    let current = snapshot("Keep this exact current document", id: initial.documentID, revision: 3)
    _ = try await store.save(current)
    try PersistenceFormat.encode(old).write(to: root.appendingPathComponent("Store/Recovery.json"))
    // Every historical directory class has a distinguishable raw copy.
    for prefix in ManagedNames.prefixes {
      let child = root.appendingPathComponent("\(prefix)\(UUID())")
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
      try Data((secret + prefix).utf8).write(to: child.appendingPathComponent("Recovery.json"))
    }
    try Data((secret + "checkpoint").utf8).write(
      to: root.appendingPathComponent("Store/.Checkpoint-\(UUID())"))
    // Legacy root layout can coexist with Store after migration.
    try Data((secret + "legacyRoot").utf8).write(to: root.appendingPathComponent("Recovery.json"))
    return (store, current)
  }
  func assertNoSecret(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    let inventory = try ManagedCopies(root: root).inventory()
    XCTAssertTrue(inventory.issues.isEmpty, file: file, line: line)
    XCTAssertEqual(inventory.copies.map(\.name), ["Store"], file: file, line: line)
    for child in try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("Store"), includingPropertiesForKeys: nil)
    {
      let data = try Data(contentsOf: child)
      XCTAssertNil(
        data.range(of: Data(secret.utf8)), "Secret remains in \(child.lastPathComponent)",
        file: file, line: line)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Purge.json").path),
      file: file, line: line)
  }
  func testPurgeRemovesAllManagedCopiesAndMilestonesAndReopens() async throws {
    let root = try root(), (store, current) = try await fixture(root: root)
    let result = await store.purge(current)
    XCTAssertEqual(result, .completed)
    let history = try await store.revisions(before: nil, limit: 100)
    XCTAssertTrue(history.isEmpty)
    try await store.close()
    try assertNoSecret(root)
    let reopened = ownStore(SQLiteStore(directory: root))
    let actual = try await reopened.load()
    XCTAssertEqual(actual, current)
  }
  func testFailuresAtPreparationAndPublicationBoundariesPreserveDocument() async throws {
    for stage in [
      StoreStage.replacementCreate, .bind, .checkpointWrite, .checkpointFileSync, .checkpointRename,
      .checkpointDirectorySync, .checkpointVerify, .checkpointManifest, .checkpointPublished,
      .walCheckpoint, .close, .purgeMarker, .purgeMarkerPublished, .purgeSwap, .purgeSwapped,
      .purgeReopen, .purgeVerified, .purgeMarkerRemoved, .cleanupRemove, .maintenanceDirectorySync,
    ] {
      let root = try root(), fault = MaintenanceFault()
      let (store, current) = try await fixture(root: root, fault: fault)
      fault.arm(stage)
      let result = await store.purge(current)
      XCTAssertNotEqual(result, .completed, "\(stage)")
      fault.arm(nil)
      try await store.close()
      let reopened = ownStore(SQLiteStore(directory: root))
      let loaded = try await reopened.load()
      XCTAssertEqual(loaded, current, "\(stage)")
      if await reopened.purgePending {
        let cleanup = await reopened.retryPurgeCleanup()
        XCTAssertEqual(cleanup, .completed, "\(stage)")
      }
      try await reopened.close()
    }
  }
  func testPostSwapCleanupFailureResumesWithoutRollback() async throws {
    let root = try root(), fault = MaintenanceFault()
    let (store, current) = try await fixture(root: root, fault: fault)
    fault.arm(.cleanupRemove)
    let result = await store.purge(current)
    guard case .incomplete(let remaining) = result else {
      return XCTFail("Expected partial cleanup: \(result)")
    }
    XCTAssertFalse(remaining.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("Purge.json").path))
    let marker = try Data(contentsOf: root.appendingPathComponent("Purge.json"))
    XCTAssertNil(marker.range(of: Data(secret.utf8)))
    try await store.close()
    let resumed = ownStore(SQLiteStore(directory: root))
    let loaded = try await resumed.load()
    XCTAssertEqual(loaded, current)
    try await resumed.close()
    try assertNoSecret(root)
  }
  func testInventoryRejectsLinksUnknownAndTraversal() async throws {
    let root = try root(), outside = try self.root()
    let sentinel = outside.appendingPathComponent("Recovery.json")
    try Data(secret.utf8).write(to: sentinel)
    let linked = root.appendingPathComponent("Damaged-\(UUID())")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    let unknown = root.appendingPathComponent("Damaged-not-a-uuid")
    try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
    let inventory = try ManagedCopies(root: root).inventory()
    XCTAssertTrue(inventory.copies.isEmpty)
    XCTAssertEqual(inventory.issues.count, 2)
    XCTAssertThrowsError(try ManagedCopies(root: root).remove("../outside"))
    XCTAssertThrowsError(try ManagedCopies(root: root).remove(linked.lastPathComponent))
    XCTAssertEqual(try Data(contentsOf: sentinel), Data(secret.utf8))
  }
  func testRetentionIndependentClassesAgeAndCount() async throws {
    let root = try root(), store = ownStore(SQLiteStore(directory: root))
    _ = try await store.load()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for prefix in ["PreMigration", "Damaged"] {
      for age in [0, 1, 2, 31] {
        let child = root.appendingPathComponent(
          ManagedNames.backup(prefix, now: now.addingTimeInterval(-Double(age) * 86400)))
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try Data(secret.utf8).write(to: child.appendingPathComponent("Recovery.json"))
      }
    }
    await store.maintainBackups(now: now)
    let copies = try ManagedCopies(root: root).inventory().copies
    XCTAssertEqual(copies.filter { $0.name.hasPrefix("PreMigration-") }.count, 2)
    XCTAssertEqual(copies.filter { $0.name.hasPrefix("Damaged-") }.count, 2)
    XCTAssertTrue(
      copies.filter { $0.name != "Store" }.allSatisfy { now.timeIntervalSince($0.date) <= 86400 })
    await store.maintainBackups(now: now.addingTimeInterval(32 * 86400))
    XCTAssertEqual(try ManagedCopies(root: root).inventory().copies.map(\.name), ["Store"])
  }
  @MainActor func testPurgeBoundaryQueuesLaterEditsAndCreatesFreshHistory() async throws {
    let root = try root(), (store, current) = try await fixture(root: root)
    let controller = PersistenceController(store: store, autosaveDelay: 3600)
    await withCheckedContinuation { continuation in controller.load { _ in continuation.resume() } }
    let later = snapshot("Accepted after boundary", id: current.documentID, revision: 4)
    controller.onMaintenance = {
      if controller.purgePhase == .preparing { controller.changed(later) }
    }
    let result = await controller.clearHistoryAndRecoveryData()
    XCTAssertEqual(result, .completed)
    let beforeSave = try await store.load()
    XCTAssertEqual(beforeSave, current)
    let saveResult: ImmediateSaveOutcome = await withCheckedContinuation { continuation in
      controller.saveImmediately { continuation.resume(returning: $0) }
    }
    XCTAssertEqual(saveResult, .saved(4))
    let afterSave = try await store.load()
    XCTAssertEqual(afterSave, later)
    _ = await controller.history?.flush()
    let entries = try await store.revisions(before: nil, limit: 100)
    for entry in entries {
      let revision = try await store.revision(sequence: entry.sequence)
      XCTAssertNotEqual(revision.snapshot.text, secret)
    }
    controller.onMaintenance = nil
  }
  func testRealProcessCrashesAtPurgeBoundaries() async throws {
    let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("StoreLockProbe")
    for stage in [
      StoreStage.replacementCreate, .checkpointWrite, .checkpointRename, .checkpointPublished,
      .walCheckpoint, .close, .purgeMarker, .purgeMarkerPublished, .purgeSwap, .purgeSwapped,
      .purgeReopen, .purgeVerified, .cleanupRemove, .purgeMarkerRemoved,
    ] {
      let root = try root(), (original, current) = try await fixture(root: root)
      try await original.close()
      let process = Process()
      process.executableURL = executable
      process.arguments = [root.path, "purge:\(stage.rawValue):1"]
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 99, "\(stage)")
      let resumed = ownStore(SQLiteStore(directory: root))
      let loaded = try await resumed.load()
      XCTAssertEqual(loaded, current, "\(stage)")
      let entries = try await resumed.revisions(before: nil, limit: 100)
      if entries.isEmpty {
        try await resumed.close()
        try assertNoSecret(root)
      } else {
        XCTAssertTrue(
          entries.contains { $0.metadata?.milestone == true },
          "Original history remains at \(stage)")
        try await resumed.close()
      }
    }
  }
  func testEveryDirectorySyncAndMarkerPublicationFailureIsRetryable() async throws {
    for stage in [
      StoreStage.maintenanceDirectorySync, .purgeMarker, .purgeMarkerPublished, .cleanupRemove,
      .purgeMarkerRemoved,
    ] {
      for hit in 1...12 {
        let root = try root(), fault = MaintenanceFault()
        let (store, current) = try await fixture(root: root, fault: fault)
        fault.arm(stage, at: hit)
        _ = await store.purge(current)
        fault.arm(nil)
        try await store.close()
        let reopened = ownStore(SQLiteStore(directory: root))
        let actual = try await reopened.load()
        XCTAssertEqual(actual, current, "\(stage) #\(hit)")
        if await reopened.purgePending {
          let cleanup = await reopened.retryPurgeCleanup()
          XCTAssertEqual(cleanup, .completed)
        }
        try await reopened.close()
      }
    }
  }

  func testRetentionRequiresHealthyOwnershipAndWarnsOnCleanupFailure() async throws {
    let root = try root(), fault = MaintenanceFault()
    let (store, current) = try await fixture(root: root, fault: fault)
    let now = Date().addingTimeInterval(31 * 86400)
    let before = try ManagedCopies(root: root).inventory().copies.map(\.name)
    let unopened = ownStore(SQLiteStore(directory: root))
    await unopened.maintainBackups(now: now)
    XCTAssertEqual(try ManagedCopies(root: root).inventory().copies.map(\.name), before)
    fault.arm(.cleanupRemove)
    await store.maintainBackups(now: now)
    let warning = await store.maintenanceWarning
    XCTAssertNotNil(warning)
    let saved = try await store.load()
    XCTAssertEqual(saved, current)
    fault.arm(nil)
    await store.maintainBackups(now: now)
    let after = try ManagedCopies(root: root).inventory().copies
    XCTAssertFalse(
      after.contains { $0.name.hasPrefix("Damaged-") || $0.name.hasPrefix("PreMigration-") })
  }
  func testUnknownBundleEntryPreventsPurgeWithoutChangingSource() async throws {
    let root = try root(), (store, current) = try await fixture(root: root)
    let unknown = root.appendingPathComponent("Store/user-file")
    let bytes = Data(secret.utf8)
    try bytes.write(to: unknown)
    let result = await store.purge(current)
    guard case .incomplete = result else { return XCTFail("Unexpected result: \(result)") }
    XCTAssertEqual(try Data(contentsOf: unknown), bytes)
    let loaded = try await store.load()
    XCTAssertEqual(loaded, current)
    let history = try await store.revisions(before: nil, limit: 100)
    XCTAssertFalse(history.isEmpty)
  }

  func testValidatedReplacementHasNoSentinelBeforeSwap() async throws {
    let root = try root(), (original, current) = try await fixture(root: root)
    try await original.close()
    let sentinel = Data(secret.utf8)
    let store = ownStore(
      SQLiteStore(directory: root) { stage in
        guard stage == .purgeSwap else { return }
        let children = try FileManager.default.contentsOfDirectory(
          at: root, includingPropertiesForKeys: nil)
        let replacement = try XCTUnwrap(
          children.first {
            $0.lastPathComponent.hasPrefix(".Purge-")
              && FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("Recovery-manifest.json").path)
          })
        for file in try FileManager.default.contentsOfDirectory(
          at: replacement, includingPropertiesForKeys: nil)
        {
          XCTAssertNil(
            try Data(contentsOf: file).range(of: sentinel),
            "Replacement contains removed content before swap")
        }
      })
    _ = try await store.load()
    let result = await store.purge(current)
    XCTAssertEqual(result, .completed)
  }

  func testPurgeAfterSaveFailureAndEditsDuringIncompleteCleanup() async throws {
    let root = try root(), fault = MaintenanceFault()
    let (store, current) = try await fixture(root: root, fault: fault)
    let controller = PersistenceController(store: store, retryDelays: [], autosaveDelay: 3600)
    await withCheckedContinuation { continuation in controller.load { _ in continuation.resume() } }
    let boundary = snapshot("Newest unsaved document", id: current.documentID, revision: 4)
    controller.changed(boundary)
    fault.arm(.checkpointWrite)
    let failed: ImmediateSaveOutcome = await withCheckedContinuation { continuation in
      controller.saveImmediately { continuation.resume(returning: $0) }
    }
    guard case .failed = failed else { return XCTFail("Expected save failure") }
    XCTAssertTrue(controller.canPurge)
    fault.arm(.cleanupRemove)
    let result = await controller.clearHistoryAndRecoveryData()
    guard case .incomplete = result else { return XCTFail("Expected incomplete cleanup") }
    let later = snapshot("Typed while cleanup was incomplete", id: current.documentID, revision: 5)
    controller.changed(later)
    controller.saveImmediately { XCTAssertEqual($0, .unavailable) }
    fault.arm(nil)
    let retried = await controller.retryCleanup()
    XCTAssertEqual(retried, .completed)
    let saved: ImmediateSaveOutcome = await withCheckedContinuation { continuation in
      controller.saveImmediately { continuation.resume(returning: $0) }
    }
    XCTAssertEqual(saved, .saved(5))
    let actual = try await store.load()
    XCTAssertEqual(actual, later)
    _ = await controller.history?.flush()
    let history = try await store.revisions(before: nil, limit: 100)
    for entry in history {
      let revision = try await store.revision(sequence: entry.sequence)
      XCTAssertFalse(revision.snapshot.text.contains(secret))
    }
  }

  func testPurgeDrainsInFlightHistoryAndDropsQueuedOldBoundaries() async throws {
    let root = try root(), gate = MaintenanceGate()
    let store = ownStore(SQLiteStore(directory: root, inject: gate.visit))
    let controller = PersistenceController(store: store, autosaveDelay: 3600)
    let initial = try await withCheckedThrowingContinuation { continuation in
      controller.load { continuation.resume(with: $0) }
    }
    let secretSnapshot = snapshot(secret, id: initial.documentID, revision: 1)
    gate.arm(.historyWrite)
    controller.changed(secretSnapshot, historyReason: .bulk)
    let entered = await gate.waitForEntry()
    XCTAssertTrue(entered)
    let boundary = snapshot("Current without secret", id: initial.documentID, revision: 2)
    controller.changed(boundary, historyReason: .bulk)
    let preparing = expectation(description: "purge barrier")
    controller.onMaintenance = {
      if controller.purgePhase == .preparing {
        preparing.fulfill()
        controller.onMaintenance = nil
      }
    }
    let purge = Task { await controller.clearHistoryAndRecoveryData() }
    await fulfillment(of: [preparing], timeout: 5)
    XCTAssertFalse(controller.canSave)
    gate.resume()
    let result = await purge.value
    XCTAssertEqual(result, .completed)
    let history = try await store.revisions(before: nil, limit: 100)
    XCTAssertTrue(history.isEmpty)
    let actual = try await store.load()
    XCTAssertEqual(actual, boundary)
  }

}
