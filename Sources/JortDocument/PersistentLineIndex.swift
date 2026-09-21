import Foundation

struct LineIndexKey: Hashable, Sendable {
  let high: UInt64
  let low: UInt64
  let isNode: Bool
  init(_ id: UUID, isNode: Bool = false) {
    let bytes = id.uuid
    (high, low) = withUnsafeBytes(of: bytes) {
      (
        $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
        $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
      )
    }
    self.isNode = isNode
  }
  func slot(_ depth: Int) -> Int {
    precondition(depth < 33)
    if depth == 0 { return isNode ? 1 : 0 }
    let position = depth - 1
    let word = position < 16 ? high : low
    return Int((word >> ((position % 16) * 4)) & 15)
  }
}

struct LineIndexAddress: Sendable {
  let parent: LineIndexKey?
  let units: Int
  let ordinal: Int
}

final class LineIndexRadix: Sendable {
  private let lifetime: DocumentStorageLifetime?
  let key: LineIndexKey?
  let value: LineIndexAddress?
  let children: [LineIndexRadix?]
  init(key: LineIndexKey, value: LineIndexAddress) {
    lifetime = .track(bytes: 96)
    self.key = key
    self.value = value
    children = []
  }
  init(children: [LineIndexRadix?]) {
    lifetime = .track(bytes: 48 + children.count * MemoryLayout<LineIndexRadix?>.stride)
    key = nil
    value = nil
    self.children = children
  }
  static func bulk(_ entries: [(LineIndexKey, LineIndexAddress)], depth: Int = 0) -> LineIndexRadix?
  {
    guard let first = entries.first else { return nil }
    DocumentInstrumentation.count(.allocatedIndexNodes)
    if entries.count == 1 {
      DocumentInstrumentation.count(.allocatedPayloadBytes, 96)
      return LineIndexRadix(key: first.0, value: first.1)
    }
    precondition(depth < 33)
    var buckets = [[(LineIndexKey, LineIndexAddress)]](repeating: [], count: 16)
    for entry in entries { buckets[entry.0.slot(depth)].append(entry) }
    DocumentInstrumentation.count(
      .allocatedPayloadBytes, 48 + 16 * MemoryLayout<LineIndexRadix?>.stride)
    return LineIndexRadix(children: buckets.map { bulk($0, depth: depth + 1) })
  }
  static func get(_ node: LineIndexRadix?, key: LineIndexKey, depth: Int = 0) -> LineIndexAddress? {
    guard let node else { return nil }
    DocumentInstrumentation.count(.visitedIndexNodes)
    if let stored = node.key { return stored == key ? node.value : nil }
    return get(
      node.children[key.slot(depth)],
      key: key, depth: depth + 1)
  }
  static func put(
    _ node: LineIndexRadix?, key: LineIndexKey, value: LineIndexAddress?, depth: Int = 0
  ) -> LineIndexRadix? {
    if node != nil { DocumentInstrumentation.count(.visitedIndexNodes) }
    guard let node else {
      guard let value else { return nil }
      DocumentInstrumentation.count(.allocatedIndexNodes)
      DocumentInstrumentation.count(.allocatedPayloadBytes, 96)
      return LineIndexRadix(key: key, value: value)
    }
    if let stored = node.key {
      if stored == key {
        guard let value else { return nil }
        DocumentInstrumentation.count(.allocatedIndexNodes)
        DocumentInstrumentation.count(.allocatedPayloadBytes, 96)
        return LineIndexRadix(key: key, value: value)
      }
      guard value != nil else { return node }
      precondition(depth < 33)
      var children = [LineIndexRadix?](repeating: nil, count: 16)
      children[stored.slot(depth)] = node
      let slot = key.slot(depth)
      children[slot] = put(children[slot], key: key, value: value, depth: depth + 1)
      DocumentInstrumentation.count(.allocatedIndexNodes)
      DocumentInstrumentation.count(
        .allocatedPayloadBytes, 16 * MemoryLayout<LineIndexRadix?>.stride + 48)
      return LineIndexRadix(children: children)
    }
    let slot = key.slot(depth)
    var children = node.children
    children[slot] = put(children[slot], key: key, value: value, depth: depth + 1)
    let remaining = children.compactMap { $0 }
    if remaining.isEmpty { return nil }
    if remaining.count == 1, remaining[0].key != nil { return remaining[0] }
    DocumentInstrumentation.count(.allocatedIndexNodes)
    DocumentInstrumentation.count(
      .allocatedPayloadBytes, 16 * MemoryLayout<LineIndexRadix?>.stride + 48)
    return LineIndexRadix(children: children)
  }
}

