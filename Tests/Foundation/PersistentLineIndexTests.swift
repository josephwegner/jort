import Foundation
import XCTest
@testable import JortDocument

final class PersistentLineIndexTests: XCTestCase {
  private func record(_ text: String, id: UUID = UUID()) -> IndexedLine {
    IndexedLine(
      id: id, text: text, createdAt: Date(timeIntervalSince1970: 1),
      lastEditedAt: Date(timeIntervalSince1970: 2))
  }

  func testExactQueriesAndImmutableRoots() throws {
    let records = [
      record("a\r\n"), record("🦊e\u{301}\u{85}"), record("\u{2028}\u{2029}"),
      IndexedLine(text: ""),
    ]
    var index = PersistentLineIndex()
    try index.replace(0..<0, with: records)
    let before = index
    var offset = 0
    for (ordinal, value) in records.enumerated() {
      XCTAssertEqual(index.resolve(value.id)?.ordinal, ordinal)
      XCTAssertEqual(index.resolve(value.id)?.units, offset)
      XCTAssertEqual(index.line(id: value.id), value.metadata(at: offset))
      XCTAssertEqual(index.line(at: ordinal)?.location, offset)
      XCTAssertEqual(index.line(containing: offset)?.ordinal, ordinal)
      offset += value.length
    }
    XCTAssertEqual(index.materializedText(), "a\r\n🦊e\u{301}\u{85}\u{2028}\u{2029}")
    XCTAssertEqual(index.line(containing: offset)?.ordinal, 3)
    try index.replace(0..<1, with: [record("longer\n", id: records[0].id)])
    XCTAssertEqual(before.line(id: records[1].id)?.location, 3)
    XCTAssertEqual(index.line(id: records[1].id)?.location, 7)
    XCTAssertEqual(before.materializedText(), "a\r\n🦊e\u{301}\u{85}\u{2028}\u{2029}")
    XCTAssertEqual(try index.utf16(in: NSRange(location: 7, length: 2)), Array("🦊".utf16))
  }

  func testEmptyAndZeroUUIDAreRealIdentities() throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    let record = IndexedLine(id: zero, text: "")
    var index = PersistentLineIndex()
    try index.replace(0..<0, with: [record])
    XCTAssertEqual(index.line(containing: 0)?.metadata.id, zero)
    XCTAssertEqual(index.resolve(zero)?.units, 0)
    XCTAssertEqual(index.materializedText(), "")
    XCTAssertEqual(index.materializedLines(), [record.metadata(at: 0)])
    XCTAssertThrowsError(try index.utf16(in: NSRange(location: 0, length: 1)))
    try index.replace(0..<1, with: [])
    XCTAssertEqual(index.count, 0)
    XCTAssertNil(index.resolve(zero))
  }

  func testDuplicateAndRangeRejectionsAreAtomic() throws {
    var index = PersistentLineIndex()
    let a = record("a"), b = record("b")
    try index.replace(0..<0, with: [a, b])
    let root = index.root
    XCTAssertThrowsError(try index.replace(0..<1, with: [b]))
    XCTAssertThrowsError(try index.replace(0..<2, with: [a, a]))
    XCTAssertThrowsError(try index.replace(-1..<0, with: []))
    XCTAssertThrowsError(try index.replace(1..<3, with: []))
    XCTAssertTrue(index.root === root)
    XCTAssertEqual(index.materializedText(), "ab")
  }

  func testLocalEditSharesSuffixAndBoundsWork() throws {
    var index = PersistentLineIndex()
    let records = (0..<25_000).map { record("\($0)\n") }
    try index.replace(0..<0, with: records)
    let before = index
    let recorder = DocumentWorkRecorder()
    try DocumentInstrumentation.$recorder.withValue(recorder) {
      try index.replace(0..<1, with: [record("changed\n", id: records[0].id)])
      XCTAssertEqual(index.line(id: records.last!.id)?.id, records.last!.id)
      XCTAssertEqual(try index.utf16(in: NSRange(location: 0, length: 7)), Array("changed".utf16))
    }
    let work = recorder.snapshot
    XCTAssertLessThan(work[.allocatedIndexNodes, default: 0], 2000)
    XCTAssertLessThan(work[.visitedIndexNodes, default: 0], 2000)
    XCTAssertLessThan(work[.visitedLines, default: 0], 256)
    XCTAssertNil(work[.flattenCalls])
    func identities(_ root: LineIndexNode?) -> Set<ObjectIdentifier> {
      guard let root else { return [] }
      return root.children.reduce(into: Set([ObjectIdentifier(root)])) {
        $0.formUnion(identities($1))
      }
    }
    let old = identities(before.root), new = identities(index.root)
    XCTAssertGreaterThan(old.intersection(new).count, old.count - 30)
    XCTAssertEqual(
      before.line(id: records.last!.id)?.location,
      records.dropLast().reduce(0) { $0 + $1.length })
  }

  func testSeededRecordReplacementMatchesFlatReference() throws {
    var index = PersistentLineIndex()
    var reference = (0..<300).map { record("\($0)🦊\r\n") }
    try index.replace(0..<0, with: reference)
    var seed: UInt64 = 0x1234
    for step in 0..<500 {
      seed = seed &* 6364136223846793005 &+ 1
      let start = Int(seed % UInt64(reference.count + 1))
      let length = min(Int(seed >> 24 & 15), reference.count - start)
      let incoming = (0..<Int(seed >> 32 & 15)).map { record("\(step):\($0)e\u{301}\n") }
      let removed = Array(reference[start..<(start + length)])
      try index.replace(start..<(start + length), with: incoming)
      reference.replaceSubrange(start..<(start + length), with: incoming)
      var offset = 0
      for (ordinal, record) in reference.enumerated() {
        XCTAssertEqual(index.resolve(record.id)?.ordinal, ordinal, "step \(step)")
        XCTAssertEqual(index.line(id: record.id)?.location, offset, "step \(step)")
        offset += record.length
      }
      for record in removed { XCTAssertNil(index.resolve(record.id), "step \(step)") }
      XCTAssertEqual(index.utf16Count, offset)
      XCTAssertEqual(
        index.materializedText(),
        reference.map { value in
          var units: [UInt16] = []
          value.textRoot?.flatten(into: &units)
          return String(decoding: units, as: UTF16.self)
        }.joined())
      if let root = index.root {
        XCTAssertLessThanOrEqual(
          root.height,
          Int(ceil(log(Double(max(1, root.count))) / log(16))) + 1)
      }
    }
  }

  func testLongLineChunkBoundariesAndReleasedRoots() throws {
    let original = Array(
      String(repeating: "🦊e\u{301}\r\n\u{85}\u{2028}\u{2029}", count: 20_000).utf16)
    var root = PersistentTextNode.build(original)
    let snapshot = root
    var expected = original
    for offset in [0, 2047, 2048, 2049, original.count - 2] {
      root = PersistentTextNode.replacing(root, range: offset..<(offset + 1), with: [120])
      expected.replaceSubrange(offset..<(offset + 1), with: [120])
      root?.validate()
    }
    var actual: [UInt16] = [], old: [UInt16] = []
    root?.flatten(into: &actual)
    snapshot?.flatten(into: &old)
    XCTAssertEqual(actual, expected)
    XCTAssertEqual(old, original)
    weak var released: LineIndexNode?
    do {
      var temporary = PersistentLineIndex()
      try temporary.replace(0..<0, with: [record("temporary")])
      released = temporary.root
      XCTAssertNotNil(released)
    }
    XCTAssertNil(released)
  }
}
