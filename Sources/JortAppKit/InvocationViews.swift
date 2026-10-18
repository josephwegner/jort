import AppKit

@MainActor final class ToolActionButton: NSButton {
  override var acceptsFirstResponder: Bool { true }
  var invoke: (() -> Void)?
  var returnToEditor: (() -> Void)?
  var moveFocus: ((Bool) -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 {
      let backwards = event.modifierFlags.contains(.shift)
      if let moveFocus {
        moveFocus(backwards)
      } else if backwards {
        window?.selectPreviousKeyView(self)
      } else {
        window?.selectNextKeyView(self)
      }
    } else if event.keyCode == 53, let returnToEditor {
      returnToEditor()
    } else if event.keyCode == 36, isEnabled {
      invoke?()
    } else {
      super.keyDown(with: event)
    }
  }
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
    toolTip =
      symbol == "play.fill"
      ? LocalizedCopy.text("InvocationViews.run_shift_enter", fallback: "Run (Shift+Enter)") : label
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

@MainActor final class ToolCompletionRow: NSButton {
  var invoke: (() -> Void)?
  var command: String
  var name: String
  var selected: Bool
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
    setAccessibilityLabel(LocalizedCopy.format("completion.row", fallback: "%@  %@", command, name))
    setAccessibilityValue(
      selected ? LocalizedCopy.text("completion.selected", fallback: "Selected") : "")
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

@MainActor final class ToolCompletionPopover: NSView {
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
    path.fill()
    NSColor.separatorColor.setStroke()
    path.stroke()
  }
}

@MainActor final class ToolPromptView: NSView, NSTextViewDelegate {
  let input = NSTextView()
  private let scroll = NSScrollView()
  private let error = NSTextField(wrappingLabelWithString: "")
  private var run: ToolActionButton!
  private var close: ToolActionButton!
  var changed: ((String) -> Void)?
  var submit: (() -> Void)?
  var dismiss: (() -> Void)?
  var multiline = true
  var preferredHeight: CGFloat { (multiline ? 150 : 70) + (error.isHidden ? 0 : 36) }
  override var isFlipped: Bool { true }
  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    layer?.borderColor = ToolPresentationColors.command.cgColor
    layer?.borderWidth = 1
    layer?.cornerRadius = 6
    error.font = .systemFont(ofSize: 11)
    error.textColor = .systemRed
    error.maximumNumberOfLines = 2
    error.isHidden = true
    error.setAccessibilityRole(.staticText)
    addSubview(error)
    input.isRichText = false
    input.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    input.delegate = self
    input.setAccessibilityLabel(
      LocalizedCopy.text("InvocationViews.tool_prompt", fallback: "Tool prompt"))
    input.isVerticallyResizable = true
    input.textContainer?.widthTracksTextView = true
    scroll.documentView = input
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    addSubview(scroll)
    run = ToolActionButton(
      symbol: "play.fill", label: LocalizedCopy.text("InvocationViews.run", fallback: "Run")
    ) { [weak self] in self?.submit?() }
    close = ToolActionButton(
      symbol: "xmark",
      label: LocalizedCopy.text("InvocationViews.dismiss_prompt", fallback: "Dismiss prompt")
    ) { [weak self] in
      self?.dismiss?()
    }
    addSubview(run)
    addSubview(close)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(
      LocalizedCopy.text("InvocationViews.tool_prompt_form", fallback: "Tool prompt form"))
    setAccessibilityChildren([scroll, run, close])
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    let errorHeight: CGFloat = error.isHidden ? 0 : 36
    error.frame = NSRect(x: 8, y: 7, width: bounds.width - 16, height: errorHeight)
    scroll.frame = NSRect(
      x: 8, y: 8 + errorHeight, width: bounds.width - 16,
      height: max(24, bounds.height - 42 - errorHeight))
    input.frame.size.width = scroll.contentSize.width
    input.minSize = NSSize(width: 0, height: scroll.contentSize.height)
    run.frame = NSRect(x: bounds.width - 68, y: bounds.height - 28, width: 36, height: 24)
    close.frame = NSRect(x: bounds.width - 30, y: bounds.height - 28, width: 24, height: 24)
  }
  func setError(_ message: String?) {
    error.stringValue = message ?? ""
    error.isHidden = message == nil
    if let message { error.setAccessibilityLabel("Tool error: \(message)") }
    setAccessibilityChildren((error.isHidden ? [] : [error]) + [scroll, run, close])
    needsLayout = true
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

@MainActor final class ToolScopeHandle: NSView {
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
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { needsDisplay = true }
    return accepted
  }
  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { needsDisplay = true }
    return resigned
  }
  override func draw(_ dirtyRect: NSRect) {
    ToolPresentationColors.context.setFill()
    let x = bounds.midX
    NSBezierPath(rect: NSRect(x: x - 1, y: 2, width: 2, height: bounds.height - 6)).fill()
    let flag = NSBezierPath()
    flag.move(to: NSPoint(x: x, y: bounds.height - 2))
    flag.line(to: NSPoint(x: x + (isStart ? 7 : -7), y: bounds.height - 2))
    flag.line(to: NSPoint(x: x, y: bounds.height - 9))
    flag.close()
    flag.fill()
    if window?.firstResponder === self {
      NSColor.keyboardFocusIndicatorColor.setStroke()
      let focusRing = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
      focusRing.lineWidth = 2
      focusRing.stroke()
    }
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
