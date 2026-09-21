import Foundation

extension PersistentLineIndex {
  struct EditResult {
    let landmarks: [Landmark]
    let removedLineIDs: Set<UUID>
    let insertedLineIDs: Set<UUID>
  }

  /// Preserve the established lineage algorithm within a bounded logical-line window.
  /// Whole-document integrity remains a separate persistence/reference boundary.
  mutating func replaceText(
    in range: NSRange, with replacement: String, landmarks: [Landmark], at time: Date,
    makeLineID: () -> UUID = { UUID() }
  ) throws -> EditResult {
    guard range.location >= 0, range.length >= 0, range.location <= utf16Count,
      range.length <= utf16Count - range.location,
      utf16Count - range.length <= Int.max - replacement.utf16.count,
      let leading = line(containing: range.location),
      let trailing = line(containing: range.location + range.length)
    else { throw DocumentError.invalidRange }
    let replacementUnits = Array(replacement.utf16)
    if try utf16(in: range) == replacementUnits {
      return EditResult(landmarks: landmarks, removedLineIDs: [], insertedLineIDs: [])
    }
    let first = max(0, leading.ordinal - 1)
    let end = min(count, trailing.ordinal + 2)
    let startOffset = line(at: first)!.location
    let endOffset = end < count ? line(at: end)!.location : utf16Count
    let windowRange = NSRange(location: startOffset, length: endOffset - startOffset)
    let oldText = String(decoding: try utf16(in: windowRange), as: UTF16.self)
    var records: [IndexedLine] = []
    var localLines: [LineMeta] = []
    var cursor = 0
    for ordinal in first..<end {
      let record = line(at: ordinal)!.record
      records.append(record)
      localLines.append(record.metadata(at: cursor))
      cursor += record.length
    }
    let oldIDs = Set(records.map(\.id))
    let localLandmarks = landmarks.filter { !$0.detached && oldIDs.contains($0.lineID) }
    let localRange = NSRange(location: range.location - startOffset, length: range.length)
    let changed = (oldText as NSString).replacingCharacters(in: localRange, with: replacement)
    var local = DocumentState(landmarks: localLandmarks, text: oldText, lines: localLines)
    local.replaceText(
      changed, editRange: localRange, replacementLength: replacementUnits.count,
      at: time, makeLineID: makeLineID)
    try local.validate(fullDocument: false)
    // The extracted window has a synthetic terminal line; a nonterminal window
    // must not publish it into the surrounding sequence.
    if end < count, local.lines.last?.length == 0 { local.lines.removeLast() }
    let originalByID = Dictionary(
      uniqueKeysWithValues: zip(records, localLines).map { ($0.0.id, $0) })
    let newSource = local.text as NSString
    let oldSource = oldText as NSString
    func splitsSurrogate(_ offset: Int) -> Bool {
      offset > 0 && offset < oldSource.length
        && (0xD800...0xDBFF).contains(oldSource.character(at: offset - 1))
        && (0xDC00...0xDFFF).contains(oldSource.character(at: offset))
    }
    let incoming = local.lines.map { metadata -> IndexedLine in
      let newRange = NSRange(location: metadata.location, length: metadata.length)
      let newText = newSource.substring(with: newRange)
      var textRoot: PersistentTextNode?
      if let (oldRecord, oldMetadata) = originalByID[metadata.id] {
        let oldRange = NSRange(location: oldMetadata.location, length: oldMetadata.length)
        if oldSource.substring(with: oldRange) == newText {
          textRoot = oldRecord.textRoot
        } else if localRange.location >= oldRange.location,
          NSMaxRange(localRange) <= NSMaxRange(oldRange),
          !splitsSurrogate(localRange.location), !splitsSurrogate(NSMaxRange(localRange)),
          metadata.location == oldMetadata.location,
          metadata.length == oldMetadata.length - range.length + replacementUnits.count
        {
          let start = localRange.location - oldRange.location
          textRoot = PersistentTextNode.replacing(
            oldRecord.textRoot,
            range: start..<(start + range.length), with: replacementUnits)
        } else {
          textRoot = PersistentTextNode.build(Array(newText.utf16))
        }
      } else {
        textRoot = PersistentTextNode.build(Array(newText.utf16))
      }
      return IndexedLine(
        id: metadata.id, textRoot: textRoot,
        createdAt: metadata.createdAt, lastEditedAt: metadata.lastEditedAt)
    }
    // ID uniqueness is proved against the complete persistent lookup before mutation.
    try replace(first..<end, with: incoming)
    let mapped = Dictionary(uniqueKeysWithValues: local.landmarks.map { ($0.id, $0) })
    let updatedLandmarks = landmarks.map { mapped[$0.id] ?? $0 }
    let newIDs = Set(incoming.map(\.id))
    return EditResult(
      landmarks: updatedLandmarks,
      removedLineIDs: oldIDs.subtracting(newIDs), insertedLineIDs: newIDs.subtracting(oldIDs))
  }
}
