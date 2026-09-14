import XCTest
import Foundation
import SQLite3
import JortDocument
@testable import JortPersistence

final class HistoryStorageTests: StoreTestCase {
  func testIdleDefaultUpgradesLegacyPolicyAndPreservesCustomIntervals() throws {
    let legacy = Data(#"{"byteBudget":1024,"minimumRecentCount":2,"idleInterval":30}"#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(HistorySettings.self, from: legacy).idleInterval, 60)
    let custom = HistorySettings(byteBudget: 1024, minimumRecentCount: 2, idleInterval: 30)
    XCTAssertEqual(
      try JSONDecoder().decode(HistorySettings.self, from: JSONEncoder().encode(custom)), custom)
    XCTAssertEqual(HistorySettings().idleInterval, 60)
  }
  private let date = Date(timeIntervalSinceReferenceDate: 100)

  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HistoryTests-\(UUID())")
    removeAfterStoresClose(url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func snapshot(documentID: UUID = UUID(), text: String = "Hello 🦊", generation: Int64 = 7)
    -> DocumentSnapshot
  {
    let line = LineMeta(location: 0, length: text.utf16.count, createdAt: date, lastEditedAt: date)
    return DocumentSnapshot(
      documentID: documentID, text: text, revision: generation, lines: [line],
      landmarks: [
        Landmark(lineID: line.id, emoji: "🌲"), Landmark(lineID: UUID(), emoji: "🦊", detached: true),
      ])
  }

  private func execute(_ root: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(root.appendingPathComponent("Store/Jort.sqlite").path, &db) == SQLITE_OK
    else {
      throw StoreError.io("test open failed")
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw StoreError.io(String(cString: sqlite3_errmsg(db)))
    }
  }

  func testEnvelopeRoundTripPreservesEveryIdentityAndMetadata() throws {
    let value = snapshot(text: String(repeating: "Hello 👩🏽‍💻 café ", count: 100))
    let (data, metadata) = try HistoryRevisionFormat.encode(
      value, reason: "Landmark changed", timestamp: date)
    let result = try HistoryRevisionFormat.decode(data)
    XCTAssertEqual(result.snapshot, value)
    XCTAssertEqual(result.metadata, metadata)
    XCTAssertNotEqual(metadata.id, value.documentID)
    XCTAssertEqual(metadata.generation, value.revision)
    XCTAssertEqual(result.snapshot.landmarks.filter(\.detached).count, 1)
    XCTAssertLessThan(data.count, try PersistenceFormat.encode(value).count)
  }

  func testStateHashExcludesOnlyGeneration() throws {
    let value = snapshot()
    let newer = DocumentSnapshot(
      documentID: value.documentID, text: value.text, revision: 100,
      lines: value.lines, landmarks: value.landmarks)
    XCTAssertEqual(
      try HistoryRevisionFormat.stateHash(value), try HistoryRevisionFormat.stateHash(newer))
    let changedMetadata = DocumentSnapshot(
      documentID: value.documentID, text: value.text,
      revision: value.revision, lines: value.lines, landmarks: [])
    XCTAssertNotEqual(
      try HistoryRevisionFormat.stateHash(value),
      try HistoryRevisionFormat.stateHash(changedMetadata))
    XCTAssertNotEqual(
      try HistoryRevisionFormat.stateHash(value), try HistoryRevisionFormat.stateHash(snapshot()))
  }

  func testEnvelopeRefusesUnsupportedMalformedAndOversizedData() throws {
    XCTAssertThrowsError(try HistoryRevisionFormat.decode(Data("{\"version\":99}".utf8))) {
      XCTAssertEqual($0 as? StoreError, .unsupportedVersion)
    }
    for bytes in [Data(), Data("{}".utf8), Data("{\"version\":0}".utf8)] {
      XCTAssertThrowsError(try HistoryRevisionFormat.decode(bytes))
    }
    let value = snapshot()
    XCTAssertThrowsError(try HistoryRevisionFormat.encode(value, reason: "", timestamp: date))
    XCTAssertThrowsError(
      try HistoryRevisionFormat.encode(
        value, reason: String(repeating: "x", count: 257), timestamp: date))
    let invalid = DocumentSnapshot(
      documentID: value.documentID, text: value.text, revision: 1,
      lines: [LineMeta(location: 0, length: 1)])
    XCTAssertThrowsError(try HistoryRevisionFormat.encode(invalid, reason: "Test", timestamp: date))
  }

  func testEnvelopeDetectsCorruptionAndBoundsDeclaredDecompression() throws {
    let (data, _) = try HistoryRevisionFormat.encode(snapshot(), reason: "Test", timestamp: date)
    for field in ["payloadHash", "uncompressedBytes", "compression", "payload"] {
      var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      var content = try XCTUnwrap(json["content"] as? [String: Any])
      switch field {
      case "payloadHash": content[field] = String(repeating: "0", count: 64)
      case "uncompressedBytes": content[field] = Int.max
      case "compression": content[field] = "future-codec"
      default: content[field] = Data("corruption".utf8).base64EncodedString()
      }
      json["content"] = content
      // Recompute the outer checksum to exercise inner validation as well.
      let canonical = try JSONSerialization.data(
        withJSONObject: content, options: [.sortedKeys, .withoutEscapingSlashes])
      json["checksum"] = PersistenceFormat.checksum(canonical)
      XCTAssertThrowsError(
        try HistoryRevisionFormat.decode(JSONSerialization.data(withJSONObject: json)), field)
    }
    var corrupted = data
    corrupted[corrupted.count / 2] ^= 1
    XCTAssertThrowsError(try HistoryRevisionFormat.decode(corrupted))
  }

  func testRetentionIsIndependentOfLiveStateAndSurvivesReopen() async throws {
    let root = try root(), store = ownStore(SQLiteStore(directory: root))
    let current = try await store.load()
    let historical = snapshot(documentID: current.documentID)
    let entry = try await store.retain(historical, reason: "Typing paused", timestamp: date)
    let preview = try await store.revision(sequence: entry.sequence)
    XCTAssertEqual(preview.snapshot, historical)
    let live = try await store.load()
    XCTAssertEqual(live, current)
    try await store.close()
    let reopened = ownStore(SQLiteStore(directory: root))
    let loaded = try await reopened.load()
    XCTAssertEqual(loaded, current)
    let retained = try await reopened.revision(sequence: entry.sequence)
    XCTAssertEqual(retained, preview)
    try await reopened.close()
  }

  func testHistoryRequiresLoadedOwnerAndSameDocument() async throws {
    let store = ownStore(SQLiteStore(directory: try root()))
    do {
      _ = try await store.retain(snapshot(), reason: "Test")
      XCTFail("Requires load")
    } catch {}
    _ = try await store.load()
    do {
      _ = try await store.retain(snapshot(), reason: "Test")
      XCTFail("Requires document identity")
    } catch {
      XCTAssertEqual(error as? StoreError, .invalidPayload)
    }
    let entries = try await store.revisions()
    XCTAssertTrue(entries.isEmpty)
    try await store.close()
  }

  func testProtectingDuplicatePromotesOriginalIdentityWithoutAnotherRevision() async throws {
    let store = ownStore(SQLiteStore(directory: try root()))
    let value = try await store.load()
    let first = try await store.retain(value, reason: "Initial", timestamp: date)
    let protected = try await store.retain(
      value, reason: "Before restore", timestamp: date.addingTimeInterval(100), milestone: true)
    XCTAssertEqual(protected.sequence, first.sequence)
    XCTAssertEqual(protected.metadata?.id, first.metadata?.id)
    XCTAssertEqual(protected.metadata?.timestamp, first.metadata?.timestamp)
    XCTAssertEqual(protected.metadata?.milestone, true)
    let rows = try await store.revisions()
    XCTAssertEqual(rows.count, 1)
    let actual = try await store.revision(sequence: first.sequence)
    XCTAssertEqual(actual.snapshot, value)
    XCTAssertTrue(actual.metadata.milestone)
    try await store.close()
  }

  func testDuplicateMustBeVerifiedBeforeSkippingPreservation() async throws {
    let root = try root(), store = ownStore(SQLiteStore(directory: root))
    let value = try await store.load()
    let first = try await store.retain(value, reason: "Initial", timestamp: date)
    let same = try await store.retain(value, reason: "Typing paused", timestamp: date)
    XCTAssertEqual(first, same)
    try execute(root, "UPDATE history_revisions SET payload=X'00'")
    let preserved = try await store.retain(value, reason: "Before restore", timestamp: date)
    XCTAssertGreaterThan(preserved.sequence, first.sequence)
    let restored = try await store.revision(sequence: preserved.sequence)
    XCTAssertEqual(restored.snapshot, value)
    do {
      _ = try await store.revision(sequence: first.sequence)
      XCTFail("Corrupt payload")
    } catch {}
    try await store.close()
  }

  func testConcurrentRequestsSerializeAndDeduplicate() async throws {
    let store = ownStore(SQLiteStore(directory: try root()))
    let value = try await store.load()
    let timestamp = date
    let sequences = try await withThrowingTaskGroup(of: Int64.self) { group in
      for _ in 0..<8 {
        group.addTask {
          try await store.retain(value, reason: "Idle", timestamp: timestamp).sequence
        }
      }
      var results: [Int64] = []
      for try await sequence in group { results.append(sequence) }
      return results
    }
    XCTAssertEqual(Set(sequences).count, 1)
    let entries = try await store.revisions()
    XCTAssertEqual(entries.count, 1)
    try await store.close()
  }

  func testSwappedValidPayloadCannotImpersonateAnotherRow() async throws {
    let root = try root(), store = ownStore(SQLiteStore(directory: root))
    let initial = try await store.load()
    let first = try await store.retain(initial, reason: "Initial", timestamp: date)
    let second = try await store.retain(
      snapshot(documentID: initial.documentID), reason: "Next", timestamp: date)
    try execute(
      root,
      "UPDATE history_revisions SET payload=(SELECT payload FROM history_revisions WHERE sequence=\(second.sequence)) WHERE sequence=\(first.sequence)"
    )
    do {
      _ = try await store.revision(sequence: first.sequence)
      XCTFail("Swapped envelope")
    } catch {
      XCTAssertEqual(error as? StoreError, .invalidPayload)
    }
    let valid = try await store.revision(sequence: second.sequence)
    XCTAssertEqual(valid.metadata, second.metadata)
    try await store.close()
  }

  func testHistoryWriteFailuresRollbackWithoutAffectingAutosaveOrRecovery() async throws {
    for stage in [StoreStage.historyWrite, .historyVerify, .historyCommit] {
      let root = try root(), seed = ownStore(SQLiteStore(directory: root))
      let initial = try await seed.load()
      let retained = try await seed.retain(initial, reason: "Initial", timestamp: date)
      try await seed.close()
      let store = ownStore(
        SQLiteStore(
          directory: root, inject: { if $0 == stage { throw StoreError.injected(stage.rawValue) } })
      )
      _ = try await store.load()
      let latest = snapshot(documentID: initial.documentID)
      _ = try await store.save(latest)
      do {
        _ = try await store.retain(latest, reason: "Test", timestamp: date)
        XCTFail("Expected \(stage)")
      } catch {
        XCTAssertEqual(error as? StoreError, .injected(stage.rawValue))
      }
      let entries = try await store.revisions()
      XCTAssertEqual(entries, [retained])
      let current = try await store.load()
      XCTAssertEqual(current, latest)
      try await store.close()
      let reopened = ownStore(SQLiteStore(directory: root))
      let recovered = try await reopened.recover()
      XCTAssertEqual(recovered, latest)
      try await reopened.close()
    }
  }

  func testDamagedMetadataOnlyDisablesItsRowAndDoesNotBlockStartup() async throws {
    let root = try root(), store = ownStore(SQLiteStore(directory: root))
    let initial = try await store.load()
    let first = try await store.retain(initial, reason: "Initial", timestamp: date)
    let next = snapshot(documentID: initial.documentID)
    let second = try await store.retain(next, reason: "Next", timestamp: date)
    try await store.close()
    try execute(
      root, "UPDATE history_revisions SET metadata=X'00' WHERE sequence=\(first.sequence)")
    let reopened = ownStore(SQLiteStore(directory: root))
    let live = try await reopened.load()
    XCTAssertEqual(live, initial)
    let rows = try await reopened.revisions()
    XCTAssertEqual(rows.map(\.sequence), [second.sequence, first.sequence])
    XCTAssertEqual(rows.first?.metadata, second.metadata)
    XCTAssertNil(rows.last?.metadata)
    _ = try await reopened.save(next)
    try await reopened.close()
  }

  func testHistorySchemaDamageDoesNotPreventCurrentStateUse() async throws {
    let root = try root(), store = ownStore(SQLiteStore(directory: root))
    let initial = try await store.load()
    try await store.close()
    try execute(root, "DROP TABLE history_revisions")
    let reopened = ownStore(SQLiteStore(directory: root))
    let current = try await reopened.load()
    XCTAssertEqual(current, initial)
    do {
      _ = try await reopened.revisions()
      XCTFail("Expected malformed history schema")
    } catch {
      XCTAssertEqual(error as? StoreError, .malformedSchema)
    }
    _ = try await reopened.save(snapshot(documentID: initial.documentID))
    try await reopened.close()
  }

  func testPagingUsesSequenceNotClockAndSettingsAreValidated() async throws {
    let store = ownStore(SQLiteStore(directory: try root()))
    let initial = try await store.load()
    let first = try await store.retain(initial, reason: "Initial", timestamp: date)
    let second = try await store.retain(
      snapshot(documentID: initial.documentID), reason: "Next",
      timestamp: date.addingTimeInterval(-10))
    let page = try await store.revisions(limit: 1)
    XCTAssertEqual(page, [second])
    let older = try await store.revisions(before: second.sequence, limit: 1)
    XCTAssertEqual(older, [first])
    let defaults = try await store.historySettings()
    XCTAssertEqual(defaults, HistorySettings())
    let settings = HistorySettings(byteBudget: 1024, minimumRecentCount: 2, idleInterval: 5)
    try await store.setHistorySettings(settings)
    let actual = try await store.historySettings()
    XCTAssertEqual(actual, settings)
    do {
      try await store.setHistorySettings(HistorySettings(byteBudget: -1))
      XCTFail("Invalid budget")
    } catch {}
    let unchanged = try await store.historySettings()
    XCTAssertEqual(unchanged, settings)
    try await store.close()
  }

  func testVersionThreeMigrationPreservesCompleteCurrentState() async throws {
    let root = try root(), seed = ownStore(SQLiteStore(directory: root))
    let initial = try await seed.load()
    let value = snapshot(documentID: initial.documentID)
    _ = try await seed.save(value)
    try await seed.close()
    try execute(
      root, "DROP TABLE history_revisions; DROP TABLE history_settings; PRAGMA user_version=3")
    let original = try Data(contentsOf: root.appendingPathComponent("Store/Jort.sqlite"))
    let store = ownStore(SQLiteStore(directory: root))
    let migrated = try await store.load()
    XCTAssertEqual(migrated, value)
    let settings = try await store.historySettings()
    XCTAssertEqual(settings, HistorySettings())
    let rows = try await store.revisions()
    XCTAssertTrue(rows.isEmpty, "Snapshot serialization is deferred until history is requested")
    let backups = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix("PreMigration-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(
      try Data(contentsOf: XCTUnwrap(backups.first).appendingPathComponent("Jort.sqlite")), original
    )
    try await store.close()
  }

  func testPruningProtectsRecentMilestonesAndCurrentState() async throws {
    let store = ownStore(SQLiteStore(directory: try root()))
    let current = try await store.load()
    let milestone = try await store.retain(current, reason: "Milestone", milestone: true)
    for index in 0..<6 {
      _ = try await store.retain(
        snapshot(documentID: current.documentID, text: "Version \(index)"), reason: "Idle")
    }
    let recent = try await store.revisions(limit: 2)
    try await store.setHistorySettings(HistorySettings(byteBudget: 1, minimumRecentCount: 2))
    let result = try await store.pruneHistory()
    XCTAssertEqual(result.removedCount, 4)
    XCTAssertTrue(result.exceedsBudget)
    let rows = try await store.revisions()
    XCTAssertEqual(rows.map(\.sequence), recent.map(\.sequence) + [milestone.sequence])
    let live = try await store.load()
    XCTAssertEqual(live, current)
    try await store.close()
  }

  func testPruneFailureRollsBackAllDeletes() async throws {
    let root = try root(), seed = ownStore(SQLiteStore(directory: root))
    let initial = try await seed.load()
    for index in 0..<4 {
      _ = try await seed.retain(
        snapshot(documentID: initial.documentID, text: "Version \(index)"), reason: "Idle")
    }
    try await seed.setHistorySettings(HistorySettings(byteBudget: 1, minimumRecentCount: 1))
    let expected = try await seed.revisions()
    try await seed.close()
    let failing = ownStore(
      SQLiteStore(
        directory: root,
        inject: { if $0 == .historyPrune { throw StoreError.sqlite(13, "disk full") } }))
    _ = try await failing.load()
    do {
      _ = try await failing.pruneHistory()
      XCTFail("Expected failure")
    } catch {}
    let actual = try await failing.revisions()
    XCTAssertEqual(actual, expected)
    _ = try await failing.save(initial)
    try await failing.close()
  }

  func testRecoveryCarriesVerifiedHistoryAndReportsDamagedEntries() async throws {
    let root = try root(), store = ownStore(SQLiteStore(directory: root))
    let initial = try await store.load()
    let first = try await store.retain(initial, reason: "Initial")
    let latest = snapshot(documentID: initial.documentID)
    _ = try await store.save(latest)
    let second = try await store.retain(latest, reason: "Latest", milestone: true)
    let settings = HistorySettings(byteBudget: 4096, minimumRecentCount: 2)
    try await store.setHistorySettings(settings)
    try await store.close()
    try execute(
      root,
      "UPDATE current_state SET payload=X'00'; UPDATE history_revisions SET payload=X'00' WHERE sequence=\(first.sequence)"
    )
    let recovery = ownStore(SQLiteStore(directory: root))
    let recovered = try await recovery.recover()
    XCTAssertEqual(recovered, latest)
    let entries = try await recovery.revisions()
    XCTAssertEqual(entries, [second])
    let actualSettings = try await recovery.historySettings()
    XCTAssertEqual(actualSettings, settings)
    let warning = await recovery.historyRecoveryWasIncomplete()
    XCTAssertTrue(warning)
    try await recovery.close()
    let reopened = ownStore(SQLiteStore(directory: root))
    _ = try await reopened.load()
    let persistedWarning = await reopened.historyRecoveryWasIncomplete()
    XCTAssertTrue(persistedWarning)
    let preview = try await reopened.revision(sequence: second.sequence)
    XCTAssertEqual(preview.snapshot, latest)
    try await reopened.close()
  }

  @MainActor func testCoordinatorCoalescesTypingAndRetainsSemanticBoundariesInOrder() async throws {
    let store = ownStore(SQLiteStore(directory: try root()))
    let initial = try await store.load()
    let owner = try DocumentCoordinator(snapshot: initial)
    let coordinator = HistoryCoordinator(store: store, initial: initial)
    for index in 0..<20 {
      try owner.apply(
        .init(
          baseRevision: owner.snapshot.revision, origin: .native,
          mutation: .edit(text: "Typing \(index)", range: nil, replacementLength: nil)))
      coordinator.changed(owner.snapshot)
    }
    let typed = owner.snapshot
    coordinator.changed(typed, reason: .bulk)
    try owner.apply(
      .init(
        baseRevision: owner.snapshot.revision, origin: .metadata,
        mutation: .landmark(Landmark(lineID: owner.snapshot.lines[0].id, emoji: "🌲"))))
    coordinator.changed(owner.snapshot, reason: .landmark)
    let success = await coordinator.flush(reason: .shutdown)
    XCTAssertTrue(success)
    let entries = try await store.revisions()
    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(
      entries.compactMap { $0.metadata?.reason },
      ["Landmark changed", "Bulk change", "Initial state"])
    let latest = try await store.revision(sequence: entries[0].sequence)
    XCTAssertEqual(latest.snapshot, owner.snapshot)
    XCTAssertEqual(coordinator.state, .healthy)
    try await store.close()
  }

  @MainActor func testIdleBoundaryUsesInjectedClockAndDelay() async throws {
    let store = ownStore(SQLiteStore(directory: try root()))
    let initial = try await store.load()
    let timestamp = date
    let coordinator = HistoryCoordinator(
      store: store, initial: initial, now: { timestamp },
      sleep: { interval in
        XCTAssertEqual(interval, 60)
        try await Task.sleep(for: .milliseconds(10))
      })
    let completed = expectation(description: "Idle retained")
    coordinator.onState = { if $0 == .healthy { completed.fulfill() } }
    coordinator.changed(snapshot(documentID: initial.documentID))
    await fulfillment(of: [completed], timeout: 3)
    let entries = try await store.revisions()
    XCTAssertEqual(entries.first?.metadata?.timestamp, timestamp)
    XCTAssertEqual(entries.first?.metadata?.reason, "Typing paused")
    try await store.close()
  }

  @MainActor func testHistoryFailureDoesNotChangeAutosaveHealth() async throws {
    let root = try root(), seed = ownStore(SQLiteStore(directory: root))
    _ = try await seed.load()
    try await seed.close()
    let store = ownStore(
      SQLiteStore(
        directory: root,
        inject: { if $0 == .historyWrite { throw StoreError.sqlite(13, "disk full") } }))
    let persistence = ownPersistence(store: store)
    let initial = try await withCheckedThrowingContinuation { continuation in
      persistence.load { continuation.resume(with: $0) }
    }
    XCTAssertNil(persistence.history, "Loading must not start retention")
    let latest = snapshot(documentID: initial.documentID)
    persistence.changed(latest, historyReason: .landmark)
    let saved = await withCheckedContinuation { continuation in
      persistence.flushLifecycle(reason: .shutdown) { continuation.resume(returning: $0) }
    }
    XCTAssertTrue(saved)
    XCTAssertEqual(persistence.status, .clean(committed: latest.revision))
    XCTAssertNotNil(persistence.historyMessage)
    let live = try await store.load()
    XCTAssertEqual(live, latest)
    try await store.close()
  }

  func testRepeatedPruningBoundsRetainedBytesAndReusesDatabaseSpace() async throws {
    let root = try root(), store = ownStore(SQLiteStore(directory: root))
    let initial = try await store.load()
    try await store.setHistorySettings(HistorySettings(byteBudget: 1, minimumRecentCount: 2))
    for index in 0..<30 {
      let value = snapshot(
        documentID: initial.documentID, text: String(repeating: "Revision \(index) 🦊 ", count: 100))
      _ = try await store.retain(value, reason: "Idle")
      let result = try await store.pruneHistory()
      XCTAssertLessThan(result.retainedBytes, 16_000)
    }
    let entries = try await store.revisions()
    XCTAssertEqual(entries.count, 2)
    try await store.close()
    let attributes = try FileManager.default.attributesOfItem(
      atPath: root.appendingPathComponent("Store/Jort.sqlite").path)
    XCTAssertLessThan(try XCTUnwrap(attributes[.size] as? NSNumber).intValue, 128 * 1024)
  }

  func testRecoveryDestinationFailurePreservesOriginalHistoryDatabase() async throws {
    let root = try root(), store = ownStore(SQLiteStore(directory: root))
    let initial = try await store.load()
    _ = try await store.retain(initial, reason: "Initial")
    try await store.close()
    let path = root.appendingPathComponent("Store/Jort.sqlite")
    let before = try Data(contentsOf: path)
    let failing = ownStore(
      SQLiteStore(
        directory: root,
        inject: { if $0 == .historyWrite { throw StoreError.sqlite(13, "disk full") } }))
    do {
      _ = try await failing.recover()
      XCTFail("Expected failure")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: path), before)
    try await failing.close()
    let retry = ownStore(SQLiteStore(directory: root))
    _ = try await retry.recover()
    let entries = try await retry.revisions()
    XCTAssertEqual(entries.count, 1)
    let incomplete = await retry.historyRecoveryWasIncomplete()
    XCTAssertFalse(incomplete)
    try await retry.close()
  }

  @MainActor func testLifecycleDrainsEditsArrivingDuringHistoryCompletion() async throws {
    let store = ownStore(SQLiteStore(directory: try root()))
    let persistence = ownPersistence(store: store)
    let initial = try await withCheckedThrowingContinuation { continuation in
      persistence.load { continuation.resume(with: $0) }
    }
    let first = snapshot(documentID: initial.documentID)
    let newest = snapshot(
      documentID: initial.documentID, text: "Arrived during history", generation: 8)
    persistence.changed(first)
    var edited = false
    persistence.onHistoryState = {
      if !edited {
        edited = true
        persistence.changed(newest)
      }
    }
    let success = await withCheckedContinuation { continuation in
      persistence.flushLifecycle(reason: .shutdown) { continuation.resume(returning: $0) }
    }
    XCTAssertTrue(success)
    XCTAssertTrue(edited)
    XCTAssertEqual(persistence.committedRevision, newest.revision)
    let saved = try await store.load()
    XCTAssertEqual(saved, newest)
    let entries = try await store.revisions()
    let retained = try await store.revision(sequence: XCTUnwrap(entries.first).sequence)
    XCTAssertEqual(retained.snapshot, newest)
    persistence.onHistoryState = nil
    try await store.close()
  }
}
