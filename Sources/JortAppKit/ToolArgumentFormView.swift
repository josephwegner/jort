import AppKit
import JortToolContracts

@MainActor private final class ToolArgumentFieldsView: NSView {
  override var isFlipped: Bool { true }
}

/// A small native form. Its values are invocation options, never document text.
@MainActor final class ToolArgumentFormView: NSView, NSTextFieldDelegate {
  private(set) var fields: [(name: String, field: NSTextField)] = []
  private let title = NSTextField(labelWithString: "Arguments")
  private var labels: [NSTextField] = []
  private let fieldScroll = NSScrollView()
  private let fieldArea = ToolArgumentFieldsView()
  private var run: ToolActionButton!
  private var back: ToolActionButton!
  var changed: ((String, String) -> Void)?
  var submit: (() -> Void)?
  var returnToEditor: (() -> Void)?
  override var isFlipped: Bool { true }
  var preferredHeight: CGFloat { CGFloat(fields.count) * 52 + 66 }

  init(definitions: [ToolArgumentDefinition], values: [String: String], description: String) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    layer?.borderColor = NSColor.systemTeal.cgColor
    layer?.borderWidth = 1
    layer?.cornerRadius = 6
    title.stringValue = description.isEmpty ? "Arguments" : description
    title.lineBreakMode = .byTruncatingTail
    title.toolTip = description
    addSubview(title)
    fieldScroll.documentView = fieldArea
    fieldScroll.hasVerticalScroller = true
    fieldScroll.drawsBackground = false
    addSubview(fieldScroll)
    for definition in definitions {
      let label = NSTextField(labelWithString: definition.label)
      let field = NSTextField(string: values[definition.name] ?? "")
      field.delegate = self
      field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
      field.focusRingType = .exterior
      field.setAccessibilityLabel(definition.label)
      field.toolTip = definition.description
      field.setAccessibilityHelp(definition.description)
      switch definition.defaultValue {
      case .integer(let value): field.placeholderString = "Default: \(value)"
      case .string(let value):
        field.placeholderString = "Default: \(value.isEmpty ? "\"\"" : value)"
      case nil:
        field.placeholderString = definition.required == true ? "Required" : "Optional"
      }
      labels.append(label)
      fields.append((definition.name, field))
      fieldArea.addSubview(label)
      fieldArea.addSubview(field)
    }
    run = ToolActionButton(symbol: "play.fill", label: "Run (Shift+Enter)") { [weak self] in
      self?.submit?()
    }
    back = ToolActionButton(symbol: "arrow.uturn.backward", label: "Return to editor (Escape)") {
      [weak self] in self?.returnToEditor?()
    }
    addSubview(run)
    addSubview(back)
    for button in [run, back] {
      button?.returnToEditor = { [weak self] in self?.returnToEditor?() }
      button?.moveFocus = { [weak self, weak button] backwards in
        guard let button else { return }
        self?.focusAdjacent(to: button, backwards: backwards)
      }
    }
    let order: [NSView] = fields.map(\.field) + [run, back]
    for index in 0..<max(0, order.count - 1) { order[index].nextKeyView = order[index + 1] }
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Tool arguments")
    setAccessibilityChildren([title] + order)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    title.frame = NSRect(x: 10, y: 8, width: bounds.width - 20, height: 20)
    fieldScroll.frame = NSRect(
      x: 6, y: 32, width: bounds.width - 12, height: max(24, bounds.height - 64))
    fieldArea.frame = NSRect(
      x: 0, y: 0, width: fieldScroll.contentSize.width,
      height: max(fieldScroll.contentSize.height, CGFloat(fields.count) * 52))
    for index in fields.indices {
      let y = CGFloat(index) * 52
      labels[index].frame = NSRect(x: 4, y: y, width: fieldArea.bounds.width - 8, height: 18)
      fields[index].field.frame = NSRect(
        x: 4, y: y + 20, width: fieldArea.bounds.width - 8, height: 24)
    }
    run.frame = NSRect(x: bounds.width - 78, y: bounds.height - 28, width: 40, height: 24)
    back.frame = NSRect(x: bounds.width - 34, y: bounds.height - 28, width: 24, height: 24)
  }

  func focusFirst() {
    if let first = fields.first {
      window?.makeFirstResponder(first.field)
      first.field.scrollToVisible(first.field.bounds)
    }
  }

  func focusLastControl() { window?.makeFirstResponder(back) }

  private func focusAdjacent(to control: NSView, backwards: Bool) {
    let order: [NSView] = fields.map(\.field) + [run, back]
    guard let index = order.firstIndex(where: { $0 === control }) else { return }
    let next = index + (backwards ? -1 : 1)
    if order.indices.contains(next) {
      window?.makeFirstResponder(order[next])
      order[next].scrollToVisible(order[next].bounds)
    } else {
      returnToEditor?()
    }
  }

  func focusArgument(named name: String?) {
    if let field = fields.first(where: { $0.name == name })?.field {
      window?.makeFirstResponder(field)
      field.scrollToVisible(field.bounds)
    } else {
      focusFirst()
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField,
      let entry = fields.first(where: { $0.field === field })
    else { return }
    changed?(entry.name, field.stringValue)
  }

  func controlTextDidBeginEditing(_ notification: Notification) {
    guard let field = notification.object as? NSTextField else { return }
    field.scrollToVisible(field.bounds.insetBy(dx: 0, dy: -20))
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      returnToEditor?()
      return true
    }
    if selector == #selector(NSResponder.insertNewline(_:)),
      NSApp.currentEvent?.modifierFlags.contains(.shift) == true
    {
      submit?()
      return true
    }
    if selector == #selector(NSResponder.insertTab(_:)) {
      focusAdjacent(to: control, backwards: false)
      return true
    }
    if selector == #selector(NSResponder.insertBacktab(_:)) {
      focusAdjacent(to: control, backwards: true)
      return true
    }
    return false
  }
}
