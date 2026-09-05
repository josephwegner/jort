import AppKit
import UniformTypeIdentifiers

final class JortTextView: NSTextView {
    var onCompositionCommit: (() -> Void)?
    override func unmarkText() {
        super.unmarkText()
        onCompositionCommit?()
    }
}

final class EditorViewController: NSViewController, NSTextViewDelegate {
    let persistence: PersistenceController
    let scroll = NSScrollView()
    let textView = JortTextView(usingTextLayoutManager: true)
    let notice = NSTextField(wrappingLabelWithString: "")
    let retry = NSButton(title: "Retry save", target: nil, action: nil)
    private(set) var state = DocumentState()
    private var ready = false
    private var pendingEdit: (NSRange, Int)?
    private var suppressNextReconcile = false
    private var ruler: LineRuler!
    var saveStatus: ((String, Bool) -> Void)?

    init(persistence: PersistenceController) { self.persistence = persistence; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.findBarPosition = .aboveContent
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(calibratedRed: 0.085, green: 0.094, blue: 0.106, alpha: 1)
        scroll.borderType = .noBorder
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        textView.backgroundColor = NSColor(calibratedRed: 0.085, green: 0.094, blue: 0.106, alpha: 1)
        textView.insertionPointColor = NSColor(calibratedRed: 0.66, green: 0.80, blue: 0.66, alpha: 1)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(calibratedRed: 0.24, green: 0.34, blue: 0.30, alpha: 1)]
        textView.textContainerInset = NSSize(width: 24, height: 28)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 24
        paragraph.maximumLineHeight = 24
        paragraph.lineSpacing = 0
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: textView.font!, .foregroundColor: textView.textColor!, .paragraphStyle: paragraph]
        textView.setAccessibilityLabel("Jort document")
        textView.setAccessibilityHelp("Your private plain text canvas. Changes save automatically on this Mac.")
        textView.delegate = self
        textView.isEditable = false
        scroll.documentView = textView
        ruler = LineRuler(scrollView: scroll, textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        view.addSubview(scroll)
        notice.font = .systemFont(ofSize: 12)
        notice.textColor = .systemYellow
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.isHidden = true
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.bezelStyle = .rounded
        retry.target = self; retry.action = #selector(save)
        retry.isHidden = true
        view.addSubview(notice); view.addSubview(retry)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 70),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: retry.leadingAnchor, constant: -12),
            notice.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            retry.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            retry.centerYAnchor.constraint(equalTo: notice.centerYAnchor)
        ])
        textView.onCompositionCommit = { [weak self] in self?.commitText() }
        persistence.onStatus = { [weak self] message, failure in
            self?.notice.stringValue = message
            self?.notice.isHidden = !failure
            self?.retry.isHidden = !failure
            self?.retry.title = self?.persistence.loadedSafely == true ? "Retry save" : "Save Recovery Copy…"
            self?.saveStatus?(message, failure)
        }
        persistence.load { [weak self] state in
            guard let self else { return }
            self.state = state
            self.textView.string = state.text
            self.ruler.lines = state.lines
            self.textView.isEditable = true
            self.ready = true
            self.textView.undoManager?.removeAllActions()
            self.view.window?.makeFirstResponder(self.textView)
        }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        if ready { view.window?.makeFirstResponder(textView) }
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if ready, !textView.hasMarkedText(), textView.string == state.text, let replacementString {
            pendingEdit = (affectedCharRange, replacementString.utf16.count)
        } else { pendingEdit = nil }
        return true
    }
    func textDidChange(_ notification: Notification) {
        commitText()
        refreshGutterAfterLayout()
    }
    func textViewDidChangeSelection(_ notification: Notification) { refreshGutterAfterLayout() }
    private func refreshGutterAfterLayout() {
        DispatchQueue.main.async { [weak self] in self?.ruler?.needsDisplay = true }
    }
    private func commitText() {
        guard ready, !textView.hasMarkedText(), textView.string != state.text else { return }
        let oldLines = state.lines
        let edit = pendingEdit
        pendingEdit = nil
        if suppressNextReconcile {
            suppressNextReconcile = false
            state.text = textView.string
            state.revision += 1
        } else {
            state.replaceText(textView.string, editRange: edit?.0, replacementLength: edit?.1)
        }
        if let undo = textView.undoManager, !undo.isUndoing, !undo.isRedoing {
            // Separate native edit groups so metadata actions pair with exact text edits.
            textView.breakUndoCoalescing()
            registerMetadataUndo(oldLines)
        }
        ruler.lines = state.lines
        persistence.changed(state)
    }
    private func registerMetadataUndo(_ lines: [LineMeta]) {
        textView.undoManager?.registerUndo(withTarget: self) { target in
            let current = target.state.lines
            target.registerMetadataUndo(current)
            target.state.lines = lines
            if target.textView.undoManager?.isUndoing == true {
                target.suppressNextReconcile = true
            } else {
                target.state.revision += 1
                target.ruler.lines = lines
                target.persistence.changed(target.state)
            }
        }
    }
    @objc func save() {
        if persistence.loadedSafely { persistence.retry() }
        else { saveRecoveryCopy() }
    }
    @objc func saveRecoveryCopy() {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = "Save Recovery Copy"
        panel.message = "Preserve your current text and line metadata in a separate recovery file."
        panel.nameFieldStringValue = "Jort Recovery.json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.persistence.saveRecoveryCopy(to: url) { result in
                switch result {
                case .success:
                    self.notice.stringValue = "Recovery copy saved to \(url.lastPathComponent)."
                case .failure(let error):
                    self.notice.stringValue = "Couldn’t save recovery copy: \(error.localizedDescription)"
                }
                self.notice.isHidden = false
            }
        }
    }
}

/// Uses TextKit 2's already-visible fragments; scrolling never forces whole-document layout.
final class LineRuler: NSRulerView {
    weak var editor: NSTextView?
    var lines: [LineMeta] = [] { didSet { needsDisplay = true } }
    init(scrollView: NSScrollView, textView: NSTextView) {
        editor = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    required init(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func update() { needsDisplay = true }
    /// Coordinates are in the text container; include the extra, zero-length EOF row.
    func visibleRows() -> [(number: Int, y: CGFloat)] {
        guard let editor else { return [] }
        if editor.string.isEmpty { return [(1, 0)] }
        guard let manager = editor.textLayoutManager, let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return [] }
        var rows: [(number: Int, y: CGFloat)] = []
        manager.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresExtraLineFragment]) { fragment in
            let paragraphOffset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let offset = paragraphOffset + line.characterRange.location
                var low = 0, high = self.lines.count
                while low < high {
                    let mid = (low + high) / 2
                    if self.lines[mid].location < offset { low = mid + 1 } else { high = mid }
                }
                if low < self.lines.count, self.lines[low].location == offset,
                   rows.last?.number != low + 1 {
                    rows.append((low + 1, fragment.layoutFragmentFrame.minY + line.typographicBounds.minY))
                }
            }
            return fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending
        }
        return rows
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor(calibratedRed: 0.085, green: 0.094, blue: 0.106, alpha: 1).setFill()
        NSRect(x: 0, y: rect.minY, width: ruleThickness, height: rect.height).fill()
        guard let editor else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for row in visibleRows() {
            let point = convert(NSPoint(x: 0, y: editor.textContainerOrigin.y + row.y), from: editor)
            let label = "\(row.number)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: point.y + 5), withAttributes: attrs)
        }
    }
}
