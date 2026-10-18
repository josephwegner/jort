import JortToolContracts
import AppKit
import JortDocument
import JortSettings

@MainActor enum ToolPresentationColors {
  /// Commands and their editable input use the same light-blue surface in every mode.
  static let command = NSColor(calibratedRed: 0.32, green: 0.69, blue: 0.98, alpha: 1)
  /// Captured context is visually subordinate to the command that consumes it.
  static let context = NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.72, alpha: 1)
  static let pending = NSColor(calibratedRed: 0.68, green: 0.38, blue: 0.86, alpha: 1)
  static let canvas = NSColor(calibratedRed: 0.085, green: 0.094, blue: 0.106, alpha: 1)
}

/// Draws only viewport-intersecting canonical ranges. Controls remain separate
/// accessibility elements and never enter the document's text storage.
@MainActor final class ToolInvocationPresentation {
  weak var editor: EditorViewController?
  private var controls: [NSView] = []
  private var completionControls: [UUID: [ToolActionButton]] = [:]
  private var accessibilityViews: [NSView] = []
  private var nextAccessibilityViews: [NSView] = []
  private var index = InvocationPresentationIndex()
  private(set) var measuredInvocationCount = 0
  private let mounts = InvocationControlMounts()
  private var controlIdentity = ""
  private var controlIsCurrent: () -> Bool = { false }
  private let overlays: InvocationOverlayCoordinator
  private let completionController = InvocationCompletionController()
  private var refreshing = false
  private var paintSnapshot = InvocationPaintSnapshot(shapes: [])
  private let styleReconciler = InvocationStyleReconciler()
  private var focusedBoundary: (UUID, Bool)?
  private var errorAccessoryIDs = Set<UUID>()
  private var errorAccessorySignatures: [UUID: [String]] = [:]
  private var errorAccessoryWidth: CGFloat?
  /// Declarations, not a tool's editable description, identify possible native effects.
  static func actionDisclosure(for manifest: ToolManifest) -> String? {
    let destinations = (manifest.hostActions ?? []).compactMap { action -> String? in
      switch action {
      case "clipboard.rich": return "replace clipboard contents with rich text"
      case "file.export": return "save a file at a destination you choose"
      case "notification.schedule": return "schedule a local notification"
      default: return nil
      }
    }
    guard !destinations.isEmpty else { return nil }
    return "This tool may " + destinations.joined(separator: "; ") + "."
  }

  private func actionDisclosure(for invocation: ToolInvocation) -> String? {
    guard invocation.phase == .inputting,
      let manifest = editor?.toolController.packages.first(where: {
        $0.manifest.id == invocation.packageID
      })?.manifest
    else { return nil }
    return Self.actionDisclosure(for: manifest)
  }

