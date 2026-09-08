import AppKit
import JortDocument

/// An in-document overlay. Navigation leaves the query and results available.
@MainActor final class DocumentSearchController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let query = NSSearchField()
    let table = PaletteTable()
    let count = NSTextField(labelWithString: "")
    let caseSensitive = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let wholeWord = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    let more = NSButton(title: "Show more matches", target: nil, action: nil)
    let close = NSButton(title: "✕", target: nil, action: nil)
    let previous = NSButton(title: "↑", target: nil, action: nil)
    let next = NSButton(title: "↓", target: nil, action: nil)
    let model = DocumentSearchModel()
    var snapshot: (() -> DocumentSnapshot)?
    var navigate: ((SearchMatch) -> Bool)?
    var onDismiss: (() -> Void)?
    var window: NSWindow? { view.window }
    private let resultsArea = NSStackView()
    private var finishing = false
    private var limit = 1_000
    private var scrollHeight: NSLayoutConstraint!

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = NSView(); view.wantsLayer = true
        view.layer?.backgroundColor = EditorMetrics.chrome.cgColor; view.layer?.cornerRadius = 10
        view.layer?.borderWidth = 1; view.layer?.borderColor = EditorMetrics.separator.cgColor
        view.shadow = NSShadow(); view.shadow?.shadowBlurRadius = 12
        view.setAccessibilityLabel("Search current document")
        query.placeholderString = "Search…"; query.delegate = self; query.sendsSearchStringImmediately = true
        query.setAccessibilityLabel("Document search query")
        close.target = self; close.action = #selector(dismissSearch); close.isBordered = false; close.setAccessibilityLabel("Close search")
        previous.target = self; previous.action = #selector(previousMatch)
        next.target = self; next.action = #selector(nextMatch)
        previous.setAccessibilityLabel("Previous search match"); next.setAccessibilityLabel("Next search match")
        count.setAccessibilityLabel("Search result count and status"); count.font = .systemFont(ofSize: 11)
        for button in [caseSensitive, wholeWord] { button.target = self; button.action = #selector(refreshQuery); button.font = .systemFont(ofSize: 11) }
        more.target = self; more.action = #selector(loadMore)
        let header = NSStackView(views: [query, close]); header.spacing = 8
        let options = NSStackView(views: [caseSensitive, wholeWord]); options.spacing = 12
        let navigation = NSStackView(views: [count, NSView(), previous, next]); navigation.spacing = 6
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = table
        table.addTableColumn(NSTableColumn(identifier: .init("match")))
        table.headerView = nil; table.rowHeight = 48; table.style = .plain; table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("Search matches in document order")
        table.activate = { [weak self] in self?.activateSelection() }; table.dismiss = { [weak self] in self?.dismiss() }
        table.target = self; table.action = #selector(clickedResult)
        resultsArea.orientation = .vertical; resultsArea.alignment = .leading; resultsArea.spacing = 8
        for child in [options, navigation, scroll, more] { resultsArea.addArrangedSubview(child) }
        let stack = NSStackView(views: [header, resultsArea]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 192)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), resultsArea.widthAnchor.constraint(equalTo: stack.widthAnchor),
            navigation.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            close.widthAnchor.constraint(equalToConstant: 22), scrollHeight
        ])
        model.onChange = { [weak self] in self?.reload() }; reload()
    }
    func present() { _ = view; view.window?.makeFirstResponder(query) }
    override func viewDidLayout() { super.viewDidLayout(); updateResultsHeight() }
    private func updateResultsHeight() {
        let available = max(48, (view.superview?.bounds.height ?? 400) - 180)
        let height = min(192, available, CGFloat(max(1, min(4, model.results.count))) * 48)
        if scrollHeight.constant != height { scrollHeight.constant = height }
    }
    func controlTextDidChange(_ obj: Notification) { refreshQuery() }
    @objc func refreshQuery() { limit = 1_000; search() }
    func documentChanged() { if !query.stringValue.isEmpty { search() } }
    private func search() {
        guard let snapshot else { return }
        model.search(snapshot: snapshot(), query: query.stringValue, options: .init(caseSensitive: caseSensitive.state == .on, wholeWord: wholeWord.state == .on), limit: limit)
    }
    @objc private func loadMore() { limit += 1_000; search() }
    private func reload() {
        table.reloadData(); count.stringValue = model.message; more.isHidden = !model.hasMore; resultsArea.isHidden = query.stringValue.isEmpty
        updateResultsHeight()
        if !model.results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        previous.isEnabled = !model.results.isEmpty; next.isEnabled = !model.results.isEmpty
        NSAccessibility.post(element: count, notification: .valueChanged)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let match = model.results[row], cell = NSTableCellView()
        let label = NSTextField(wrappingLabelWithString: "\(match.ordinal)   \(match.snippet)")
        label.font = .systemFont(ofSize: 12); label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel("Line \(match.ordinal), \(match.snippet)"); label.toolTip = match.snippet
        label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); cell.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): select(delta: 1)
        case #selector(NSResponder.moveUp(_:)): select(delta: -1)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }
    private func select(delta: Int) {
        guard !model.results.isEmpty else { return }
        let row = (max(0, table.selectedRow) + delta + model.results.count) % model.results.count
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
        NSAccessibility.post(element: table, notification: .selectedRowsChanged)
    }
    @objc func previousMatch() { select(delta: -1); activateSelection() }
    @objc func nextMatch() { select(delta: 1); activateSelection() }
    @objc private func clickedResult() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false); activateSelection()
    }
    @objc func activateSelection() {
        guard !finishing, model.results.indices.contains(table.selectedRow) else { return }
        if navigate?(model.results[table.selectedRow]) == true {
            count.stringValue = "\(table.selectedRow + 1) of \(model.results.count)\(model.hasMore ? "+" : "") matches"
        } else { search(); count.stringValue = "Document changed — refreshing matches" }
    }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    @objc private func dismissSearch() { dismiss() }
    @objc func dismiss() {
        guard !finishing else { return }; finishing = true; model.cancel()
        let callback = onDismiss; onDismiss = nil; callback?()
    }
}