struct IndexedLine: Sendable {
  let id: UUID
  let textRoot: PersistentTextNode?
  let createdAt: Date?
  let lastEditedAt: Date?
  var length: Int { textRoot?.count ?? 0 }
  init(id: UUID = UUID(), text: String, createdAt: Date? = nil, lastEditedAt: Date? = nil) {
    self.id = id
    textRoot = PersistentTextNode.build(Array(text.utf16))
    self.createdAt = createdAt
    self.lastEditedAt = lastEditedAt
  }
  init(id: UUID, textRoot: PersistentTextNode?, createdAt: Date?, lastEditedAt: Date?) {
    self.id = id
    self.textRoot = textRoot
    self.createdAt = createdAt
    self.lastEditedAt = lastEditedAt
  }
  func metadata(at location: Int) -> LineMeta {
    LineMeta(
      id: id, location: location, length: length, createdAt: createdAt, lastEditedAt: lastEditedAt)
  }
}

final class LineIndexNode: Sendable {
  private let lifetime: DocumentStorageLifetime?
  let id: LineIndexKey
  let generation: UUID
  let records: [IndexedLine]
  let children: [LineIndexNode]
  let units: Int
  let count: Int
  let height: Int
  init(id: LineIndexKey, generation: UUID, records: [IndexedLine]) {
    lifetime = .track(bytes: 80 + records.count * MemoryLayout<IndexedLine>.stride)
    self.id = id
    self.generation = generation
    self.records = records
    children = []
    units = records.reduce(0) { $0 + $1.length }
    count = records.count
    height = 0
  }
  init(id: LineIndexKey, generation: UUID, children: [LineIndexNode]) {
    lifetime = .track(bytes: 80 + children.count * MemoryLayout<LineIndexNode>.stride)
    precondition(!children.isEmpty)
    precondition(children.allSatisfy { $0.height == children[0].height })
    self.id = id
    self.generation = generation
    records = []
    self.children = children
    units = children.reduce(0) { $0 + $1.units }
    count = children.reduce(0) { $0 + $1.count }
    height = children[0].height + 1
  }
}

/// One mutable builder publishes immutable roots plus an immutable parent/ID map.
struct PersistentLineIndex: Sendable {
  private let fanout = 16
  private let leafCapacity = 16
  private(set) var root: LineIndexNode?
  private(set) var addresses: LineIndexRadix?
  private var generation = UUID()
  private var removed = Set<LineIndexKey>()
  private var removedRecords = Set<UUID>()

