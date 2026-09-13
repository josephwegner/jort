import AppKit
import JortDocument
import JortSettings

@MainActor final class ToolInvocationController {
    weak var editor: EditorViewController?
    var packages: [ToolPackage] = []
    var activeID: UUID?
    var prompts: [UUID: String] = [:]
    private(set) var warnings: [UUID: String] = [:]
    var dispatcher = ToolExecutorDispatcher()
    var executionInputFactory: (String) -> ToolExecutionInput = { ToolExecutionInput(content: $0) }
    private var warningContent: [UUID: String] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    init(editor: EditorViewController) { self.editor = editor }
    func documentChanged() {
        guard let editor else { return }
        let ids = Set(editor.state.invocations.map(\.id))
        for id in Array(jobs.keys) where !ids.contains(id) { jobs.removeValue(forKey: id)?.cancel() }
        for id in Array(prompts.keys) where !ids.contains(id) { prompts.removeValue(forKey: id) }
        for id in Array(warnings.keys) {
            guard let invocation = editor.state.invocations.first(where: { $0.id == id }),
                  invocation.phase == .inputting, content(invocation) == warningContent[id] else {
                clearWarning(id); continue
            }
        }
    }

    func reconcilePackages() {
        guard let editor else { return }
        for original in editor.state.invocations {
            guard let current = editor.state.invocations.first(where: { $0.id == original.id }) else { continue }
            guard current.validated(in: editor.state) else { cancel(current.id); continue }
            if jobs[current.id] != nil, [.submitted, .processing].contains(current.phase) { continue }
            if let package = packages.first(where: { $0.manifest.id == current.packageID }),
               package.manifest.entryContract == current.entryContract,
               package.manifest.executorType.rawValue == (current.executor ?? "javascript"),
               package.manifest.inputMode.rawValue == current.inputMode,
               package.manifest.outputOperation.rawValue == current.outputOperation,
               package.manifest.version == current.packageVersion || package.manifest.compatibleVersions?.contains(current.packageVersion) == true {
                var mapped = current; mapped.packageVersion = package.manifest.version
                if [.submitted, .processing].contains(mapped.phase), jobs[mapped.id] == nil {
                    mapped.phase = .error; mapped.message = "Execution was interrupted."
                }
                if mapped.inputMode.hasPrefix("ephemeral"), mapped.phase == .inputting, prompts[mapped.id] == nil { prompts[mapped.id] = "" }
                if mapped != current { try? update(mapped) }
            } else if current.phase == .pending {
                // Preserve completed output and contextual source, independently of the old merge policy.
                var completed = current; completed.outputOperation = "replace-invocation"
                try? update(completed); try? merge(completed.id)
            } else { cancel(current.id) }
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
        guard let editor else { return }
        let before = editor.state
        guard packages.contains(package), before.invocations.count < 1000 else { return }
        guard !before.invocations.contains(where: {
            guard let scope = $0.scope.resolve(in: before.lines) else { return true }
            return NSIntersectionRange(scope, range).length > 0
        }) else { return }
        let manifest = package.manifest
        let command = manifest.command
        let replacement = command + (space ? " " : "")
        let plain = try replacing(before, range: range, with: replacement)
        var annotations = ToolRangeEditing.remap(before.invocations, from: before, to: plain, edit: range, replacementLength: replacement.utf16.count)
        let tokenRange = NSRange(location: range.location, length: command.utf16.count)
        var scopeRange = NSRange(location: range.location, length: manifest.inputMode.isEphemeral ? command.utf16.count : replacement.utf16.count)
        if manifest.inputMode == .contextual {
            scopeRange = (plain.text as NSString).lineRange(for: tokenRange)
            while scopeRange.length > 0 && [10, 13].contains((plain.text as NSString).character(at: NSMaxRange(scopeRange) - 1)) { scopeRange.length -= 1 }
            for other in annotations {
                guard let scope = occupied(other, in: plain) else { continue }
                if NSMaxRange(scope) <= tokenRange.location && NSMaxRange(scope) > scopeRange.location {
                    scopeRange.length -= NSMaxRange(scope) - scopeRange.location; scopeRange.location = NSMaxRange(scope)
                } else if scope.location >= NSMaxRange(tokenRange) && scope.location < NSMaxRange(scopeRange) {
                    scopeRange.length = scope.location - scopeRange.location
                }
            }
        }
        var invocation = ToolInvocation(packageID: manifest.id, packageVersion: manifest.version,
            entryContract: manifest.entryContract, inputMode: manifest.inputMode.rawValue,
            outputOperation: manifest.outputOperation.rawValue, command: command,
            token: try .init(tokenRange, lines: plain.lines), scope: try .init(scopeRange, lines: plain.lines),
            sourceHash: ToolInvocation.hash((plain.text as NSString).substring(with: scopeRange)))
        invocation.executor = manifest.executorType.rawValue
        annotations.append(invocation)
        try commit(plain, edit: range, replacementLength: replacement.utf16.count, invocations: annotations)
        editor.textView.setSelectedRange(NSRange(location: range.location + replacement.utf16.count, length: 0))
        activeID = invocation.id
        if manifest.inputMode.isEphemeral { prompts[invocation.id] = "" }
        editor.refreshToolPresentation()
    }

    func content(_ invocation: ToolInvocation) -> String? {
        guard let editor, let scope = invocation.scope.resolve(in: editor.state.lines),
              let token = invocation.token.resolve(in: editor.state.lines) else { return nil }
        func submitted(_ content: String) -> String {
            content.unicodeScalars.first?.value == 0x20 ? String(content.unicodeScalars.dropFirst()) : content
        }
        if invocation.inputMode.hasPrefix("ephemeral") { return prompts[invocation.id].map(submitted) }
        let text = editor.state.text as NSString
        if invocation.inputMode == "contextual" {
            return submitted((text.substring(with: scope) as NSString).replacingCharacters(in: NSRange(location: token.location - scope.location, length: token.length), with: ""))
        }
        return submitted(text.substring(with: NSRange(location: NSMaxRange(token), length: NSMaxRange(scope) - NSMaxRange(token))))
    }

    func submit(_ id: UUID) {
        guard let editor, var invocation = editor.state.invocations.first(where: { $0.id == id }),
              invocation.phase == .inputting,
              let package = packages.first(where: { $0.manifest.id == invocation.packageID }),
               let content = content(invocation) else { return }
        clearWarning(id)
        guard content.utf8.count <= package.manifest.maximumInputBytes,
               invocation.inputMode != "contextual" || !content.isEmpty else {
            setWarning("Enter content within the tool’s input limit.", content: content, for: id); return
        }
        guard jobs[id] == nil else { return }
        let sourceHash = invocation.sourceHash
        let captured = executionInputFactory(content)
        jobs[id] = Task { [weak self] in
            let validation = await self?.dispatcher.validate(package, input: captured) ?? ToolExecutionResult(error: "Cancelled.")
            guard let self, !Task.isCancelled else { return }
            self.jobs.removeValue(forKey: id)
            guard var current = self.editor?.state.invocations.first(where: { $0.id == id }),
                  current.phase == .inputting, current.sourceHash == sourceHash, self.content(current) == content else { return }
            if let error = validation.error { self.setWarning(error, content: content, for: id) }
            else { self.start(current, package: package, input: captured) }
        }
    }

    private func start(_ value: ToolInvocation, package: ToolPackage, input: ToolExecutionInput) {
        guard let editor else { return }
        var invocation = value
        invocation.packageVersion = package.manifest.version
        invocation.executor = package.manifest.executorType.rawValue
        let id = invocation.id
        let selection = try? ToolAnchoredRange(editor.textView.selectedRange(), lines: editor.state.lines)
        let viewport = editor.linePresentation.viewportAnchor()
        invocation.restoration = ToolInvocationRestoration(invocation: invocation, selection: selection,
            viewportLineID: viewport?.0, viewportOffset: viewport.map { Double($0.1) })
        invocation.phase = .submitted; invocation.generation = UUID(); invocation.message = nil
        let generation = invocation.generation
        do { try update(invocation) } catch { return }
        jobs[id] = Task { [weak self] in
            let indicator = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, var current = self.current(id, generation), current.phase == .submitted else { return }
                current.phase = .processing; try? self.update(current)
            }
            let result = await self?.dispatcher.execute(package, input: input) ?? ToolExecutionResult(error: "Cancelled.")
            indicator.cancel()
            guard let self, !Task.isCancelled, var current = self.current(id, generation),
                  [.submitted, .processing].contains(current.phase) else { return }
            self.jobs.removeValue(forKey: id)
            if let error = result.error { current.phase = .error; current.message = error; try? self.update(current) }
            else { try? self.publish(current, output: result.output ?? "") }
        }
    }

