import JortToolContracts
import AppKit
import JortDocument
import JortSettings

@MainActor final class ToolInvocationController {
  weak var editor: EditorViewController?
  var packages: [ToolPackage] = []
  var coordinator: any ToolInvocationCoordinating = UnavailableInvocationCoordinator()
  var executionInputFactory: (String) -> ToolExecutionInput = { ToolExecutionInput(content: $0) }
  private var knownIDs = Set<UUID>()
  init(editor: EditorViewController) { self.editor = editor }
  func documentChanged() {
    guard let editor else { return }
    let ids = Set(editor.state.invocations.map(\.id))
    for id in knownIDs where !ids.contains(id) {
      coordinator.remove(id)
      coordinator.transient.remove(id)
    }
    knownIDs = ids
    for invocation in editor.state.invocations {
      coordinator.transient.reconcile(
        invocation.id, inputting: invocation.phase == .inputting,
        content: content(invocation))
    }
  }

  func reconcilePackages() {
    guard let editor else { return }
    for original in editor.state.invocations {
      guard let current = editor.state.invocations.first(where: { $0.id == original.id }) else {
        continue
      }
      guard current.validated(in: editor.state) else {
        cancel(current.id)
        continue
      }
      let candidate = packages.first(where: { $0.manifest.id == current.packageID })?.manifest
      try? perform(
        .reconcile(
          current.packageReference, candidate: candidate,
          hasLiveJob: coordinator.hasJob(current.id)), id: current.id)
      if current.inputMode.hasPrefix("ephemeral"), current.phase == .inputting,
        prompt(for: current.id) == nil
      {
        setPrompt("", for: current.id)
      }

    }
  }

  func focused() -> ToolInvocation? {
    guard let editor else { return nil }
    let caret = editor.textView.selectedRange()
    return editor.state.invocations.first {
      guard let source = $0.scope.resolve(in: editor.state.lines) else { return false }
      let range = NSUnionRange(source, $0.output?.resolve(in: editor.state.lines) ?? source)
      return caret.location >= range.location && NSMaxRange(caret) <= NSMaxRange(range)
    }
  }

  func accept(_ package: ToolPackage, token range: NSRange, space: Bool) throws {
    guard let editor, packages.contains(package) else { return }
    let identity = InvocationGeneration(invocationID: UUID(), generation: UUID())
    var lifecycle = InvocationLifecycleState(identity: identity, phase: .inputting)
    for case .document(let effect) in lifecycle.reduce(.accept) {
      guard
        let plan = try ToolDocumentEffects.accept(
          effect, package: package,
          token: range, space: space, in: editor.state)
      else { return }
      do {
        try apply(plan)
        _ = lifecycle.reduce(.acknowledge(effect, accepted: true))
      } catch {
        _ = lifecycle.reduce(.acknowledge(effect, accepted: false))
        throw error
      }
    }
    editor.textView.setSelectedRange(
      NSRange(
        location: range.location + package.manifest.command.utf16.count + (space ? 1 : 0), length: 0
      ))
    if package.manifest.inputMode.isEphemeral { setPrompt("", for: identity.invocationID) }
    editor.refreshToolPresentation()
  }

  func content(_ invocation: ToolInvocation) -> String? {
    guard let editor else { return nil }
    return invocation.capturedContent(in: editor.state, prompt: prompt(for: invocation.id))
  }

