import AppKit

@MainActor enum EditorMetrics {
    static let gutterWidth: CGFloat = 48
    static let footerHeight: CGFloat = 36
    static let contentInset = NSSize(width: 24, height: 0)
    static let canvas = NSColor(calibratedRed: 0.085, green: 0.094, blue: 0.106, alpha: 1)
    static let chrome = NSColor(calibratedWhite: 0.075, alpha: 1)
    static let separator = NSColor(calibratedWhite: 0.20, alpha: 1)
    static func pixel(in view: NSView) -> CGFloat { 1 / (view.window?.backingScaleFactor ?? 1) }
}

struct LandmarkModeState: Equatable {
    var latched = false
    var optionHeld = false
    var isVisible: Bool { latched || optionHeld }
    var description: String { optionHeld ? "Landmark index, Option held" : latched ? "Landmark index, latched" : "Line numbers" }
}

@MainActor final class EditorFooter: NSView {
    let landmarks = LandmarkStatusButton(title: "⌥ Landmarks 0", target: nil, action: nil)
    override init(frame: NSRect) {
        super.init(frame: frame)
        landmarks.isBordered = false
        landmarks.font = .systemFont(ofSize: 11)
        landmarks.contentTintColor = .secondaryLabelColor
        landmarks.toolTip = "Hold Option to reveal landmarks; click to toggle"
        landmarks.setAccessibilityLabel("Landmarks")
        landmarks.translatesAutoresizingMaskIntoConstraints = false
        addSubview(landmarks)
        NSLayoutConstraint.activate([
            landmarks.leadingAnchor.constraint(equalTo: leadingAnchor),
            landmarks.centerYAnchor.constraint(equalTo: centerYAnchor),
            landmarks.widthAnchor.constraint(equalToConstant: 154)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        EditorMetrics.chrome.setFill(); bounds.fill()
        EditorMetrics.separator.setFill()
        let pixel = EditorMetrics.pixel(in: self)
        NSRect(x: bounds.minX, y: bounds.maxY - pixel, width: bounds.width, height: pixel).fill()
    }
    func update(count: Int, mode: LandmarkModeState) {
        landmarks.title = "⌥ \(String(localized: "Landmarks")) \(count)"
        landmarks.setAccessibilityValue("\(count) landmarks, \(mode.description)")
        landmarks.contentTintColor = mode.isVisible ? .labelColor : .secondaryLabelColor
    }
}

@MainActor final class LandmarkStatusButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: contentTintColor ?? NSColor.secondaryLabelColor]
        let symbol = "⌥" as NSString
        let symbolSize = symbol.size(withAttributes: attributes)
        symbol.draw(at: NSPoint(x: (EditorMetrics.gutterWidth - symbolSize.width) / 2, y: (bounds.height - symbolSize.height) / 2), withAttributes: attributes)
        let text = String(title.dropFirst(2)) as NSString
        text.draw(at: NSPoint(x: EditorMetrics.gutterWidth + 10, y: (bounds.height - symbolSize.height) / 2), withAttributes: attributes)
    }
}
