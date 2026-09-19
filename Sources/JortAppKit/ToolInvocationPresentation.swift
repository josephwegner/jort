import JortToolContracts
import AppKit
import JortDocument
import JortSettings

@MainActor enum ToolPresentationColors {
  static let pending = NSColor(calibratedRed: 0.68, green: 0.38, blue: 0.86, alpha: 1)
  static let canvas = NSColor(calibratedRed: 0.085, green: 0.094, blue: 0.106, alpha: 1)
}

/// Draws only viewport-intersecting canonical ranges. Controls remain separate
/// accessibility elements and never enter the document's text storage.
@MainActor final class ToolInvocationPresentation {
  weak var editor: EditorViewController?
  private var controls: [NSView] = []
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
  func invalidateStyles() { styleReconciler.invalidate() }
  init(editor: EditorViewController) {
    self.editor = editor
    overlays = InvocationOverlayCoordinator(textView: editor.textView, parent: editor.view)
    overlays.key = { [weak self] in self?.handle($0) ?? false }
    overlays.send = { [weak self] in self?.routeOverlay($0) }
  }
  private func routeOverlay(_ action: InvocationOverlayAction) {
    guard let editor else { return }
    switch action {
    case .prompt(let id, let value): editor.toolController.setPrompt(value, for: id)
    case .submit(let id): editor.toolController.submit(id)
    case .cancel(let id): editor.toolController.cancel(id)
    case .focusBoundary(let id, let start): focusedBoundary = (id, start)
    case .moveBoundary(let id, let start, let point):
      try? editor.toolController.moveBoundary(
        id, start: start, to: editor.textView.characterIndexForInsertion(at: point))
    case .adjustBoundary(let id, let start, let direction):
      guard let current = editor.state.invocations.first(where: { $0.id == id }),
        let scope = current.scope.resolve(in: editor.state.lines)
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
    if key == "/" { completionController.completionArmed = editor.toolController.focused() == nil }
    if key == "\r", event.modifierFlags.contains(.shift) {
      if editor.view.window?.firstResponder is ToolScopeHandle, let (id, _) = focusedBoundary {
        editor.toolController.submit(id)
      } else if let invocation = editor.toolController.focused() {
        editor.toolController.submit(invocation.id)
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
        try? editor.toolController.accept(packages[selected], token: range, space: true)
        return true
      }
    }
    let caretInvocation = editor.toolController.focused()
    let boundaryOwnsFocus = editor.view.window?.firstResponder is ToolScopeHandle
    if !boundaryOwnsFocus, focusedBoundary?.0 != caretInvocation?.id { focusedBoundary = nil }
    let focusedContext =
      focusedBoundary.flatMap { id, _ in editor.state.invocations.first { $0.id == id } }
      ?? caretInvocation
    if (event.modifierFlags.contains([.command, .option])
      || event.modifierFlags.contains([.option, .shift])), let invocation = focusedContext,
      invocation.inputMode == "contextual",
      let scope = invocation.scope.resolve(in: editor.state.lines),
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

  private func updateCompletion() {
    guard let editor else { return }
    completionController.update(
      text: editor.state.text, selection: editor.textView.selectedRange(),
      packages: editor.toolController.packages,
      acceptsCompletion: !editor.textView.hasMarkedText() && !editor.textView.isPasting
        && editor.toolController.focused() == nil)
  }
  func reconcileStyles() -> Bool {
    guard let editor, let storage = editor.textView.textStorage else { return false }
    if styleReconciler.reconcile(
      snapshot: editor.state, storage: storage,
      paragraphStyle: editor.textView.defaultParagraphStyle,
      documentFont: .monospacedSystemFont(ofSize: 15, weight: .regular),
      hasMarkedText: editor.textView.hasMarkedText())
    {
      updateErrorAccessories(editor.state)
      return true
    }
    return false
  }
  func reconcileControls(recomputeCompletion: Bool = true, invalidateDisplay: Bool = true) {
    guard !refreshing, let editor, !editor.textView.hasMarkedText(),
      editor.textView.textStorage != nil
    else { return }
    refreshing = true
    defer { refreshing = false }
    let snapshot = editor.state
    var shapes: [(NSBezierPath, NSColor)] = []
    mounts.begin()
    controls = []
    nextAccessibilityViews = []
    defer {
      mounts.finish()
      controls = mounts.ordered
      paintSnapshot = InvocationPaintSnapshot(shapes: shapes)
      accessibilityViews = nextAccessibilityViews
    }
    overlays.begin()
    if recomputeCompletion { updateCompletion() }
    if snapshot.invocations.isEmpty && !styleReconciler.hasStyles
      && completionController.completion == nil
    {
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
      guard let token = invocation.token.resolve(in: snapshot.lines),
        let scope = invocation.scope.resolve(in: snapshot.lines)
      else { continue }
      let output = invocation.output?.resolve(in: snapshot.lines)
      var ranges = [
        token, scope, NSRange(location: scope.location, length: 0),
        NSRange(location: NSMaxRange(scope), length: 0),
      ]
      if scope.length > 0, (snapshot.text as NSString).character(at: NSMaxRange(scope) - 1) == 10 {
        ranges.append(NSRange(location: scope.location, length: scope.length - 1))
      }
      if let output { ranges += [output, NSRange(location: output.location, length: 0)] }
      let capturedRects = Dictionary(uniqueKeysWithValues: Set(ranges).map { ($0, rects($0)) })
      let ends = Set([NSMaxRange(scope)] + (output.map { [NSMaxRange($0)] } ?? []))
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
      let anchor = prepared.anchor, controlFrame = prepared.controlFrame
      let sourceEndsLine = prepared.sourceEndsLine, inlineActions = prepared.inlineActions
      shapes += prepared.shapes
      switch invocation.phase {
      case .inputting:
        if inlineActions {
          addButton(
            "play.fill", LocalizedCopy.text("ToolInvocationPresentation.run", fallback: "Run"),
            frame: controlFrame.offsetBy(dx: 10, dy: 0)
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
      }
      let boundaries = [(true, scope.location), (false, NSMaxRange(scope))].compactMap {
        start, offset -> (Bool, Int, NSRect)? in
        rects(NSRange(location: offset, length: 0)).first.map { (start, offset, $0) }
      }
      let overlay = overlays.reconcile(
        invocation: invocation, snapshot: snapshot,
        token: token, scope: scope, sourceEndsLine: sourceEndsLine,
        tokenRect: rects(token).last, boundaries: boundaries,
        promptValue: editor.toolController.prompt(for: invocation.id), isCurrent: controlIsCurrent)
      nextAccessibilityViews += overlay.views
      if !overlay.connectors.isEmpty {
        shapes.append((Self.union(overlay.connectors), .systemTeal))
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
              + ($0.manifest.name as NSString).size(withAttributes: [
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
        button.name = package.manifest.name
        button.setAccessibilityLabel(
          LocalizedCopy.format("completion.row", fallback: "%@  %@", button.command, button.name))
        button.selected = index + first == selected
        button.setAccessibilityValue(
          button.selected ? LocalizedCopy.text("completion.selected", fallback: "Selected") : "")
        button.needsDisplay = true
        button.invoke = { [weak self, weak editor] in
          guard self?.completionController.completion?.0 == range else { return }
          self?.abandonCompletion()
          try? editor?.toolController.accept(package, token: range, space: true)
        }
        button.frame = NSRect(x: 6, y: 6 + CGFloat(index) * 32, width: width - 12, height: 32)
      }
      popover.setAccessibilityChildren(popover.subviews)

    }
    editor.textView.window?.invalidateCursorRects(for: editor.textView)
    if invalidateDisplay { editor.textView.setNeedsDisplay(editor.textView.visibleRect) }
  }

  private func updateErrorAccessories(_ snapshot: DocumentSnapshot) {
    guard let editor else { return }
    var values = editor.linePresentation.accessories.values.filter {
      !errorAccessoryIDs.contains($0.lineID)
    }
    let messages = Dictionary(
      grouping: snapshot.invocations.filter {
        $0.message != nil || editor.toolController.warning(for: $0.id) != nil
      }, by: { $0.token.start.lineID })
    let previous = errorAccessoryIDs
    errorAccessoryIDs = Set(messages.keys)
    guard !messages.isEmpty || !previous.isEmpty else { return }
    for (lineID, invocations) in messages {
      let rows = NSStackView()
      rows.orientation = .vertical
      rows.alignment = .leading
      rows.spacing = 4
      var height: CGFloat = 8
      for invocation in invocations {
        let message =
          invocation.message ?? editor.toolController.warning(for: invocation.id)
          ?? LocalizedCopy.text(
            "ToolInvocationPresentation.execution_failed", fallback: "Execution failed")
        let label = NSTextField(wrappingLabelWithString: "\(invocation.command): \(message)")
        label.font = .systemFont(ofSize: 12)
        let width = max(
          120, editor.scroll.contentSize.width - editor.textView.textContainerOrigin.x * 2 - 12)
        label.preferredMaxLayoutWidth = width
        height += max(
          22,
          ceil(
            (label.stringValue as NSString).boundingRect(
              with: NSSize(width: width, height: 1024), options: [.usesLineFragmentOrigin],
              attributes: [.font: label.font!]
            ).height) + 6)
        label.textColor = invocation.phase == .error ? .systemRed : .systemOrange
        label.setAccessibilityLabel(label.stringValue)
        rows.addArrangedSubview(label)
      }
      values.append(LineAccessory(lineID: lineID, height: height, view: rows))
    }
    editor.linePresentation.setAccessories(Array(values), deferLayout: true)
  }
  private func addButton(
    _ symbol: String, _ label: String, frame: NSRect, action: @escaping () -> Void
  ) {
    guard let editor else { return }
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
  func draw(_ rect: NSRect) { paintSnapshot.draw(rect) }
  var controlSnapshot: [PresentationGeometry.Control] { mounts.snapshot }
  static func union(_ rectangles: [NSRect]) -> NSBezierPath { InvocationGeometry.union(rectangles) }
}
