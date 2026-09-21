import Foundation

/// A bounded atomic change, expressed against one immutable document revision.
public struct DocumentPatch: Sendable {
  public struct Replacement: Sendable {
    public let range: NSRange
    public let text: String
    public let anchor: ToolAnchoredRange
    public let sourceHash: String
    let lineIDs: [UUID]?
    let timestamp: Date
    public init(range: NSRange, text: String, in snapshot: DocumentSnapshot, at time: Date = Date())
      throws
    {
      self.range = range
      self.text = text
      anchor = try ToolAnchoredRange(range, snapshot: snapshot)
      sourceHash = ToolInvocation.hash(try snapshot.text(in: range))
      lineIDs = nil
      timestamp = time
    }
    init(
      range: NSRange, text: String, anchor: ToolAnchoredRange, sourceHash: String,
      lineIDs: [UUID], timestamp: Date
    ) {
      self.range = range
      self.text = text
      self.anchor = anchor
      self.sourceHash = sourceHash
      self.lineIDs = lineIDs
      self.timestamp = timestamp
    }
  }
  public enum InvocationChange: Sendable { case upsert(ToolInvocation), remove(UUID) }
  public enum LandmarkChange: Sendable { case upsert(Landmark), remove(LandmarkID) }
  public let documentID: UUID
  public let revision: Int64
  public let replacements: [Replacement]
  /// Exact prior values include anchors, hashes, lifecycle and package generations.
  public let expectedInvocations: [ToolInvocation]
  public let invocations: [InvocationChange]
  public let landmarks: [LandmarkChange]
  public init(
    in snapshot: DocumentSnapshot, replacements: [Replacement] = [],
    expectedInvocations: [ToolInvocation] = [], invocations: [InvocationChange] = [],
    landmarks: [LandmarkChange] = []
  ) {
    documentID = snapshot.documentID
    revision = snapshot.revision
    self.replacements = replacements
    self.expectedInvocations = expectedInvocations
    self.invocations = invocations
    self.landmarks = landmarks
  }

  /// Preview remains inside the document boundary. The coordinator replays the
  /// same allocated identities after checking the original revision and anchors.
  static func preview(_ snapshot: DocumentSnapshot, range: NSRange, text: String) throws
    -> (Replacement, DocumentSnapshot)
  {
    var index = try snapshot.indexed(), ids: [UUID] = []
    let time = Date()
    let delta = try index.replaceText(
      in: range, with: text, landmarks: snapshot.landmarks,
      at: time,
      makeLineID: {
        let id = UUID()
        ids.append(id)
        return id
      })
    let replacement = Replacement(
      range: range, text: text,
      anchor: try ToolAnchoredRange(range, snapshot: snapshot),
      sourceHash: ToolInvocation.hash(try snapshot.text(in: range)), lineIDs: ids, timestamp: time)
    return (
      replacement,
      DocumentSnapshot(
        documentID: snapshot.documentID,
        revision: snapshot.revision, index: index, landmarks: delta.landmarks, invocations: [])
    )
  }

  func applying(to before: DocumentSnapshot) throws
    -> (after: DocumentSnapshot, removed: Set<UUID>, inserted: Set<UUID>)
  {
    guard documentID == before.documentID, revision == before.revision,
      before.revision < Int64.max, replacements.count <= 256,
      invocations.count <= 2000, landmarks.count <= 2000,
      expectedInvocations.count <= 1000,
      Set(expectedInvocations.map(\.id)).count == expectedInvocations.count
    else { throw DocumentError.invalidState }
    for expected in expectedInvocations {
      guard before.invocations.first(where: { $0.id == expected.id }) == expected else {
        throw DocumentError.invalidState
      }
    }
    let changedIDs = Set(
      invocations.map { change -> UUID in
        switch change {
        case .upsert(let value): value.id
        case .remove(let id): id
        }
      })
    let authorized = Set(expectedInvocations.map(\.id)).intersection(changedIDs)
    var previous: NSRange?
    for replacement in replacements {
      let range = replacement.range
      guard range.location >= 0, range.length >= 0, range.location <= before.utf16Count,
        range.length <= before.utf16Count - range.location,
        replacement.anchor.resolve(in: before) == range,
        ToolInvocation.hash(try before.text(in: range)) == replacement.sourceHash
      else { throw DocumentError.invalidRange }
      if let previous {
        guard NSMaxRange(previous) <= range.location, previous.location != range.location else {
          throw DocumentError.invalidRange
        }
      }
      guard
        ToolRangeEditing.intersectingLocks(range, snapshot: before)
          .allSatisfy({ authorized.contains($0.id) })
      else { throw DocumentError.invalidRange }
      previous = range
    }
    var working = before, removed = Set<UUID>(), inserted = Set<UUID>()
    for replacement in replacements.reversed() {
      var index = try working.indexed(), nextID = 0, exhausted = false
      let delta = try index.replaceText(
        in: replacement.range, with: replacement.text,
        landmarks: working.landmarks, at: replacement.timestamp,
        makeLineID: {
          guard let ids = replacement.lineIDs else { return UUID() }
          guard nextID < ids.count else {
            exhausted = true
            return UUID()
          }
          defer { nextID += 1 }
          return ids[nextID]
        })
      guard !exhausted, replacement.lineIDs == nil || nextID == replacement.lineIDs?.count else {
        throw DocumentError.invalidState
      }
      let plain = DocumentSnapshot(
        documentID: documentID, revision: revision,
        index: index, landmarks: delta.landmarks, invocations: [])
      let mapped = ToolRangeEditing.remap(
        working.invocations, from: working, to: plain,
        edit: replacement.range, replacementLength: replacement.text.utf16.count)
      working = DocumentSnapshot(
        documentID: documentID, revision: revision,
        index: index, landmarks: delta.landmarks, invocations: mapped)
      removed.formUnion(delta.removedLineIDs)
      inserted.formUnion(delta.insertedLineIDs)
    }
    var values = working.invocations, marks = working.landmarks
    for change in invocations {
      switch change {
      case .remove(let id):
        if before.invocations.contains(where: { $0.id == id }),
          !expectedInvocations.contains(where: { $0.id == id })
        {
          throw DocumentError.invalidState
        }
        values.removeAll { $0.id == id }
      case .upsert(let value):
        // Existing annotation replacement must name its exact precondition.
        if before.invocations.contains(where: { $0.id == value.id }),
          !expectedInvocations.contains(where: { $0.id == value.id })
        {
          throw DocumentError.invalidState
        }
        values.removeAll { $0.id == value.id }
        values.append(value)
      }
    }
    for change in landmarks {
      switch change {
      case .remove(let id): marks.removeAll { $0.id == id }
      case .upsert(let value):
        marks.removeAll { $0.id == value.id }
        marks.append(value)
      }
    }
    let after = DocumentSnapshot(
      documentID: documentID, revision: revision + 1,
      index: try working.indexed(), landmarks: marks, invocations: values)
    var attached = Set<UUID>()
    for mark in marks {
      guard Landmark.isValidEmoji(mark.emoji),
        mark.detached
          || (after.line(id: mark.lineID) != nil && attached.insert(mark.lineID).inserted)
      else { throw DocumentError.invalidState }
    }
    guard Set(marks.map(\.id)).count == marks.count, values.count <= 1000,
      ToolInvocation.sanitized(values, in: after) == values
    else { throw DocumentError.invalidState }
    return (after, removed.subtracting(inserted), inserted.subtracting(removed))
  }
}
