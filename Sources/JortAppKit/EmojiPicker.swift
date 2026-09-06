import AppKit
import JortDocument

struct EmojiEntry: Decodable, Equatable {
    let emoji: String
    let search: String
}

@MainActor final class EmojiPicker: NSObject, NSPopoverDelegate, NSSearchFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let popover = NSPopover()
    private let search = NSSearchField()
    private let collection = NSCollectionView()
    private let hadEmoji: Bool
    private let catalog: [EmojiEntry]
    private var visible: [EmojiEntry]
    var commit: ((String) -> Void)?
    var clear: (() -> Void)?
    var finished: (() -> Void)?

    init(parent: NSWindow, emoji: String?) {
        hadEmoji = emoji != nil
        catalog = Self.loadCatalog()
        visible = catalog
        super.init()

        let controller = NSViewController()
        controller.preferredContentSize = NSSize(width: 340, height: 420)
        let root = NSView(frame: NSRect(origin: .zero, size: controller.preferredContentSize))

        search.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Search emoji"
        search.delegate = self
        search.setAccessibilityLabel("Search emoji")
        root.addSubview(search)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 36, height: 36)
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.register(EmojiItem.self, forItemWithIdentifier: EmojiItem.identifier)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        collection.frame = NSRect(x: 0, y: 0, width: 316, height: 420)
        collection.autoresizingMask = [.width]
        scroll.documentView = collection
        root.addSubview(scroll)

        var constraints = [
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10)
        ]
        if hadEmoji {
            let clearButton = NSButton(title: "Remove Landmark", target: self, action: #selector(removeEmoji))
            clearButton.bezelStyle = .rounded
            clearButton.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(clearButton)
            constraints += [
                scroll.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -10),
                clearButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                clearButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
            ]
        } else {
            constraints.append(scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12))
        }
        NSLayoutConstraint.activate(constraints)
        controller.view = root
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    func present(relativeTo rect: NSRect, in view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        resizeCollectionToClipWidth()
        popover.contentViewController?.view.window?.makeFirstResponder(search)
    }

    private func resizeCollectionToClipWidth() {
        guard let clip = collection.enclosingScrollView?.contentView else { return }
        var frame = collection.frame
        frame.origin = .zero
        frame.size.width = clip.bounds.width
        collection.frame = frame
        clip.scroll(to: .zero)
        collection.collectionViewLayout?.invalidateLayout()
    }

    func controlTextDidChange(_ obj: Notification) {
        let terms = search.stringValue.lowercased().split(whereSeparator: \Character.isWhitespace)
        visible = terms.isEmpty ? catalog : catalog.filter { entry in terms.allSatisfy { entry.search.contains($0) } }
        collection.reloadData()
        if !visible.isEmpty { collection.scrollToItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .top) }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { visible.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: EmojiItem.identifier, for: indexPath) as! EmojiItem
        item.configure(visible[indexPath.item])
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, visible.indices.contains(indexPath.item) else { return }
        let emoji = visible[indexPath.item].emoji
        collectionView.deselectItems(at: indexPaths)
        commit?(emoji)
        popover.performClose(nil)
    }

    @objc private func removeEmoji() {
        guard hadEmoji else { return }
        clear?()
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        finished?()
        finished = nil
    }

    nonisolated private static func loadCatalog() -> [EmojiEntry] {
        let bundles = [Bundle.main, Bundle(for: EmojiPicker.self)]
        guard let url = bundles.lazy.compactMap({ $0.url(forResource: "emoji", withExtension: "json") }).first,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([EmojiEntry].self, from: data) else {
            return [EmojiEntry(emoji: "😀", search: "grinning face smile happy")]
        }
        return entries
    }
}

@MainActor private final class EmojiItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("EmojiItem")
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 21)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func configure(_ entry: EmojiEntry) {
        label.stringValue = entry.emoji
        view.toolTip = entry.search
        view.setAccessibilityLabel(entry.search)
    }
}
