import Foundation

final class PersistentTextNode: Sendable {
  private let lifetime: DocumentStorageLifetime?
  static let capacity = 2048
  let units: [UInt16]
  let left: PersistentTextNode?
  let right: PersistentTextNode?
  let count: Int
  let height: Int
  let first: UInt16?
  let last: UInt16?
  init(_ units: [UInt16]) {
    lifetime = .track(bytes: 80 + units.count * MemoryLayout<UInt16>.stride)
    precondition(units.count <= Self.capacity)
    DocumentInstrumentation.count(.allocatedChunks)
    DocumentInstrumentation.count(.allocatedPayloadBytes, units.count * MemoryLayout<UInt16>.stride)
    self.units = units
    left = nil
    right = nil
    count = units.count
    height = 0
    first = units.first
    last = units.last
  }
  init(_ left: PersistentTextNode, _ right: PersistentTextNode) {
    lifetime = .track(bytes: 80)
    DocumentInstrumentation.count(.allocatedIndexNodes)
    units = []
    self.left = left
    self.right = right
    count = left.count + right.count
    height = max(left.height, right.height) + 1
    first = left.first
    last = right.last
  }
  static func balanced(_ a: PersistentTextNode, _ b: PersistentTextNode) -> PersistentTextNode {
    if a.height > b.height + 1 {
      let l = a.left!, r = a.right!
      if l.height >= r.height { return PersistentTextNode(l, PersistentTextNode(r, b)) }
      return PersistentTextNode(PersistentTextNode(l, r.left!), PersistentTextNode(r.right!, b))
    }
    if b.height > a.height + 1 {
      let l = b.left!, r = b.right!
      if r.height >= l.height { return PersistentTextNode(PersistentTextNode(a, l), r) }
      return PersistentTextNode(PersistentTextNode(a, l.left!), PersistentTextNode(l.right!, r))
    }
    return PersistentTextNode(a, b)
  }
  static func joined(_ a: PersistentTextNode?, _ b: PersistentTextNode?) -> PersistentTextNode? {
    guard let a else { return b }
    guard let b else { return a }
    if a.height == 0 && b.height == 0 && a.count + b.count <= capacity {
      return PersistentTextNode(a.units + b.units)
    }
    if a.height > b.height + 1 { return balanced(a.left!, joined(a.right, b)!) }
    if b.height > a.height + 1 { return balanced(joined(a, b.left)!, b.right!) }
    return PersistentTextNode(a, b)
  }
  static func build(_ units: [UInt16]) -> PersistentTextNode? {
    if units.isEmpty { return nil }
    if units.count <= capacity { return PersistentTextNode(units) }
    var middle = units.count / 2
    // Keep complete surrogate pairs and CRLF together at initial chunk boundaries.
    if (0xD800...0xDBFF).contains(units[middle - 1]) && (0xDC00...0xDFFF).contains(units[middle])
      || units[middle - 1] == 13 && units[middle] == 10
    {
      middle -= 1
    }
    return PersistentTextNode(build(Array(units[..<middle]))!, build(Array(units[middle...]))!)
  }
  static func split(_ root: PersistentTextNode?, at offset: Int) -> (
    PersistentTextNode?, PersistentTextNode?
  ) {
    DocumentInstrumentation.count(.visitedIndexNodes)
    guard let root else {
      precondition(offset == 0)
      return (nil, nil)
    }
    precondition(offset >= 0 && offset <= root.count)
    if offset == 0 { return (nil, root) }
    if offset == root.count { return (root, nil) }
    if root.height == 0 {
      return (
        PersistentTextNode(Array(root.units[..<offset])),
        PersistentTextNode(Array(root.units[offset...]))
      )
    }
    if offset < root.left!.count {
      let (a, b) = split(root.left, at: offset)
      return (a, joined(b, root.right))
    }
    let (a, b) = split(root.right, at: offset - root.left!.count)
    return (joined(root.left, a), b)
  }
  static func replacing(_ root: PersistentTextNode?, range: Range<Int>, with units: [UInt16])
    -> PersistentTextNode?
  {
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
  /// Append only intersecting chunks. Ranges are exact UTF-16 positions.
  func append(_ range: Range<Int>, into result: inout [UInt16]) {
    precondition(range.lowerBound >= 0 && range.upperBound <= count)
    guard !range.isEmpty else { return }
    DocumentInstrumentation.count(.visitedIndexNodes)
    if height == 0 {
      DocumentInstrumentation.count(.visitedChunks)
      result.append(contentsOf: units[range])
      return
    }
    let boundary = left!.count
    if range.lowerBound < boundary {
      left!.append(range.lowerBound..<min(range.upperBound, boundary), into: &result)
    }
    if range.upperBound > boundary {
      right!.append(
        max(0, range.lowerBound - boundary)..<(range.upperBound - boundary), into: &result)
    }
  }
}

extension PersistentTextNode {
  struct UnitIterator: IteratorProtocol {
    private var nodes: [PersistentTextNode]
    private var leaf: PersistentTextNode?
    private var offset = 0
    init(_ root: PersistentTextNode?) { nodes = root.map { [$0] } ?? [] }
    mutating func next() -> UInt16? {
      if let leaf, offset < leaf.units.count {
        defer { offset += 1 }
        return leaf.units[offset]
      }
      while let node = nodes.popLast() {
        if node.height == 0 {
          guard !node.units.isEmpty else { continue }
          leaf = node
          offset = 1
          return node.units[0]
        }
        nodes.append(node.right!)
        nodes.append(node.left!)
      }
      return nil
    }
  }
}
