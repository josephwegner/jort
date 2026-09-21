import Foundation

public struct DocumentSnapshot: Equatable, Sendable {
  private enum Storage: Sendable {
    case indexed(PersistentLineIndex)
    // Preserve nonthrowing construction of invalid candidates. Validation rejects
    // these values before a coordinator or persistence boundary can publish them.
    case invalid(text: String, lines: [LineMeta])
  }
  private let storage: Storage
  public let documentID: UUID
  public let revision: Int64
  public let landmarks: [Landmark]
  public let invocations: [ToolInvocation]
  public var text: String {
    switch storage {
    case .indexed(let index): return index.materializedText()
    case .invalid(let text, _): return text
    }
  }
  public var lines: DocumentLineView {
    switch storage {
    case .indexed(let index): return DocumentLineView(index)
    case .invalid(_, let lines): return DocumentLineView(lines)
    }
  }
  public var utf16Count: Int {
    switch storage {
    case .indexed(let index): return index.utf16Count
    case .invalid(let text, _): return text.utf16.count
    }
  }
  public var lineCount: Int {
    switch storage {
    case .indexed(let index): return index.count
    case .invalid(_, let lines): return lines.count
    }
  }
  public init(
    documentID: UUID = UUID(), text: String = "", revision: Int64 = 0,
    lines: [LineMeta] = [LineMeta(location: 0, length: 0)], landmarks: [Landmark] = [],
    invocations: [ToolInvocation] = []
  ) {
    self.documentID = documentID
    self.revision = revision
    self.invocations = invocations
    let source = text as NSString
    var index = PersistentLineIndex(), records: [IndexedLine] = [], cursor = 0
    var valid = !lines.isEmpty
    for line in lines {
      guard line.location == cursor, line.length >= 0, cursor <= source.length,
        line.length <= source.length - cursor
      else {
        valid = false
        break
      }
      records.append(
        IndexedLine(
          id: line.id,
          text: source.substring(with: NSRange(location: cursor, length: line.length)),
          createdAt: line.createdAt, lastEditedAt: line.lastEditedAt))
      cursor += line.length
    }
    valid = valid && cursor == source.length
    if valid, (try? index.replace(0..<0, with: records)) != nil {
      storage = .indexed(index)
    } else {
      storage = .invalid(text: text, lines: lines)
    }
    var order: [UUID: Int] = [:]
    if !landmarks.isEmpty {
      for (ordinal, line) in lines.enumerated() { order[line.id] = ordinal }
    }
    self.landmarks = Self.sorted(landmarks) { order[$0] }
  }

  public init(
    documentID: UUID = UUID(), text: String = "", revision: Int64 = 0,
    lines: DocumentLineView, landmarks: [Landmark] = [], invocations: [ToolInvocation] = []
  ) {
    self.init(
      documentID: documentID, text: text, revision: revision,
      lines: lines.materialized(), landmarks: landmarks, invocations: invocations)
  }

  init(
    documentID: UUID, revision: Int64, index: PersistentLineIndex,
    landmarks: [Landmark], invocations: [ToolInvocation]
  ) {
    self.documentID = documentID
    self.revision = revision
    storage = .indexed(index)
    self.landmarks = Self.sorted(landmarks) { index.resolve($0)?.ordinal }
    self.invocations = invocations
  }

  private static func sorted(_ values: [Landmark], ordinal: (UUID) -> Int?) -> [Landmark] {
    values.sorted {
      let a = $0.detached ? Int.max : ordinal($0.lineID) ?? Int.max
      let b = $1.detached ? Int.max : ordinal($1.lineID) ?? Int.max
      return a == b ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : a < b
    }
  }
  func indexed() throws -> PersistentLineIndex {
    guard case .indexed(let index) = storage else { throw DocumentError.invalidState }
    return index
  }

  public func line(id: UUID) -> LineMeta? {
    switch storage {
    case .indexed(let index): return index.line(id: id)
    case .invalid(_, let lines): return lines.first { $0.id == id }
    }
  }
  public func line(at ordinal: Int) -> LineMeta? {
    switch storage {
    case .indexed(let index):
      guard let value = index.line(at: ordinal) else { return nil }
      return value.record.metadata(at: value.location)
    case .invalid(_, let lines): return lines.indices.contains(ordinal) ? lines[ordinal] : nil
    }
  }
  public func line(containingUTF16Offset offset: Int) -> LineMeta? {
    switch storage {
    case .indexed(let index): return index.line(containing: offset)?.metadata
    case .invalid(_, let lines):
      return lines.last { $0.location <= offset && offset <= $0.location + $0.length }
    }
  }
  public func ordinal(of id: UUID) -> Int? {
    switch storage {
    case .indexed(let index): return index.resolve(id)?.ordinal
    case .invalid(_, let lines): return lines.firstIndex { $0.id == id }
    }
  }
  public func text(in range: NSRange) throws -> String {
    String(decoding: try utf16(in: range), as: UTF16.self)
  }
  public func utf16(in range: NSRange) throws -> [UInt16] {
    switch storage {
    case .indexed(let index): return try index.utf16(in: range)
    case .invalid: throw DocumentError.invalidState
    }
  }
  public func validate() throws {
    _ = try validatedMaterialization()
  }
  /// Explicit full-document boundary for encoding/export/integrity work.
  public func validatedMaterialization() throws -> (text: String, lines: [LineMeta]) {
    _ = try indexed()
    let materialized = (text: text, lines: lines.materialized())
    try DocumentState(
      documentID: documentID, landmarks: landmarks, invocations: invocations,
      text: materialized.text, revision: revision, lines: materialized.lines
    ).validate()
    guard invocations.count <= 1000, ToolInvocation.sanitized(invocations, in: self) == invocations
    else { throw DocumentError.invalidState }
    return materialized
  }
  var liveState: DocumentState {
    DocumentState(
      documentID: documentID, landmarks: landmarks, invocations: invocations,
      text: text, revision: revision, lines: lines.materialized())
  }
  public func isDetached(_ landmark: Landmark) -> Bool {
    landmark.detached || line(id: landmark.lineID) == nil
  }
  public var orderedLandmarks: [Landmark] { landmarks }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.documentID == rhs.documentID, lhs.revision == rhs.revision,
      lhs.landmarks == rhs.landmarks, lhs.invocations == rhs.invocations
    else { return false }
    switch (lhs.storage, rhs.storage) {
    case (.indexed(let a), .indexed(let b)): return a.hasEqualContent(to: b)
    case (.invalid(let a, let x), .invalid(let b, let y)): return a == b && x == y
    default: return false
    }
  }
}
