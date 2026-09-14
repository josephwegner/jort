import AppKit
import JortDocument
import JortSettings

@MainActor enum ToolPresentationColors {
  static let pending = NSColor(calibratedRed: 0.68, green: 0.38, blue: 0.86, alpha: 1)
  static let canvas = NSColor(calibratedRed: 0.085, green: 0.094, blue: 0.106, alpha: 1)
}

@MainActor private final class ToolActionButton: NSButton {
  var invoke: (() -> Void)?
  private var hovered = false
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }
  override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
  override func mouseEntered(with event: NSEvent) {
    NSCursor.pointingHand.set()
    hovered = true
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hovered = false
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    if hovered || isHighlighted {
      NSColor.white.withAlphaComponent(isHighlighted ? 0.18 : 0.10).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 4, yRadius: 4).fill()
    }
    super.draw(dirtyRect)
  }
  init(symbol: String, label: String, action: @escaping () -> Void) {
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    title = ""
    isBordered = false
    bezelStyle = .inline
    contentTintColor = NSColor(calibratedWhite: 0.88, alpha: 1)
    if symbol == "play.fill" {
      image = nil
      title = "⇧↵"
      font = .systemFont(ofSize: 13, weight: .medium)
    }
    toolTip = symbol == "play.fill" ? "Run (Shift+Enter)" : label
    setAccessibilityLabel(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    target = self
    self.action = #selector(activate)
    invoke = action
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func activate() { invoke?() }
  override func accessibilityPerformPress() -> Bool {
    guard isEnabled, let invoke else { return false }
    invoke()
    return true
  }
}

@MainActor private final class ToolCompletionRow: NSButton {
  var invoke: (() -> Void)?
  let command: String
  let name: String
  let selected: Bool
  init(command: String, name: String, selected: Bool, action: @escaping () -> Void) {
    self.command = command
    self.name = name
    self.selected = selected
    self.invoke = action
    super.init(frame: .zero)
    title = ""
    isBordered = false
    target = self
    self.action = #selector(activate)
    setAccessibilityLabel("\(command)  \(name)")
    setAccessibilityValue(selected ? "Selected" : "")
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func activate() { invoke?() }
  override func draw(_ dirtyRect: NSRect) {
    if selected || isHighlighted {
      NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
    let commandAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
      .foregroundColor: NSColor.labelColor,
    ]
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .right
    paragraph.lineBreakMode = .byTruncatingTail
    let nameAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph,
    ]
    let commandWidth = min(
      (command as NSString).size(withAttributes: commandAttributes).width, bounds.width * 0.6)
    (command as NSString).draw(
      in: NSRect(x: 10, y: (bounds.height - 17) / 2, width: commandWidth, height: 17),
      withAttributes: commandAttributes)
    (name as NSString).draw(
      in: NSRect(
        x: commandWidth + 26, y: (bounds.height - 16) / 2,
        width: max(0, bounds.width - commandWidth - 36), height: 16), withAttributes: nameAttributes
    )
  }
  override func accessibilityPerformPress() -> Bool {
    invoke?()
    return true
  }
}

@MainActor private final class ToolCompletionPopover: NSView {
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
    path.fill()
    NSColor.separatorColor.setStroke()
    path.stroke()
  }
}

@MainActor private final class ToolPromptView: NSView, NSTextViewDelegate {
  let input = NSTextView()
  private let scroll = NSScrollView()
  var changed: ((String) -> Void)?
  var submit: (() -> Void)?
  var dismiss: (() -> Void)?
  var multiline = true
  override var isFlipped: Bool { true }
  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    layer?.borderColor = NSColor.systemTeal.cgColor
    layer?.borderWidth = 1
    layer?.cornerRadius = 6
    input.isRichText = false
    input.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    input.delegate = self
    input.setAccessibilityLabel("Tool prompt")
    input.isVerticallyResizable = true
    input.textContainer?.widthTracksTextView = true
    scroll.documentView = input
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    addSubview(scroll)
    let run = ToolActionButton(symbol: "play.fill", label: "Run") { [weak self] in self?.submit?() }
    let close = ToolActionButton(symbol: "xmark", label: "Dismiss prompt") { [weak self] in
      self?.dismiss?()
    }
    addSubview(run)
    addSubview(close)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Tool prompt form")
    setAccessibilityChildren([scroll, run, close])
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    scroll.frame = bounds.insetBy(dx: 8, dy: 8)
    scroll.frame.size.height -= 26
    input.frame.size.width = scroll.contentSize.width
    input.minSize = NSSize(width: 0, height: scroll.contentSize.height)
    subviews[1].frame = NSRect(x: bounds.width - 68, y: bounds.height - 28, width: 36, height: 24)
    subviews[2].frame = NSRect(x: bounds.width - 30, y: bounds.height - 28, width: 24, height: 24)
  }
  func textDidChange(_ notification: Notification) { changed?(input.string) }
  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      dismiss?()
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
        submit?()
        return true
      }
      return !multiline
    }
    return false
  }
}