    private func current(_ id: UUID, _ generation: UUID) -> ToolInvocation? {
        editor?.state.invocations.first { $0.id == id && $0.generation == generation }
    }

    private func publish(_ invocation: ToolInvocation, output: String) throws {
        guard let editor, invocation.validated(in: editor.state),
              let token = invocation.token.resolve(in: editor.state.lines),
              let scope = invocation.scope.resolve(in: editor.state.lines) else { throw DocumentError.invalidState }
        let before = editor.state
        let offset = invocation.inputMode == "contained" ? NSMaxRange(scope) : NSMaxRange(token)
        let edit = NSRange(location: offset, length: 0)
        let plain = try replacing(before, range: edit, with: output)
        var annotations = ToolRangeEditing.remap(before.invocations.filter { $0.id != invocation.id }, from: before, to: plain, edit: edit, replacementLength: output.utf16.count)
        var pending = invocation; pending.phase = .pending
        pending.token = try .init(token, lines: plain.lines)
        pending.scope = try .init(NSRange(location: scope.location, length: scope.length + (invocation.inputMode == "contextual" ? output.utf16.count : 0)), lines: plain.lines)
        pending.output = try .init(NSRange(location: offset, length: output.utf16.count), lines: plain.lines)
        pending.outputHash = ToolInvocation.hash(output)
        annotations.append(pending)
        // Publication's inverse is the editable pre-submit invocation, not a dead job.
        var inputting = restored(invocation)
        let undo = DocumentSnapshot(documentID: before.documentID, text: before.text, revision: before.revision,
            lines: before.lines, landmarks: before.landmarks,
            invocations: before.invocations.map { $0.id == invocation.id ? inputting : $0 })
        try commit(plain, edit: edit, replacementLength: output.utf16.count, invocations: annotations, undo: .none)
        editor.registerToolUndo(undo, restoration: invocation.restoration)
    }

