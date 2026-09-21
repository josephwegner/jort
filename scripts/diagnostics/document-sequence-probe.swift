// A bounded representation spike, independent of the live document model.
// Run through scripts/benchmark-document-sequence.py after the baseline completes.
import Foundation
import Darwin

struct Work {
  var nodes = 0
  var bytes = 0
  var lookups = 0
}

// Deterministic full-width identities for reproducible UUID-sized storage measurements.
func mixed(_ key: UInt64) -> UInt64 {
  var value = key &+ 0x9e3779b97f4a7c15
  value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
  value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
  return value ^ (value >> 31)
}

struct Key: Hashable, Sendable {
  let high: UInt64
  let low: UInt64
  static let zero = Key(high: 0, low: 0)
  init(_ serial: UInt64) {
    high = mixed(serial ^ 0xa54ff53a5f1d36f1)
    low = mixed(serial)
  }
  private init(high: UInt64, low: UInt64) {
    self.high = high
    self.low = low
  }
  func slot(_ depth: Int) -> Int {
    precondition(depth < 32)
    let word = depth < 16 ? high : low
    return Int((word >> ((depth % 16) * 4)) & 15)
  }
}

struct Address: Sendable {
  let parent: Key
  let units: Int
  let ordinal: Int
}

/// Persistent radix map. Branching is bounded at sixteen and depth at thirty-two.
final class Radix: Sendable {
  let key: Key?
  let value: Address?
  let children: [Radix?]
  init(key: Key, value: Address) {
    self.key = key
    self.value = value
    children = []
  }
  init(children: [Radix?]) {
    key = nil
    value = nil
    self.children = children
  }
  static func get(_ node: Radix?, key: Key, depth: Int = 0, work: inout Work) -> Address? {
    guard let node else { return nil }
    work.lookups += 1
    if let stored = node.key { return stored == key ? node.value : nil }
    return get(
      node.children[key.slot(depth)],
      key: key, depth: depth + 1, work: &work)
  }
  static func put(
    _ node: Radix?, key: Key, value: Address?, depth: Int = 0,
    work: inout Work
  ) -> Radix? {
    guard let node else {
      guard let value else { return nil }
      work.nodes += 1
      work.bytes += 96
      return Radix(key: key, value: value)
    }
    if let stored = node.key {
      if stored == key {
        guard let value else { return nil }
        work.nodes += 1
        work.bytes += 96
        return Radix(key: key, value: value)
      }
      guard value != nil else { return node }
      precondition(depth < 32)
      var children = [Radix?](repeating: nil, count: 16)
      children[stored.slot(depth)] = node
      let slot = key.slot(depth)
      children[slot] = put(children[slot], key: key, value: value, depth: depth + 1, work: &work)
      work.nodes += 1
      work.bytes += 16 * MemoryLayout<Radix?>.stride + 48
      return Radix(children: children)
    }
    let slot = key.slot(depth)
    var children = node.children
    children[slot] = put(children[slot], key: key, value: value, depth: depth + 1, work: &work)
    let remaining = children.compactMap { $0 }
    if remaining.isEmpty { return nil }
    if remaining.count == 1, remaining[0].key != nil { return remaining[0] }
    work.nodes += 1
    work.bytes += 16 * MemoryLayout<Radix?>.stride + 48
    return Radix(children: children)
  }
}