@MainActor private final class ToolScopeHandle: NSView {
  var isStart = false
  var moved: ((NSPoint) -> Void)?
  var focused: (() -> Void)?
  var key: ((NSEvent) -> Bool)?
  var adjusted: ((Int) -> Void)?
  override func accessibilityPerformIncrement() -> Bool {
    guard let adjusted else { return false }
    adjusted(1)
    return true
  }
  override func accessibilityPerformDecrement() -> Bool {
    guard let adjusted else { return false }
    adjusted(-1)
    return true
  }
  override var acceptsFirstResponder: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.systemTeal.setFill()
    let x = bounds.midX
    NSBezierPath(rect: NSRect(x: x - 1, y: 2, width: 2, height: bounds.height - 6)).fill()
    let flag = NSBezierPath()
    flag.move(to: NSPoint(x: x, y: bounds.height - 2))
    flag.line(to: NSPoint(x: x + (isStart ? 7 : -7), y: bounds.height - 2))
    flag.line(to: NSPoint(x: x, y: bounds.height - 9))
    flag.close()
    flag.fill()
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    focused?()
  }
  override func keyDown(with event: NSEvent) {
    if key?(event) != true { super.keyDown(with: event) }
  }
  override func mouseDragged(with event: NSEvent) {
    guard let superview else { return }
    moved?(superview.convert(event.locationInWindow, from: nil))
  }
}

/// Draws only viewport-intersecting canonical ranges. Controls remain separate
/// accessibility elements and never enter the document's text storage.
@MainActor final class ToolInvocationPresentation {
  weak var editor: EditorViewController?
  private var controls: [NSView] = []
  private var prompts: [UUID: ToolPromptView] = [:]
  private var completion: (NSRange, [ToolPackage], Int)?
  private var suppressedCompletion = false
  private var completionArmed = false
  private var refreshing = false
  private var shapes: [(NSBezierPath, NSColor)] = []
  private var styled: [NSRange] = []
  private let decorationAttribute = NSAttributedString.Key("JortToolDecoration")
  private var styledRevision: Int64 = -1
  private struct ViewportStamp: Equatable {
    let visible: NSRect
    let size: NSSize
    let end: Int
  }
  private var decoratedViewport: ViewportStamp?
  private func viewportStamp() -> ViewportStamp? {
    guard let view = editor?.textView, let manager = view.textLayoutManager,
      let content = manager.textContentManager,
      let viewport = manager.textViewportLayoutController.viewportRange
    else { return nil }
    return ViewportStamp(
      visible: view.visibleRect, size: view.bounds.size,
      end: content.offset(from: content.documentRange.location, to: viewport.endLocation))
  }
  private let documentFont: NSFont
  private var handles: [String: ToolScopeHandle] = [:]
  private var focusedBoundary: (UUID, Bool)?
  private var errorAccessoryIDs = Set<UUID>()
  func invalidateStyles() { styledRevision = -1 }
  init(editor: EditorViewController) {
    self.editor = editor
    documentFont = editor.textView.font ?? .monospacedSystemFont(ofSize: 15, weight: .regular)
  }
  func abandonCompletion() {
    completion = nil
    completionArmed = false
    suppressedCompletion = true
  }
  func accessibilityChildren() -> [Any] {
    controls.filter { !$0.isHidden } + handles.values.filter { !$0.isHidden }
      + prompts.values.filter { !$0.isHidden }
  }
  func armCommittedSlash() {
    completionArmed = editor?.toolController.focused() == nil
    suppressedCompletion = false
  }