    func cancel(_ id: UUID) {
        jobs.removeValue(forKey: id)?.cancel(); prompts.removeValue(forKey: id); clearWarning(id)
        guard let editor else { return }
        try? commit(editor.state, edit: nil, replacementLength: nil, invocations: editor.state.invocations.filter { $0.id != id })
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
        let annotations = ToolRangeEditing.remap(before.invocations.filter { !ids.contains($0.id) },
            from: before, to: plain, edit: range, replacementLength: 0)
        try commit(plain, edit: range, replacementLength: 0, invocations: annotations)
        editor.textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    func dismiss(_ id: UUID) throws {
        guard let editor, var invocation = editor.state.invocations.first(where: { $0.id == id }) else { return }
        if invocation.phase == .inputting { cancel(id); return }
        let restoration = invocation.restoration
        let before = editor.state
        if let output = invocation.output?.resolve(in: before.lines) {
            let plain = try replacing(before, range: output, with: "")
            guard let token = invocation.token.resolve(in: before.lines), let scope = invocation.scope.resolve(in: before.lines) else { return }
            invocation.token = try .init(token, lines: plain.lines)
            invocation.scope = try .init(NSRange(location: scope.location, length: scope.length - (invocation.inputMode == "contextual" ? output.length : 0)), lines: plain.lines)
            invocation = restored(invocation, token: invocation.token, scope: invocation.scope)
            var values = ToolRangeEditing.remap(before.invocations.filter { $0.id != id }, from: before, to: plain, edit: output, replacementLength: 0)
            values.append(invocation)
            try commit(plain, edit: output, replacementLength: 0, invocations: values)
        } else { invocation = restored(invocation); try update(invocation) }
        clearWarning(id)
        editor.restoreToolPresentation(restoration)
    }

    func merge(_ id: UUID) throws {
        guard let editor, let invocation = editor.state.invocations.first(where: { $0.id == id }), invocation.phase == .pending,
              let output = invocation.output?.resolve(in: editor.state.lines),
              let token = invocation.token.resolve(in: editor.state.lines), let scope = invocation.scope.resolve(in: editor.state.lines) else { return }
        let before = editor.state
        let range: NSRange, replacement: String
        if invocation.outputOperation == "replace-context" {
            range = scope; replacement = (before.text as NSString).substring(with: output)
        } else {
            range = invocation.inputMode == "contained" ? scope : token; replacement = ""
        }
        let plain = try replacing(before, range: range, with: replacement)
        let annotations = ToolRangeEditing.remap(before.invocations.filter { $0.id != id }, from: before, to: plain, edit: range, replacementLength: replacement.utf16.count)
        try commit(plain, edit: range, replacementLength: replacement.utf16.count, invocations: annotations)
        prompts.removeValue(forKey: id)
    }

    func moveBoundary(_ id: UUID, start: Bool, to requested: Int) throws {
        guard let editor, var invocation = editor.state.invocations.first(where: { $0.id == id }), invocation.phase == .inputting,
              invocation.inputMode == "contextual", let token = invocation.token.resolve(in: editor.state.lines),
              let scope = invocation.scope.resolve(in: editor.state.lines) else { return }
        var a = start ? min(token.location, max(0, requested)) : scope.location
        var b = start ? NSMaxRange(scope) : max(NSMaxRange(token), min(editor.state.text.utf16.count, requested))
        for other in editor.state.invocations where other.id != id {
            guard let occupied = occupied(other, in: editor.state) else { continue }
            if NSMaxRange(occupied) <= token.location { a = max(a, NSMaxRange(occupied)) }
            else if occupied.location >= NSMaxRange(token) { b = min(b, occupied.location) }
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
        try commit(editor.state, edit: nil, replacementLength: nil,
            invocations: editor.state.invocations.map { $0.id == invocation.id ? invocation : $0 }, undo: .none)
    }
    func warning(for id: UUID) -> String? { warnings[id] }
    private func setWarning(_ warning: String, content: String, for id: UUID) {
        warnings[id] = warning; warningContent[id] = content; editor?.refreshToolPresentation()
    }
    private func clearWarning(_ id: UUID) {
        warnings.removeValue(forKey: id); warningContent.removeValue(forKey: id)
    }
    private func restored(_ invocation: ToolInvocation, token: ToolAnchoredRange? = nil,
                          scope: ToolAnchoredRange? = nil) -> ToolInvocation {
        guard let restoration = invocation.restoration else {
            var value = invocation; value.phase = .inputting; value.message = nil
            value.output = nil; value.outputHash = nil; return value
        }
        var value = restoration.invocation(id: invocation.id)
        value.token = token ?? restoration.token; value.scope = scope ?? restoration.scope
        return value
    }
    private func replacing(_ snapshot: DocumentSnapshot, range: NSRange, with text: String) throws -> DocumentSnapshot {
        let plain = DocumentSnapshot(documentID: snapshot.documentID, text: snapshot.text, revision: snapshot.revision, lines: snapshot.lines, landmarks: snapshot.landmarks)
        let model = try DocumentCoordinator(snapshot: plain)
        return try model.apply(.init(baseRevision: plain.revision, origin: .automation,
            mutation: .edit(text: (plain.text as NSString).replacingCharacters(in: range, with: text), range: range, replacementLength: text.utf16.count))).after
    }
    private func commit(_ plain: DocumentSnapshot, edit: NSRange?, replacementLength: Int?, invocations: [ToolInvocation], undo: UndoPolicy = .register) throws {
        guard let editor else { return }
        let snapshot = DocumentSnapshot(documentID: plain.documentID, text: plain.text, revision: plain.revision,
            lines: plain.lines, landmarks: plain.landmarks, invocations: invocations)
        try editor.apply(.init(baseRevision: editor.state.revision, origin: .automation, undoPolicy: undo,
            mutation: .tools(snapshot, edit: edit, replacementLength: replacementLength)))
        editor.refreshToolPresentation()
    }
}
