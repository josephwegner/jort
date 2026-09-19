import Darwin
import Foundation
import XCTest
import JortDocument
@testable import JortPersistence

final class RecoveryControlsTests: StoreTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RecoveryTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    removeAfterStoresClose(root)
    return root
  }
  private func assertRejected(
    _ reason: RecoveryRejectionReason, reader: BoundedRecoveryReader,
    role: RecoverySourceRole = .manifest, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try reader.read(role), file: file, line: line) {
      XCTAssertEqual(($0 as? RecoveryRejection)?.reason, reason, file: file, line: line)
    }
  }
  func testBoundsAndSpecialFiles() throws {
    let root = try root(), path = root.appendingPathComponent(RecoverySourceRole.manifest.rawValue)
    let reader = BoundedRecoveryReader(directory: root)
    assertRejected(.missing, reader: reader)
    let exact = Data(repeating: 32, count: 64 * 1024)
    try exact.write(to: path)
    XCTAssertEqual(try reader.read(.manifest), exact)
    let fd = Darwin.open(path.path, O_WRONLY)
    XCTAssertGreaterThanOrEqual(fd, 0)
    XCTAssertEqual(ftruncate(fd, 64 * 1024 + 1), 0)
    Darwin.close(fd)
    assertRejected(.oversized, reader: reader)
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createSymbolicLink(
      at: path, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
    assertRejected(.symbolicLink, reader: reader)
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    assertRejected(.nonRegular, reader: reader)
    try FileManager.default.removeItem(at: path)
    XCTAssertEqual(mkfifo(path.path, 0o600), 0)
    assertRejected(.nonRegular, reader: reader)
    try FileManager.default.removeItem(at: path)
    try exact.write(to: path)
    try FileManager.default.linkItem(at: path, to: root.appendingPathComponent("linked"))
    assertRejected(.hardLink, reader: reader)
  }
  func testTruncationAndGrowthOnOpenedDescriptor() throws {
    for growing in [false, true] {
      let root = try root(),
        path = root.appendingPathComponent(RecoverySourceRole.manifest.rawValue)
      try Data(repeating: 32, count: 64 * 1024).write(to: path)
      let reader = BoundedRecoveryReader(directory: root) { stage in
        guard stage == .boundedReadOpened else { return }
        let fd = Darwin.open(path.path, O_WRONLY)
        defer { Darwin.close(fd) }
        guard ftruncate(fd, growing ? 64 * 1024 + 1 : 4) == 0 else {
          throw StoreError.io("fixture")
        }
      }
      assertRejected(.changed, reader: reader)
    }
  }
  func testPayloadSparseLimitBeforeDecode() throws {
    let root = try root(), path = root.appendingPathComponent(RecoverySourceRole.legacy.rawValue)
    let fd = Darwin.open(path.path, O_CREAT | O_WRONLY, 0o600)
    defer { Darwin.close(fd) }
    XCTAssertEqual(ftruncate(fd, off_t(PersistenceFormat.maximumBytes)), 0)
    XCTAssertEqual(
      try BoundedRecoveryReader(directory: root).read(.legacy).count, PersistenceFormat.maximumBytes
    )
    XCTAssertEqual(ftruncate(fd, off_t(PersistenceFormat.maximumBytes + 1)), 0)
    assertRejected(.oversized, reader: BoundedRecoveryReader(directory: root), role: .legacy)
  }
  func testMalformedManifestCannotSupplyPathsAndLegacyFallback() throws {
    let root = try root()
    let snapshot = DocumentSnapshot()
    try PersistenceFormat.encode(snapshot).write(to: root.appendingPathComponent("Recovery.json"))
    for manifest in [
      "{",
      "{\"version\":1,\"entries\":[{\"slot\":-1,\"revision\":0,\"documentID\":\"\(snapshot.documentID)\",\"checksum\":\"../outside\"}]}",
    ] {
      try Data(manifest.utf8).write(to: root.appendingPathComponent("Recovery-manifest.json"))
      let result = RecoveryCheckpoints(directory: root, inject: { _ in }).attempt()
      XCTAssertEqual(result.snapshot, snapshot)
      XCTAssertEqual(result.role, .legacy)
      XCTAssertEqual(result.rejections.first?.reason, .malformed)
    }
  }
  func testTypedSlotFallbackAndFutureRefusal() throws {
    let root = try root(), checkpoints = RecoveryCheckpoints(directory: root, inject: { _ in })
    let before = DocumentSnapshot()
    let after = DocumentSnapshot(
      documentID: before.documentID, text: "later", revision: 1,
      lines: [LineMeta(location: 0, length: 5, createdAt: Date(), lastEditedAt: Date())])
    try checkpoints.publish(PersistenceFormat.encode(before), snapshot: before)
    try checkpoints.publish(PersistenceFormat.encode(after), snapshot: after)
    try Data("bad".utf8).write(to: root.appendingPathComponent("Recovery-1.json"))
    let result = checkpoints.attempt()
    XCTAssertEqual(result.snapshot, before)
    XCTAssertEqual(result.rejections, [RecoveryRejection(role: .slot1, reason: .checksumMismatch)])
    try Data("{\"version\":99,\"entries\":[]}".utf8).write(
      to: root.appendingPathComponent("Recovery-manifest.json"))
    XCTAssertTrue(checkpoints.attempt().unsupported)
  }
  @MainActor func testManualSaveStartsWithAutosaveDelayedAndCoalescesNewest() async throws {
    let store = StartupLoadStore(), initial = DocumentSnapshot()
    await store.resolve(.success(initial))
    let controller = PersistenceController(store: store, autosaveDelay: 3600)
    await withCheckedContinuation { continuation in controller.load { _ in continuation.resume() } }
    let first = DocumentSnapshot(
      documentID: initial.documentID, text: "first", revision: 1,
      lines: [LineMeta(location: 0, length: 5, createdAt: Date(), lastEditedAt: Date())])
    controller.changed(first)
    let prior = await store.writes
    XCTAssertTrue(prior.isEmpty)
    await store.delaySaves()
    let saved = expectation(description: "explicit save")
    controller.saveImmediately { outcome in
      XCTAssertEqual(outcome, .saved(2))
      saved.fulfill()
    }
    await store.waitForSave()
    let newest = DocumentSnapshot(
      documentID: initial.documentID, text: "newest", revision: 2,
      lines: [LineMeta(location: 0, length: 6, createdAt: Date(), lastEditedAt: Date())])
    controller.changed(newest)
    let coalesced = expectation(description: "coalesced")
    controller.saveImmediately { outcome in
      XCTAssertEqual(outcome, .coalesced(2))
      coalesced.fulfill()
    }
    await store.releaseSave()
    await fulfillment(of: [saved, coalesced], timeout: 3)
    let writes = await store.writes
    XCTAssertEqual(writes, [first, newest])
    controller.saveImmediately { XCTAssertEqual($0, .clean(2)) }
  }
  func testLegacyChecksumFutureAndIORejectionsAreTyped() throws {
    let root = try root(), path = root.appendingPathComponent("Recovery.json")
    let snapshot = DocumentSnapshot()
    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: PersistenceFormat.encode(snapshot)) as? [String: Any])
    envelope["checksum"] = "wrong"
    try JSONSerialization.data(withJSONObject: envelope).write(to: path)
    let checkpoints = RecoveryCheckpoints(directory: root, inject: { _ in })
    XCTAssertEqual(checkpoints.attempt().rejections.last?.reason, .checksumMismatch)
    try Data("{\"formatVersion\":999}".utf8).write(to: path)
    XCTAssertTrue(checkpoints.attempt().unsupported)
    try PersistenceFormat.encode(snapshot).write(to: path)
    let failing = RecoveryCheckpoints(directory: root) {
      if $0 == .boundedReadOpened { throw StoreError.injected("read") }
    }
    XCTAssertEqual(failing.attempt().rejections.last?.reason, .io)
  }
  func testRejectedCleanupPreservesDatabaseBackupsAndLinkTarget() async throws {
    let root = try root(), store = ownStore(SQLiteStore(directory: root))
    _ = try await store.load()
    try await store.close()
    let active = root.appendingPathComponent("Store")
    let database = active.appendingPathComponent("Jort.sqlite")
    let damaged = Data("damaged SQLite sentinel".utf8)
    try damaged.write(to: database)
    let external = root.appendingPathComponent("export.json")
    try Data("external sentinel".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(
      at: active.appendingPathComponent("Recovery.json"), withDestinationURL: external)
    try Data("malformed".utf8).write(to: active.appendingPathComponent("Recovery-manifest.json"))
    let unused = active.appendingPathComponent("Recovery-0.json")
    let unusedBefore = try Data(contentsOf: unused)
    let recovering = ownStore(SQLiteStore(directory: root))
    do {
      _ = try await recovering.load()
      XCTFail("Corrupt source")
    } catch {}
    do {
      _ = try await recovering.recover()
      XCTFail("No valid candidate")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: database), damaged)
    let disposition = await recovering.recoveryDisposition
    guard case .rejected(let rejected) = disposition else { return XCTFail("Typed rejection") }
    XCTAssertTrue(rejected.contains { $0.role == .legacy && $0.reason == .symbolicLink })
    let remaining = await recovering.cleanupRejectedRecovery()
    XCTAssertTrue(remaining.isEmpty)
    XCTAssertEqual(try Data(contentsOf: database), damaged)
    XCTAssertEqual(try Data(contentsOf: unused), unusedBefore)
    XCTAssertEqual(try Data(contentsOf: external), Data("external sentinel".utf8))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: active.appendingPathComponent("Recovery-manifest.json").path))
  }
  @MainActor func testManualSaveUnavailableWhileLoadUnresolved() async {
    let store = StartupLoadStore()
    let controller = PersistenceController(store: store, autosaveDelay: 3600)
    controller.saveImmediately { XCTAssertEqual($0, .unavailable) }
    let writes = await store.writes
    XCTAssertTrue(writes.isEmpty)
  }

  func testRecoveryOnlyRootAndDanglingCandidatesNeverCreateEmptyStore() async throws {
    for name in ["Recovery-manifest.json", "Recovery-0.json", "Recovery.json"] {
      let root = try root()
      let candidate = root.appendingPathComponent(name)
      try FileManager.default.createSymbolicLink(
        at: candidate, withDestinationURL: root.appendingPathComponent("missing-target"))
      let store = ownStore(SQLiteStore(directory: root))
      do {
        _ = try await store.load()
        XCTFail("Must not silently initialize")
      } catch {}
      do {
        _ = try await store.recover()
        XCTFail("No valid candidate")
      } catch {}
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Store").path))
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(atPath: candidate.path),
        root.appendingPathComponent("missing-target").path)
    }
  }

}
