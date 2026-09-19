import AppKit

@MainActor public struct PaletteAction {
  public let id: String
  public let title: String
  public let keywords: String
  public let enabled: () -> Bool
  public let execute: () -> Void
  public init(
    id: String, title: String, keywords: String = "", enabled: @escaping () -> Bool = { true },
    execute: @escaping () -> Void
  ) {
    self.id = id
    self.title = title
    self.keywords = keywords
    self.enabled = enabled
    self.execute = execute
  }
  public func matches(_ query: String) -> Bool {
    query.split(whereSeparator: \.isWhitespace).allSatisfy {
      (title + " " + keywords).range(
        of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }
}

@MainActor
final class CommandPalette: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate, NSWindowDelegate
{
  let query = NSSearchField()
  let table = PaletteTable()
  let count = NSTextField(labelWithString: "")
  var actions: [PaletteAction] = []
  private(set) var results: [PaletteAction] = []
  var restore: (() -> Void)?
  private var finishing = false
  init(parent: NSWindow) {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 330),
      styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
    panel.title = "Pocket"
    panel.isReleasedWhenClosed = false
    super.init(window: panel)
    panel.delegate = self
    panel.setAccessibilityRole(.window)
    panel.setAccessibilitySubrole(.dialog)
    panel.setAccessibilityLabel("Pocket")
    let content = NSView()
    panel.contentView = content
    query.placeholderString = "Search actions"
    query.delegate = self
    query.setAccessibilityLabel("Search actions")
    query.sendsSearchStringImmediately = true
    count.setAccessibilityLabel("Matching actions")
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = table
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 30
    table.delegate = self
    table.dataSource = self
    table.setAccessibilityLabel("Actions")
    table.target = self
    table.action = #selector(executeClickedRow)
    table.doubleAction = #selector(executeClickedRow)
    table.activate = { [weak self] in self?.executeSelection() }
    table.dismiss = { [weak self] in self?.dismiss() }
    for view in [query, scroll, count] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    NSLayoutConstraint.activate([
      query.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      query.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      query.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      scroll.topAnchor.constraint(equalTo: query.bottomAnchor, constant: 10),
      scroll.leadingAnchor.constraint(equalTo: query.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: query.trailingAnchor),
      count.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
      count.leadingAnchor.constraint(equalTo: query.leadingAnchor),
      count.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
    ])
    panel.setFrameOrigin(NSPoint(x: parent.frame.midX - 220, y: parent.frame.maxY - 420))
    parent.addChildWindow(panel, ordered: .above)
  }
  required init?(coder: NSCoder) { fatalError() }
  func present(actions: [PaletteAction], restore: @escaping () -> Void) {
    self.actions = actions
    self.restore = restore
    reload()
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(query)
  }
  func reload() {
    let selected = results.indices.contains(table.selectedRow) ? results[table.selectedRow].id : nil
    results = actions.filter { $0.matches(query.stringValue) }
    table.reloadData()
    if !results.isEmpty {
      table.selectRowIndexes(
        IndexSet(integer: results.firstIndex { $0.id == selected } ?? 0),
        byExtendingSelection: false)
    }
    count.stringValue = results.isEmpty ? "No matching actions" : "\(results.count) actions"
    NSAccessibility.post(element: count, notification: .valueChanged)
  }
  func controlTextDidChange(_ obj: Notification) { reload() }
  func numberOfRows(in tableView: NSTableView) -> Int { results.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let action = results[row], enabled = action.enabled()
    let cell = NSTableCellView()
    let label = NSTextField(labelWithString: action.title + (enabled ? "" : " — unavailable"))
    label.textColor = enabled ? .labelColor : .secondaryLabelColor
    label.setAccessibilityLabel(label.stringValue)
    label.setAccessibilityEnabled(enabled)
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(label)
    cell.textField = label
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    guard !textView.hasMarkedText() else { return false }
    switch commandSelector {
    case #selector(NSResponder.moveDown(_:)): select(delta: 1)
    case #selector(NSResponder.moveUp(_:)): select(delta: -1)
    case #selector(NSResponder.insertNewline(_:)): executeSelection()
    case #selector(NSResponder.cancelOperation(_:)): dismiss()
    default: return false
    }
    return true
  }
  func select(delta: Int) {
    guard !results.isEmpty else { return }
    let row = max(0, min(results.count - 1, table.selectedRow + delta))
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    table.scrollRowToVisible(row)
    NSAccessibility.post(element: table, notification: .selectedRowsChanged)
  }
  @objc func executeSelection() {
    execute(row: table.selectedRow)
  }
  @objc private func executeClickedRow() {
    execute(row: table.clickedRow)
  }
  private func execute(row: Int) {
    guard !finishing, results.indices.contains(row) else { return }
    let action = results[row]
    guard action.enabled() else {
      reload()
      return
    }
    dismiss()
    action.execute()
  }
  override func cancelOperation(_ sender: Any?) { dismiss() }
  func windowDidResignKey(_ notification: Notification) { dismiss() }
  func dismiss() {
    guard !finishing else { return }
    finishing = true
    window?.parent?.removeChildWindow(window!)
    window?.orderOut(nil)
    let callback = restore
    restore = nil
    callback?()
  }
}

@MainActor class PaletteTable: NSTableView {
  var activate: (() -> Void)?
  var dismiss: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 {
      activate?()
    } else if event.keyCode == 53 {
      dismiss?()
    } else {
      super.keyDown(with: event)
    }
  }
}
