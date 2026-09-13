import AppKit
import JortSettings

@MainActor public final class ModelPicker: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public let search = NSSearchField()
    public let table = NSTableView()
    public var onSelect: ((String) -> Void)?
    public var selectedID: String?
    public private(set) var models = ModelCatalog.bundled.models
    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        let column = NSTableColumn(identifier: .init("model")); table.addTableColumn(column); table.headerView = nil
        table.rowHeight = 38; table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("Available models"); search.setAccessibilityLabel("Filter models")
        search.placeholderString = "Filter models"; search.delegate = self
        table.target = self; table.action = #selector(selectModel)
        for item in [search, scroll] { item.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(item) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10), search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root; preferredContentSize = root.frame.size
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { models.count }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let model = models[row]
        let label = NSTextField(labelWithString: "\(model.name) · \(model.provider)")
        label.setAccessibilityLabel(label.stringValue); return label
    }
    public func controlTextDidChange(_ obj: Notification) {
        if search.stringValue.count > 256 { search.stringValue = String(search.stringValue.prefix(256)) }
        models = ModelCatalog.bundled.filter(search.stringValue); table.reloadData()
        if !models.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard !models.isEmpty else { return true }
            let step = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            table.selectRowIndexes(IndexSet(integer: max(0, min(models.count - 1, table.selectedRow + step))), byExtendingSelection: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { selectModel(); return true }
        return false
    }
    @objc public func selectModel() {
        guard models.indices.contains(table.selectedRow) else { return }; selectedID = models[table.selectedRow].id; onSelect?(selectedID!)
    }
}
