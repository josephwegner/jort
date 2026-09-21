import Foundation
import XCTest
import JortPersistence
@testable import JortDocument

final class IncrementalLineEditingTests: XCTestCase {
  @MainActor func testRetainedStorageChargesSharedSubtreesOnce() throws {
    let coordinator = try DocumentCoordinator()
    try coordinator.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .replace(
          range: NSRange(location: 0, length: 0),
          text: String(repeating: "short line\n", count: 10_000))))
    let before = coordinator.snapshot
    let ledger = DocumentRetainedStorage()
    ledger.retain(before)
    let bytes = ledger.estimatedBytes
    ledger.retain(before)
    XCTAssertEqual(ledger.estimatedBytes, bytes)
    ledger.release(before)
    let after = try coordinator.apply(
      .init(
        baseRevision: 1, origin: .native,
        mutation: .replace(range: NSRange(location: 1, length: 0), text: "x"))
    ).after
    let recorder = DocumentWorkRecorder()
    DocumentInstrumentation.$recorder.withValue(recorder) { ledger.retain(after) }
    XCTAssertLessThan(ledger.estimatedBytes - bytes, 100_000)
    XCTAssertLessThan(recorder.snapshot[.visitedIndexNodes, default: 0], 2000)
    ledger.release(before)
    XCTAssertGreaterThan(ledger.estimatedBytes, 0)
    ledger.release(after)
    XCTAssertEqual(ledger.estimatedBytes, 0)
    XCTAssertEqual(ledger.nodeCount, 0)
  }

  @MainActor func testMetadataSharesRootAndRejectsConflictingLandmarks() throws {
    let coordinator = try DocumentCoordinator()
    let before = coordinator.snapshot
    let landmark = Landmark(lineID: before.lines[0].id, emoji: "🌲")
    let recorder = DocumentWorkRecorder()
    let result = try DocumentInstrumentation.$recorder.withValue(recorder) {
      try coordinator.apply(
        .init(baseRevision: 0, origin: .metadata, mutation: .landmark(landmark)))
    }
    XCTAssertTrue(try before.indexed().root === result.after.indexed().root)
    XCTAssertNil(recorder.snapshot[.flattenCalls])
    XCTAssertNil(recorder.snapshot[.completeValidations])
    XCTAssertEqual(result.after.landmarks, [landmark])
    XCTAssertThrowsError(
      try coordinator.apply(
        .init(
          baseRevision: 1, origin: .metadata,
          mutation: .landmark(Landmark(lineID: landmark.lineID, emoji: "🦊")))))
    XCTAssertEqual(coordinator.snapshot, result.after)
    let restored = try coordinator.apply(
      .init(
        baseRevision: 1, origin: .undo,
        mutation: .restore(before)))
    XCTAssertTrue(try before.indexed().root === restored.after.indexed().root)
    XCTAssertEqual(restored.after.revision, 2)
    XCTAssertTrue(restored.after.landmarks.isEmpty)
  }

  @MainActor func testStorageReleasedAfterCoordinatorAndRetainedRootsFinish() throws {
    let recorder = DocumentWorkRecorder()
    var retained: DocumentSnapshot? = try DocumentInstrumentation.$recorder.withValue(recorder) {
      let coordinator = try DocumentCoordinator()
      try coordinator.apply(
        .init(
          baseRevision: 0, origin: .native,
          mutation: .replace(
            range: NSRange(location: 0, length: 0),
            text: String(repeating: "line\n", count: 1000))))
      let previous = coordinator.snapshot
      try coordinator.apply(
        .init(
          baseRevision: 1, origin: .native,
          mutation: .replace(range: NSRange(location: 2, length: 0), text: "x")))
      return previous
    }
    XCTAssertEqual(retained?.revision, 1)
    XCTAssertGreaterThan(
      recorder.snapshot[.retainedStorageObjects, default: 0],
      recorder.snapshot[.releasedStorageObjects, default: 0])
    retained = nil
    XCTAssertEqual(
      recorder.snapshot[.retainedStorageObjects], recorder.snapshot[.releasedStorageObjects])
    XCTAssertEqual(
      recorder.snapshot[.retainedStorageBytes], recorder.snapshot[.releasedStorageBytes])
  }

  @MainActor func testCoordinatorReplacementPublishesOneSharedRootWithoutGlobalWork() throws {
    var state = DocumentState()
    state.replaceText(String(repeating: "short line\n", count: 25_000))
    let original = DocumentSnapshot(text: state.text, lines: state.lines)
    let coordinator = try DocumentCoordinator(snapshot: original)
    var publications = 0
    coordinator.onTransaction = { _ in publications += 1 }
    let recorder = DocumentWorkRecorder()
    let result = try DocumentInstrumentation.$recorder.withValue(recorder) {
      try coordinator.apply(
        .init(
          baseRevision: 0, origin: .native,
          mutation: .replace(range: NSRange(location: 1, length: 0), text: "new")))
    }
    XCTAssertEqual(publications, 1)
    XCTAssertEqual(result.after.revision, 1)
    XCTAssertEqual(result.before, original)
    XCTAssertEqual(result.after.utf16Count, original.utf16Count + 3)
    XCTAssertNil(recorder.snapshot[.flattenCalls])
    XCTAssertNil(recorder.snapshot[.completeValidations])
    XCTAssertLessThan(recorder.snapshot[.visitedLines, default: 0], 512)
    XCTAssertTrue(
      try result.before.indexed().line(at: 20_000)?.record.textRoot
        === result.after.indexed().line(at: 20_000)?.record.textRoot)
    try result.after.validate()
    let accepted = coordinator.snapshot
    for transaction in [
      DocumentTransaction(
        baseRevision: 0, origin: .native,
        mutation: .replace(range: NSRange(location: 0, length: 0), text: "stale")),
      DocumentTransaction(
        baseRevision: 1, origin: .native,
        mutation: .replace(range: NSRange(location: Int.max, length: 1), text: "invalid")),
    ] {
      XCTAssertThrowsError(try coordinator.apply(transaction))
      XCTAssertEqual(coordinator.snapshot, accepted)
      XCTAssertEqual(publications, 1)
    }
  }

  private func IDs(step: Int) -> () -> UUID {
    var counter: UInt16 = 0
    return {
      counter &+= 1
      return UUID(
        uuid: (
          0, 0, 0, 0, 0, 0, UInt8(step >> 8), UInt8(step & 255),
          0, 0, 0, 0, 0, 0, UInt8(counter >> 8), UInt8(counter & 255)
        ))
    }
  }

  func testSeededUnicodeAndLandmarkEditsMatchReference() throws {
    var reference = DocumentState()
    reference.replaceText(
      "first\r\nsecond\n🦊 e\u{301}\rthird\u{85}fourth\u{2028}last\u{2029}",
      at: Date(timeIntervalSince1970: 1))
    var index = PersistentLineIndex()
    let source = reference.text as NSString
    try index.replace(
      0..<0,
      with: reference.lines.map {
        IndexedLine(
          id: $0.id,
          text: source.substring(with: NSRange(location: $0.location, length: $0.length)),
          createdAt: $0.createdAt, lastEditedAt: $0.lastEditedAt)
      })
    var landmarks: [Landmark] = []
    let replacements = [
      "", "x", "\r", "\n", "\r\n", "\u{85}", "\u{2028}", "\u{2029}", "🦊", "e\u{301}", " \t ",
    ]
    var seed: UInt64 = 0x5eed
    for step in 1...500 {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      if step.isMultiple(of: 17),
        let line = reference.lines.first(where: { candidate in
          !landmarks.contains { !$0.detached && $0.lineID == candidate.id }
        })
      {
        let landmark = Landmark(lineID: line.id, emoji: "🌲")
        reference.landmarks.append(landmark)
        landmarks.append(landmark)
      }
      let count = reference.text.utf16.count
      let start = Int(seed % UInt64(count + 1))
      let length = min(Int(seed >> 24 & 7), count - start)
      let range = NSRange(location: start, length: length)
      let replacement = replacements[Int(seed >> 32) % replacements.count]
      let changed = (reference.text as NSString).replacingCharacters(in: range, with: replacement)
      let time = Date(timeIntervalSince1970: Double(step + 1))
      reference.replaceText(
        changed, editRange: range, replacementLength: replacement.utf16.count,
        at: time, makeLineID: IDs(step: step))
      try reference.validate()
      let result = try index.replaceText(
        in: range, with: replacement,
        landmarks: landmarks, at: time, makeLineID: IDs(step: step))
      landmarks = result.landmarks
      XCTAssertEqual(
        index.materializedText(), reference.text, "step \(step), seed \(seed), range \(range)")
      XCTAssertEqual(
        index.materializedLines(), reference.lines, "step \(step), seed \(seed), range \(range)")
      XCTAssertEqual(landmarks, reference.landmarks, "step \(step), seed \(seed), range \(range)")
    }
  }

  func testEarlyReplacementHasLocalValidationAndSharedText() throws {
    var reference = DocumentState()
    reference.replaceText(
      String(repeating: "a short line\n", count: 25_000),
      at: Date(timeIntervalSince1970: 1))
    var index = PersistentLineIndex()
    try index.replace(
      0..<0,
      with: reference.lines.map {
        IndexedLine(
          id: $0.id, text: $0.length == 0 ? "" : "a short line\n",
          createdAt: $0.createdAt, lastEditedAt: $0.lastEditedAt)
      })
    let before = index
    let recorder = DocumentWorkRecorder()
    _ = try DocumentInstrumentation.$recorder.withValue(recorder) {
      try index.replaceText(
        in: NSRange(location: 1, length: 0), with: "new",
        landmarks: [], at: Date(timeIntervalSince1970: 2))
    }
    XCTAssertNil(recorder.snapshot[.completeValidations])
    XCTAssertNil(recorder.snapshot[.flattenCalls])
    XCTAssertLessThan(recorder.snapshot[.visitedLines, default: 0], 512)
    XCTAssertLessThan(recorder.snapshot[.visitedChunks, default: 0], 8)
    XCTAssertTrue(
      index.line(at: 20_000)?.record.textRoot === before.line(at: 20_000)?.record.textRoot)
    XCTAssertEqual(index.line(at: 20_000)?.location, before.line(at: 20_000)!.location + 3)
  }
}

