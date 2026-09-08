import AppKit
import JortDocument
import JortPersistence

@MainActor final class HistoryWorkspaceController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: HistoryBrowserModel
    let revisions = PaletteTable()
    let changes = HistoryDiffTable()
    let snapshot = HistorySnapshotText(usingTextLayoutManager: true)
    let snapshotScroll = NSScrollView()
    let changesScroll = NSScrollView()
    let mode = NSSegmentedControl(labels: ["Changes", "Snapshot"], trackingMode: .selectOne, target: nil, action: nil)
    let status = NSTextField(labelWithString: "Read-only history")
    let restore = NSButton(title: "Restore…", target: nil, action: nil)
    let done = NSButton(title: "Done", target: nil, action: nil)
    private let revisionScroll = NSScrollView()
    private var snapshotRuler: LineRuler!
    private var shownRevision: UUID?
    private var shownComparison: UUID?
    private var wantsChanges = true
    private(set) var restoring = false
    private enum Row { case line(Int), fold(Range<Int>) }
    private var rows: [Row] = []
    var onDismiss: (() -> Void)?
    var onRestore: ((Int64) async throws -> Void)?

    init(store: any HistoryStore) { model = HistoryBrowserModel(store: store); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true; view.layer?.backgroundColor = EditorMetrics.canvas.cgColor
        let rail = NSView(), footer = NSView(), actions = NSView(), divider = NSBox()
        divider.boxType = .separator
        for surface in [rail, footer] { surface.wantsLayer = true; surface.layer?.backgroundColor = EditorMetrics.chrome.cgColor }
        let title = NSTextField(labelWithString: "Version History")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        revisionScroll.hasVerticalScroller = true; revisionScroll.documentView = revisions
        revisionScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateVisibleRevisions), name: NSView.boundsDidChangeNotification, object: revisionScroll.contentView)
        revisions.addTableColumn(NSTableColumn(identifier: .init("revision")))
        revisions.headerView = nil; revisions.rowHeight = 76; revisions.style = .plain
        revisions.backgroundColor = EditorMetrics.chrome
        revisions.delegate = self; revisions.dataSource = self
        revisions.setAccessibilityLabel("Retained revisions, newest first")
        revisions.dismiss = { [weak self] in self?.dismissHistory() }
        revisions.activate = { [weak self] in self?.selectRow() }
        mode.target = self; mode.action = #selector(selectPresentation)
        mode.setAccessibilityLabel("History presentation")
        restore.target = self; restore.action = #selector(confirmRestore)
        restore.bezelStyle = .rounded; restore.isEnabled = false
        restore.setAccessibilityLabel("Restore selected revision, confirmation required")
        done.target = self; done.action = #selector(dismissHistory); done.bezelStyle = .rounded
        status.font = .systemFont(ofSize: 11); status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        snapshot.isEditable = false; snapshot.isSelectable = true; snapshot.isRichText = false
        snapshot.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        snapshot.minSize = .zero; snapshot.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        snapshot.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        snapshot.textColor = .labelColor; snapshot.backgroundColor = EditorMetrics.canvas
        snapshot.textContainerInset = EditorMetrics.contentInset
        snapshot.isVerticallyResizable = true; snapshot.isHorizontallyResizable = false
        snapshot.autoresizingMask = [.width]
        snapshot.textContainer?.widthTracksTextView = true
        snapshot.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        snapshot.setAccessibilityLabel("Historical snapshot, read-only")
        snapshot.dismiss = { [weak self] in self?.dismissHistory() }
        snapshotScroll.documentView = snapshot; snapshotScroll.hasVerticalScroller = true
        snapshotRuler = LineRuler(scrollView: snapshotScroll, textView: snapshot)
        snapshotRuler.readOnly = true
        snapshotScroll.verticalRulerView = snapshotRuler
        snapshotScroll.hasVerticalRuler = true; snapshotScroll.rulersVisible = true
        let changeColumn = NSTableColumn(identifier: .init("change")); changeColumn.width = 800
        changes.addTableColumn(changeColumn); changes.headerView = nil; changes.rowHeight = 24
        changes.style = .plain; changes.intercellSpacing = .zero; changes.selectionHighlightStyle = .none
        changes.backgroundColor = EditorMetrics.canvas
        changes.delegate = self; changes.dataSource = self
        changes.setAccessibilityLabel("Changes with old and new line numbers")
        changes.activate = { [weak self] in self?.expandSelection() }
        changes.dismiss = { [weak self] in self?.dismissHistory() }
        changes.target = self; changes.doubleAction = #selector(expandSelection)
        changesScroll.documentView = changes; changesScroll.hasVerticalScroller = true; changesScroll.hasHorizontalScroller = true
        for child in [snapshotScroll, changesScroll, rail, footer] { add(child, to: view) }
        for child in [title, mode, revisionScroll, actions] { add(child, to: rail) }
        for child in [divider, restore, done] { add(child, to: actions) }
        add(status, to: footer)
        let railWidth = rail.widthAnchor.constraint(equalToConstant: 280); railWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            railWidth, rail.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.48),
            rail.trailingAnchor.constraint(equalTo: view.trailingAnchor), rail.topAnchor.constraint(equalTo: view.topAnchor), rail.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: EditorMetrics.footerHeight),
            title.topAnchor.constraint(equalTo: rail.topAnchor, constant: 16), title.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 16),
            mode.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12), mode.leadingAnchor.constraint(equalTo: title.leadingAnchor), mode.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -16),
            revisionScroll.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 12), revisionScroll.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 6), revisionScroll.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -6),
            revisionScroll.bottomAnchor.constraint(equalTo: actions.topAnchor),
            actions.leadingAnchor.constraint(equalTo: rail.leadingAnchor), actions.trailingAnchor.constraint(equalTo: rail.trailingAnchor), actions.bottomAnchor.constraint(equalTo: rail.bottomAnchor), actions.heightAnchor.constraint(equalToConstant: 64),
            divider.leadingAnchor.constraint(equalTo: actions.leadingAnchor, constant: 12), divider.trailingAnchor.constraint(equalTo: actions.trailingAnchor, constant: -12), divider.topAnchor.constraint(equalTo: actions.topAnchor),
            done.trailingAnchor.constraint(equalTo: actions.trailingAnchor, constant: -12), done.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
            restore.leadingAnchor.constraint(equalTo: actions.leadingAnchor, constant: 12), restore.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12), status.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor, constant: -12), status.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        for preview in [snapshotScroll, changesScroll] {
            NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo: view.leadingAnchor), preview.trailingAnchor.constraint(equalTo: rail.leadingAnchor, constant: -1), preview.topAnchor.constraint(equalTo: view.topAnchor), preview.bottomAnchor.constraint(equalTo: footer.topAnchor)])
        }
        model.onChange = { [weak self] in self?.refresh() }
        refresh(); model.loadMore()
    }

    private func add(_ child: NSView, to parent: NSView) { child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child) }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(revisions) }
    override func viewDidLayout() { super.viewDidLayout(); updateVisibleRevisions() }
    override func cancelOperation(_ sender: Any?) { dismissHistory() }
    @objc func dismissHistory() { guard !restoring else { return }; model.cancel(); onDismiss?() }
    @objc private func updateVisibleRevisions() {
        guard isViewLoaded, !model.entries.isEmpty else { return }
        let range = revisions.rows(in: revisions.visibleRect)
        guard range.location != NSNotFound, range.location < model.entries.count, range.length > 0 else { return }
        let end = min(model.entries.count, NSMaxRange(range))
        model.requestSummaries(Array(model.entries[range.location..<end].map(\.sequence)))
        if end >= model.entries.count - 3 { model.loadMore() }
    }
    @objc func selectPresentation() { wantsChanges = mode.selectedSegment == 0; refresh() }

    private func refresh() {
        let selectedRow = model.entries.firstIndex { $0.sequence == model.selectedSequence }
        revisions.reloadData()
        if let selectedRow { revisions.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false) }
        restore.isEnabled = model.selected != nil && !restoring
        mode.setEnabled(model.comparison != nil, forSegment: 0)
        mode.selectedSegment = wantsChanges && model.comparison != nil ? 0 : 1
        snapshotScroll.isHidden = mode.selectedSegment == 0
        changesScroll.isHidden = !snapshotScroll.isHidden
        if let revision = model.selected {
            let attached = revision.snapshot.landmarks.filter { !$0.detached }.count
            status.stringValue = "\(HistoryBrowserModel.date(revision.metadata.timestamp)) · Read-only · \(attached) landmarks"
            if let comparison = model.comparison {
                if shownComparison != revision.metadata.id { makeRows(comparison); shownComparison = revision.metadata.id }
            }
            if shownRevision != revision.metadata.id {
                snapshot.string = revision.snapshot.text
                snapshotRuler.lines = revision.snapshot.lines; snapshotRuler.landmarks = revision.snapshot.landmarks
                snapshot.scrollRangeToVisible(NSRange(location: 0, length: 0))
                shownRevision = revision.metadata.id
            }
        } else {
            snapshot.string = ""; snapshotRuler.lines = []; snapshotRuler.landmarks = []
            shownRevision = nil; shownComparison = nil; rows = []; changes.reloadData()
            status.stringValue = model.message
        }
        status.toolTip = status.stringValue
        mode.toolTip = model.message
        status.setAccessibilityHelp(model.message)
        NSAccessibility.post(element: status, notification: .valueChanged)
        DispatchQueue.main.async { [weak self] in self?.updateVisibleRevisions() }
    }

    private func makeRows(_ comparison: HistoryComparison) {
        rows = []; var index = 0
        while index < comparison.lines.count {
            if comparison.lines[index].kind == .unchanged {
                let start = index
                while index < comparison.lines.count && comparison.lines[index].kind == .unchanged { index += 1 }
                if index - start > 8 {
                    rows.append(contentsOf: (start..<(start + 3)).map { .line($0) })
                    rows.append(.fold((start + 3)..<(index - 3)))
                    rows.append(contentsOf: ((index - 3)..<index).map { .line($0) })
                } else { rows.append(contentsOf: (start..<index).map { .line($0) }) }
            } else { rows.append(.line(index)); index += 1 }
        }
        let digits = String(max(comparison.lines.compactMap(\.oldOrdinal).max() ?? 1, comparison.lines.compactMap(\.newOrdinal).max() ?? 1)).count
        changes.gutterWidth = CGFloat(max(2, digits) * 16 + 62)
        changes.tableColumns[0].width = max(changesScroll.contentSize.width, CGFloat(comparison.lines.map { $0.text.utf16.count }.max() ?? 0) * 8 + CGFloat(max(2, digits) * 16 + 80))
        changes.reloadData()
    }

    @objc func expandSelection() {
        let index = changes.selectedRow
        guard rows.indices.contains(index), case .fold(let range) = rows[index] else { return }
        rows.replaceSubrange(index...index, with: range.map { .line($0) }); changes.reloadData()
        changes.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === revisions ? model.entries.count : rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView === revisions ? HistoryRevisionRow() : nil
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if notification.object as? NSTableView === revisions { selectRow() } }
    private func selectRow() {
        guard !restoring, model.entries.indices.contains(revisions.selectedRow) else { return }
        let sequence = model.entries[revisions.selectedRow].sequence
        if sequence != model.selectedSequence { model.select(sequence) }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === revisions { return revisionCell(model.entries[row]) }
        switch rows[row] {
        case .fold(let range):
            let cell = NSTableCellView()
            let button = NSButton(title: "Show \(range.count) unchanged lines", target: self, action: #selector(expandButton(_:)))
            button.bezelStyle = .inline; button.tag = row
            button.setAccessibilityLabel("Expand \(range.count) unchanged lines")
            add(button, to: cell)
            NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12), button.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        case .line(let index):
            guard let comparison = model.comparison else { return nil }
            let digits = String(max(model.selected?.snapshot.lines.count ?? 1, model.baseline?.snapshot.lines.count ?? 1)).count
            return HistoryDiffCell(line: comparison.lines[index], digits: digits)
        }
    }

    @objc private func expandButton(_ sender: NSButton) {
        changes.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
        expandSelection()
    }

    private func revisionCell(_ entry: HistoryEntry) -> NSView {
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: entry.metadata.map { HistoryBrowserModel.date($0.timestamp) } ?? "Unavailable revision")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let reason = NSTextField(labelWithString: entry.metadata?.reason ?? "Cannot read revision")
        reason.font = .systemFont(ofSize: 11); reason.textColor = .secondaryLabelColor
        reason.lineBreakMode = .byTruncatingTail
        let counts = NSTextField(labelWithString: "Calculating changes…")
        counts.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); counts.textColor = .tertiaryLabelColor
        if let summary = model.summaries[entry.sequence] {
            switch summary {
            case .changes(let added, let removed):
                let value = NSMutableAttributedString(string: "+\(added)", attributes: [.foregroundColor: NSColor.systemGreen])
                value.append(NSAttributedString(string: "  −\(removed)", attributes: [.foregroundColor: NSColor.systemRed]))
                counts.attributedStringValue = value
                counts.setAccessibilityLabel("\(added) added lines, \(removed) removed lines")
            case .initial: counts.stringValue = "Initial snapshot"
            case .unavailable: counts.stringValue = "Comparison unavailable"
            }
        }
        if model.unavailable.contains(entry.sequence) { reason.stringValue = "Unavailable" }
        for label in [title, counts, reason] { add(label, to: cell) }
        cell.textField = title
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 9), title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12), title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            counts.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5), counts.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            reason.leadingAnchor.constraint(equalTo: title.leadingAnchor), reason.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), reason.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -9)
        ])
        cell.setAccessibilityLabel("\(title.stringValue), \(reason.stringValue), \(counts.accessibilityLabel() ?? counts.stringValue)")
        return cell
    }

    @objc private func confirmRestore() {
        guard let selected = model.selected, let sequence = model.selectedSequence, let window = view.window, !restoring else { return }
        let alert = NSAlert()
        alert.messageText = "Restore this revision?"
        alert.informativeText = "Replace the current document with \(HistoryBrowserModel.date(selected.metadata.timestamp))? Your current text and landmarks will be retained in history, and you can undo the restore."
        alert.addButton(withTitle: "Restore"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await self?.performRestore(sequence) }
        }
    }

    func performRestore(_ sequence: Int64) async {
        guard !restoring, let onRestore else { return }
        restoring = true; restore.isEnabled = false; done.isEnabled = false; mode.isEnabled = false
        do { try await onRestore(sequence) }
        catch { status.stringValue = "Restore could not complete. Your current document was not replaced."; status.toolTip = String(describing: error) }
        restoring = false; done.isEnabled = true; mode.isEnabled = true; restore.isEnabled = model.selected != nil
    }
}

@MainActor private final class HistoryRevisionRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 3), xRadius: 5, yRadius: 5).fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: 4, y: 9, width: 2, height: max(0, bounds.height - 18)).fill()
    }
}

@MainActor final class HistorySnapshotText: NSTextView {
    var dismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}
