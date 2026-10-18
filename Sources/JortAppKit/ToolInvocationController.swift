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
  private var arguments: [UUID: [String: String]] = [:]
  private var inlineInputs: [UUID: String] = [:]
  init(editor: EditorViewController) { self.editor = editor }
  func documentChanged() {
    guard let editor else { return }
    let ids = Set(editor.state.invocations.map(\.id))
    for id in knownIDs where !ids.contains(id) {
      arguments.removeValue(forKey: id)
      inlineInputs.removeValue(forKey: id)
      coordinator.remove(id)
      coordinator.transient.remove(id)
    }
    knownIDs = ids
    var editedInlineErrors: [UUID] = []
    for invocation in editor.state.invocations {
      if let inline = invocation.inlineInput(in: editor.state) {
        let previous = inlineInputs.updateValue(inline, forKey: invocation.id)
        if previous != nil, previous != inline, invocation.phase == .inputting,
          invocation.message != nil
        {
          editedInlineErrors.append(invocation.id)
        }
      }
      if arguments[invocation.id] == nil, let captured = invocation.capturedArguments {
        arguments[invocation.id] = captured.mapValues { value in
          switch value {
          case .integer(let number): return String(number)
          case .string(let text):
            // Use the same small escape vocabulary as the argument parser.
            // JSONEncoder also emits escapes such as \/ that it does not accept.
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
              .replacingOccurrences(of: "\"", with: "\\\"")
              .replacingOccurrences(of: "\n", with: "\\n")
              .replacingOccurrences(of: "\r", with: "\\r")
              .replacingOccurrences(of: "\t", with: "\\t")
            return "\"" + escaped + "\""
          }
        }
      }
      coordinator.transient.reconcile(
        invocation.id, inputting: invocation.phase == .inputting,
        content: warningIdentity(invocation))
    }
    for id in editedInlineErrors { clearExecutionError(id) }
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
      let candidate = executionPackage(for: current)?.manifest
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
      guard let source = $0.scope.resolve(in: editor.state) else { return false }
      let range = NSUnionRange(source, $0.output?.resolve(in: editor.state) ?? source)
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
    if package.manifest.inputMode == .contextual, package.manifest.entryContract == 1,
      !(package.manifest.arguments?.isEmpty ?? true)
    {
      editor.toolPresentation.requestArgumentFocus(for: identity.invocationID)
      editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
      editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }
    editor.refreshToolPresentation()
  }

  func content(_ invocation: ToolInvocation) -> String? {
    guard let editor else { return nil }
    return invocation.capturedContent(in: editor.state, prompt: prompt(for: invocation.id))
  }

  func submit(_ id: UUID) {
    guard let editor, let invocation = editor.state.invocations.first(where: { $0.id == id }),
      invocation.phase == .inputting,
      let package = executionPackage(for: invocation),
      let content = content(invocation)
    else { return }
    clearWarning(id)
    clearExecutionError(id)
    let submittedArguments = arguments[id] ?? [:]
    let inline = invocation.call == nil ? nil : invocation.inlineInput(in: editor.state)
    let identity = InvocationGeneration(invocationID: id, generation: UUID())
    let input: ToolExecutionInput
    do {
      let definitions = package.manifest.arguments ?? []
      let parsed: [String: ToolArgumentValue]
      var instruction: String?
      if let inline, package.manifest.inputMode == .contextual {
        // Typed inputs are owned by the call, never harvested from its context.
        if package.manifest.executorType == .model {
          let values = try ToolArguments.parseModelInputs(inline, definitions: definitions)
          parsed = values.arguments
          instruction = values.instruction
        } else {
          parsed = try ToolArguments.parse(inline, definitions: definitions)
        }
      } else if definitions.isEmpty {
        parsed = [:]
      } else if package.manifest.inputMode == .contextual {
        parsed = try parsedArguments(for: id, definitions: definitions)
      } else {
        parsed = try ToolArguments.parse(content, definitions: definitions)
      }
      input = executionInputFactory(content).withArguments(parsed).withInstruction(instruction)
    } catch {
      setWarning(
        (error as? ToolFailure)?.message ?? "Check the tool arguments.", content: content, for: id)
      let invalid = (package.manifest.arguments ?? []).first { definition in
        do {
          _ = try parsedArguments(for: id, definitions: [definition])
          return false
        } catch { return true }
      }
      editor.toolPresentation.focusArguments(for: id, name: invalid?.name)
      return
    }
    coordinator.submit(
      identity: identity, package: package, input: input,
      apply: { [weak self] effect in
        guard let self, let editor = self.editor,
          var current = editor.state.invocations.first(where: { $0.id == id })
        else { return false }
        do {
          switch effect.operation {
          case .submit:
            guard current.phase == .inputting, current.generation == invocation.generation,
              current.sourceHash == invocation.sourceHash,
              self.content(current) == content,
              (self.arguments[id] ?? [:]) == submittedArguments
            else { return false }
            current.packageVersion = package.manifest.version
            current.executor = package.manifest.executorType.rawValue
            // Contract 1 has no argument metadata; keep its Undo restoration exact.
            current.capturedArguments = package.manifest.entryContract == 2 ? input.arguments : nil
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
          self.content(current) == content,
          (self.arguments[id] ?? [:]) == submittedArguments
        else { return }
        self.setWarning(warning, content: content, for: id)
      })
  }

  private func executionPackage(for invocation: ToolInvocation) -> ToolPackage? {
    guard var package = packages.first(where: { $0.manifest.id == invocation.packageID })
    else { return nil }
    // Ask and Rewrite v2 changed their entry contracts, not their instructions.
    // Preserve v1 saved calls rather than cancelling them or auto-merging their
    // pending results. New accepts always use the unmodified current package.
    let oldMode: ToolInputMode
    switch invocation.packageID {
    case "dev.jort.ask": oldMode = .ephemeralMultiline
    case "dev.jort.rewrite": oldMode = .contextual
    default: return package
    }
    guard invocation.call == nil, invocation.entryContract == 1,
      invocation.packageVersion == 1, invocation.executor == "model",
      invocation.inputMode == oldMode.rawValue,
      invocation.outputOperation == package.manifest.outputOperation.rawValue,
      invocation.command == package.manifest.command,
      package.manifest.version == 2, package.manifest.entryContract == 2,
      package.manifest.executorType == .model,
      package.manifest.arguments?.isEmpty ?? true,
      package.manifest.capturedData?.isEmpty ?? true,
      package.manifest.hostActions?.isEmpty ?? true
    else { return package }
    package.manifest.schemaVersion = 2
    package.manifest.entryContract = 1
    package.manifest.version = 1
    package.manifest.inputMode = oldMode
    package.manifest.arguments = nil
    package.manifest.capturedData = nil
    package.manifest.hostActions = nil
    return package
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
    let dispatched =
      editor?.state.invocations.first(where: { $0.id == id })?.actionStatus == .dispatched
    coordinator.remove(id)
    setPrompt(nil, for: id)
    clearWarning(id)
    if dispatched {
      // Coordinator removal records unknown outcome. Keep that receipt visible;
      // cancellation cannot prove an already dispatched external effect did not occur.
      editor?.refreshToolPresentation()
      return
    }
    try? perform(.detach, id: id)
  }

  func cancelReminder(_ id: UUID) {
    guard let editor,
      let invocation = editor.state.invocations.first(where: { $0.id == id }),
      invocation.phase == .completed, invocation.actionKind == "notification.schedule",
      let cancel = editor.cancelToolReminder
    else { return }
    let identity = InvocationGeneration(invocationID: id, generation: invocation.generation)
    Task { [weak self] in
      let message = await cancel(identity)
      guard let self, let editor = self.editor,
        let current = editor.state.invocations.first(where: { $0.id == id }),
        current.phase == .completed, current.generation == identity.generation
      else { return }
      try? self.perform(.completionMessage(UTF8Bounds.prefix(message, maximumBytes: 512)), id: id)
      editor.refreshToolPresentation()
    }
  }

  /// Deletes only the requested characters and drops the whole affected pending
  /// annotation. Text, annotations and their inverse share one transaction.
  func deletePending(in range: NSRange, expectedRevision: Int64) throws {
    guard let editor, editor.state.revision == expectedRevision, range.length > 0 else { return }
    let before = editor.state
    let affected = ToolRangeEditing.intersectingLocks(range, snapshot: before)
    guard !affected.isEmpty, affected.allSatisfy({ $0.phase == .pending }) else { return }
    let ids = Set(affected.map(\.id))
    let patch = DocumentPatch(
      in: before,
      replacements: [try .init(range: range, text: "", in: before)],
      expectedInvocations: affected, invocations: ids.map { .remove($0) })
    try editor.apply(
      .init(baseRevision: before.revision, origin: .automation, mutation: .patch(patch)))
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

  func done(_ id: UUID) throws { try perform(.done, id: id) }

  func argumentValues(for id: UUID) -> [String: String] { arguments[id] ?? [:] }

  func setArgument(_ value: String, name: String, for id: UUID) {
    guard arguments[id]?[name] != value else { return }
    arguments[id, default: [:]][name] = value
    clearWarning(id)
    clearExecutionError(id)
    editor?.refreshToolPresentation()
  }

  private func parsedArguments(for id: UUID, definitions: [ToolArgumentDefinition]) throws
    -> [String: ToolArgumentValue]
  {
    var parsed: [String: ToolArgumentValue] = [:]
    let raw = argumentValues(for: id)
    for definition in definitions {
      let field = try ToolArguments.parse(raw[definition.name] ?? "", definitions: [definition])
      parsed.merge(field) { _, new in new }
    }
    return try ToolArguments.validate(parsed, definitions: definitions)
  }

  func moveBoundary(_ id: UUID, start: Bool, to requested: Int) throws {
    guard let editor, var invocation = editor.state.invocations.first(where: { $0.id == id }),
      invocation.phase == .inputting,
      invocation.inputMode == "contextual",
      let token = invocation.token.resolve(in: editor.state),
      let scope = invocation.scope.resolve(in: editor.state)
    else { return }
    var a = start ? min(token.location, max(0, requested)) : scope.location
    var b =
      start
      ? NSMaxRange(scope)
      : max(
        invocation.call?.resolve(in: editor.state).map(NSMaxRange) ?? NSMaxRange(token),
        min(editor.state.text.utf16.count, requested))
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
    invocation.message = nil
    if invocation.actionStatus == .failed || invocation.actionStatus == .cancelled {
      invocation.actionStatus = nil
      invocation.actionKind = nil
    }
    try update(invocation)
  }

  private func occupied(_ invocation: ToolInvocation, in snapshot: DocumentSnapshot) -> NSRange? {
    guard let scope = invocation.scope.resolve(in: snapshot) else { return nil }
    return NSUnionRange(scope, invocation.output?.resolve(in: snapshot) ?? scope)
  }

  private func update(_ invocation: ToolInvocation) throws {
    guard let editor else { return }
    let before = editor.state
    guard let expected = before.invocations.first(where: { $0.id == invocation.id }) else {
      throw DocumentError.missingAnchor
    }
    let patch = DocumentPatch(
      in: before, expectedInvocations: [expected],
      invocations: [.upsert(invocation)])
    try editor.apply(
      .init(
        baseRevision: before.revision, origin: .automation,
        undoPolicy: .none, mutation: .patch(patch)))
    editor.refreshToolPresentation()
  }

  func prompt(for id: UUID) -> String? { coordinator.transient.prompt(for: id) }
  func setPrompt(_ text: String?, for id: UUID) {
    let previous = coordinator.transient.prompt(for: id)
    guard previous != text else { return }
    coordinator.transient.setPrompt(text, for: id)
    clearWarning(id)
    if previous != nil { clearExecutionError(id) }
    editor?.refreshToolPresentation()
  }
  func warning(for id: UUID) -> String? { coordinator.transient.warning(for: id) }
  private func setWarning(_ warning: String, content: String, for id: UUID) {
    let current = editor?.state.invocations.first(where: { $0.id == id })
    coordinator.transient.setWarning(
      warning, content: current.map(warningIdentity) ?? content, for: id)
    editor?.refreshToolPresentation()
  }
  private func warningIdentity(_ invocation: ToolInvocation) -> String? {
    // The contextual content excludes typed inputs. Track the full call/context
    // hash so correcting an argument clears a warning immediately, too.
    invocation.call == nil ? content(invocation) : invocation.sourceHash
  }
  private func clearWarning(_ id: UUID) {
    coordinator.transient.setWarning(nil, content: nil, for: id)
  }
  private func clearExecutionError(_ id: UUID) {
    guard let current = editor?.state.invocations.first(where: { $0.id == id }),
      current.phase == .inputting, current.message != nil,
      current.actionStatus == nil || current.actionStatus == .failed
        || current.actionStatus == .cancelled
    else { return }
    var cleared = current
    cleared.message = nil
    cleared.actionStatus = nil
    cleared.actionKind = nil
    try? update(cleared)
  }
}