  func escape() -> Bool {
    if completion != nil {
      completion = nil
      suppressedCompletion = true
      refresh()
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
    let key = event.charactersIgnoringModifiers ?? ""
    if key == "/" { completionArmed = editor.toolController.focused() == nil }
    if key == "\r", event.modifierFlags.contains(.shift) {
      if editor.view.window?.firstResponder is ToolScopeHandle, let (id, _) = focusedBoundary {
        editor.toolController.submit(id)
      } else if let invocation = editor.toolController.focused() {
        editor.toolController.submit(invocation.id)
      }
      return true
    }
    if let (range, packages, selected) = completion {
      if event.keyCode == 125 || event.keyCode == 126 {
        completion = (
          range, packages,
          max(0, min(packages.count - 1, selected + (event.keyCode == 125 ? 1 : -1)))
        )
        refresh(recomputeCompletion: false)
        return true
      }
      if key == " " || key == "\r" {
        completion = nil
        suppressedCompletion = true
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
    suppressedCompletion = false
    return false
  }

  private func findCompletion() {
    guard let editor, completionArmed, !suppressedCompletion, !editor.textView.hasMarkedText(),
      !editor.textView.isPasting,
      editor.textView.selectedRange().length == 0, editor.toolController.focused() == nil
    else {
      completion = nil
      return
    }
    let text = editor.state.text as NSString, caret = editor.textView.selectedRange().location
    guard caret <= text.length else {
      completion = nil
      return
    }
    let start = max(0, caret - 65)
    let prefix = text.substring(with: NSRange(location: start, length: caret - start))
    guard let slash = prefix.lastIndex(of: "/") else {
      completion = nil
      return
    }
    let offset = start + prefix[..<slash].utf16.count
    guard
      offset == 0
        || UnicodeScalar(text.character(at: offset - 1)).map({
          CharacterSet.whitespacesAndNewlines.contains($0)
        }) == true
    else {
      completion = nil
      return
    }
    let query = text.substring(with: NSRange(location: offset, length: caret - offset))
    let packages = editor.toolController.packages.filter { $0.manifest.command.hasPrefix(query) }
    completion =
      packages.isEmpty ? nil : (NSRange(location: offset, length: caret - offset), packages, 0)
  }

  func refresh(recomputeCompletion: Bool = true, invalidateDisplay: Bool = true) {
    guard !refreshing, let editor, let storage = editor.textView.textStorage else { return }
    refreshing = true
    defer { refreshing = false }
    controls.forEach { $0.removeFromSuperview() }
    controls = []
    shapes = []
    var visibleHandles = Set<String>()
    var visiblePrompts = Set<UUID>()
    if recomputeCompletion { findCompletion() }
    let snapshot = editor.state
    if snapshot.invocations.isEmpty && styled.isEmpty && completion == nil {
      for prompt in prompts.values { prompt.removeFromSuperview() }
      prompts = [:]
      for handle in handles.values { handle.removeFromSuperview() }
      handles = [:]
      return
    }
    if styledRevision != snapshot.revision {
      updateErrorAccessories(snapshot)
      // Attribute runs move with native edits; cached numeric ranges do not.
      var oldRuns: [NSRange] = []
      storage.enumerateAttribute(
        decorationAttribute, in: NSRange(location: 0, length: storage.length)
      ) { value, range, _ in
        if value != nil { oldRuns.append(range) }
      }
      storage.beginEditing()
      for range in oldRuns {
        storage.removeAttribute(.kern, range: range)
        storage.removeAttribute(.paragraphStyle, range: range)
        if let paragraph = editor.textView.defaultParagraphStyle {
          storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        storage.addAttribute(.font, value: documentFont, range: range)
        storage.removeAttribute(decorationAttribute, range: range)
      }
      styled = []
      for invocation in snapshot.invocations {
        guard let token = invocation.token.resolve(in: snapshot.lines),
          let scope = invocation.scope.resolve(in: snapshot.lines)
        else { continue }
        storage.addAttribute(
          .font, value: NSFontManager.shared.convert(documentFont, toHaveTrait: .boldFontMask),
          range: token)
        storage.addAttribute(decorationAttribute, value: true, range: token)
        styled.append(token)
        if invocation.inputMode.hasPrefix("ephemeral"), invocation.phase == .inputting { continue }
        let output = invocation.output?.resolve(in: snapshot.lines)
        let leading = output.map { leadingActions($0, text: snapshot.text) } ?? false
        let controlOffset =
          output.map { leading ? $0.location : NSMaxRange($0) }
          ?? NSMaxRange(invocation.inputMode == "contextual" ? token : scope)
        if let output, output.location < storage.length,
          leadingIndent(output, text: snapshot.text)
            || output.length == 0 && startsLine(output, text: snapshot.text)
        {
          let padding = (snapshot.text as NSString).rangeOfComposedCharacterSequence(
            at: output.location)
          let paragraph =
            (editor.textView.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
          paragraph.firstLineHeadIndent += output.length == 0 ? 78 : 54
          storage.addAttribute(.paragraphStyle, value: paragraph, range: padding)
          storage.addAttribute(decorationAttribute, value: true, range: padding)
          styled.append(padding)
        } else if controlOffset > 0 && controlOffset <= storage.length {
          let padding = (snapshot.text as NSString).rangeOfComposedCharacterSequence(
            at: controlOffset - 1)
          storage.addAttribute(.kern, value: output?.length == 0 ? 78 : 54, range: padding)
          styled.append(padding)
          storage.addAttribute(decorationAttribute, value: true, range: padding)
          if endsLine(controlOffset, text: snapshot.text),
            !startsLine(NSRange(location: controlOffset, length: 0), text: snapshot.text)
          {
            // TextKit omits trailing kern at a paragraph's end. Keep
            // room for the accessory even at a narrow viewport edge.
            let paragraph =
              (editor.textView.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
              ?? NSMutableParagraphStyle()
            paragraph.tailIndent -= output?.length == 0 ? 82 : 64
            storage.addAttribute(.paragraphStyle, value: paragraph, range: padding)
          }
        }
      }
      storage.endEditing()
      styledRevision = snapshot.revision
      editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }
    for invocation in snapshot.invocations {
      guard let token = invocation.token.resolve(in: snapshot.lines),
        let scope = invocation.scope.resolve(in: snapshot.lines)
      else { continue }
      let output = invocation.output?.resolve(in: snapshot.lines)
      let leading = output.map { leadingActions($0, text: snapshot.text) } ?? false
      let indented = output.map { leadingIndent($0, text: snapshot.text) } ?? false
      let emptyAtLineStart =
        output.map { $0.length == 0 && startsLine($0, text: snapshot.text) } ?? false
      let sourceEndsLine = endsLine(
        NSMaxRange(invocation.inputMode == "contextual" ? token : scope), text: snapshot.text)
      let outputEndsLine = output.map { endsLine(NSMaxRange($0), text: snapshot.text) } ?? false
      let inlineActions =
        !(invocation.inputMode.hasPrefix("ephemeral") && invocation.phase == .inputting)
      var paintedScope = scope
      // The newline belongs to the range, but the insertion position on
      // the following line does not. Do not paint that exclusive end.
      if invocation.inputMode == "contextual", paintedScope.length > 0,
        (snapshot.text as NSString).character(at: NSMaxRange(paintedScope) - 1) == 10
      {
        paintedScope.length -= 1
      }
      var sourceFrames = rects(paintedScope)
      if invocation.inputMode == "contained", invocation.phase == .inputting,
        startsLine(NSRange(location: NSMaxRange(scope), length: 0), text: snapshot.text),
        let emptyLine = rects(NSRange(location: NSMaxRange(scope), length: 0)).first,
        !sourceFrames.contains(where: { abs($0.minY - emptyLine.minY) < 2 })
      {
        sourceFrames.append(emptyLine)
      }
      var sourceRects = connected(sourceFrames)
      if output == nil, invocation.inputMode == "contextual", let tokenFrame = rects(token).last {
        sourceRects.append(
          NSRect(
            x: tokenFrame.maxX - (sourceEndsLine ? 3 : 27), y: tokenFrame.minY,
            width: sourceEndsLine ? 63 : 54, height: tokenFrame.height))
      }
      if output == nil, invocation.inputMode != "contextual", inlineActions, !sourceRects.isEmpty {
        sourceRects[sourceRects.count - 1].size.width +=
          sourceEndsLine
          ? (invocation.phase == .inputting ? 48 : 60) : (invocation.phase == .inputting ? 15 : 27)
      }
      if let output, !sourceRects.isEmpty, invocation.inputMode != "contextual" {
        sourceRects[sourceRects.count - 1].size.width -=
          output.length == 0 && !emptyAtLineStart ? 42 : leading && !indented ? 30 : 3
      }
      sourceRects = clippedBeforeFollowingGlyph(
        sourceRects, end: NSMaxRange(scope), text: snapshot.text)
      let warning = editor.toolController.warning(for: invocation.id)
      let color: NSColor =
        invocation.phase == .error ? .systemRed : warning == nil ? .systemTeal : .systemOrange
      shapes.append((Self.union(sourceRects), color))
      let outputRects: [NSRect]
      if let output {
        var frames = connected(rects(output))
        if output.length == 0, let anchor = frames.first {
          let offset: CGFloat = emptyAtLineStart ? (output.location < storage.length ? 78 : 0) : 36
          frames = [
            NSRect(x: anchor.minX - offset, y: anchor.minY, width: 78, height: anchor.height)
          ]
        } else if !frames.isEmpty {
          frames[0].origin.x += 3
          frames[0].size.width -= 3
          if leading {
            let reserve: CGFloat = indented ? 54 : 27
            frames[0].origin.x -= reserve
            frames[0].size.width += reserve
          }
          // Standard segments include half the trailing kern. Complete
          // the action reservation, leaving clearance before the next glyph.
          else {
            frames[frames.count - 1].size.width += outputEndsLine ? 54 : 21
          }
        }
        if let a = sourceRects.last, let b = frames.first, b.minY > a.minY {
          let seam = NSRect(
            x: min(a.minX, b.minX), y: a.maxY - 2,
            width: max(a.maxX, b.maxX) - min(a.minX, b.minX), height: max(4, b.minY - a.maxY + 4))
          frames.insert(seam, at: 0)
        }
        frames = clippedBeforeFollowingGlyph(frames, end: NSMaxRange(output), text: snapshot.text)
        outputRects = frames
        shapes.append((Self.union(frames), ToolPresentationColors.pending))
      } else {
        outputRects = []
      }
      var contextControl =
        invocation.inputMode == "contextual" && output == nil ? rects(token).last : nil
      contextControl?.size.width += sourceEndsLine ? 60 : 27
      let leadingAnchor =
        leading ? rects(NSRange(location: output!.location, length: 0)).first : nil
      guard let anchor = (leadingAnchor ?? outputRects.last ?? contextControl ?? sourceRects.last)
      else { continue }
      let controlFrame = NSRect(
        x: leading ? anchor.minX - (indented ? 48 : 21) : anchor.maxX - 50, y: anchor.minY,
        width: 50, height: max(24, anchor.height))
      switch invocation.phase {
      case .inputting:
        if inlineActions {
          addButton("play.fill", "Run", frame: controlFrame.offsetBy(dx: 10, dy: 0)) {
            [weak editor] in editor?.toolController.submit(invocation.id)
          }
        }
      case .submitted: break
      case .processing:
        let spinner = NSProgressIndicator(
          frame: NSRect(x: controlFrame.minX, y: controlFrame.minY + 3, width: 18, height: 18))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        mount(spinner)
        addButton("xmark", "Cancel", frame: controlFrame.offsetBy(dx: 24, dy: 0)) { [weak editor] in
          editor?.toolController.cancel(invocation.id)
        }
      case .pending:
        if output?.length == 0 {
          let empty = NSTextField(labelWithString: "∅")
          empty.textColor = .secondaryLabelColor
          empty.setAccessibilityLabel("Empty result")
          empty.toolTip = "Empty result"
          empty.frame = NSRect(x: anchor.minX + 4, y: anchor.minY + 3, width: 20, height: 22)
          mount(empty)
        }
        addButton("arrow.triangle.merge", "Merge", frame: controlFrame) { [weak editor] in
          try? editor?.toolController.merge(invocation.id)
        }
        addButton("xmark", "Dismiss", frame: controlFrame.offsetBy(dx: 24, dy: 0)) {
          [weak editor] in try? editor?.toolController.dismiss(invocation.id)
        }
      case .error:
        addButton(
          "xmark", "Dismiss: \(invocation.message ?? "Execution error")", frame: controlFrame
        ) { [weak editor] in try? editor?.toolController.dismiss(invocation.id) }
      }
      if invocation.inputMode == "contextual", invocation.phase == .inputting {
        for (start, offset) in [(true, scope.location), (false, NSMaxRange(scope))] {
          guard let position = rects(NSRange(location: offset, length: 0)).first else { continue }
          let handleKey = invocation.id.uuidString + (start ? ".start" : ".end")
          visibleHandles.insert(handleKey)
          let handle = handles[handleKey] ?? ToolScopeHandle(frame: .zero)
          handles[handleKey] = handle
          handle.isHidden = false
          handle.isStart = start
          handle.toolTip =
            start
            ? "Context start — drag to choose source text"
            : "Context end — drag to choose source text"
          let controlGap: CGFloat =
            !start && offset == NSMaxRange(token) && !sourceEndsLine ? 27 : 0
          handle.frame = NSRect(
            x: position.minX - 5 - controlGap, y: max(0, position.minY - 7), width: 16,
            height: max(30, position.height + 7))
          handle.setAccessibilityRole(.slider)
          handle.setAccessibilityElement(true)
          handle.setAccessibilityLabel(start ? "Context start" : "Context end")
          handle.setAccessibilityValue(NSNumber(value: offset))
          handle.setAccessibilityMinValue(NSNumber(value: 0))
          handle.setAccessibilityMaxValue(NSNumber(value: (snapshot.text as NSString).length))
          handle.adjusted = { [weak editor] direction in
            guard let editor,
              let current = editor.state.invocations.first(where: { $0.id == invocation.id }),
              let scope = current.scope.resolve(in: editor.state.lines)
            else { return }
            let offset = start ? scope.location : NSMaxRange(scope),
              text = editor.state.text as NSString
            let next =
              direction < 0
              ? (offset > 0 ? text.rangeOfComposedCharacterSequence(at: offset - 1).location : 0)
              : (offset < text.length
                ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset)) : offset)
            try? editor.toolController.moveBoundary(invocation.id, start: start, to: next)
          }
          handle.moved = { [weak editor] point in
            guard let editor else { return }
            let index = editor.textView.characterIndexForInsertion(at: point)
            try? editor.toolController.moveBoundary(invocation.id, start: start, to: index)
          }
          handle.focused = { [weak self] in self?.focusedBoundary = (invocation.id, start) }
          handle.key = { [weak self] in self?.handle($0) ?? false }
          editor.textView.addSubview(handle, positioned: .above, relativeTo: nil)
        }
      }
      if invocation.inputMode.hasPrefix("ephemeral"), invocation.phase == .inputting,
        let tokenRect = rects(token).last
      {
        visiblePrompts.insert(invocation.id)
        let prompt = prompts[invocation.id] ?? ToolPromptView()
        let isNew = prompts[invocation.id] == nil
        prompts[invocation.id] = prompt
        prompt.isHidden = false
        prompt.appearance = NSAppearance(named: .darkAqua)
        if isNew { prompt.input.string = editor.toolController.prompts[invocation.id] ?? "" }
        prompt.multiline = invocation.inputMode == "ephemeralMultiline"
        let viewport = editor.textView.visibleRect
        let width = min(320, max(120, viewport.width - 16))
        // Prefer below/right. At a window edge keep the form usable and
        // retain a short attachment to the same document anchor.
        let x = max(viewport.minX + 8, min(tokenRect.maxX, viewport.maxX - width))
        let height = min(prompt.multiline ? 150.0 : 70.0, viewport.height)
        let below = tokenRect.maxY + 4
        let y =
          below + height <= viewport.maxY ? below : max(viewport.minY, tokenRect.minY - height - 4)
        prompt.frame = editor.view.convert(
          NSRect(x: x, y: y, width: width, height: height), from: editor.textView)
        if x < tokenRect.maxX {
          shapes.append(
            (
              Self.union([NSRect(x: tokenRect.maxX - 2, y: tokenRect.maxY, width: 2, height: 5)]),
              .systemTeal
            ))
        }
        prompt.changed = { [weak editor] in editor?.toolController.prompts[invocation.id] = $0 }
        prompt.submit = { [weak editor] in editor?.toolController.submit(invocation.id) }
        prompt.dismiss = { [weak editor] in editor?.toolController.cancel(invocation.id) }
        // A persistent prompt must not share the glyph/control stacking
        // context: inline actions are rebuilt on subsequent refreshes.
        editor.view.addSubview(prompt, positioned: .above, relativeTo: nil)
        if isNew { editor.view.window?.makeFirstResponder(prompt.input) }
      }
    }
    for (id, prompt) in prompts
    where !snapshot.invocations.contains(where: { $0.id == id && $0.phase == .inputting }) {
      if editor.view.window?.firstResponder === prompt.input {
        editor.view.window?.makeFirstResponder(editor.textView)
      }
      prompt.removeFromSuperview()
      prompts.removeValue(forKey: id)
    }
    for (id, prompt) in prompts where !visiblePrompts.contains(id) { prompt.isHidden = true }
    for (key, handle) in handles
    where !snapshot.invocations.contains(where: {
      key.hasPrefix($0.id.uuidString) && $0.phase == .inputting
    }) {
      if editor.view.window?.firstResponder === handle {
        editor.view.window?.makeFirstResponder(editor.textView)
      }
      handle.removeFromSuperview()
      handles.removeValue(forKey: key)
    }
    for (key, handle) in handles where !visibleHandles.contains(key) { handle.isHidden = true }
    if let (range, packages, selected) = completion, let anchor = rects(range).last {
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
      let popover = ToolCompletionPopover(frame: .zero)
      popover.appearance = NSAppearance(named: .darkAqua)
      let origin = editor.view.convert(anchor, from: editor.textView)
      let height = CGFloat(visible.count) * 32 + 12
      let viewport = editor.view.convert(
        editor.scroll.contentView.bounds, from: editor.scroll.contentView)
      // Root overlay sits above TextKit's independently composited glyph layers.
      let below = editor.view.isFlipped ? origin.maxY + 4 : origin.minY - height - 4
      popover.frame = NSRect(
        x: min(max(viewport.minX + 8, origin.minX), viewport.maxX - width - 8),
        y: max(viewport.minY, min(below, viewport.maxY - height)), width: width, height: height)
      popover.wantsLayer = true
      popover.layer?.cornerRadius = 9
      popover.shadow = NSShadow()
      popover.shadow?.shadowBlurRadius = 12
      popover.setAccessibilityElement(true)
      popover.setAccessibilityRole(.group)
      popover.setAccessibilityLabel("Tool completions")
      for (index, package) in visible.enumerated() {
        let button = ToolCompletionRow(
          command: package.manifest.command, name: package.manifest.name,
          selected: index + first == selected
        ) { [weak self, weak editor] in
          self?.abandonCompletion()
          try? editor?.toolController.accept(package, token: range, space: true)
        }
        button.frame = NSRect(x: 6, y: 6 + CGFloat(index) * 32, width: width - 12, height: 32)
        popover.addSubview(button)
      }
      popover.setAccessibilityChildren(popover.subviews)
      editor.view.addSubview(popover, positioned: .above, relativeTo: nil)
      controls.append(popover)
    }
    editor.textView.window?.invalidateCursorRects(for: editor.textView)
    decoratedViewport = viewportStamp()
    if invalidateDisplay { editor.textView.needsDisplay = true }
  }

  private func mount(_ view: NSView) {
    editor?.textView.addSubview(view)
    controls.append(view)
  }
  private func clippedBeforeFollowingGlyph(_ frames: [NSRect], end: Int, text: String) -> [NSRect] {
    guard end < text.utf16.count,
      ![10, 13, 0x85, 0x2028, 0x2029].contains((text as NSString).character(at: end)),
      let next = editor?.linePresentation.glyphFrame(at: end)
    else { return frames }
    // Decorations may pad into whitespace inside their range, but neither
    // their fill nor their 1pt stroke may enter the next character's cell.
    return frames.compactMap { frame in
      guard frame.maxY > next.minY + 1, frame.minY < next.maxY - 1 else { return frame }
      var clipped = frame
      clipped.size.width = min(frame.maxX, next.minX - 1) - frame.minX
      return clipped.width > 0 ? clipped : nil
    }
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
          ?? "Execution failed"
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
    editor.linePresentation.setAccessories(Array(values))
  }
  private func leadingActions(_ output: NSRange, text: String) -> Bool {
    // Long results keep their actions at the source/output seam rather than
    // requiring a scroll to the end. Short inline results retain trailing actions.
    output.length > 40 || (text as NSString).substring(with: output).contains("\n")
  }
  private func leadingIndent(_ output: NSRange, text: String) -> Bool {
    output.length > 0 && leadingActions(output, text: text) && startsLine(output, text: text)
  }
  private func startsLine(_ output: NSRange, text: String) -> Bool {
    output.location > 0
      && [10, 13, 0x85, 0x2028, 0x2029].contains(
        (text as NSString).character(at: output.location - 1))
  }
  private func endsLine(_ offset: Int, text: String) -> Bool {
    let text = text as NSString
    return offset == text.length
      || offset < text.length
        && [10, 13, 0x85, 0x2028, 0x2029].contains(text.character(at: offset))
  }
  private func connected(_ frames: [NSRect]) -> [NSRect] {
    guard frames.count > 1 else { return frames }
    var result: [NSRect] = []
    for (index, frame) in frames.enumerated() {
      if index > 0 {
        let previous = frames[index - 1]
        if frame.minY > previous.minY {
          result.append(
            NSRect(
              x: min(previous.minX, frame.minX), y: previous.maxY - 1,
              width: max(previous.maxX, frame.maxX) - min(previous.minX, frame.minX),
              height: max(2, frame.minY - previous.maxY + 2)))
        }
      }
      result.append(frame)
    }
    return result
  }
  private func addButton(
    _ symbol: String, _ label: String, frame: NSRect, action: @escaping () -> Void
  ) {
    let button = ToolActionButton(symbol: symbol, label: label, action: action)
    button.frame = NSRect(
      x: frame.minX, y: frame.minY, width: symbol == "play.fill" ? 36 : 24,
      height: max(24, frame.height))
    mount(button)
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
    shapes.contains { path, color in
      (color == ToolPresentationColors.pending) == pending && path.contains(point)
    }
  }
  func draw(_ rect: NSRect) {
    // TextKit can expand/reposition its viewport after publication or during
    // scrolling without a document edit. Derive paths for the actual paint
    // pass, rather than retaining only the old viewport's rectangles.
    if decoratedViewport != viewportStamp() {
      refresh(recomputeCompletion: false, invalidateDisplay: false)
    }
    for (path, color) in shapes where path.elementCount > 0 && path.bounds.intersects(rect) {
      // Composite once against the canvas, never against another tool's
      // tint (contextual scopes can geometrically contain their result).
      ToolPresentationColors.canvas.blended(withFraction: 0.16, of: color)!.setFill()
      path.fill()
      color.withAlphaComponent(0.65).setStroke()
      path.lineWidth = 1
      path.stroke()
    }
  }

  /// Trace the union's boundary on a coordinate grid, omitting every shared edge.
  static func union(_ rectangles: [NSRect]) -> NSBezierPath {
    let rects = rectangles.filter { $0.width > 0 && $0.height > 0 }
    let result = NSBezierPath()
    guard !rects.isEmpty else { return result }
    let xs = Array(Set(rects.flatMap { [$0.minX, $0.maxX] })).sorted()
    let ys = Array(Set(rects.flatMap { [$0.minY, $0.maxY] })).sorted()
    struct Point: Hashable {
      let x: Int
      let y: Int
    }
    var occupied = Set<Point>()
    for x in 0..<max(0, xs.count - 1) {
      for y in 0..<max(0, ys.count - 1) {
        let center = NSPoint(x: (xs[x] + xs[x + 1]) / 2, y: (ys[y] + ys[y + 1]) / 2)
        if rects.contains(where: { $0.contains(center) }) { occupied.insert(Point(x: x, y: y)) }
      }
    }
    var edges: [Point: Point] = [:]
    for p in occupied {
      if !occupied.contains(Point(x: p.x, y: p.y - 1)) { edges[p] = Point(x: p.x + 1, y: p.y) }
      if !occupied.contains(Point(x: p.x + 1, y: p.y)) {
        edges[Point(x: p.x + 1, y: p.y)] = Point(x: p.x + 1, y: p.y + 1)
      }
      if !occupied.contains(Point(x: p.x, y: p.y + 1)) {
        edges[Point(x: p.x + 1, y: p.y + 1)] = Point(x: p.x, y: p.y + 1)
      }
      if !occupied.contains(Point(x: p.x - 1, y: p.y)) { edges[Point(x: p.x, y: p.y + 1)] = p }
    }
    while let start = edges.keys.first {
      var points: [NSPoint] = []
      var current = start
      while let next = edges.removeValue(forKey: current) {
        points.append(NSPoint(x: xs[current.x], y: ys[current.y]))
        current = next
        if current == start { break }
      }
      guard points.count >= 3 else { continue }
      // Remove collinear grid vertices before rounding only boundary corners.
      points = points.indices.compactMap { index in
        let p = points[(index + points.count - 1) % points.count], c = points[index],
          n = points[(index + 1) % points.count]
        return p.x == c.x && c.x == n.x || p.y == c.y && c.y == n.y ? nil : c
      }
      guard points.count >= 3 else { continue }
      for index in points.indices {
        let p = points[(index + points.count - 1) % points.count], c = points[index],
          n = points[(index + 1) % points.count]
        let before = hypot(c.x - p.x, c.y - p.y), after = hypot(n.x - c.x, n.y - c.y)
        let radius = min(4, min(before, after) / 2)
        let a = NSPoint(
          x: c.x + (p.x - c.x) * radius / before, y: c.y + (p.y - c.y) * radius / before)
        let b = NSPoint(
          x: c.x + (n.x - c.x) * radius / after, y: c.y + (n.y - c.y) * radius / after)
        if index == 0 { result.move(to: a) } else { result.line(to: a) }
        result.curve(to: b, controlPoint1: c, controlPoint2: c)
      }
      result.close()
    }
    return result
  }
}