/// Immutable bounded UTF-16 chunks; balancing shares every untouched branch.
final class TextNode: Sendable {
  static let capacity = 2048
  let units: [UInt16]
  let left: TextNode?
  let right: TextNode?
  let count: Int
  let height: Int
  let first: UInt16?
  let last: UInt16?
  init(_ units: [UInt16]) {
    precondition(units.count <= Self.capacity)
    self.units = units
    left = nil
    right = nil
    count = units.count
    height = 0
    first = units.first
    last = units.last
  }
  init(_ left: TextNode, _ right: TextNode) {
    units = []
    self.left = left
    self.right = right
    count = left.count + right.count
    height = max(left.height, right.height) + 1
    first = left.first
    last = right.last
  }
  static func balanced(_ a: TextNode, _ b: TextNode) -> TextNode {
    if a.height > b.height + 1 {
      let l = a.left!, r = a.right!
      if l.height >= r.height { return TextNode(l, TextNode(r, b)) }
      return TextNode(TextNode(l, r.left!), TextNode(r.right!, b))
    }
    if b.height > a.height + 1 {
      let l = b.left!, r = b.right!
      if r.height >= l.height { return TextNode(TextNode(a, l), r) }
      return TextNode(TextNode(a, l.left!), TextNode(l.right!, r))
    }
    return TextNode(a, b)
  }
  static func joined(_ a: TextNode?, _ b: TextNode?) -> TextNode? {
    guard let a else { return b }
    guard let b else { return a }
    if a.height == 0 && b.height == 0 && a.count + b.count <= capacity {
      return TextNode(a.units + b.units)
    }
    if a.height > b.height + 1 { return balanced(a.left!, joined(a.right, b)!) }
    if b.height > a.height + 1 { return balanced(joined(a, b.left)!, b.right!) }
    return TextNode(a, b)
  }
  static func build(_ units: [UInt16]) -> TextNode? {
    if units.isEmpty { return nil }
    if units.count <= capacity { return TextNode(units) }
    var middle = units.count / 2
    // Keep complete surrogate pairs and CRLF together at initial chunk boundaries.
    if (0xD800...0xDBFF).contains(units[middle - 1]) && (0xDC00...0xDFFF).contains(units[middle])
      || units[middle - 1] == 13 && units[middle] == 10
    {
      middle -= 1
    }
    return TextNode(build(Array(units[..<middle]))!, build(Array(units[middle...]))!)
  }
  static func split(_ root: TextNode?, at offset: Int) -> (TextNode?, TextNode?) {
    guard let root else {
      precondition(offset == 0)
      return (nil, nil)
    }
    precondition(offset >= 0 && offset <= root.count)
    if offset == 0 { return (nil, root) }
    if offset == root.count { return (root, nil) }
    if root.height == 0 {
      return (TextNode(Array(root.units[..<offset])), TextNode(Array(root.units[offset...])))
    }
    if offset < root.left!.count {
      let (a, b) = split(root.left, at: offset)
      return (a, joined(b, root.right))
    }
    let (a, b) = split(root.right, at: offset - root.left!.count)
    return (joined(root.left, a), b)
  }
  static func replacing(_ root: TextNode?, range: Range<Int>, with units: [UInt16]) -> TextNode? {
    let (a, tail) = split(root, at: range.lowerBound)
    let (_, b) = split(tail, at: range.count)
    return joined(joined(a, build(units)), b)
  }
  func flatten(into result: inout [UInt16]) {
    if height == 0 {
      result.append(contentsOf: units)
    } else {
      left!.flatten(into: &result)
      right!.flatten(into: &result)
    }
  }
  func validate() {
    if height == 0 {
      precondition(
        left == nil && right == nil && units.count <= Self.capacity && count == units.count)
    } else {
      precondition(abs(left!.height - right!.height) <= 1)
      precondition(count == left!.count + right!.count)
      precondition(height == max(left!.height, right!.height) + 1)
      left!.validate()
      right!.validate()
    }
  }
}

struct Record: Sendable {
  let id: Key
  let root: TextNode?
  var length: Int { root?.count ?? 0 }
  var text: [UInt16] {
    var result: [UInt16] = []
    result.reserveCapacity(length)
    root?.flatten(into: &result)
    return result
  }
  init(id: Key, text: [UInt16]) {
    self.id = id
    root = TextNode.build(text)
  }
  private init(id: Key, root: TextNode?) {
    self.id = id
    self.root = root
  }
  func appending(_ unit: UInt16) -> Record {
    Record(id: id, root: TextNode.joined(root, TextNode([unit])))
  }
}

