import AppKit

@MainActor open class SettingsPaneViewController: NSViewController {
    open var hasUnsavedChanges: Bool { false }
    open var initialFirstResponder: NSResponder? { view }
    open func resolvePendingChanges(in window: NSWindow, completion: @escaping (Bool) -> Void) { completion(true) }
}

@MainActor public struct SettingsPaneDescriptor {
    public let id: String
    public let title: String
    public let symbolName: String
    public let keywords: String
    public let makeViewController: () -> SettingsPaneViewController
    public init(id: String, title: String, symbolName: String, keywords: String = "",
                makeViewController: @escaping () -> SettingsPaneViewController) {
        self.id = id; self.title = title; self.symbolName = symbolName; self.keywords = keywords
        self.makeViewController = makeViewController
    }
}

@MainActor final class SettingsSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    var panes: [SettingsPaneDescriptor] = []
    var onSelect: ((Int) -> Void)?
    override func loadView() {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        let column = NSTableColumn(identifier: .init("pane")); table.addTableColumn(column); table.headerView = nil
        table.rowHeight = 36; table.dataSource = self; table.delegate = self; table.style = .sourceList
        table.setAccessibilityLabel("Settings categories"); view = scroll
    }
    func numberOfRows(in tableView: NSTableView) -> Int { panes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let pane = panes[row], cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: pane.title)
        for subview in [image, label] { subview.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(subview) }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6)
        ])
        cell.setAccessibilityLabel(pane.title); return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if table.selectedRow >= 0 { onSelect?(table.selectedRow) } }
}

@MainActor final class SettingsDetailHost: NSViewController {
    override func loadView() { view = NSView() }
    func show(_ controller: NSViewController) {
        children.forEach { $0.view.removeFromSuperview(); $0.removeFromParent() }
        addChild(controller); controller.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor), controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

@MainActor public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public let panes: [SettingsPaneDescriptor]
    public private(set) var selectedPaneID: String?
    private let sidebar = SettingsSidebarController(), detail = SettingsDetailHost()
    private let defaults: UserDefaults
    private var instances: [String: SettingsPaneViewController] = [:]
    private var active: SettingsPaneViewController?
    private var suppressSelection = false
    private var closingAfterResolution = false
    private let selectedKey = "Jort.Settings.SelectedPane"

    public init(panes: [SettingsPaneDescriptor], defaults: UserDefaults = .standard) {
        precondition(!panes.isEmpty && Set(panes.map(\.id)).count == panes.count)
        self.panes = panes; self.defaults = defaults
        let split = NSSplitViewController(); split.splitView.isVertical = true
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar); sidebarItem.minimumThickness = 150; sidebarItem.maximumThickness = 240
        let detailItem = NSSplitViewItem(viewController: detail); detailItem.minimumThickness = 520
        split.addSplitViewItem(sidebarItem); split.addSplitViewItem(detailItem)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Jort Settings"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 680, height: 480)
        window.contentViewController = split; window.setFrameAutosaveName("JortSettingsWindow")
        super.init(window: window); window.delegate = self; window.setAccessibilityLabel("Jort Settings")
        sidebar.panes = panes; sidebar.table.reloadData()
        sidebar.onSelect = { [weak self] in self?.requestSelection(index: $0) }
        let remembered = defaults.string(forKey: selectedKey)
        let index = panes.firstIndex(where: { $0.id == remembered }) ?? 0
        select(index: index)
    }
    required init?(coder: NSCoder) { fatalError() }
    public func present() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let responder = active?.initialFirstResponder { window?.makeFirstResponder(responder) }
    }
    public func selectPane(id: String) { if let index = panes.firstIndex(where: { $0.id == id }) { requestSelection(index: index) } }
    private func requestSelection(index: Int) {
        guard panes.indices.contains(index), panes[index].id != selectedPaneID, !suppressSelection else { return }
        guard let window, let active, active.hasUnsavedChanges else { select(index: index); return }
        let oldIndex = panes.firstIndex(where: { $0.id == selectedPaneID }) ?? 0
        suppressSelection = true; sidebar.table.selectRowIndexes(IndexSet(integer: oldIndex), byExtendingSelection: false); suppressSelection = false
        active.resolvePendingChanges(in: window) { [weak self] allowed in if allowed { self?.select(index: index) } }
    }
    private func select(index: Int) {
        let descriptor = panes[index]
        let controller = instances[descriptor.id] ?? descriptor.makeViewController()
        instances[descriptor.id] = controller; active = controller; selectedPaneID = descriptor.id; defaults.set(descriptor.id, forKey: selectedKey)
        detail.show(controller); suppressSelection = true
        sidebar.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); suppressSelection = false
    }
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingAfterResolution { closingAfterResolution = false; return true }
        guard let active, active.hasUnsavedChanges else { return true }
        active.resolvePendingChanges(in: sender) { [weak self] allowed in
            if allowed { self?.closingAfterResolution = true; self?.window?.performClose(nil) }
        }
        return false
    }
    public func prepareForTermination(completion: @escaping (Bool) -> Void) {
        guard let window, let active, active.hasUnsavedChanges else { completion(true); return }
        active.resolvePendingChanges(in: window, completion: completion)
    }
}