  private mutating func node(records: [IndexedLine]) -> LineIndexNode {
    DocumentInstrumentation.count(.allocatedIndexNodes)
    DocumentInstrumentation.count(
      .allocatedPayloadBytes, 80 + records.count * MemoryLayout<IndexedLine>.stride)
    return LineIndexNode(
      id: LineIndexKey(UUID(), isNode: true), generation: generation, records: records)
  }
  private mutating func node(children: [LineIndexNode]) -> LineIndexNode {
    DocumentInstrumentation.count(.allocatedIndexNodes)
    DocumentInstrumentation.count(
      .allocatedPayloadBytes, 80 + children.count * MemoryLayout<LineIndexNode>.stride)
    return LineIndexNode(
      id: LineIndexKey(UUID(), isNode: true), generation: generation, children: children)
  }
  private mutating func retire(_ node: LineIndexNode) {
    removed.insert(node.id)
    DocumentInstrumentation.count(.visitedLines, node.records.count)
    removedRecords.formUnion(node.records.map(\.id))
  }
  private mutating func build(_ records: [IndexedLine]) -> LineIndexNode? {
    if records.isEmpty { return nil }
    var level: [LineIndexNode] = []
    for offset in stride(from: 0, to: records.count, by: leafCapacity) {
      level.append(
        node(records: Array(records[offset..<min(records.count, offset + leafCapacity)])))
    }
    while level.count > 1 {
      var next: [LineIndexNode] = []
      for offset in stride(from: 0, to: level.count, by: fanout) {
        next.append(node(children: Array(level[offset..<min(level.count, offset + fanout)])))
      }
      level = next
    }
    return level[0]
  }
  private mutating func split(_ root: LineIndexNode?, at ordinal: Int) -> (
    LineIndexNode?, LineIndexNode?
  ) {
    guard let root else { return (nil, nil) }
    if ordinal == 0 { return (nil, root) }
    if ordinal == root.count { return (root, nil) }
    precondition(ordinal > 0 && ordinal < root.count)
    retire(root)
    if root.height == 0 {
      return (
        node(records: Array(root.records[..<ordinal])),
        node(records: Array(root.records[ordinal...]))
      )
    }
    var prefix = 0
    for (index, child) in root.children.enumerated() {
      if ordinal <= prefix + child.count {
        let (left, right) = split(child, at: ordinal - prefix)
        var a = Array(root.children[..<index])
        if let left { a.append(left) }
        var b: [LineIndexNode] = []
        if let right { b.append(right) }
        b.append(contentsOf: root.children[(index + 1)...])
        return (a.isEmpty ? nil : node(children: a), b.isEmpty ? nil : node(children: b))
      }
      prefix += child.count
    }
    preconditionFailure()
  }
  /// Returns one or two roots of equal height; overflow propagates on the boundary path.
  private mutating func joined(_ a: LineIndexNode, _ b: LineIndexNode) -> [LineIndexNode] {
    if a.height == b.height {
      retire(a)
      retire(b)
      if a.height == 0 {
        let records = a.records + b.records
        if records.count <= leafCapacity { return [node(records: records)] }
        let middle = records.count / 2
        return [node(records: Array(records[..<middle])), node(records: Array(records[middle...]))]
      }
      // Rebalance the split boundary recursively instead of accumulating unary paths.
      let middle = joined(a.children.last!, b.children.first!)
      return packed(Array(a.children.dropLast()) + middle + Array(b.children.dropFirst()))
    }
    if a.height > b.height {
      retire(a)
      return packed(Array(a.children.dropLast()) + joined(a.children.last!, b))
    }
    retire(b)
    return packed(joined(a, b.children.first!) + Array(b.children.dropFirst()))
  }
  private mutating func packed(_ children: [LineIndexNode]) -> [LineIndexNode] {
    if children.count <= fanout { return [node(children: children)] }
    let middle = children.count / 2
    return [node(children: Array(children[..<middle])), node(children: Array(children[middle...]))]
  }
  private mutating func join(_ a: LineIndexNode?, _ b: LineIndexNode?) -> LineIndexNode? {
    guard let a else { return b }
    guard let b else { return a }
    let roots = joined(a, b)
    var result = roots.count == 1 ? roots[0] : node(children: roots)
    while result.children.count == 1 {
      retire(result)
      result = result.children[0]
    }
    return result
  }
  private mutating func index(
    _ node: LineIndexNode, parent: LineIndexKey?, units: Int, ordinal: Int
  ) {
    addresses = LineIndexRadix.put(
      addresses, key: node.id,
      value: LineIndexAddress(parent: parent, units: units, ordinal: ordinal))
    guard node.generation == generation else { return }
    DocumentInstrumentation.count(.visitedLines, node.records.count)
    var offset = 0, count = 0
    for record in node.records {
      addresses = LineIndexRadix.put(
        addresses, key: LineIndexKey(record.id),
        value: LineIndexAddress(parent: node.id, units: offset, ordinal: count))
      removedRecords.remove(record.id)
      offset += record.length
      count += 1
    }
    for child in node.children {
      index(child, parent: node.id, units: offset, ordinal: count)
      offset += child.units
      count += child.count
    }
  }
  mutating func replace(_ range: Range<Int>, with records: [IndexedLine]) throws {
    guard range.lowerBound >= 0 && range.upperBound <= (root?.count ?? 0) else {
      throw DocumentError.invalidRange
    }
    var incoming = Set<UUID>()
    for record in records {
      guard incoming.insert(record.id).inserted else { throw DocumentError.invalidState }
      if let existing = resolve(record.id), !range.contains(existing.ordinal) {
        throw DocumentError.invalidState
      }
    }
    generation = UUID()
    removed = []
    removedRecords = []
    if range.lowerBound == 0, range.upperBound == count {
      // Decoding and explicit whole-document replacement need no persistent
      // intermediate radix versions. Construct each final address node once.
      root = build(records)
      var entries: [(LineIndexKey, LineIndexAddress)] = []
      func collect(_ node: LineIndexNode, parent: LineIndexKey?, units: Int, ordinal: Int) {
        entries.append((node.id, LineIndexAddress(parent: parent, units: units, ordinal: ordinal)))
        DocumentInstrumentation.count(.visitedLines, node.records.count)
        var offset = 0, number = 0
        for record in node.records {
          entries.append(
            (
              LineIndexKey(record.id),
              LineIndexAddress(parent: node.id, units: offset, ordinal: number)
            ))
          offset += record.length
          number += 1
        }
        for child in node.children {
          collect(child, parent: node.id, units: offset, ordinal: number)
          offset += child.units
          number += child.count
        }
      }
      if let root { collect(root, parent: nil, units: 0, ordinal: 0) }
      addresses = LineIndexRadix.bulk(entries)
      return
    }
    let (left, tail) = split(root, at: range.lowerBound)
    let (deleted, right) = split(tail, at: range.count)
    func collect(_ node: LineIndexNode?) -> [LineIndexKey] {
      guard let node else { return [] }
      return [node.id] + node.records.map { LineIndexKey($0.id) }
        + node.children.flatMap { collect($0) }
    }
    for key in collect(deleted) {
      addresses = LineIndexRadix.put(addresses, key: key, value: nil)
    }
    let insertion = build(records)
    root = join(join(left, insertion), right)
    for key in removed { addresses = LineIndexRadix.put(addresses, key: key, value: nil) }
    if let root { index(root, parent: nil, units: 0, ordinal: 0) }
    for key in removedRecords {
      addresses = LineIndexRadix.put(addresses, key: LineIndexKey(key), value: nil)
    }
    removed = []
    removedRecords = []
  }
  func flatten() -> [IndexedLine] {
    func visit(_ node: LineIndexNode?) -> [IndexedLine] {
      guard let node else { return [] }
      if node.height == 0 { return node.records }
      return node.children.flatMap { visit($0) }
    }
    return visit(root)
  }
  func resolve(_ id: UUID) -> (units: Int, ordinal: Int)? {
    var cursor: LineIndexKey? = LineIndexKey(id)
    var offset = 0, ordinal = 0, steps = 0
    while let key = cursor {
      guard let address = LineIndexRadix.get(addresses, key: key) else { return nil }
      offset += address.units
      ordinal += address.ordinal
      cursor = address.parent
      steps += 1
      precondition(steps <= (root?.height ?? 0) + 2)
    }
    return (offset, ordinal)
  }
  func record(at offset: Int) -> IndexedLine? {
    guard var current = root, offset >= 0, offset < current.units else { return nil }
    var remaining = offset
    while !current.children.isEmpty {
      var selected: LineIndexNode?
      for child in current.children {
        if remaining < child.units {
          selected = child
          break
        }
        remaining -= child.units
      }
      current = selected!
    }
    for record in current.records {
      if remaining < record.length { return record }
      remaining -= record.length
    }
    return nil
  }
}

