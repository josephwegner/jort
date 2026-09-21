import Foundation

/// Counts distinct immutable storage across bounded consumers. Shared subtrees are
/// charged once; subsequent roots visit only newly retained paths. No live-model
/// references are stored in this ledger.
@MainActor public final class DocumentRetainedStorage {
  private enum Node {
    case line(LineIndexNode), radix(LineIndexRadix), text(PersistentTextNode)
    var identity: ObjectIdentifier {
      switch self {
      case .line(let node): ObjectIdentifier(node)
      case .radix(let node): ObjectIdentifier(node)
      case .text(let node): ObjectIdentifier(node)
      }
    }
    var bytes: Int {
      switch self {
      case .line(let node):
        80 + node.records.count * MemoryLayout<IndexedLine>.stride
          + node.children.count * MemoryLayout<LineIndexNode>.stride
      case .radix(let node):
        node.key == nil ? 48 + node.children.count * MemoryLayout<LineIndexRadix?>.stride : 96
      case .text(let node): 80 + node.units.count * MemoryLayout<UInt16>.stride
      }
    }
    var children: [Node] {
      switch self {
      case .line(let node):
        node.children.map(Node.line) + node.records.compactMap { $0.textRoot.map(Node.text) }
      case .radix(let node): node.children.compactMap { $0.map(Node.radix) }
      case .text(let node): [node.left, node.right].compactMap { $0.map(Node.text) }
      }
    }
  }
  private var references: [ObjectIdentifier: Int] = [:]
  public private(set) var estimatedBytes = 0
  public var nodeCount: Int { references.count }
  public init() {}
  public func retain(_ snapshot: DocumentSnapshot) {
    guard let index = try? snapshot.indexed() else { return }
    estimatedBytes += Self.annotationBytes(snapshot)
    if let root = index.root { retain(.line(root)) }
    if let root = index.addresses { retain(.radix(root)) }
  }
  public func release(_ snapshot: DocumentSnapshot) {
    guard let index = try? snapshot.indexed() else { return }
    estimatedBytes -= Self.annotationBytes(snapshot)
    if let root = index.root { release(.line(root)) }
    if let root = index.addresses { release(.radix(root)) }
  }
  /// Annotation arrays use conservative per-snapshot charging because their
  /// Foundation copy-on-write allocation identities are not exposed.
  private static func annotationBytes(_ snapshot: DocumentSnapshot) -> Int {
    var bytes =
      snapshot.landmarks.count * MemoryLayout<Landmark>.stride
      + snapshot.invocations.count * MemoryLayout<ToolInvocation>.stride
    bytes += snapshot.landmarks.reduce(0) { $0 + $1.emoji.utf16.count * 2 }
    for invocation in snapshot.invocations {
      let strings: [String?] = [
        invocation.packageID, invocation.executor, invocation.inputMode,
        invocation.outputOperation, invocation.command, invocation.sourceHash,
        invocation.outputHash, invocation.message,
      ]
      bytes += strings.reduce(0) { $0 + ($1?.utf16.count ?? 0) * 2 }
      if let restoration = invocation.restoration {
        let strings: [String?] = [
          restoration.packageID, restoration.executor, restoration.inputMode,
          restoration.outputOperation, restoration.command, restoration.sourceHash,
          restoration.message,
        ]
        bytes += strings.reduce(0) { $0 + ($1?.utf16.count ?? 0) * 2 }
      }
    }
    return bytes
  }
  private func retain(_ node: Node) {
    DocumentInstrumentation.count(.visitedIndexNodes)
    let id = node.identity
    let count = references[id, default: 0]
    references[id] = count + 1
    guard count == 0 else { return }
    estimatedBytes += node.bytes
    for child in node.children { retain(child) }
  }
  private func release(_ node: Node) {
    DocumentInstrumentation.count(.visitedIndexNodes)
    let id = node.identity
    guard let count = references[id] else { preconditionFailure("Unbalanced storage release") }
    if count > 1 {
      references[id] = count - 1
      return
    }
    references[id] = nil
    estimatedBytes -= node.bytes
    for child in node.children { release(child) }
  }
}
