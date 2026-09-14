import Foundation

public enum DocumentError: Error, Equatable, Sendable {
  case invalidState, staleRevision(expected: Int64, actual: Int64), missingAnchor, invalidRange
}
public struct LandmarkID: Codable, Hashable, Sendable {
  public let rawValue: UUID
  public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
  public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(UUID.self)
  }
  public func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    try value.encode(rawValue)
  }
}
public struct Landmark: Codable, Equatable, Sendable {
  public let id: LandmarkID
  public let lineID: UUID
  public let emoji: String
  public let detached: Bool
  public init(id: LandmarkID = LandmarkID(), lineID: UUID, emoji: String, detached: Bool = false) {
    self.id = id
    self.lineID = lineID
    self.emoji = emoji.precomposedStringWithCanonicalMapping
    self.detached = detached
  }
  public func attaching(to lineID: UUID) -> Landmark {
    Landmark(id: id, lineID: lineID, emoji: emoji)
  }
  public func detaching() -> Landmark {
    Landmark(id: id, lineID: lineID, emoji: emoji, detached: true)
  }

  /// Accept one presenting emoji, including keycaps, flags, modifiers and joined sequences.
  public static func isValidEmoji(_ value: String) -> Bool {
    guard value.count == 1 else { return false }
    let scalars = Array(value.unicodeScalars)
    let numbers = scalars.map(\.value)
    if numbers.contains(0xFE0E) { return false }
    if numbers.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0) }) { return numbers.count == 2 }
    if numbers.last == 0x20E3 {
      return (numbers.count == 2 || numbers.count == 3 && numbers[1] == 0xFE0F)
        && (numbers[0] == 35 || numbers[0] == 42 || (48...57).contains(numbers[0]))
    }
    guard let first = scalars.first,
      first.properties.isEmoji || (0x1FA70...0x1FAFF).contains(first.value),
      !(0x1F3FB...0x1F3FF).contains(first.value), !(48...57).contains(first.value),
      first.value != 35, first.value != 42
    else { return false }
    let parts = scalars.split(omittingEmptySubsequences: false) { $0.value == 0x200D }
    return parts.allSatisfy { part in
      let s = Array(part)
      guard let base = s.first, base.properties.isEmoji || (0x1FA70...0x1FAFF).contains(base.value),
        !(0x1F3FB...0x1F3FF).contains(base.value),
        base.properties.isEmojiPresentation || (0x1FA70...0x1FAFF).contains(base.value)
          || s.dropFirst().first?.value == 0xFE0F
      else { return false }
      var modifier = false, variation = false
      for scalar in s.dropFirst() {
        if scalar.value == 0xFE0F, !variation, !modifier {
          variation = true
        } else if (0x1F3FB...0x1F3FF).contains(scalar.value), base.properties.isEmojiModifierBase,
          !modifier
        {
          modifier = true
        } else if base.value == 0x1F3F4, (0xE0020...0xE007F).contains(scalar.value),
          s.last?.value == 0xE007F
        {
          continue
        } else {
          return false
        }
      }
      return true
    }
  }
}
public struct DocumentSnapshot: Equatable, Sendable {
  public let documentID: UUID
  public let text: String
  public let revision: Int64
  public let lines: [LineMeta]
  public let landmarks: [Landmark]
  public let invocations: [ToolInvocation]
  public init(
    documentID: UUID = UUID(), text: String = "", revision: Int64 = 0,
    lines: [LineMeta] = [LineMeta(location: 0, length: 0)], landmarks: [Landmark] = [],
    invocations: [ToolInvocation] = []
  ) {
    self.documentID = documentID
    self.text = text
    self.revision = revision
    self.lines = lines
    self.invocations = invocations
    if landmarks.isEmpty {
      self.landmarks = []
      return
    }
    var order: [UUID: Int] = [:]
    for (index, line) in lines.enumerated() { order[line.id] = index }
    self.landmarks = landmarks.sorted {
      let a = $0.detached ? Int.max : order[$0.lineID] ?? Int.max
      let b = $1.detached ? Int.max : order[$1.lineID] ?? Int.max
      return a == b ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : a < b
    }
  }
  public func validate() throws {
    try liveState.validate()
    guard invocations.count <= 1000, ToolInvocation.sanitized(invocations, in: self) == invocations
    else { throw DocumentError.invalidState }
  }
  var liveState: DocumentState {
    DocumentState(
      documentID: documentID, landmarks: landmarks, invocations: invocations, text: text,
      revision: revision, lines: lines)
  }
  public func isDetached(_ landmark: Landmark) -> Bool {
    landmark.detached || !lines.contains { $0.id == landmark.lineID }
  }
  public var orderedLandmarks: [Landmark] { landmarks }
}
public enum MutationOrigin: String, Sendable {
  case native, undo, redo, metadata, restore, automation
}
public enum UndoPolicy: Sendable { case register, replay, none }
public enum DocumentMutation: Sendable {
  case edit(text: String, range: NSRange?, replacementLength: Int?)
  case restore(DocumentSnapshot)
  case landmark(Landmark)
  case removeLandmark(LandmarkID)
  case clearLandmarks
  case insertAfter(lineID: UUID, text: String)
  case tools(DocumentSnapshot, edit: NSRange? = nil, replacementLength: Int? = nil)
}
public struct DocumentTransaction: Sendable {
  public let baseRevision: Int64
  public let origin: MutationOrigin
  public let undoPolicy: UndoPolicy
  public let mutation: DocumentMutation
  public init(
    baseRevision: Int64, origin: MutationOrigin, undoPolicy: UndoPolicy = .register,
    mutation: DocumentMutation
  ) {
    self.baseRevision = baseRevision
    self.origin = origin
    self.undoPolicy = undoPolicy
    self.mutation = mutation
  }
}
public struct TransactionResult: Sendable {
  public let before: DocumentSnapshot
  public let after: DocumentSnapshot
  public let transaction: DocumentTransaction
  public let removedLineIDs: Set<UUID>
  public let insertedLineIDs: Set<UUID>
}