extension PersistentLineIndex {
  var count: Int { root?.count ?? 0 }
  var utf16Count: Int { root?.units ?? 0 }

  func line(at ordinal: Int) -> (record: IndexedLine, location: Int)? {
    guard var node = root, ordinal >= 0, ordinal < node.count else { return nil }
    var remaining = ordinal, location = 0
    while !node.children.isEmpty {
      DocumentInstrumentation.count(.visitedIndexNodes)
      for child in node.children {
        if remaining < child.count {
          node = child
          break
        }
        remaining -= child.count
        location += child.units
      }
    }
    DocumentInstrumentation.count(.visitedIndexNodes)
    DocumentInstrumentation.count(.visitedLines, remaining + 1)
    for record in node.records.prefix(remaining) { location += record.length }
    return (node.records[remaining], location)
  }

  func line(id: UUID) -> LineMeta? {
    guard let position = resolve(id), let value = line(at: position.ordinal) else { return nil }
    return value.record.metadata(at: position.units)
  }

  func line(containing offset: Int) -> (ordinal: Int, metadata: LineMeta)? {
    guard offset >= 0, offset <= utf16Count, var node = root else { return nil }
    if offset == utf16Count {
      guard let value = line(at: count - 1) else { return nil }
      return (count - 1, value.record.metadata(at: value.location))
    }
    var remaining = offset, ordinal = 0, location = 0
    while !node.children.isEmpty {
      DocumentInstrumentation.count(.visitedIndexNodes)
      for child in node.children {
        if remaining < child.units {
          node = child
          break
        }
        remaining -= child.units
        location += child.units
        ordinal += child.count
      }
    }
    DocumentInstrumentation.count(.visitedIndexNodes)
    for record in node.records {
      DocumentInstrumentation.count(.visitedLines)
      if remaining < record.length { return (ordinal, record.metadata(at: location)) }
      remaining -= record.length
      location += record.length
      ordinal += 1
    }
    return nil
  }