  func submit(_ id: UUID) {
    guard let editor, let invocation = editor.state.invocations.first(where: { $0.id == id }),
      invocation.phase == .inputting,
      let package = packages.first(where: { $0.manifest.id == invocation.packageID }),
      let content = content(invocation)
    else { return }
    clearWarning(id)
    let identity = InvocationGeneration(invocationID: id, generation: UUID())
    coordinator.submit(
      identity: identity, package: package, input: executionInputFactory(content),
      apply: { [weak self] effect in
        guard let self, let editor = self.editor,
          var current = editor.state.invocations.first(where: { $0.id == id })
        else { return false }
        do {
          switch effect.operation {
          case .submit:
            guard current.phase == .inputting, current.generation == invocation.generation,
              current.sourceHash == invocation.sourceHash,
              self.content(current) == content
            else { return false }
            current.packageVersion = package.manifest.version
            current.executor = package.manifest.executorType.rawValue
            let selection = try? ToolAnchoredRange(
              editor.textView.selectedRange(), lines: editor.state.lines)
            let viewport = editor.linePresentation.viewportAnchor()
            current.restoration = ToolInvocationRestoration(
              invocation: current, selection: selection, viewportLineID: viewport?.0,
              viewportOffset: viewport.map { Double($0.1) })
            let plan = try ToolDocumentEffects.prepare(
              effect, in: editor.state,
              expected: editor.state.invocations.first(where: { $0.id == id })!, submission: current
            )
            try self.apply(plan)
          default:
            let plan = try ToolDocumentEffects.prepare(effect, in: editor.state, expected: current)
            try self.apply(plan)
          }
          return true
        } catch { return false }
      },
      warning: { [weak self] warning in
        guard let self, let current = self.editor?.state.invocations.first(where: { $0.id == id }),
          current.phase == .inputting, current.generation == invocation.generation,
          current.sourceHash == invocation.sourceHash,
          self.content(current) == content
        else { return }
        self.setWarning(warning, content: content, for: id)
      })
  }

  private func apply(_ plan: ToolDocumentPlan) throws {
    guard let editor else { throw DocumentError.invalidState }
    try editor.apply(plan.transaction)
    if let undo = plan.undoSnapshot {
      editor.registerToolUndo(undo, restoration: plan.restoration)
    } else if let restoration = plan.restoration {
      editor.restoreToolPresentation(restoration)
    }
    editor.refreshToolPresentation()
  }

  private func perform(_ action: InvocationLifecycleState.Action, id: UUID) throws {
    guard let editor, let invocation = editor.state.invocations.first(where: { $0.id == id }) else {
      return
    }
    var lifecycle = invocation.lifecycle
    for effect in lifecycle.reduce(action) {
      switch effect {
      case .document(let effect):
        do {
          try apply(ToolDocumentEffects.prepare(effect, in: editor.state, expected: invocation))
          _ = lifecycle.reduce(.acknowledge(effect, accepted: true))
        } catch {
          _ = lifecycle.reduce(.acknowledge(effect, accepted: false))
          throw error
        }
      case .cancel: coordinator.remove(id)
      default: break
      }
    }
  }

  func cancel(_ id: UUID) {
    coordinator.remove(id)
    setPrompt(nil, for: id)
    clearWarning(id)
    try? perform(.detach, id: id)
  }

  /// Deletes only the requested characters and drops the whole affected pending
  /// annotation. Text, annotations and their inverse share one transaction.
  func deletePending(in range: NSRange, expectedRevision: Int64) throws {
    guard let editor, editor.state.revision == expectedRevision, range.length > 0 else { return }
    let before = editor.state
    let affected = ToolRangeEditing.intersectingLocks(range, snapshot: before)
    guard !affected.isEmpty, affected.allSatisfy({ $0.phase == .pending }) else { return }
    let ids = Set(affected.map(\.id))
    let plain = try replacing(before, range: range, with: "")
    let annotations = ToolRangeEditing.remap(
      before.invocations.filter { !ids.contains($0.id) },
      from: before, to: plain, edit: range, replacementLength: 0)
    try commit(plain, edit: range, replacementLength: 0, invocations: annotations)
    editor.textView.setSelectedRange(NSRange(location: range.location, length: 0))
  }

  func dismiss(_ id: UUID) throws {
    try perform(.dismiss, id: id)
    clearWarning(id)
  }

  func merge(_ id: UUID) throws {
    try perform(.merge, id: id)
    setPrompt(nil, for: id)
  }