/// The only mutable live document. Storage and adapters receive value snapshots.
@MainActor public final class DocumentCoordinator {
  private var state: DocumentState
  public private(set) var committedRevision: Int64?
  public var onTransaction: (@MainActor (TransactionResult) -> Void)?
  public var snapshot: DocumentSnapshot {
    DocumentSnapshot(
      documentID: state.documentID, text: state.text, revision: state.revision, lines: state.lines,
      landmarks: state.landmarks, invocations: state.invocations)
  }
  public init(snapshot: DocumentSnapshot = DocumentSnapshot(), committed: Bool = false) throws {
    try snapshot.validate()
    state = snapshot.liveState
    committedRevision = committed ? snapshot.revision : nil
  }
  public func markCommitted(_ revision: Int64) {
    guard revision >= 0, revision <= state.revision else { return }
    committedRevision = max(committedRevision ?? -1, revision)
  }
  @discardableResult public func apply(_ transaction: DocumentTransaction, at time: Date = Date())
    throws -> TransactionResult
  {
    guard transaction.baseRevision == state.revision else {
      throw DocumentError.staleRevision(expected: transaction.baseRevision, actual: state.revision)
    }
    let before = snapshot
    var next = state
    switch transaction.mutation {
    case .tools(let snapshot, let edit, let replacementLength):
      try snapshot.validate()
      guard snapshot.documentID == state.documentID else { throw DocumentError.invalidState }
      if let edit, let replacementLength {
        let count = (state.text as NSString).length
        guard edit.location >= 0, edit.location <= count, edit.length >= 0,
          edit.length <= count - edit.location, replacementLength >= 0,
          count - edit.length <= Int.max - replacementLength,
          count - edit.length + replacementLength == (snapshot.text as NSString).length
        else { throw DocumentError.invalidRange }
      }
      next = snapshot.liveState
    case .edit(let text, let range, let length):
      if let range, let length {
        let count = state.text.utf16.count
        guard range.location >= 0, range.length >= 0, range.location <= count,
          range.length <= count - range.location, length >= 0,
          count - range.length <= Int.max - length,
          count - range.length + length == text.utf16.count
        else { throw DocumentError.invalidRange }
      }
      let effectiveRange: NSRange, effectiveLength: Int
      if let range, let length {
        effectiveRange = range
        effectiveLength = length
      } else {
        let old = Array(state.text.utf16), new = Array(text.utf16)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix,
          old[old.count - suffix - 1] == new[new.count - suffix - 1]
        { suffix += 1 }
        effectiveRange = NSRange(location: prefix, length: old.count - prefix - suffix)
        effectiveLength = new.count - prefix - suffix
      }
      if ToolRangeEditing.intersectsLock(effectiveRange, snapshot: before) {
        throw DocumentError.invalidRange
      }
      next.replaceText(
        text, editRange: effectiveRange, replacementLength: effectiveLength, at: time)
      if !state.invocations.isEmpty {
        let plain = DocumentSnapshot(
          documentID: next.documentID, text: next.text, revision: next.revision, lines: next.lines,
          landmarks: next.landmarks)
        next.invocations = ToolRangeEditing.remap(
          state.invocations, from: before, to: plain, edit: effectiveRange,
          replacementLength: effectiveLength)
      }
    case .restore(let snapshot):
      try snapshot.validate()
      guard snapshot.documentID == state.documentID else { throw DocumentError.invalidState }
      next = snapshot.liveState
    case .landmark(let landmark):
      guard !landmark.detached, state.lines.contains(where: { $0.id == landmark.lineID }) else {
        throw DocumentError.missingAnchor
      }
      next.landmarks.removeAll { $0.id == landmark.id }
      next.landmarks.append(landmark)
    case .removeLandmark(let id): next.landmarks.removeAll { $0.id == id }
    case .clearLandmarks: next.landmarks.removeAll()
    case .insertAfter(let id, let text):
      guard let line = state.lines.first(where: { $0.id == id }) else {
        throw DocumentError.missingAnchor
      }
      let offset = line.location + line.length
      let prefix = offset == state.text.utf16.count && !state.text.hasSuffix("\n") ? "\n" : ""
      let inserted = prefix + text + (text.hasSuffix("\n") ? "" : "\n")
      let range = NSRange(location: offset, length: 0)
      if ToolRangeEditing.intersectsLock(range, snapshot: before) {
        throw DocumentError.invalidRange
      }
      next.replaceText(
        (state.text as NSString).replacingCharacters(in: range, with: inserted), editRange: range,
        replacementLength: inserted.utf16.count, at: time)
      let plain = DocumentSnapshot(
        documentID: next.documentID, text: next.text, revision: next.revision, lines: next.lines,
        landmarks: next.landmarks)
      next.invocations = ToolRangeEditing.remap(
        state.invocations, from: before, to: plain, edit: range,
        replacementLength: inserted.utf16.count)
    }
    guard state.revision < Int64.max else { throw DocumentError.invalidState }
    next.revision = state.revision + 1
    try next.validate()
    state = next
    let after = snapshot
    let old = Set(before.lines.map(\.id)), new = Set(after.lines.map(\.id))
    let result = TransactionResult(
      before: before, after: after, transaction: transaction, removedLineIDs: old.subtracting(new),
      insertedLineIDs: new.subtracting(old))
    onTransaction?(result)
    return result
  }
}