  /// Validation failures are transient; execution failures and unknown host
  /// outcomes live on the invocation. Keep acknowledgements out of this path.
  private func errorMessage(for invocation: ToolInvocation) -> String? {
    if let warning = editor?.toolController.warning(for: invocation.id) { return warning }
    if invocation.phase == .error {
      return invocation.message
        ?? LocalizedCopy.text("invocation.execution_error", fallback: "Execution error")
    }
    if invocation.phase == .inputting || invocation.actionStatus == .unknown {
      return invocation.message
    }
    return nil
  }
  func invalidateStyles() { styleReconciler.invalidate() }
  func clearChangedStyles(before: DocumentSnapshot, after: DocumentSnapshot) {
    guard let editor, let storage = editor.textView.textStorage else { return }
    styleReconciler.clearChanged(
      before: before, after: after, storage: storage,
      paragraphStyle: editor.textView.defaultParagraphStyle,
      documentFont: .monospacedSystemFont(ofSize: 15, weight: .regular))
  }
  init(editor: EditorViewController) {
    self.editor = editor
    overlays = InvocationOverlayCoordinator(textView: editor.textView, parent: editor.view)
    overlays.key = { [weak self] in self?.handle($0) ?? false }
    overlays.send = { [weak self] in self?.routeOverlay($0) }
  }
  private func routeOverlay(_ action: InvocationOverlayAction) {
    guard let editor else { return }
    switch action {
    case .argument(let id, let name, let value):
      editor.toolController.setArgument(value, name: name, for: id)
    case .returnToEditor(let id):
      if let invocation = editor.state.invocations.first(where: { $0.id == id }),
        let token = (invocation.call ?? invocation.token).resolve(in: editor.state)
      {
        editor.textView.setSelectedRange(NSRange(location: NSMaxRange(token), length: 0))
        editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
      }
      editor.view.window?.makeFirstResponder(editor.textView)
    case .prompt(let id, let value): editor.toolController.setPrompt(value, for: id)
    case .submit(let id): editor.toolController.submit(id)
    case .cancel(let id): editor.toolController.cancel(id)
    case .focusBoundary(let id, let start): focusedBoundary = (id, start)
    case .moveBoundary(let id, let start, let point):
      try? editor.toolController.moveBoundary(
        id, start: start, to: editor.textView.characterIndexForInsertion(at: point))
    case .adjustBoundary(let id, let start, let direction):
      guard let current = editor.state.invocations.first(where: { $0.id == id }),
        let scope = current.scope.resolve(in: editor.state)
      else { return }
      let offset = start ? scope.location : NSMaxRange(scope), text = editor.state.text as NSString
      let next =
        direction < 0
        ? (offset > 0 ? text.rangeOfComposedCharacterSequence(at: offset - 1).location : 0)
        : (offset < text.length
          ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset)) : offset)
      try? editor.toolController.moveBoundary(id, start: start, to: next)
    }
  }
  func abandonCompletion() {
    completionController.completion = nil
    completionController.completionArmed = false
    completionController.suppressedCompletion = true
  }
  func accessibilityChildren() -> [Any] { accessibilityViews.filter { !$0.isHidden } }
  func removePresentation(
    for removedIDs: Set<UUID>, affectedSurvivorIDs: Set<UUID> = []
  ) {
    let retiredIDs = removedIDs.union(affectedSurvivorIDs)
    guard !retiredIDs.isEmpty, let editor else { return }
    let firstResponder = editor.view.window?.firstResponder
    paintSnapshot = paintSnapshot.removing(retiredIDs)
    let removed = mounts.remove(for: retiredIDs) + overlays.remove(for: retiredIDs)
    let identities = Set(removed.map(ObjectIdentifier.init))
    controls.removeAll { identities.contains(ObjectIdentifier($0)) }
    accessibilityViews.removeAll { identities.contains(ObjectIdentifier($0)) }
    nextAccessibilityViews.removeAll { identities.contains(ObjectIdentifier($0)) }
    if removed.contains(where: { view in
      firstResponder === view || (firstResponder as? NSView)?.isDescendant(of: view) == true
    }) {
      editor.view.window?.makeFirstResponder(editor.textView)
    }
    if let focusedBoundary, retiredIDs.contains(focusedBoundary.0) { self.focusedBoundary = nil }
    editor.textView.window?.invalidateCursorRects(for: editor.textView)
    editor.textView.setNeedsDisplay(editor.textView.visibleRect)
  }
  func armCommittedSlash() {
    completionController.completionArmed = editor?.toolController.focused() == nil
    completionController.suppressedCompletion = false
  }

  func escape() -> Bool {
    if completionController.completion != nil {
      completionController.completion = nil
      completionController.suppressedCompletion = true
      editor?.presentationCoordinator.invalidate(.interaction)
      return true
    }
    if let invocation = editor?.toolController.focused(), invocation.phase == .pending {
      try? editor?.toolController.dismiss(invocation.id)
      return true
    }
    if let invocation = editor?.toolController.focused(), invocation.phase == .completed {
      try? editor?.toolController.done(invocation.id)
      return true
    }
    if let invocation = editor?.toolController.focused(), invocation.phase == .inputting {
      editor?.toolController.cancel(invocation.id)
      return true
    }
    return false
  }

  func handle(_ event: NSEvent) -> Bool {
    guard let editor else { return false }
    updateCompletion()
    let key = event.charactersIgnoringModifiers ?? ""
    // Context adjustment owns only handle focus. Ordinary text selection,
    // Option-Shift arrows, clipboard commands, and typing remain native.
    if editor.view.window?.firstResponder is ToolScopeHandle, let (id, start) = focusedBoundary {
      if event.keyCode == 53 || (event.keyCode == 36 && !event.modifierFlags.contains(.shift)) {
        routeOverlay(.returnToEditor(id))
        focusedBoundary = nil
        return true
      }
      if event.keyCode == 48 {
        // A contextual call has two adjustment endpoints. Tab and Shift-Tab
        // both move to the other endpoint, so handle traversal remains inside
        // this mode until an explicit Return or Escape exits it.
        return focusContextBoundary(for: id, start: !start)
      }
      if [123, 124, 125, 126].contains(event.keyCode),
        !event.modifierFlags.contains(.command),
        let invocation = editor.state.invocations.first(where: { $0.id == id }),
        let scope = invocation.scope.resolve(in: editor.state)
      {
        let offset = start ? scope.location : NSMaxRange(scope)
        let text = editor.state.text as NSString
        let next: Int
        switch event.keyCode {
        case 123:
          next = offset > 0 ? text.rangeOfComposedCharacterSequence(at: offset - 1).location : 0
        case 124:
          next =
            offset < text.length
            ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset)) : offset
        case 126:
          next =
            offset > 0 ? text.lineRange(for: NSRange(location: offset - 1, length: 0)).location : 0
        default:
          next = NSMaxRange(
            text.lineRange(for: NSRange(location: min(offset, text.length), length: 0)))
        }
        try? editor.toolController.moveBoundary(id, start: start, to: next)
        return true
      }
    }
    if event.keyCode == 48,
      event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
      editor.textView.selectedRange().length == 0,
      let invocation = editor.toolController.focused(), invocation.phase == .inputting,
      invocation.inputMode == "contextual", let call = invocation.call?.resolve(in: editor.state),
      NSLocationInRange(editor.textView.selectedRange().location, call)
        || editor.textView.selectedRange().location == NSMaxRange(call)
    {
      return focusContextBoundary(
        for: invocation.id, start: !event.modifierFlags.contains(.shift))
    }
    if event.keyCode == 48, let invocation = editor.toolController.focused(),
      invocation.phase == .completed, let buttons = completionControls[invocation.id],
      let button = event.modifierFlags.contains(.shift) ? buttons.last : buttons.first
    {
      editor.view.window?.makeFirstResponder(button)
      return true
    }
    if event.keyCode == 48, let invocation = editor.toolController.focused(),
      invocation.phase == .inputting,
      overlays.focusArguments(for: invocation.id, backwards: event.modifierFlags.contains(.shift))
    {
      return true
    }
    if key == "/" { completionController.completionArmed = editor.toolController.focused() == nil }
    if key == "\r", event.modifierFlags.contains(.shift) {
      if editor.view.window?.firstResponder is ToolScopeHandle, let (id, _) = focusedBoundary {
        editor.toolController.submit(id)
      } else if let (range, packages, _) = completionController.completion,
        let command = try? editor.state.text(in: range),
        let package = packages.first(where: { $0.manifest.command == command }),
        ["/now", "/daily"].contains(command)
      {
        completionController.completion = nil
        completionController.suppressedCompletion = true
        try? editor.toolController.accept(package, token: range, space: true)
        if let invocation = editor.toolController.focused(), invocation.phase == .inputting {
          editor.toolController.submit(invocation.id)
        }
      } else if let invocation = pendingInvocationContainingOutputCaret(in: editor) {
        try? editor.toolController.merge(invocation.id)
      } else if let invocation = editor.toolController.focused() {
        if invocation.phase == .inputting {
          editor.toolController.submit(invocation.id)
        } else if invocation.phase == .completed {
          try? editor.toolController.done(invocation.id)
        }
      }
      return true
    }
    if let (range, packages, selected) = completionController.completion {
      if event.keyCode == 125 || event.keyCode == 126 {
        completionController.completion = (
          range, packages,
          max(0, min(packages.count - 1, selected + (event.keyCode == 125 ? 1 : -1)))
        )
        editor.presentationCoordinator.invalidate(.interaction)
        return true
      }
      if key == " " || key == "\r" {
        completionController.completion = nil
        completionController.suppressedCompletion = true
        acceptCompletion(packages[selected], token: range, runIfReady: key == "\r")
        return true
      }
    }
    let caretInvocation = editor.toolController.focused()
    let boundaryOwnsFocus = editor.view.window?.firstResponder is ToolScopeHandle
    if !boundaryOwnsFocus, focusedBoundary?.0 != caretInvocation?.id { focusedBoundary = nil }
    let focusedContext =
      focusedBoundary.flatMap { id, _ in editor.state.invocations.first { $0.id == id } }
      ?? caretInvocation
    if event.modifierFlags.contains([.command, .option]), let invocation = focusedContext,
      invocation.inputMode == "contextual",
      let scope = invocation.scope.resolve(in: editor.state),
      [123, 124, 125, 126].contains(event.keyCode)
    {
      let start =
        focusedBoundary?.0 == invocation.id
        ? focusedBoundary!.1 : [123, 126].contains(event.keyCode)
      focusedBoundary = (invocation.id, start)
      let offset = start ? scope.location : NSMaxRange(scope)
      let text = editor.state.text as NSString
      let next: Int
      if event.keyCode == 123 {
        next = offset > 0 ? text.rangeOfComposedCharacterSequence(at: offset - 1).location : 0
      } else if event.keyCode == 124 {
        next =
          offset < text.length
          ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset)) : offset
      } else if event.keyCode == 126 {
        next =
          offset > 0 ? text.lineRange(for: NSRange(location: offset - 1, length: 0)).location : 0
      } else {
        next = NSMaxRange(
          text.lineRange(for: NSRange(location: min(offset, text.length), length: 0)))
      }
      try? editor.toolController.moveBoundary(invocation.id, start: start, to: next)
      return true
    }
    completionController.suppressedCompletion = false
    return false
  }

  private func pendingInvocationContainingOutputCaret(in editor: EditorViewController)
    -> ToolInvocation?
  {
    let selection = editor.textView.selectedRange()
    guard selection.length == 0 else { return nil }
    return editor.state.invocations.first { invocation in
      guard invocation.phase == .pending,
        let output = invocation.output?.resolve(in: editor.state)
      else { return false }
      return NSLocationInRange(selection.location, output)
    }
  }

  private func updateCompletion() {
    guard let editor else { return }
    completionController.update(
      snapshot: editor.state, selection: editor.textView.selectedRange(),
      packages: editor.toolController.packages,
      acceptsCompletion: !editor.textView.hasMarkedText() && !editor.textView.isPasting
        && editor.toolController.focused() == nil)
  }
  private func focusContextBoundary(for id: UUID, start: Bool, retry: Bool = true) -> Bool {
    guard let editor,
      let invocation = editor.state.invocations.first(where: { $0.id == id }),
      let scope = invocation.scope.resolve(in: editor.state)
    else { return false }
    let offset = start ? scope.location : NSMaxRange(scope)
    // Handles are viewport-owned. Reveal the requested endpoint before mounting
    // and focusing it, without moving the editor's ordinary selection.
    editor.textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
    editor.linePresentation.prepareViewportLayout()
    editor.linePresentation.capture(epoch: editor.presentationCoordinator.epoch)
    reconcileControls(recomputeCompletion: false)
    if !overlays.focusBoundary(for: id, start: start), retry,
      let responder = editor.view.window?.firstResponder
    {
      let selection = editor.textView.selectedRange()
      let revision = editor.state.revision
      Task { @MainActor [weak self, weak editor] in
        guard let self, let editor, editor.view.window?.firstResponder === responder,
          editor.textView.selectedRange() == selection, editor.state.revision == revision
        else { return }
        _ = self.focusContextBoundary(for: id, start: start, retry: false)
      }
    }
    // A deferred viewport layout must not turn the adjustment gesture into
    // a literal tab in the document.
    return true
  }

  /// Contract-two generators explicitly declare their arguments. Legacy Date
  /// and UUID are also known to need no input; other old tools (such as Calc)
  /// may consume typed content despite having no argument declarations.
  private static func runsOnCompletion(_ manifest: ToolManifest) -> Bool {
    manifest.executorType == .javascript && manifest.inputMode == .contained
      && (manifest.arguments ?? []).isEmpty && (manifest.hostActions ?? []).isEmpty
      && (manifest.entryContract == 2
        || ["dev.jort.date", "dev.jort.uuid"].contains(manifest.id))
  }

  private func acceptCompletion(_ package: ToolPackage, token: NSRange, runIfReady: Bool) {
    guard let editor else { return }
    do {
      try editor.toolController.accept(package, token: token, space: true)
    } catch { return }
    guard runIfReady, Self.runsOnCompletion(package.manifest),
      let invocation = editor.toolController.focused(), invocation.phase == .inputting,
      invocation.packageID == package.manifest.id
    else { return }
    editor.toolController.submit(invocation.id)
  }

  func reconcileStyles() -> Bool {
    guard let editor, let storage = editor.textView.textStorage else { return false }
    index.update(editor.state)
    let visible = editor.linePresentation.visibleCanonicalRange ?? NSRange(location: 0, length: 0)
    let stylesChanged = styleReconciler.reconcile(
      snapshot: editor.state, storage: storage, visibleRange: visible,
      invocations: index.visible(in: visible),
      paragraphStyle: editor.textView.defaultParagraphStyle,
      documentFont: .monospacedSystemFont(ofSize: 15, weight: .regular),
      hasMarkedText: editor.textView.hasMarkedText())
    // Validation warnings are transient: they do not change the document's
    // revision or styles. Reconcile their rows independently of the style cache.
    let accessoriesChanged = updateErrorAccessories(editor.state)
    return stylesChanged || accessoriesChanged
  }
  func reconcileControls(recomputeCompletion: Bool = true, invalidateDisplay: Bool = true) {
    guard !refreshing, let editor, !editor.textView.hasMarkedText(),
      editor.textView.textStorage != nil
    else { return }
    refreshing = true
    defer { refreshing = false }
    let snapshot = editor.state
    let hadPresentation = !paintSnapshot.shapes.isEmpty || !controls.isEmpty
    var refreshDisplay = invalidateDisplay
    var shapes: [InvocationPaintSnapshot.Shape] = []
    mounts.begin()
    controls = []
    completionControls = [:]
    nextAccessibilityViews = []
    defer {
      mounts.finish()
      controls = mounts.ordered
      paintSnapshot = InvocationPaintSnapshot(shapes: shapes)
      accessibilityViews = nextAccessibilityViews
      if refreshDisplay {
        editor.textView.window?.invalidateCursorRects(for: editor.textView)
        editor.textView.setNeedsDisplay(editor.textView.visibleRect)
      }
    }
    overlays.begin()
    if recomputeCompletion { updateCompletion() }
    if snapshot.invocations.isEmpty && !styleReconciler.hasStyles
      && completionController.completion == nil
    {
      refreshDisplay = invalidateDisplay && hadPresentation
      nextAccessibilityViews += overlays.finish(snapshot: snapshot)
      return
    }
    index.update(snapshot)
    let visibleInvocations = index.visible(
      in: editor.linePresentation.visibleCanonicalRange ?? NSRange(location: 0, length: 0))
    measuredInvocationCount = visibleInvocations.count
    for invocation in visibleInvocations {
      controlIdentity = "\(invocation.id).\(invocation.generation).\(invocation.phase)"
      controlIsCurrent = { [weak editor] in
        guard let current = editor?.state.invocations.first(where: { $0.id == invocation.id })
        else { return false }
        return current.generation == invocation.generation && current.phase == invocation.phase
      }
      guard let token = invocation.token.resolve(in: snapshot),
        let scope = invocation.scope.resolve(in: snapshot)
      else { continue }
      let output = invocation.output?.resolve(in: snapshot)
      var ranges = [
        token, scope, NSRange(location: scope.location, length: 0),
        NSRange(location: NSMaxRange(scope), length: 0),
      ]
      if let call = invocation.call?.resolve(in: snapshot) { ranges.append(call) }
      ranges += invocation.contextRanges(in: snapshot)
      if scope.length > 0,
        (try? snapshot.utf16(in: NSRange(location: NSMaxRange(scope) - 1, length: 1)).first) == 10
      {
        ranges.append(NSRange(location: scope.location, length: scope.length - 1))
      }
      if let output { ranges += [output, NSRange(location: output.location, length: 0)] }
      let capturedRects = Dictionary(uniqueKeysWithValues: Set(ranges).map { ($0, rects($0)) })
      let ends = Set(
        [NSMaxRange(scope)]
          + (invocation.call?.resolve(in: snapshot).map { [NSMaxRange($0)] } ?? [])
          + invocation.contextRanges(in: snapshot).map(NSMaxRange)
          + (output.map { [NSMaxRange($0)] } ?? []))
      let glyphs = Dictionary(
        uniqueKeysWithValues: ends.compactMap { offset in
          editor.linePresentation.glyphFrame(at: offset).map { (offset, $0) }
        })
      guard
        let prepared = InvocationGeometry.prepare(
          invocation: invocation, snapshot: snapshot,
          token: token, scope: scope, output: output,
          input: .init(
            rects: capturedRects, glyphs: glyphs,
            warning: editor.toolController.warning(for: invocation.id)))
      else { continue }
      let anchor = prepared.anchor
      var controlFrame = prepared.controlFrame
      if invocation.inputMode == "contextual", invocation.call != nil,
        anchor.minX < editor.textView.visibleRect.maxX,
        controlFrame.maxX > editor.textView.visibleRect.maxX
      {
        // The trailing kern can reach the viewport edge after a wrapped call.
        // Keep its controls in that reserved gap instead of clipping them.
        controlFrame.origin.x = max(
          editor.textView.visibleRect.minX,
          editor.textView.visibleRect.maxX - controlFrame.width)
      }
      let sourceEndsLine = prepared.sourceEndsLine, inlineActions = prepared.inlineActions
      shapes += prepared.shapes.map {
        .init(invocationID: invocation.id, path: $0.0, color: $0.1)
      }
      switch invocation.phase {
      case .inputting:
        if inlineActions {
          addButton(
            "play.fill",
            actionDisclosure(for: invocation).map { "Run: " + $0 }
              ?? LocalizedCopy.text("ToolInvocationPresentation.run", fallback: "Run"),
            frame: controlFrame.offsetBy(dx: 3, dy: 0)
          ) {
            [weak editor] in editor?.toolController.submit(invocation.id)
          }
        }
      case .submitted: break
      case .processing:
        let spinner: NSProgressIndicator = mounts.view(
          key: controlIdentity + ".progress", in: editor.textView
        ) {
          let view = NSProgressIndicator()
          view.style = .spinning
          view.controlSize = .small
          view.startAnimation(nil)
          return view
        }
        nextAccessibilityViews.append(spinner)
        spinner.frame = NSRect(
          x: controlFrame.minX, y: controlFrame.minY + 3, width: 18, height: 18)
        addButton(
          "xmark", LocalizedCopy.text("ToolInvocationPresentation.cancel", fallback: "Cancel"),
          frame: controlFrame.offsetBy(dx: 24, dy: 0)
        ) { [weak editor] in
          editor?.toolController.cancel(invocation.id)
        }
      case .pending:
        if output?.length == 0 {
          let empty: NSTextField = mounts.view(key: controlIdentity + ".empty", in: editor.textView)
          { NSTextField(labelWithString: "∅") }
          nextAccessibilityViews.append(empty)
          empty.textColor = .secondaryLabelColor
          empty.setAccessibilityLabel(
            LocalizedCopy.text("ToolInvocationPresentation.empty_result", fallback: "Empty result"))
          empty.toolTip = LocalizedCopy.text(
            "ToolInvocationPresentation.empty_result", fallback: "Empty result")
          empty.frame = NSRect(x: anchor.minX + 4, y: anchor.minY + 3, width: 20, height: 22)
        }
        addButton(
          "arrow.triangle.merge",
          LocalizedCopy.text("ToolInvocationPresentation.merge", fallback: "Merge"),
          frame: controlFrame
        ) { [weak editor] in
          try? editor?.toolController.merge(invocation.id)
        }
        addButton(
          "xmark", LocalizedCopy.text("ToolInvocationPresentation.dismiss", fallback: "Dismiss"),
          frame: controlFrame.offsetBy(dx: 24, dy: 0)
        ) {
          [weak editor] in try? editor?.toolController.dismiss(invocation.id)
        }
      case .error:
        addButton(
          "xmark",
          LocalizedCopy.format(
            "invocation.dismiss_error", fallback: "Dismiss: %@",
            invocation.message
              ?? LocalizedCopy.text("invocation.execution_error", fallback: "Execution error")),
          frame: controlFrame
        ) { [weak editor] in try? editor?.toolController.dismiss(invocation.id) }
      case .completed:
        var buttons: [ToolActionButton] = []
        if let done = addButton(
          "checkmark", "Done", frame: controlFrame,
          action: { [weak editor] in
            try? editor?.toolController.done(invocation.id)
          })
        {
          buttons.append(done)
        }
        if invocation.actionKind == "notification.schedule", editor.cancelToolReminder != nil {
          if let cancel = addButton(
            "bell.slash", "Cancel Reminder", frame: controlFrame.offsetBy(dx: 24, dy: 0),
            action: {
              [weak editor] in editor?.toolController.cancelReminder(invocation.id)
            })
          {
            buttons.append(cancel)
          }
        }
        for (index, button) in buttons.enumerated() {
          let next: NSView = index + 1 < buttons.count ? buttons[index + 1] : editor.textView
          let previous: NSView = index > 0 ? buttons[index - 1] : editor.textView
          button.nextKeyView = next
          button.moveFocus = { [weak next, weak previous, weak editor] backwards in
            editor?.view.window?.makeFirstResponder(backwards ? previous : next)
          }
          button.returnToEditor = { [weak editor] in
            editor?.view.window?.makeFirstResponder(editor?.textView)
          }
        }
        completionControls[invocation.id] = buttons
      }
      let boundaries = [(true, scope.location), (false, NSMaxRange(scope))].compactMap {
        start, offset -> (Bool, Int, NSRect)? in
        rects(NSRange(location: offset, length: 0)).first.map { (start, offset, $0) }
      }
      let package = editor.toolController.packages.first { $0.manifest.id == invocation.packageID }
      let overlay = overlays.reconcile(
        invocation: invocation, snapshot: snapshot,
        token: token, scope: scope, sourceEndsLine: sourceEndsLine,
        tokenRect: rects(token).last, command: invocation.call?.resolve(in: snapshot) ?? token,
        boundaries: boundaries,
        promptValue: editor.toolController.prompt(for: invocation.id),
        argumentDefinitions: package?.manifest.arguments ?? [],
        argumentValues: editor.toolController.argumentValues(for: invocation.id),
        description: package?.manifest.description ?? "",
        errorMessage: errorMessage(for: invocation),
        isCurrent: controlIsCurrent)
      nextAccessibilityViews += overlay.views
      if !overlay.connectors.isEmpty {
        shapes.append(
          .init(
            invocationID: invocation.id, path: Self.union(overlay.connectors),
            color: ToolPresentationColors.command))
      }
    }
    nextAccessibilityViews += overlays.finish(snapshot: snapshot)
    if let (range, packages, selected) = completionController.completion,
      let anchor = rects(range).last
    {
      let first = max(0, selected - 7)
      let visible = Array(packages.dropFirst(first).prefix(8))
      let width = min(
        editor.scroll.contentSize.width - 16,
        max(
          180,
          visible.map {
            ($0.manifest.command as NSString).size(withAttributes: [
              .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
            ]).width
              + (($0.manifest.description.isEmpty ? $0.manifest.name : $0.manifest.description)
              as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 13)
              ]).width + 56
          }.max() ?? 180))
      let popover: ToolCompletionPopover = mounts.view(key: "completion", in: editor.view) {
        ToolCompletionPopover(frame: .zero)
      }
      let origin = editor.view.convert(anchor, from: editor.textView)
      let height = CGFloat(visible.count) * 32 + 12
      let viewport = editor.view.convert(
        editor.scroll.contentView.bounds, from: editor.scroll.contentView)
      // Root overlay sits above TextKit's independently composited glyph layers.
      let below = editor.view.isFlipped ? origin.maxY + 4 : origin.minY - height - 4
      popover.frame = NSRect(
        x: min(max(viewport.minX + 8, origin.minX), viewport.maxX - width - 8),
        y: max(viewport.minY, min(below, viewport.maxY - height)), width: width, height: height)
      nextAccessibilityViews.append(popover)
      popover.wantsLayer = true
      popover.layer?.cornerRadius = 9
      popover.shadow = NSShadow()
      popover.shadow?.shadowBlurRadius = 12
      popover.setAccessibilityElement(true)
      popover.setAccessibilityRole(.group)
      popover.setAccessibilityLabel(
        LocalizedCopy.text(
          "ToolInvocationPresentation.tool_completions", fallback: "Tool completions"))
      for (index, package) in visible.enumerated() {
        let button: ToolCompletionRow = mounts.view(
          key: "completion.\(range).\(package.manifest.id)", in: popover
        ) {
          ToolCompletionRow(
            command: package.manifest.command, name: package.manifest.name, selected: false,
            action: {})
        }
        button.command = package.manifest.command
        button.name =
          package.manifest.description.isEmpty
          ? package.manifest.name : package.manifest.description
        button.toolTip = package.manifest.description
        button.setAccessibilityLabel(
          LocalizedCopy.format("completion.row", fallback: "%@  %@", button.command, button.name))
        button.selected = index + first == selected
        button.setAccessibilityValue(
          button.selected ? LocalizedCopy.text("completion.selected", fallback: "Selected") : "")
        button.needsDisplay = true
        button.invoke = { [weak self] in
          guard self?.completionController.completion?.0 == range else { return }
          self?.abandonCompletion()
          self?.acceptCompletion(package, token: range, runIfReady: true)
        }
        button.frame = NSRect(x: 6, y: 6 + CGFloat(index) * 32, width: width - 12, height: 32)
      }
      popover.setAccessibilityChildren(popover.subviews)

    }
  }

  private func updateErrorAccessories(_ snapshot: DocumentSnapshot) -> Bool {
    guard let editor else { return false }
    var values = editor.linePresentation.accessories.values.filter {
      !errorAccessoryIDs.contains($0.lineID)
    }
    let messages = Dictionary(
      grouping: snapshot.invocations.filter {
        !accessoryMessages(for: $0).isEmpty
      }, by: { $0.token.start.lineID })
    let previous = errorAccessoryIDs
    let priorSignatures = errorAccessorySignatures
    let priorWidth = errorAccessoryWidth
    let width = max(
      120, editor.scroll.contentSize.width - editor.textView.textContainerOrigin.x * 2 - 12)
    let signatures = messages.mapValues { invocations in
      invocations.map { invocation in
        "\(invocation.phase):\(invocation.command):"
          + accessoryMessages(for: invocation).map { "\($0.kind):\($0.text)" }
          .joined(separator: "\n")
      }
    }
    if signatures == priorSignatures, width == priorWidth,
      messages.keys.allSatisfy({ editor.linePresentation.accessories[$0] != nil })
    {
      return false
    }
    errorAccessoryIDs = Set(messages.keys)
    errorAccessorySignatures = signatures
    errorAccessoryWidth = width
    guard !messages.isEmpty || !previous.isEmpty else { return false }
    for (lineID, invocations) in messages {
      if let existing = editor.linePresentation.accessories[lineID],
        previous.contains(lineID), signatures[lineID] == priorSignatures[lineID],
        width == priorWidth
      {
        values.append(existing)
        continue
      }
      let rows = NSStackView()
      rows.orientation = .vertical
      rows.alignment = .leading
      rows.spacing = 4
      rows.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)
      var height: CGFloat = 12
      for invocation in invocations {
        for detail in accessoryMessages(for: invocation) {
          let label = NSTextField(
            wrappingLabelWithString: "\(invocation.command): \(detail.text)")
          label.font = .systemFont(ofSize: 12)
          label.preferredMaxLayoutWidth = width
          height += max(
            22,
            ceil(
              (label.stringValue as NSString).boundingRect(
                with: NSSize(width: width, height: 1024), options: [.usesLineFragmentOrigin],
                attributes: [.font: label.font!]
              ).height) + 6)
          switch detail.kind {
          case "error": label.textColor = .systemRed
          default: label.textColor = .secondaryLabelColor
          }
          label.isSelectable = detail.kind == "message" && invocation.phase == .completed
          label.setAccessibilityLabel(
            detail.kind == "error" ? "Tool error: \(detail.text)" : label.stringValue)
          rows.addArrangedSubview(label)
        }
      }
      values.append(LineAccessory(lineID: lineID, height: height, view: rows))
    }
    editor.linePresentation.setAccessories(Array(values), deferLayout: true)
    return true
  }

  private func accessoryMessages(for invocation: ToolInvocation) -> [(kind: String, text: String)] {
    var messages: [(kind: String, text: String)] = []
    if let help = inlineHelp(for: invocation) { messages.append(("help", help)) }
    if let error = errorMessage(for: invocation) {
      messages.append(("error", error))
    } else if let message = invocation.message {
      messages.append(("message", message))
    }
    return messages
  }
  @discardableResult private func addButton(
    _ symbol: String, _ label: String, frame: NSRect, action: @escaping () -> Void
  ) -> ToolActionButton? {
    guard let editor else { return nil }
    let current = controlIsCurrent
    let button: ToolActionButton = mounts.view(
      key: controlIdentity + "." + label, in: editor.textView
    ) {
      ToolActionButton(symbol: symbol, label: label, action: {})
    }
    nextAccessibilityViews.append(button)
    button.invoke = { [weak editor] in
      guard current() else {
        editor?.presentationCoordinator.invalidate(.lifecycle)
        return
      }
      action()
    }
    button.frame = NSRect(
      x: frame.minX, y: frame.minY, width: symbol == "play.fill" ? 36 : 24,
      height: max(24, frame.height))
    return button
  }
  private func rects(_ range: NSRange) -> [NSRect] {
    editor?.linePresentation.canonicalRects(for: range).map { frame in
      var frame = frame.insetBy(dx: -3, dy: -1)
      if frame.minY < 0.5 {
        frame.size.height -= 0.5 - frame.minY
        frame.origin.y = 0.5
      }
      return frame
    } ?? []
  }
  func geometry(for range: NSRange) -> [NSRect] { rects(range) }
  func containsDecoration(at point: NSPoint, pending: Bool) -> Bool {
    paintSnapshot.contains(point, pending: pending)
  }

  func focusArguments(for id: UUID, name: String? = nil) {
    if let editor, let invocation = editor.state.invocations.first(where: { $0.id == id }),
      let call = invocation.call?.resolve(in: editor.state),
      let token = invocation.token.resolve(in: editor.state)
    {
      let start = min(NSMaxRange(call), NSMaxRange(token) + 1)
      editor.textView.setSelectedRange(NSRange(location: start, length: NSMaxRange(call) - start))
      editor.view.window?.makeFirstResponder(editor.textView)
      return
    }
    _ = overlays.focusArguments(for: id, name: name)
  }

  private func inlineHelp(for invocation: ToolInvocation) -> String? {
    guard invocation.phase == .inputting, let editor,
      let manifest = editor.toolController.packages.first(where: {
        $0.manifest.id == invocation.packageID
      })?.manifest
    else { return nil }
    return Self.inlineHelp(for: manifest, hasInlineCall: invocation.call != nil)
  }

  static func inlineHelp(for manifest: ToolManifest, hasInlineCall: Bool) -> String {
    func sentence(_ value: String) -> String {
      let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return "" }
      return ".!?".contains(text.last!) ? text : text + "."
    }

    var parts = [
      sentence(
        manifest.description.isEmpty ? manifest.name : manifest.description)
    ]
    if hasInlineCall {
      for definition in manifest.arguments ?? [] {
        let detail = definition.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var prompt =
          detail.isEmpty
          ? "\(definition.type == .enum ? "Choose" : "Enter") \(definition.label.lowercased())"
          : detail
        var details: [String] = []
        if let minimum = definition.minimum, let maximum = definition.maximum {
          if !prompt.contains("\(minimum)–\(maximum)") {
            details.append("\(minimum)–\(maximum)")
          }
        } else if let minimum = definition.minimum {
          if !prompt.contains("at least \(minimum)") { details.append("at least \(minimum)") }
        } else if let maximum = definition.maximum {
          if !prompt.contains("at most \(maximum)") { details.append("at most \(maximum)") }
        } else if detail.isEmpty, let choices = definition.choices, choices.count <= 6 {
          details.append(choices.joined(separator: ", "))
        }
        if let defaultValue = definition.defaultValue {
          let value: String
          switch defaultValue {
          case .integer(let number): value = String(number)
          case .string(let text): value = text.isEmpty ? "\"\"" : text
          }
          let namesDefault =
            prompt.contains("default \(value)")
            || prompt.contains("\(value) (default)")
            || (definition.type == .enum && value == "default" && prompt.contains("default"))
          if !namesDefault { details.append("default \(value)") }
        }
        if !details.isEmpty {
          if prompt.hasSuffix(".") { prompt.removeLast() }
          prompt += " (\(details.joined(separator: "; ")))"
        }
        parts.append(sentence(prompt))
      }
      if manifest.executorType == .model && manifest.inputMode == .contextual {
        parts.append("Add a question or instruction if needed.")
      } else if manifest.executorType == .model && manifest.inputMode == .contained,
        (manifest.arguments ?? []).isEmpty
      {
        parts.append("Enter your question.")
      }
    }
    return parts.filter { !$0.isEmpty }.joined(separator: " ")
  }

  func requestArgumentFocus(for id: UUID) { overlays.requestArgumentFocus(for: id) }
  func draw(_ rect: NSRect) { paintSnapshot.draw(rect) }
  var controlSnapshot: [PresentationGeometry.Control] { mounts.snapshot }
  static func union(_ rectangles: [NSRect]) -> NSBezierPath { InvocationGeometry.union(rectangles) }
}