  /// Deliberate full traversal for persistence, diagnostics and reference comparison.
  func materializedLines() -> [LineMeta] {
    DocumentInstrumentation.count(.flattenCalls)
    var location = 0
    return flatten().map { record in
      DocumentInstrumentation.count(.visitedLines)
      defer { location += record.length }
      return record.metadata(at: location)
    }
  }

  func utf16(in range: NSRange) throws -> [UInt16] {
    guard range.location >= 0, range.length >= 0, range.location <= utf16Count,
      range.length <= utf16Count - range.location
    else { throw DocumentError.invalidRange }
    var units: [UInt16] = []
    units.reserveCapacity(range.length)
    let end = range.location + range.length
    func visit(_ node: LineIndexNode, at start: Int) {
      guard range.length > 0, start < end, start + node.units > range.location else { return }
      DocumentInstrumentation.count(.visitedIndexNodes)
      var cursor = start
      for child in node.children {
        visit(child, at: cursor)
        cursor += child.units
      }
      for record in node.records {
        if cursor < end && cursor + record.length > range.location {
          DocumentInstrumentation.count(.visitedLines)
          record.textRoot?.append(
            max(0, range.location - cursor)..<min(record.length, end - cursor),
            into: &units)
        }
        cursor += record.length
      }
    }
    if let root { visit(root, at: 0) }
    return units
  }

  func materializedText() -> String {
    DocumentInstrumentation.count(.flattenCalls)
    DocumentInstrumentation.count(.flattenedUTF16Units, utf16Count)
    return String(
      decoding: try! utf16(in: NSRange(location: 0, length: utf16Count)), as: UTF16.self)
  }
}

extension PersistentLineIndex {
  struct RecordIterator: IteratorProtocol {
    private var nodes: [LineIndexNode]
    private var leaf: LineIndexNode?
    private var offset = 0
    init(_ root: LineIndexNode?) { nodes = root.map { [$0] } ?? [] }
    mutating func next() -> IndexedLine? {
      if let leaf, offset < leaf.records.count {
        defer { offset += 1 }
        return leaf.records[offset]
      }
      while let node = nodes.popLast() {
        if node.height == 0 {
          leaf = node
          offset = 1
          return node.records.first
        }
        nodes.append(contentsOf: node.children.reversed())
      }
      return nil
    }
  }

  func hasEqualContent(to other: PersistentLineIndex) -> Bool {
    if root === other.root { return true }
    guard count == other.count, utf16Count == other.utf16Count else { return false }
    var left = RecordIterator(root), right = RecordIterator(other.root)
    while let a = left.next(), let b = right.next() {
      guard a.id == b.id, a.createdAt == b.createdAt, a.lastEditedAt == b.lastEditedAt,
        a.length == b.length
      else { return false }
      if a.textRoot !== b.textRoot {
        var x = PersistentTextNode.UnitIterator(a.textRoot)
        var y = PersistentTextNode.UnitIterator(b.textRoot)
        while let unit = x.next() { if unit != y.next() { return false } }
      }
    }
    return true
  }
}
