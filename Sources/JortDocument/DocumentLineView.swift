import Foundation

/// Read-only indexed projection. Flat arrays are an explicit compatibility boundary.
public struct DocumentLineView: RandomAccessCollection, Equatable, Sendable {
  public typealias Index = Int
  public typealias Element = LineMeta
  private let index: PersistentLineIndex?
  private let flat: [LineMeta]
  init(_ index: PersistentLineIndex) {
    self.index = index
    flat = []
  }
  public init(_ lines: [LineMeta]) {
    index = nil
    flat = lines
  }
  public var startIndex: Int { 0 }
  public var endIndex: Int { index?.count ?? flat.count }
  public subscript(position: Int) -> LineMeta {
    if let index {
      precondition(position >= 0 && position < index.count)
      let value = index.line(at: position)!
      return value.record.metadata(at: value.location)
    }
    return flat[position]
  }
  public func line(id: UUID) -> LineMeta? {
    index?.line(id: id) ?? (index == nil ? flat.first { $0.id == id } : nil)
  }
  public func ordinal(of id: UUID) -> Int? {
    index?.resolve(id)?.ordinal ?? (index == nil ? flat.firstIndex { $0.id == id } : nil)
  }
  public func line(containing offset: Int) -> LineMeta? {
    if let index { return index.line(containing: offset)?.metadata }
    return flat.last { $0.location <= offset && offset <= $0.location + $0.length }
  }
  public struct Iterator: IteratorProtocol {
    private var indexed: PersistentLineIndex.RecordIterator?
    private var flat: IndexingIterator<[LineMeta]>
    private var location = 0
    fileprivate init(index: PersistentLineIndex?, flat: [LineMeta]) {
      indexed = index.map { PersistentLineIndex.RecordIterator($0.root) }
      self.flat = flat.makeIterator()
    }
    public mutating func next() -> LineMeta? {
      if indexed != nil {
        guard let record = indexed?.next() else { return nil }
        DocumentInstrumentation.count(.visitedLines)
        defer { location += record.length }
        return record.metadata(at: location)
      }
      return flat.next()
    }
  }
  public func makeIterator() -> Iterator { Iterator(index: index, flat: flat) }
  public func materialized() -> [LineMeta] {
    DocumentInstrumentation.count(.flattenCalls)
    return Array(self)
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.count == rhs.count else { return false }
    if let a = lhs.index, let b = rhs.index, a.root === b.root { return true }
    return lhs.elementsEqual(rhs)
  }
}