extension IncrementalLineEditingTests {
  @MainActor func testSeededTransactionsRestoreAndPersistenceWithShrinkingReference() throws {
    for reduced: [UInt64] in [
      [12897629574360492620, 1426699516013569195],
      [6327915629386038101, 13755001091425050255],
      [10583938234553972560, 16114367815180315231],
    ] { XCTAssertNil(checkScenario(reduced), "Surrogate-boundary regression") }
    for initial in [UInt64(7), 71, 991, 0x5eed, 0xcafe] {
      var seed = initial
      let steps = (0..<100).map { _ -> UInt64 in
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed
      }
      if let failure = checkScenario(steps) {
        var minimal = steps, width = max(1, steps.count / 2)
        while width > 0 {
          var offset = 0
          while offset < minimal.count {
            var candidate = minimal
            candidate.removeSubrange(offset..<min(offset + width, candidate.count))
            if !candidate.isEmpty, checkScenario(candidate) != nil {
              minimal = candidate
            } else {
              offset += width
            }
          }
          width /= 2
        }
        XCTFail("seed \(initial): \(failure); minimized sequence: \(minimal)")
      }
    }
  }

  @MainActor private func checkScenario(_ steps: [UInt64]) -> String? {
    do {
      let owner = try DocumentCoordinator()
      var reference = owner.snapshot.liveState
      var history: [(DocumentSnapshot, DocumentState)] = []
      let replacements = [
        "", "x", "\r", "\n", "\r\n", "🦊", "e\u{301}", "\u{85}", "\u{2028}", "\u{2029}",
      ]
      for (step, seed) in steps.enumerated() {
        let before = owner.snapshot, oldReference = reference
        let time = Date(timeIntervalSince1970: Double(step + 1))
        switch seed % 5 {
        case 0, 1:
          let start = Int(seed >> 16) % (reference.text.utf16.count + 1)
          let length = min(Int(seed >> 32 & 3), reference.text.utf16.count - start)
          let range = NSRange(location: start, length: length)
          let replacement = replacements[Int(seed >> 40) % replacements.count]
          let result = try owner.apply(
            .init(
              baseRevision: before.revision, origin: .native,
              mutation: .replace(range: range, text: replacement)), at: time)
          let oldIDs = Set(before.lines.map(\.id))
          var newIDs = result.after.lines.filter { !oldIDs.contains($0.id) }.map(\.id)
            .makeIterator()
          let text = (reference.text as NSString).replacingCharacters(in: range, with: replacement)
          reference.replaceText(
            text, editRange: range, replacementLength: replacement.utf16.count,
            at: time, makeLineID: { newIDs.next() ?? UUID() })
          history.append((before, oldReference))
        case 2:
          if reference.landmarks.isEmpty {
            let ordinal = Int(seed >> 16) % reference.lines.count
            let landmark = Landmark(lineID: reference.lines[ordinal].id, emoji: "🌲")
            try owner.apply(
              .init(
                baseRevision: before.revision, origin: .metadata,
                mutation: .landmark(landmark)))
            reference.landmarks.append(landmark)
          } else {
            try owner.apply(
              .init(baseRevision: before.revision, origin: .metadata, mutation: .clearLandmarks))
            reference.landmarks.removeAll()
          }
          history.append((before, oldReference))
        case 3:
          if let previous = history.popLast() {
            try owner.apply(
              .init(baseRevision: before.revision, origin: .undo, mutation: .restore(previous.0)))
            reference = previous.1
          }
        default:
          let decoded = try PersistenceFormat.decode(PersistenceFormat.encode(before)).snapshot
          guard decoded == before else { return "persistence mismatch at \(step)" }
          try owner.apply(
            .init(baseRevision: before.revision, origin: .restore, mutation: .restore(decoded)))
        }
        reference.revision = owner.snapshot.revision
        try reference.validate()
        let expected = DocumentSnapshot(
          documentID: reference.documentID, text: reference.text,
          revision: reference.revision, lines: reference.lines, landmarks: reference.landmarks)
        guard owner.snapshot == expected else { return "reference mismatch at \(step)" }
      }
      return nil
    } catch { return "unexpected rejection: \(error)" }
  }
}