/// Immutable augmented chunked sequence with bounded fanout/leaf capacity.
final class Node: Sendable {
  let id: Key
  let generation: Int
  let records: [Record]
  let children: [Node]
  let units: Int
  let count: Int
  let height: Int
  init(id: Key, generation: Int, records: [Record]) {
    self.id = id
    self.generation = generation
    self.records = records
    children = []
    units = records.reduce(0) { $0 + $1.length }
    count = records.count
    height = 0
  }
  init(id: Key, generation: Int, children: [Node]) {
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
struct SequenceIndex {
  let fanout: Int
  let leafCapacity: Int
  var root: Node?
  var addresses: Radix?
  var generation = 0
  var nextNodeID = UInt64.max
  var removed = Set<Key>()
  var removedRecords = Set<Key>()
  var work = Work()

  mutating func node(records: [Record]) -> Node {
    defer { nextNodeID -= 1 }
    work.nodes += 1
    work.bytes += 80 + records.count * MemoryLayout<Record>.stride
    return Node(id: Key(nextNodeID), generation: generation, records: records)
  }
  mutating func node(children: [Node]) -> Node {
    defer { nextNodeID -= 1 }
    work.nodes += 1
    work.bytes += 80 + children.count * MemoryLayout<Node>.stride
    return Node(id: Key(nextNodeID), generation: generation, children: children)
  }
  mutating func retire(_ node: Node) {
    removed.insert(node.id)
    removedRecords.formUnion(node.records.map(\.id))
  }
  mutating func build(_ records: [Record]) -> Node? {
    if records.isEmpty { return nil }
    var level: [Node] = []
    for offset in stride(from: 0, to: records.count, by: leafCapacity) {
      level.append(
        node(records: Array(records[offset..<min(records.count, offset + leafCapacity)])))
    }
    while level.count > 1 {
      var next: [Node] = []
      for offset in stride(from: 0, to: level.count, by: fanout) {
        next.append(node(children: Array(level[offset..<min(level.count, offset + fanout)])))
      }
      level = next
    }
    return level[0]
  }
  mutating func split(_ root: Node?, at ordinal: Int) -> (Node?, Node?) {
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
        var b: [Node] = []
        if let right { b.append(right) }
        b.append(contentsOf: root.children[(index + 1)...])
        return (a.isEmpty ? nil : node(children: a), b.isEmpty ? nil : node(children: b))
      }
      prefix += child.count
    }
    preconditionFailure()
  }
  /// Returns one or two roots of equal height; overflow propagates on the boundary path.
  mutating func joined(_ a: Node, _ b: Node) -> [Node] {
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
  mutating func packed(_ children: [Node]) -> [Node] {
    if children.count <= fanout { return [node(children: children)] }
    let middle = children.count / 2
    return [node(children: Array(children[..<middle])), node(children: Array(children[middle...]))]
  }
  mutating func join(_ a: Node?, _ b: Node?) -> Node? {
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
  mutating func index(_ node: Node, parent: Key, units: Int, ordinal: Int) {
    addresses = Radix.put(
      addresses, key: node.id,
      value: Address(parent: parent, units: units, ordinal: ordinal), work: &work)
    guard node.generation == generation else { return }
    var offset = 0, count = 0
    for record in node.records {
      addresses = Radix.put(
        addresses, key: record.id,
        value: Address(parent: node.id, units: offset, ordinal: count), work: &work)
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
  mutating func replace(_ range: Range<Int>, with records: [Record]) {
    precondition(range.lowerBound >= 0 && range.upperBound <= (root?.count ?? 0))
    generation += 1
    removed = []
    removedRecords = []
    let (left, tail) = split(root, at: range.lowerBound)
    let (deleted, right) = split(tail, at: range.count)
    func collect(_ node: Node?) -> [Key] {
      guard let node else { return [] }
      return [node.id] + node.records.map(\.id) + node.children.flatMap { collect($0) }
    }
    for key in collect(deleted) {
      addresses = Radix.put(addresses, key: key, value: nil, work: &work)
    }
    let insertion = build(records)
    root = join(join(left, insertion), right)
    for key in removed { addresses = Radix.put(addresses, key: key, value: nil, work: &work) }
    if let root { index(root, parent: .zero, units: 0, ordinal: 0) }
    for key in removedRecords {
      addresses = Radix.put(addresses, key: key, value: nil, work: &work)
    }
    removed = []
    removedRecords = []
  }
  func flatten() -> [Record] {
    func visit(_ node: Node?) -> [Record] {
      guard let node else { return [] }
      if node.height == 0 { return node.records }
      return node.children.flatMap { visit($0) }
    }
    return visit(root)
  }
  func resolve(_ id: Key, work: inout Work) -> (units: Int, ordinal: Int)? {
    var key = id, offset = 0, ordinal = 0, steps = 0
    while key != .zero {
      guard let address = Radix.get(addresses, key: key, work: &work) else { return nil }
      offset += address.units
      ordinal += address.ordinal
      key = address.parent
      steps += 1
      precondition(steps <= (root?.height ?? 0) + 2)
    }
    return (offset, ordinal)
  }
  func record(at offset: Int) -> Record? {
    guard var current = root, offset >= 0, offset < current.units else { return nil }
    var remaining = offset
    while !current.children.isEmpty {
      var selected: Node?
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

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
func distribution(_ samples: [Double]) -> [String: Double] {
  let sorted = samples.sorted().map { $0 * 1000 }
  func p(_ q: Double) -> Double { sorted[Int(ceil(Double(sorted.count) * q)) - 1] }
  return ["p50Ms": p(0.5), "p95Ms": p(0.95), "p99Ms": p(0.99)]
}
func verify(_ index: SequenceIndex, _ reference: [Record]) {
  func validate(_ node: Node) {
    precondition(node.children.count <= index.fanout && node.records.count <= index.leafCapacity)
    if node.height == 0 {
      precondition(node.count == node.records.count)
      precondition(node.units == node.records.reduce(0) { $0 + $1.length })
      for record in node.records { record.root?.validate() }
    } else {
      precondition(node.children.allSatisfy { $0.height + 1 == node.height })
      precondition(node.count == node.children.reduce(0) { $0 + $1.count })
      precondition(node.units == node.children.reduce(0) { $0 + $1.units })
      node.children.forEach(validate)
    }
  }
  if let root = index.root {
    validate(root)
    precondition(
      root.height <= Int(ceil(log(Double(max(1, root.count))) / log(Double(index.fanout)))) + 1)
  }
  let actual = index.flatten()
  precondition(actual.map(\.id) == reference.map(\.id))
  precondition(actual.flatMap(\.text) == reference.flatMap(\.text))
  var offset = 0, work = Work()
  for (ordinal, record) in reference.enumerated() {
    let position = index.resolve(record.id, work: &work)
    precondition(position?.units == offset && position?.ordinal == ordinal)
    if record.length > 0 { precondition(index.record(at: offset)?.id == record.id) }
    offset += record.length
  }
  precondition((index.root?.units ?? 0) == offset)
}
var longReference = Array(
  String(repeating: "🦊e\u{301}\r\n\u{85}\u{2028}\u{2029}", count: 1000).utf16)
var longRoot = TextNode.build(longReference)
let retainedLongRoot = longRoot
let retainedLongReference = longReference
var ropeSeed: UInt64 = 9
for _ in 0..<500 {
  ropeSeed = mixed(ropeSeed)
  let offset = Int(ropeSeed % UInt64(longReference.count + 1))
  let length = min(Int((ropeSeed >> 20) % 7), longReference.count - offset)
  let replacement: [UInt16] = [120, 13, 10]
  longRoot = TextNode.replacing(longRoot, range: offset..<(offset + length), with: replacement)
  longReference.replaceSubrange(offset..<(offset + length), with: replacement)
  longRoot?.validate()
  var flattened: [UInt16] = []
  longRoot?.flatten(into: &flattened)
  precondition(flattened == longReference)
}
var retainedUnits: [UInt16] = []
retainedLongRoot?.flatten(into: &retainedUnits)
precondition(retainedUnits == retainedLongReference)
weak var releasedRoot: TextNode?
do {
  var temporary = TextNode.build(Array(repeating: UInt16(120), count: 100_000))
  releasedRoot = temporary
  precondition(releasedRoot != nil)
  temporary = nil
}
precondition(releasedRoot == nil)

let arguments = CommandLine.arguments
let fanout = Int(arguments[1])!
let capacity = Int(arguments[2])!
let fixture = try String(contentsOfFile: arguments[3], encoding: .utf8)
let raw = fixture as NSString
var records: [Record] = [], offset = 0, id: UInt64 = 1
while offset < raw.length {
  let range = raw.lineRange(for: NSRange(location: offset, length: 0))
  let units = Array(raw.substring(with: range).utf16)
  records.append(Record(id: Key(id), text: units))
  id += 1
  offset = NSMaxRange(range)
}

if fanout == 0 {
  var retained: [[Record]] = []
  var edits: [Double] = [], ids: [Double] = [], offsets: [Double] = [], captures: [Double] = [],
    flats: [Double] = []
  for iteration in 0..<220 {
    let position = iteration % records.count
    let old = records[position]
    var start = uptime()
    records[position] = old.appending(120)
    let editTime = uptime() - start
    let queried = records[(iteration * 7919) % records.count]
    start = uptime()
    let ordinal = records.firstIndex { $0.id == queried.id }!
    let location = records[..<ordinal].reduce(0) { $0 + $1.length }
    let idTime = uptime() - start
    start = uptime()
    var offset = 0, selected: Key?
    for record in records {
      if location < offset + record.length {
        selected = record.id
        break
      }
      offset += record.length
    }
    precondition(selected == queried.id)
    let offsetTime = uptime() - start
    start = uptime()
    retained.append(records)
    if retained.count > 200 { retained.removeFirst() }
    let snapshotTime = uptime() - start
    if iteration >= 20 {
      edits.append(editTime)
      ids.append(idTime)
      offsets.append(offsetTime)
      captures.append(snapshotTime)
    }
    if iteration % 10 == 0 {
      start = uptime()
      let units = records.flatMap(\.text)
      precondition(!units.isEmpty)
      if iteration >= 20 { flats.append(uptime() - start) }
    }
  }
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  let result: [String: Any] = [
    "fanout": 0, "leafCapacity": 0, "fixtureUTF16Units": raw.length,
    "lineCount": records.count, "warmup": 20, "samples": 200,
    "edit": distribution(edits), "idLookup": distribution(ids),
    "offsetLookup": distribution(offsets), "snapshot": distribution(captures),
    "flatten": distribution(flats), "peakResidentBytes": usage.ru_maxrss,
    "retainedSnapshots": retained.count,
  ]
  let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
  exit(0)
}

var index = SequenceIndex(fanout: fanout, leafCapacity: capacity)
index.replace(0..<0, with: records)
verify(index, records)
let original = index
let originalRecords = records
var seed: UInt64 = 42
// Deterministic state-machine property run, including empty/split/join/deletion cases.
for iteration in 0..<200 {
  seed = mixed(seed)
  let at = Int(seed % UInt64(records.count + 1))
  let deleted = min(Int((seed >> 16) % 4), records.count - at)
  let inserted = Int((seed >> 24) % 4)
  var replacement: [Record] = []
  for _ in 0..<inserted {
    replacement.append(Record(id: Key(id), text: Array("🦊e\u{301}\r\n".utf16)))
    id += 1
  }
  index.replace(at..<(at + deleted), with: replacement)
  records.replaceSubrange(at..<(at + deleted), with: replacement)
  if iteration % 10 == 0 { verify(index, records) }
}
verify(index, records)
verify(original, originalRecords)
func nodeIDs(_ node: Node?) -> Set<Key> {
  guard let node else { return [] }
  return node.children.reduce(into: Set([node.id])) { $0.formUnion(nodeIDs($1)) }
}
let beforeSharing = nodeIDs(index.root)
index.replace(0..<1, with: [records[0]])
let afterSharing = nodeIDs(index.root)
precondition(beforeSharing.intersection(afterSharing).count > beforeSharing.count / 2)
weak var releasedIndexRoot: Node?
do {
  var temporary = SequenceIndex(fanout: fanout, leafCapacity: capacity)
  temporary.replace(0..<0, with: Array(records.prefix(100)))
  releasedIndexRoot = temporary.root
  temporary.replace(0..<1, with: [records[0].appending(120)])
}
precondition(releasedIndexRoot == nil)
let historyCount = 200
var snapshots: [SequenceIndex] = []
var edits: [Double] = [], ids: [Double] = [], offsets: [Double] = [], captures: [Double] = [],
  flats: [Double] = []
var maxNodes = 0, maxBytes = 0
for iteration in 0..<220 {
  let position = iteration % records.count
  let record = records[position]
  index.work = Work()
  var start = uptime()
  index.replace(position..<(position + 1), with: [record.appending(120)])
  let elapsed = uptime() - start
  if iteration >= 20 {
    edits.append(elapsed)
    maxNodes = max(maxNodes, index.work.nodes)
    maxBytes = max(maxBytes, index.work.bytes)
  }
  records[position] = record.appending(120)
  var lookupWork = Work()
  start = uptime()
  let queried = records[(iteration * 7919) % records.count]
  let location = index.resolve(queried.id, work: &lookupWork)!
  let idTime = uptime() - start
  start = uptime()
  precondition(index.record(at: location.units)?.id == queried.id)
  let offsetTime = uptime() - start
  start = uptime()
  snapshots.append(index)
  if snapshots.count > historyCount { snapshots.removeFirst() }
  let captureTime = uptime() - start
  if iteration >= 20 {
    ids.append(idTime)
    offsets.append(offsetTime)
    captures.append(captureTime)
  }
  if iteration % 10 == 0 {
    start = uptime()
    let flattened = index.flatten().flatMap(\.text)
    precondition(flattened.count == index.root!.units)
    if iteration >= 20 { flats.append(uptime() - start) }
  }
}
verify(index, records)
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
let result: [String: Any] = [
  "fanout": fanout, "leafCapacity": capacity, "fixtureUTF16Units": raw.length,
  "lineCount": original.root!.count, "propertySeed": 42, "propertySteps": 200,
  "warmup": 20, "samples": 200, "edit": distribution(edits), "idLookup": distribution(ids),
  "offsetLookup": distribution(offsets), "snapshot": distribution(captures),
  "flatten": distribution(flats), "peakResidentBytes": usage.ru_maxrss,
  "maxAllocatedNodesPerEdit": maxNodes, "maxEstimatedAllocatedBytesPerEdit": maxBytes,
  "height": index.root!.height, "retainedSnapshots": snapshots.count,
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
