import AppKit
import JortDocument

/// Every top-level user group has a unique native undo target, allowing eviction
/// of whole groups without disturbing newer groups or native undo/redo ordering.
@MainActor final class DocumentUndoManager: UndoManager {
  private final class Group {
    var snapshots: [DocumentSnapshot] = []
  }
  private var openGroup: Group?
  private var undoGroups: [Group] = []
  private var redoGroups: [Group] = []
  private let storage = DocumentRetainedStorage()
  var payloadLimit = 256 * 1024 * 1024
  var groupLimit = 200
  var retainedPayloadBytes: Int { storage.estimatedBytes }
  var retainedGroupCount: Int { undoGroups.count + redoGroups.count }

  override func beginUndoGrouping() {
    if groupingLevel == 0, openGroup == nil { openGroup = Group() }
    super.beginUndoGrouping()
  }
  override func endUndoGrouping() {
    super.endUndoGrouping()
    guard groupingLevel == 0, let group = openGroup else { return }
    openGroup = nil
    guard !group.snapshots.isEmpty else { return }
    if isUndoing { redoGroups.append(group) } else { undoGroups.append(group) }
    if !isUndoing && !isRedoing { enforceBudget() }
  }
  func register(
    before: DocumentSnapshot, after: DocumentSnapshot,
    action: @escaping @MainActor () -> Void
  ) {
    guard isUndoRegistrationEnabled else { return }
    if !isUndoing && !isRedoing {
      for group in redoGroups { release(group) }
      redoGroups.removeAll()
    }
    let group = openGroup ?? Group()
    openGroup = group
    for snapshot in [before, after] {
      storage.retain(snapshot)
      group.snapshots.append(snapshot)
    }
    super.registerUndo(withTarget: group) { _ in MainActor.assumeIsolated { action() } }
  }
  override func undo() {
    // UndoManager closes its automatic event group itself. Closing it here
    // breaks its scheduled end-of-event bookkeeping.
    let source = openGroup?.snapshots.isEmpty == false ? openGroup : undoGroups.last
    super.undo()
    if let source, let index = undoGroups.firstIndex(where: { $0 === source }) {
      undoGroups.remove(at: index)
      release(source)
    }
    enforceBudget()
  }
  override func redo() {
    let source = redoGroups.last
    super.redo()
    if let source, let index = redoGroups.firstIndex(where: { $0 === source }) {
      redoGroups.remove(at: index)
      release(source)
    }
    enforceBudget()
  }
  override func removeAllActions() {
    super.removeAllActions()
    for group in undoGroups + redoGroups { release(group) }
    if let openGroup { release(openGroup) }
    undoGroups.removeAll()
    redoGroups.removeAll()
    openGroup = nil
  }
  private func release(_ group: Group) {
    for snapshot in group.snapshots { storage.release(snapshot) }
    group.snapshots.removeAll()
  }
  private func enforceBudget() {
    // Keep the newest complete group even when a single paste exceeds the budget.
    while retainedGroupCount > 1,
      retainedGroupCount > groupLimit || retainedPayloadBytes > payloadLimit
    {
      let group: Group
      if !undoGroups.isEmpty {
        group = undoGroups.removeFirst()
      } else {
        group = redoGroups.removeFirst()
      }
      super.removeAllActions(withTarget: group)
      release(group)
    }
  }
}
