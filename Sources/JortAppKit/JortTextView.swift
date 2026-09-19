import AppKit

@MainActor public final class JortTextView: NSTextView {
  let history = UndoManager()
  // Native text mutations must not register a second, text-only undo action.
  public override var undoManager: UndoManager? { nil }
  public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(undo(_:)) { return history.canUndo }
    if item.action == #selector(redo(_:)) { return history.canRedo }
    return super.validateUserInterfaceItem(item)
  }
  @objc public func undo(_ sender: Any?) { history.undo() }
  @objc public func redo(_ sender: Any?) { history.redo() }
  var onCompositionCommit: (() -> Void)?
  var onLayout: (() -> Void)?
  var onWindowGeometry: (() -> Void)?
  var onAppearance: (() -> Void)?
  private var lastLayoutBounds: NSRect?
  private var lastVisibleRect: NSRect?
  private var lastViewportEnd: Int?
  public override func layout() {
    super.layout()
    let end: Int?
    if let manager = textLayoutManager, let content = manager.textContentManager,
      let viewport = manager.textViewportLayoutController.viewportRange
    {
      end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
    } else {
      end = nil
    }
    guard lastLayoutBounds != bounds || lastVisibleRect != visibleRect || lastViewportEnd != end
    else { return }
    lastLayoutBounds = bounds
    lastVisibleRect = visibleRect
    lastViewportEnd = end
    onLayout?()
  }
  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onAppearance?()
  }
  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    onWindowGeometry?()
  }
  var onTextChange: (() -> Void)?
  var onEscape: (() -> Bool)?
  var onToolKey: ((NSEvent) -> Bool)?
  var onToolDraw: ((NSRect) -> Void)?
  var isPasting = false
  var onPaste: (() -> Void)?
  var onCommittedSlash: (() -> Void)?
  public override func resetCursorRects() {
    super.resetCursorRects()
    // NSTextView installs an I-beam across its entire visible area, including
    // embedded controls. Partition that region instead of competing with it.
    discardCursorRects()
    var regions = [visibleRect]
    for button in subviews where button is NSButton && !button.isHidden {
      let hit = button.frame.intersection(visibleRect)
      guard !hit.isEmpty else { continue }
      regions = regions.flatMap { region -> [NSRect] in
        let cut = region.intersection(hit)
        guard !cut.isEmpty else { return [region] }
        return [
          NSRect(
            x: region.minX, y: region.minY, width: region.width, height: cut.minY - region.minY),
          NSRect(x: region.minX, y: cut.maxY, width: region.width, height: region.maxY - cut.maxY),
          NSRect(x: region.minX, y: cut.minY, width: cut.minX - region.minX, height: cut.height),
          NSRect(x: cut.maxX, y: cut.minY, width: region.maxX - cut.maxX, height: cut.height),
        ].filter { !$0.isEmpty }
      }
      addCursorRect(hit, cursor: .pointingHand)
    }
    for region in regions { addCursorRect(region, cursor: .iBeam) }
  }
  public override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    let point = convert(event.locationInWindow, from: nil)
    if subviews.contains(where: { $0 is NSButton && !$0.isHidden && $0.frame.contains(point) }) {
      NSCursor.pointingHand.set()
    }
  }
  public override func cursorUpdate(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if subviews.contains(where: { $0 is NSButton && !$0.isHidden && $0.frame.contains(point) }) {
      NSCursor.pointingHand.set()
    } else {
      super.cursorUpdate(with: event)
    }
  }
  public override func keyDown(with event: NSEvent) {
    if !hasMarkedText(), onToolKey?(event) == true { return }
    super.keyDown(with: event)
  }
  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if window?.firstResponder === self, event.modifierFlags.contains([.command, .option]),
      [123, 124, 125, 126].contains(event.keyCode),
      !hasMarkedText(), onToolKey?(event) == true
    {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
  public override func insertText(_ insertString: Any, replacementRange: NSRange) {
    let committed = (insertString as? NSAttributedString)?.string ?? (insertString as? String ?? "")
    if !isPasting, committed == "/" || (hasMarkedText() && committed.contains("/")) {
      onCommittedSlash?()
    }
    var attributes = typingAttributes
    attributes[.kern] = 0
    attributes.removeValue(forKey: NSAttributedString.Key("JortToolDecoration"))
    attributes[.font] = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    typingAttributes = attributes
    super.insertText(insertString, replacementRange: replacementRange)
  }
  public override func paste(_ sender: Any?) {
    pasteAsPlainText(sender)
  }
  public override func pasteAsPlainText(_ sender: Any?) {
    let previous = isPasting
    isPasting = true
    defer { isPasting = previous }
    onPaste?()
    super.pasteAsPlainText(sender)
  }
  public override func copy(_ sender: Any?) {
    let range = selectedRange()
    guard NSMaxRange(range) <= string.utf16.count else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString((string as NSString).substring(with: range), forType: .string)
  }
  public override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    onToolDraw?(rect)
  }
  public override func didChangeText() {
    super.didChangeText()
    onTextChange?()
  }
  public override func cancelOperation(_ sender: Any?) {
    if onEscape?() != true { super.cancelOperation(sender) }
  }
  var lineAccessibilityChildren: (() -> [Any]?)?
  var toolAccessibilityChildren: (() -> [Any])?
  public override func accessibilityChildren() -> [Any]? {
    let children = lineAccessibilityChildren?() ?? super.accessibilityChildren() ?? []
    let tools = toolAccessibilityChildren?() ?? []
    return children
      + tools.filter { tool in !children.contains { ($0 as AnyObject) === (tool as AnyObject) } }
  }
  public override func unmarkText() {
    let marked = markedRange()
    if !isPasting, marked.location != NSNotFound, NSMaxRange(marked) <= string.utf16.count,
      (string as NSString).substring(with: marked).contains("/")
    {
      onCommittedSlash?()
    }
    super.unmarkText()
    onCompositionCommit?()
  }
}
