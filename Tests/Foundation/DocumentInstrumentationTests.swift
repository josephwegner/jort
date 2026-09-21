import XCTest
import JortDocument

final class DocumentInstrumentationTests: XCTestCase {
  @MainActor func testFlatTransactionExposesGlobalWork() throws {
    let coordinator = try DocumentCoordinator()
    let text = String(repeating: "line\n", count: 1000)
    try coordinator.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .edit(text: text, range: nil, replacementLength: nil)))
    let recorder = DocumentWorkRecorder()
    try DocumentInstrumentation.$recorder.withValue(recorder) {
      try coordinator.apply(
        .init(
          baseRevision: 1, origin: .native,
          mutation: .edit(
            text: "x" + text, range: NSRange(location: 0, length: 0), replacementLength: 1)))
    }
    let counts = recorder.snapshot
    XCTAssertEqual(counts[.completeValidations], 1)
    XCTAssertGreaterThan(counts[.visitedLines, default: 0], 1000)
    XCTAssertGreaterThan(counts[.copiedLineRecords, default: 0], 1000)
    XCTAssertGreaterThan(counts[.allocatedPayloadBytes, default: 0], 0)
    XCTAssertNil(DocumentInstrumentation.recorder)
  }

  func testConcurrentCollectorsRemainIsolated() async {
    let results = await withTaskGroup(of: Int.self) { group in
      for count in [7, 13] {
        group.addTask {
          let recorder = DocumentWorkRecorder()
          await DocumentInstrumentation.$recorder.withValue(recorder) {
            await withTaskGroup(of: Void.self) { children in
              for _ in 0..<count {
                children.addTask { DocumentInstrumentation.count(.visitedIndexNodes) }
              }
            }
          }
          return recorder.snapshot[.visitedIndexNodes, default: 0]
        }
      }
      var values: [Int] = []
      for await result in group { values.append(result) }
      return values.sorted()
    }
    XCTAssertEqual(results, [7, 13])
  }

  func testThrowRestoresCollectionScope() {
    let recorder = DocumentWorkRecorder()
    XCTAssertThrowsError(
      try DocumentInstrumentation.$recorder.withValue(recorder) {
        DocumentInstrumentation.count(.flattenCalls)
        throw DocumentError.invalidState
      })
    DocumentInstrumentation.count(.flattenCalls)
    XCTAssertEqual(recorder.snapshot[.flattenCalls], 1)
    XCTAssertNil(DocumentInstrumentation.recorder)
  }
}