  func moveBoundary(_ id: UUID, start: Bool, to requested: Int) throws {
    guard let editor, var invocation = editor.state.invocations.first(where: { $0.id == id }),
      invocation.phase == .inputting,
      invocation.inputMode == "contextual",
      let token = invocation.token.resolve(in: editor.state.lines),
      let scope = invocation.scope.resolve(in: editor.state.lines)
    else { return }
    var a = start ? min(token.location, max(0, requested)) : scope.location
    var b =
      start
      ? NSMaxRange(scope) : max(NSMaxRange(token), min(editor.state.text.utf16.count, requested))
    for other in editor.state.invocations where other.id != id {
      guard let occupied = occupied(other, in: editor.state) else { continue }
      if NSMaxRange(occupied) <= token.location {
        a = max(a, NSMaxRange(occupied))
      } else if occupied.location >= NSMaxRange(token) {
        b = min(b, occupied.location)
      }
    }
    let source = editor.state.text as NSString
    if a < source.length { a = source.rangeOfComposedCharacterSequence(at: a).location }
    if b < source.length { b = source.rangeOfComposedCharacterSequence(at: b).location }
    let range = NSRange(location: a, length: max(0, b - a))
    invocation.scope = try .init(range, lines: editor.state.lines)
    invocation.sourceHash = ToolInvocation.hash(source.substring(with: range))
    try update(invocation)
  }

  private func occupied(_ invocation: ToolInvocation, in snapshot: DocumentSnapshot) -> NSRange? {
    guard let scope = invocation.scope.resolve(in: snapshot.lines) else { return nil }
    return NSUnionRange(scope, invocation.output?.resolve(in: snapshot.lines) ?? scope)
  }

  private func update(_ invocation: ToolInvocation) throws {
    guard let editor else { return }
    try commit(
      editor.state, edit: nil, replacementLength: nil,
      invocations: editor.state.invocations.map { $0.id == invocation.id ? invocation : $0 },
      undo: .none)
  }
  func prompt(for id: UUID) -> String? { coordinator.transient.prompt(for: id) }
  func setPrompt(_ text: String?, for id: UUID) { coordinator.transient.setPrompt(text, for: id) }
  func warning(for id: UUID) -> String? { coordinator.transient.warning(for: id) }
  private func setWarning(_ warning: String, content: String, for id: UUID) {
    coordinator.transient.setWarning(warning, content: content, for: id)
    editor?.refreshToolPresentation()
  }
  private func clearWarning(_ id: UUID) {
    coordinator.transient.setWarning(nil, content: nil, for: id)
  }
  private func replacing(_ snapshot: DocumentSnapshot, range: NSRange, with text: String) throws
    -> DocumentSnapshot
  {
    let plain = DocumentSnapshot(
      documentID: snapshot.documentID, text: snapshot.text, revision: snapshot.revision,
      lines: snapshot.lines, landmarks: snapshot.landmarks)
    let model = try DocumentCoordinator(snapshot: plain)
    return try model.apply(
      .init(
        baseRevision: plain.revision, origin: .automation,
        mutation: .edit(
          text: (plain.text as NSString).replacingCharacters(in: range, with: text), range: range,
          replacementLength: text.utf16.count))
    ).after
  }
  private func commit(
    _ plain: DocumentSnapshot, edit: NSRange?, replacementLength: Int?,
    invocations: [ToolInvocation], undo: UndoPolicy = .register
  ) throws {
    guard let editor else { return }
    let snapshot = DocumentSnapshot(
      documentID: plain.documentID, text: plain.text, revision: plain.revision,
      lines: plain.lines, landmarks: plain.landmarks, invocations: invocations)
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .automation, undoPolicy: undo,
        mutation: .tools(snapshot, edit: edit, replacementLength: replacementLength)))
    editor.refreshToolPresentation()
  }
}
