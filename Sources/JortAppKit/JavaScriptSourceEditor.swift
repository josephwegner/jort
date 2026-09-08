import AppKit
import JortSettings

@MainActor public final class SourceTextView: NSTextView {
    public let sourceUndoManager = UndoManager()
    public override var undoManager: UndoManager? { sourceUndoManager }
    public var maximumUTF8Bytes = SettingsLimits.maximumSourceBytes
    public var rejectedOversize: (() -> Void)?

    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let replacement = replacementString ?? ""
        let proposed = (string as NSString).replacingCharacters(in: affectedCharRange, with: replacement)
        guard proposed.utf8.count <= maximumUTF8Bytes else { rejectedOversize?(); NSSound.beep(); return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
}

@MainActor final class SourceLineRuler: NSRulerView {
    weak var sourceView: SourceTextView?
    init(scrollView: NSScrollView, sourceView: SourceTextView) {
        self.sourceView = sourceView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 44
    }
    required init(coder: NSCoder) { fatalError() }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = sourceView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let visible = scrollView?.contentView.bounds ?? .zero
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let text = textView.string as NSString
        var line = 1
        var cursor = 0
        while cursor < text.length && cursor < layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location {
            let range = text.lineRange(for: NSRange(location: cursor, length: 0)); cursor = NSMaxRange(range); line += 1
        }
        var glyph = glyphRange.location
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        while glyph < NSMaxRange(glyphRange) {
            let character = layout.characterIndexForGlyph(at: glyph)
            let lineRange = text.lineRange(for: NSRange(location: character, length: 0))
            let lineGlyph = layout.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let fragment = layout.lineFragmentRect(forGlyphAt: lineGlyph.location, effectiveRange: nil)
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: fragment.minY + textView.textContainerInset.height), withAttributes: attributes)
            glyph = max(NSMaxRange(lineGlyph), glyph + 1); line += 1
        }
    }
}

@MainActor public final class JavaScriptSourceEditor: NSView, NSTextViewDelegate {
    public let scrollView = NSScrollView()
    public let textView = SourceTextView(frame: .zero)
    public let status = NSTextField(labelWithString: "Line 1, Column 1")
    public var onChange: ((String) -> Void)?
    public var onOversize: (() -> Void)?
    private var updating = false

    public var source: String {
        get { textView.string }
        set {
            updating = true; textView.string = newValue; textView.sourceUndoManager.removeAllActions(); updating = false
            refreshStatus(); scrollView.verticalRulerView?.needsDisplay = true
        }
    }
    public var isSourceEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue; textView.backgroundColor = newValue ? .textBackgroundColor : .controlBackgroundColor }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.translatesAutoresizingMaskIntoConstraints = false; status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView); addSubview(status)
        scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true; scrollView.borderType = .bezelBorder
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 320)
        textView.isRichText = false; textView.importsGraphics = false; textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false; textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false; textView.isAutomaticDataDetectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = true
        textView.minSize = .zero; textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.allowsUndo = true; textView.usesFindBar = true; textView.isIncrementalSearchingEnabled = true
        textView.delegate = self; textView.setAccessibilityLabel("JavaScript source")
        textView.setAccessibilityHelp("Plain-text JavaScript source. Saving does not run this code.")
        textView.rejectedOversize = { [weak self] in self?.onOversize?() }
        scrollView.documentView = textView
        let ruler = SourceLineRuler(scrollView: scrollView, sourceView: textView)
        scrollView.verticalRulerView = ruler; scrollView.hasVerticalRuler = true; scrollView.rulersVisible = true
        status.textColor = .secondaryLabelColor; status.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        status.setAccessibilityLabel("Source position")
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: leadingAnchor), status.trailingAnchor.constraint(equalTo: trailingAnchor), status.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    public required init?(coder: NSCoder) { fatalError() }
    public func textDidChange(_ notification: Notification) {
        refreshStatus(); scrollView.verticalRulerView?.needsDisplay = true
        if !updating { onChange?(textView.string) }
    }
    public func textViewDidChangeSelection(_ notification: Notification) { refreshStatus() }
    public func reveal(_ range: ToolSourceRange) {
        let safe = NSRange(location: min(range.location, textView.string.utf16.count), length: min(range.length, max(0, textView.string.utf16.count - range.location)))
        textView.setSelectedRange(safe); textView.scrollRangeToVisible(safe); window?.makeFirstResponder(textView)
    }
    private func refreshStatus() {
        let offset = min(textView.selectedRange().location, textView.string.utf16.count)
        let prefix = (textView.string as NSString).substring(to: offset)
        let lines = prefix.components(separatedBy: "\n")
        status.stringValue = "Line \(lines.count), Column \((lines.last?.utf16.count ?? 0) + 1)"
        status.setAccessibilityValue(status.stringValue)
    }
}
