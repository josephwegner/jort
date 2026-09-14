import XCTest
import Foundation
@testable import JortDocument
@testable import JortPersistence

final class LandmarkTests: StoreTestCase {
  func testEmojiValidation() {
    for value in ["🌲", "🦊", "🫥", "🇺🇸", "👍🏽", "❤️", "👩🏽‍💻", "👨‍👩‍👧‍👦", "1️⃣", "🏳️‍🌈"] {
      XCTAssertTrue(Landmark.isValidEmoji(value), value)
    }
    for value in ["", "a", "1", "#", "©", "❤", "🌲🌲", "🇺", "🏽", "🦊\u{FE0E}", "🦊a", "🦊\u{301}"] {
      XCTAssertFalse(Landmark.isValidEmoji(value), value)
    }
  }
  @MainActor func testClearLandmarksIsAtomic() throws {
    let owner = try DocumentCoordinator()
    try owner.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .edit(text: "a\nb", range: nil, replacementLength: nil)))
    let landmarks = [
      Landmark(lineID: owner.snapshot.lines[0].id, emoji: "🌲"),
      Landmark(lineID: owner.snapshot.lines[1].id, emoji: "🦊"),
    ]
    for landmark in landmarks {
      try owner.apply(
        .init(
          baseRevision: owner.snapshot.revision, origin: .metadata, mutation: .landmark(landmark)))
    }
    let result = try owner.apply(
      .init(baseRevision: owner.snapshot.revision, origin: .metadata, mutation: .clearLandmarks))
    XCTAssertEqual(result.before.landmarks, landmarks)
    XCTAssertTrue(result.after.landmarks.isEmpty)
    XCTAssertEqual(result.after.revision, result.before.revision + 1)
  }
  @MainActor func testJoinsDetachMoveAndExactReplay() throws {
    for leadingMarked in [false, true] {
      let owner = try DocumentCoordinator()
      func apply(_ mutation: DocumentMutation) throws {
        try owner.apply(
          .init(baseRevision: owner.snapshot.revision, origin: .metadata, mutation: mutation))
      }
      try apply(.edit(text: "a\nb\nc", range: nil, replacementLength: nil))
      let first = owner.snapshot.lines[0].id
      let trailing = Landmark(lineID: owner.snapshot.lines[1].id, emoji: "🌲")
      try apply(.landmark(trailing))
      if leadingMarked { try apply(.landmark(Landmark(lineID: first, emoji: "🌲"))) }
      let before = owner.snapshot
      try apply(.edit(text: "ab\nc", range: NSRange(location: 1, length: 1), replacementLength: 0))
      let after = owner.snapshot
      let joined = try XCTUnwrap(after.landmarks.first { $0.id == trailing.id })
      XCTAssertEqual(joined.detached, leadingMarked)
      XCTAssertEqual(joined.lineID, leadingMarked ? trailing.lineID : first)
      try apply(.restore(before))
      XCTAssertEqual(owner.snapshot.landmarks, before.landmarks)
      try apply(.restore(after))
      XCTAssertEqual(owner.snapshot.landmarks, after.landmarks)
      let text = owner.snapshot.text
      try apply(.landmark(joined.attaching(to: owner.snapshot.lines[1].id)))
      XCTAssertEqual(owner.snapshot.text, text)
      try apply(.removeLandmark(joined.id))
      XCTAssertFalse(owner.snapshot.landmarks.contains { $0.id == joined.id })
    }
  }
  @MainActor func testValidationAndRandomEditsWithLandmarks() throws {
    let owner = try DocumentCoordinator()
    var seed: UInt64 = 42
    func next(_ n: Int) -> Int {
      seed = seed &* 6364136223846793005 &+ 1
      return Int(seed >> 32) % n
    }
    for _ in 0..<150 {
      let line = owner.snapshot.lines[next(owner.snapshot.lines.count)]
      if !owner.snapshot.landmarks.contains(where: { !$0.detached && $0.lineID == line.id }) {
        try owner.apply(
          .init(
            baseRevision: owner.snapshot.revision, origin: .metadata,
            mutation: .landmark(Landmark(lineID: line.id, emoji: "🌲"))))
      }
      let before = owner.snapshot
      let chars = Array(before.text), start = next(chars.count + 1)
      let end = start + next(chars.count - start + 1)
      let range = NSRange(
        location: String(chars[..<start]).utf16.count,
        length: String(chars[start..<end]).utf16.count)
      let replacement = ["a", "\n", "日本語\n🦊", "", " \n"][next(5)]
      let text = (before.text as NSString).replacingCharacters(in: range, with: replacement)
      let result = try owner.apply(
        .init(
          baseRevision: before.revision, origin: .native,
          mutation: .edit(text: text, range: range, replacementLength: replacement.utf16.count)))
      try result.after.validate()
      try owner.apply(
        .init(baseRevision: owner.snapshot.revision, origin: .undo, mutation: .restore(before)))
      XCTAssertEqual(owner.snapshot.landmarks, before.landmarks)
      try owner.apply(
        .init(
          baseRevision: owner.snapshot.revision, origin: .redo, mutation: .restore(result.after)))
      XCTAssertEqual(owner.snapshot.landmarks, result.after.landmarks)
      XCTAssertEqual(
        try PersistenceFormat.decode(PersistenceFormat.encode(owner.snapshot)).snapshot,
        owner.snapshot)
    }
    let line = owner.snapshot.lines[0].id
    for landmarks in [
      [Landmark(lineID: line, emoji: "text")], [Landmark(lineID: UUID(), emoji: "🌲")],
      [Landmark(lineID: line, emoji: "🌲"), Landmark(lineID: line, emoji: "🦊")],
    ] {
      XCTAssertThrowsError(
        try DocumentSnapshot(
          text: owner.snapshot.text, lines: owner.snapshot.lines, landmarks: landmarks
        ).validate())
    }
  }
  @MainActor func testCheckpointRotationFallbackAndInterruptedPublication() async throws {
    for failure in [
      StoreStage.checkpointWrite, .checkpointFileSync, .checkpointRename, .checkpointDirectorySync,
      .checkpointVerify, .checkpointManifest, .checkpointPublished,
    ] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "WalkCheckpoint-\(UUID())")
      removeAfterStoresClose(root)
      let store = ownStore(SQLiteStore(directory: root))
      let loaded = try await store.load()
      let owner = try DocumentCoordinator(snapshot: loaded)
      try owner.apply(
        .init(
          baseRevision: 0, origin: .metadata,
          mutation: .landmark(Landmark(lineID: loaded.lines[0].id, emoji: "🌲"))))
      let previous = owner.snapshot
      _ = try await store.save(previous)
      try await store.close()
      try owner.apply(
        .init(
          baseRevision: previous.revision, origin: .metadata,
          mutation: .removeLandmark(previous.landmarks[0].id)))
      let newest = owner.snapshot
      let broken = ownStore(
        SQLiteStore(
          directory: root,
          inject: { if $0 == failure { throw StoreError.injected(failure.rawValue) } }))
      _ = try await broken.load()
      do {
        _ = try await broken.save(newest)
        XCTFail("Expected publication failure")
      } catch {}
      try await broken.close()
      let recovered = try RecoveryCheckpoints(
        directory: root.appendingPathComponent("Store"), inject: { _ in }
      ).recover()
      XCTAssertEqual(recovered, failure == .checkpointPublished ? newest : previous)
      let retry = ownStore(SQLiteStore(directory: root))
      _ = try await retry.load()
      _ = try await retry.save(newest)
      try await retry.close()
      let folder = root.appendingPathComponent("Store")
      let manifest = try JSONDecoder().decode(
        RecoveryCheckpoints.Manifest.self,
        from: Data(contentsOf: folder.appendingPathComponent("Recovery-manifest.json")))
      XCTAssertEqual(manifest.entries.count, 2)
      let active = manifest.entries[0].slot
      try Data("damaged".utf8).write(to: folder.appendingPathComponent("Recovery-\(active).json"))
      // A previous publication can contain the same revision after a retry; both are valid backups.
      let fallback = try RecoveryCheckpoints(directory: folder, inject: { _ in }).recover()
      XCTAssertLessThanOrEqual(fallback.revision, newest.revision)
      try fallback.validate()
    }
  }
  func testSavingAfterNewestCheckpointDamagePreservesValidFallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WalkDamagedSlot-\(UUID())")
    removeAfterStoresClose(root)
    let store = ownStore(SQLiteStore(directory: root))
    let first = try await store.load()
    let second = DocumentSnapshot(
      documentID: first.documentID, revision: 1, lines: first.lines,
      landmarks: [Landmark(lineID: first.lines[0].id, emoji: "🌲")])
    _ = try await store.save(second)
    try await store.close()
    let directory = root.appendingPathComponent("Store")
    let manifest = try JSONDecoder().decode(
      RecoveryCheckpoints.Manifest.self,
      from: Data(contentsOf: directory.appendingPathComponent("Recovery-manifest.json")))
    try Data("damaged".utf8).write(
      to: directory.appendingPathComponent("Recovery-\(manifest.entries[0].slot).json"))
    let failed = ownStore(
      SQLiteStore(
        directory: root,
        inject: { if $0 == .checkpointManifest { throw StoreError.injected("manifest") } }))
    _ = try await failed.load()
    let third = DocumentSnapshot(
      documentID: first.documentID, revision: 2, lines: first.lines,
      landmarks: [Landmark(lineID: first.lines[0].id, emoji: "🦊")])
    do {
      _ = try await failed.save(third)
      XCTFail("Expected failure")
    } catch {}
    try await failed.close()
    XCTAssertEqual(try RecoveryCheckpoints(directory: directory, inject: { _ in }).recover(), first)
  }
}
