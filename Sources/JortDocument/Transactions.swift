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
public enum MutationOrigin: String, Sendable {
  case native, undo, redo, metadata, restore, automation, startupMerge
}
public enum UndoPolicy: Sendable { case register, replay, none }
public enum DocumentMutation: Sendable {
  case patch(DocumentPatch)
  case replace(range: NSRange, text: String)
  case edit(text: String, range: NSRange?, replacementLength: Int?)
  case restore(DocumentSnapshot)
  case landmark(Landmark)
  case removeLandmark(LandmarkID)
  case clearLandmarks
  case insertAfter(lineID: UUID, text: String)
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
  private var current: DocumentSnapshot
  #if DEBUG
    private var validationPending: DocumentSnapshot?
    private var validationTask: Task<Void, Never>?
  #endif
  public private(set) var committedRevision: Int64?
  public var onTransaction: (@MainActor (TransactionResult) -> Void)?
  public var snapshot: DocumentSnapshot { current }
  public init(snapshot: DocumentSnapshot = DocumentSnapshot(), committed: Bool = false) throws {
    try snapshot.validate()
    current = snapshot
    committedRevision = committed ? snapshot.revision : nil
  }
  public func markCommitted(_ revision: Int64) {
    guard revision >= 0, revision <= current.revision else { return }
    committedRevision = max(committedRevision ?? -1, revision)
  }
  /// One worker owns at most an in-flight root and the newest waiting root.
  /// Full integrity checks never execute in an input callback.
  private func scheduleIntegrityCheck() {
    #if DEBUG
      validationPending = current
      guard validationTask == nil else { return }
      validationTask = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
          guard let snapshot = self?.validationPending else { break }
          self?.validationPending = nil
          let valid = await Task.detached(priority: .utility) {
            do {
              try snapshot.validate()
              return true
            } catch { return false }
          }.value
          if self?.current.revision == snapshot.revision,
            self?.current.documentID == snapshot.documentID
          {
            precondition(valid, "Asynchronous document integrity check failed")
          }
        }
        self?.validationTask = nil
      }
    #endif
  }
  @discardableResult public func apply(_ transaction: DocumentTransaction, at time: Date = Date())
    throws -> TransactionResult
  {
    let measurement = DocumentInstrumentation.begin(
      "DocumentTransaction", revision: transaction.baseRevision)
    defer { DocumentInstrumentation.end(measurement) }
    guard transaction.baseRevision == current.revision else {
      throw DocumentError.staleRevision(
        expected: transaction.baseRevision, actual: current.revision)
    }
    let before = snapshot
    if case .patch(let patch) = transaction.mutation {
      let applied = try patch.applying(to: before)
      current = applied.after
      scheduleIntegrityCheck()
      let result = TransactionResult(
        before: before, after: applied.after, transaction: transaction,
        removedLineIDs: applied.removed, insertedLineIDs: applied.inserted)
      onTransaction?(result)
      return result
    }
    var metadata = before.landmarks
    let metadataOnly: Bool
    switch transaction.mutation {
    case .landmark(let landmark):
      guard !landmark.detached, before.line(id: landmark.lineID) != nil else {
        throw DocumentError.missingAnchor
      }
      guard Landmark.isValidEmoji(landmark.emoji),
        !metadata.contains(where: {
          $0.id != landmark.id && !$0.detached && $0.lineID == landmark.lineID
        })
      else { throw DocumentError.invalidState }
      metadata.removeAll { $0.id == landmark.id }
      metadata.append(landmark)
      metadataOnly = true
    case .removeLandmark(let id):
      metadata.removeAll { $0.id == id }
      metadataOnly = true
    case .clearLandmarks:
      metadata.removeAll()
      metadataOnly = true
    default: metadataOnly = false
    }
    if metadataOnly {
      guard before.revision < Int64.max else { throw DocumentError.invalidState }
      let after = DocumentSnapshot(
        documentID: before.documentID, revision: before.revision + 1,
        index: try before.indexed(), landmarks: metadata, invocations: before.invocations)
      current = after
      scheduleIntegrityCheck()
      let result = TransactionResult(
        before: before, after: after, transaction: transaction,
        removedLineIDs: [], insertedLineIDs: [])
      onTransaction?(result)
      return result
    }
    if case .restore(let restored) = transaction.mutation {
      guard before.revision < Int64.max, restored.documentID == before.documentID else {
        throw DocumentError.invalidState
      }
      try restored.validate()
      let after = DocumentSnapshot(
        documentID: before.documentID, revision: before.revision + 1,
        index: try restored.indexed(), landmarks: restored.landmarks,
        invocations: restored.invocations)
      let old = Set(before.lines.map(\.id)), new = Set(after.lines.map(\.id))
      current = after
      scheduleIntegrityCheck()
      let result = TransactionResult(
        before: before, after: after, transaction: transaction,
        removedLineIDs: old.subtracting(new), insertedLineIDs: new.subtracting(old))
      onTransaction?(result)
      return result
    }
    let replacement: (NSRange, String)?
    switch transaction.mutation {
    case .replace(let range, let text): replacement = (range, text)
    case .insertAfter(let id, let text):
      guard let line = before.line(id: id) else { throw DocumentError.missingAnchor }
      let offset = line.location + line.length
      let endsWithLF =
        try before.utf16Count > 0
        && before.utf16(in: NSRange(location: before.utf16Count - 1, length: 1)).first == 10
      let prefix = offset == before.utf16Count && !endsWithLF ? "\n" : ""
      replacement = (
        NSRange(location: offset, length: 0), prefix + text + (text.hasSuffix("\n") ? "" : "\n")
      )
    default: replacement = nil
    }
    if let (range, text) = replacement {
      guard before.revision < Int64.max else { throw DocumentError.invalidState }
      guard range.location >= 0, range.length >= 0, range.location <= before.utf16Count,
        range.length <= before.utf16Count - range.location
      else { throw DocumentError.invalidRange }
      guard !ToolRangeEditing.intersectsLock(range, snapshot: before) else {
        throw DocumentError.invalidRange
      }
      var index = try before.indexed()
      let delta = try index.replaceText(
        in: range, with: text, landmarks: before.landmarks, at: time)
      let plain = DocumentSnapshot(
        documentID: before.documentID, revision: before.revision + 1,
        index: index, landmarks: delta.landmarks, invocations: [])
      let invocations =
        before.invocations.isEmpty
        ? []
        : ToolRangeEditing.remap(
          before.invocations, from: before, to: plain, edit: range,
          replacementLength: text.utf16.count)
      let after = DocumentSnapshot(
        documentID: before.documentID, revision: before.revision + 1,
        index: index, landmarks: delta.landmarks, invocations: invocations)
      guard ToolInvocation.sanitized(invocations, in: after) == invocations else {
        throw DocumentError.invalidState
      }
      current = after
      scheduleIntegrityCheck()
      let result = TransactionResult(
        before: before, after: after, transaction: transaction,
        removedLineIDs: delta.removedLineIDs, insertedLineIDs: delta.insertedLineIDs)
      onTransaction?(result)
      return result
    }
    // Explicit bulk compatibility boundary. Ordinary callers submit exact replacements.
    let state = before.liveState
    var next = state
    switch transaction.mutation {
    case .replace, .patch, .insertAfter: throw DocumentError.invalidState
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

    }
    guard state.revision < Int64.max else { throw DocumentError.invalidState }
    next.revision = state.revision + 1
    try next.validate()
    current = DocumentSnapshot(
      documentID: next.documentID, text: next.text, revision: next.revision,
      lines: next.lines, landmarks: next.landmarks, invocations: next.invocations)
    let after = snapshot
    DocumentInstrumentation.count(.visitedLines, before.lines.count + after.lines.count)
    let old = Set(before.lines.map(\.id)), new = Set(after.lines.map(\.id))
    let result = TransactionResult(
      before: before, after: after, transaction: transaction, removedLineIDs: old.subtracting(new),
      insertedLineIDs: new.subtracting(old))
    onTransaction?(result)
    return result
  }
}

/// The insertion prefix preserves all user-supplied newline sequences verbatim.
public enum StartupMerge {
  public static func prefix(draft: String, stored: String) -> String {
    let boundaries: Set<UInt16> = [10, 13, 0x85, 0x2028, 0x2029]
    guard let last = draft.utf16.last, let first = stored.utf16.first,
      !boundaries.contains(last), !boundaries.contains(first)
    else { return draft }
    return draft + "\n"
  }
}
