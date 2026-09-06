import AppKit
import JortDocument

/// Transient views are owned by their feature; only their geometry lives here.
@MainActor struct LineAccessory {
    let lineID: UUID
    let height: CGFloat
    let view: NSView
    init(lineID: UUID, height: CGFloat, view: NSView) {
        self.lineID = lineID
        self.height = height.isFinite ? min(1024, max(0, height)) : 0
        self.view = view
    }
}

private final class AccessoryLayoutFragment: NSTextLayoutFragment {
    let accessoryHeight: @MainActor () -> CGFloat
    init(element: NSTextElement, height: @escaping @MainActor () -> CGFloat) {
        accessoryHeight = height
        super.init(textElement: element, range: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var bottomMargin: CGFloat {
        let height = accessoryHeight
        return super.bottomMargin + MainActor.assumeIsolated { height() }
    }
}

/// All positions are TextKit container coordinates, before the text view inset.
@MainActor final class LinePresentationLayout: NSObject, @preconcurrency NSTextLayoutManagerDelegate {
    struct Band {
        let id: UUID
        let number: Int
        let frame: NSRect
        let textY: CGFloat
        let accessoryFrame: NSRect?
    }
    weak var editor: NSTextView?
    private(set) var lines: [LineMeta] = []
    private var byOffset: [Int: UUID] = [:]
    private var byID: [UUID: LineMeta] = [:]
    private var mounted: Set<UUID> = []
    private(set) var accessories: [UUID: LineAccessory] = [:]
    init(editor: NSTextView) {
        self.editor = editor
        super.init()
        editor.textLayoutManager?.delegate = self
    }
    func update(lines: [LineMeta]) {
        self.lines = lines
        byOffset = Dictionary(uniqueKeysWithValues: lines.map { ($0.location, $0.id) })
        byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        let surviving = Set(lines.map(\.id))
        for id in Array(accessories.keys) where !surviving.contains(id) {
            accessories.removeValue(forKey: id)?.view.removeFromSuperview()
            mounted.remove(id)
        }
    }
    func setAccessories(_ values: [LineAccessory]) {
        guard let editor, let manager = editor.textLayoutManager, let content = manager.textContentManager else { return }
        let anchor = viewportAnchor()
        let originalX = editor.enclosingScrollView?.contentView.bounds.minX ?? 0
        let previous = Set(accessories.keys)
        for value in accessories.values { value.view.removeFromSuperview() }
        mounted = []
        accessories = [:]
        let surviving = Set(lines.map(\.id))
        for value in values where value.height > 0 && surviving.contains(value.lineID) {
            accessories[value.lineID] = value
        }
        for id in previous.union(accessories.keys) {
            guard let line = byID[id] else { continue }
            if let start = content.location(content.documentRange.location, offsetBy: line.location),
               let end = content.location(start, offsetBy: line.length), let range = NSTextRange(location: start, end: end) {
                manager.invalidateLayout(for: range)
            }
        }
        manager.textViewportLayoutController.layoutViewport()
        if let (id, relative) = anchor, let band = band(for: id) {
            editor.enclosingScrollView?.contentView.scroll(to: NSPoint(x: originalX, y: max(0, band.frame.minY + relative)))
        }
        refreshViews()
    }
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        guard let content = textLayoutManager.textContentManager else { return NSTextLayoutFragment(textElement: textElement, range: nil) }
        return AccessoryLayoutFragment(element: textElement) { [weak self, weak textElement, weak content] in
            guard let self, let textElement, let content, let range = textElement.elementRange else { return 0 }
            let offset = content.offset(from: content.documentRange.location, to: range.location)
            guard let id = self.byOffset[offset] else { return 0 }
            return self.accessories[id]?.height ?? 0
        }
    }
    func visibleBands() -> [Band] {
        guard let editor, let manager = editor.textLayoutManager, let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return [] }
        var result: [Band] = []
        manager.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresExtraLineFragment]) { fragment in
            result.append(contentsOf: self.bands(fragment, content: content))
            return fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending
        }
        return result
    }
    private func bands(_ fragment: NSTextLayoutFragment, content: NSTextContentManager) -> [Band] {
        let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        var result: [Band] = []
        for textLine in fragment.textLineFragments {
            let start = offset + textLine.characterRange.location
            var low = 0, high = lines.count
            while low < high { let mid = (low + high) / 2; if lines[mid].location < start { low = mid + 1 } else { high = mid } }
            guard low < lines.count, lines[low].location == start else { continue }
            let line = lines[low], frame = fragment.layoutFragmentFrame
            let height = accessories[line.id]?.height ?? 0
            let bottom = fragment.textLineFragments.map { $0.typographicBounds.maxY }.max() ?? frame.height
            let accessoryFrame = height > 0 ? NSRect(x: frame.minX, y: frame.minY + bottom, width: frame.width, height: height) : nil
            result.append(Band(id: line.id, number: low + 1, frame: frame, textY: frame.minY + textLine.typographicBounds.minY, accessoryFrame: accessoryFrame))
        }
        return result
    }
    func band(for id: UUID) -> Band? {
        guard let line = byID[id], let manager = editor?.textLayoutManager,
              let content = manager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: line.location) else { return nil }
        manager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = manager.textLayoutFragment(for: location) else { return nil }
        return bands(fragment, content: content).first { $0.id == id }
    }
    func refreshViews() {
        guard !accessories.isEmpty, let editor else { return }
        let visible = visibleBands()
        let ids = Set(visible.map(\.id))
        for id in mounted.subtracting(ids) { accessories[id]?.view.removeFromSuperview(); mounted.remove(id) }
        for band in visible {
            guard let value = accessories[band.id], var frame = band.accessoryFrame else { continue }
            frame.origin.x += editor.textContainerOrigin.x
            frame.origin.y += editor.textContainerOrigin.y
            frame.size.width = max(0, editor.bounds.width - 2 * editor.textContainerOrigin.x)
            if value.view.superview !== editor { editor.addSubview(value.view) }
            mounted.insert(band.id)
            value.view.frame = frame
            value.view.setAccessibilityHelp("After line \(band.number)")
        }
    }
    func viewportAnchor() -> (UUID, CGFloat)? {
        guard let editor, let scroll = editor.enclosingScrollView, let band = visibleBands().first else { return nil }
        return (band.id, scroll.contentView.bounds.minY - band.frame.minY)
    }
    func accessibilityChildren() -> [Any]? {
        guard !accessories.isEmpty, let editor else { return nil }
        var children: [Any] = []
        for band in visibleBands() {
            guard let line = byID[band.id], line.location + line.length <= editor.string.utf16.count else { continue }
            let text = NSAccessibilityElement()
            text.setAccessibilityRole(.staticText)
            text.setAccessibilityParent(editor)
            text.setAccessibilityLabel("Line \(band.number)")
            text.setAccessibilityValue((editor.string as NSString).substring(with: NSRange(location: line.location, length: line.length)))
            let frame = band.frame.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            if let window = editor.window { text.setAccessibilityFrame(window.convertToScreen(editor.convert(frame, to: nil))) }
            children.append(text)
            if let accessory = accessories[band.id] { children.append(accessory.view) }
        }
        return children
    }
}
