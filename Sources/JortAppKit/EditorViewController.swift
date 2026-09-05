import AppKit
import UniformTypeIdentifiers
import JortDocument
import JortPersistence

@MainActor public final class JortTextView: NSTextView {
    public let history = UndoManager()
    // Native text mutations must not register a second, text-only undo action.
    public override var undoManager: UndoManager? { nil }
    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return history.canUndo }
        if item.action == #selector(redo(_:)) { return history.canRedo }
        return super.validateUserInterfaceItem(item)
    }
    @objc public func undo(_ sender: Any?) { history.undo() }
    @objc public func redo(_ sender: Any?) { history.redo() }
    var onCompositionCommit: (() -> Void)?
    public override func unmarkText() {
        super.unmarkText()
        onCompositionCommit?()
    }
}

@MainActor public final class EditorViewController: NSViewController, NSTextViewDelegate {
    public let persistence: PersistenceController
    public let scroll = NSScrollView()
    public let textView = JortTextView(usingTextLayoutManager: true)
    let notice = NSTextField(wrappingLabelWithString: "")
    let retry = NSButton(title: "Retry save", target: nil, action: nil)
    private let unloaded = DocumentSnapshot()
    public private(set) var coordinator: DocumentCoordinator!
    public var state: DocumentSnapshot { coordinator?.snapshot ?? unloaded }
    private var ready = false
    private var pendingEdit: (NSRange, Int)?
    private var ruler: LineRuler!
    public var saveStatus: ((PersistenceState) -> Void)?

    public init(persistence: PersistenceController) { self.persistence = persistence; super.init(nibName: nil, bundle: nil) }
    public required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
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
        textView.allowsUndo = false
        textView.history.levelsOfUndo = 200
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
        persistence.onState = { [weak self] status in
            self?.present(status)
            self?.saveStatus?(status)
        }
        persistence.onCommit = { [weak self] revision in self?.coordinator?.markCommitted(revision) }
        persistence.load { [weak self] result in
            guard let self else { return }
            if case .success(let snapshot) = result {
                self.coordinator = try! DocumentCoordinator(snapshot: snapshot, committed: true)
                self.textView.string = snapshot.text
            } else { self.coordinator = try! DocumentCoordinator(snapshot: self.unloaded) }
            self.coordinator.onTransaction = { [weak self] result in
                guard let self else { return }
                if result.transaction.origin != .native && result.transaction.undoPolicy == .register {
                    self.recordUndo(result.before, selection: self.textView.selectedRange())
                }
                if self.textView.string != result.after.text {
                    self.display(result, selection: self.textView.selectedRange(), preserveAnchors: true)
                }
                self.ruler.lines = result.after.lines
                self.persistence.changed(result.after)
            }
            self.ruler.lines = self.state.lines
            self.textView.isEditable = true
            self.ready = true
            self.textView.history.removeAllActions()
            self.view.window?.makeFirstResponder(self.textView)
        }
    }
    private func present(_ status: PersistenceState) {
        let message: String?
        switch status {
        case .loadBlockedFuture: message = String(localized: "This store needs a newer version of Jort. Existing files are unchanged.")
        case .loadFailed: message = String(localized: "Storage could not be opened. Your typing stays in memory; save a recovery copy to keep it.")
        case .ownershipConflict: message = String(localized: "This canvas is already open in another Jort process.")
        default: message = status.failure == nil ? nil : String(localized: "Couldn’t save. Your text is still here. Retry with ⌘S.")
        }
        notice.stringValue = message ?? ""
        notice.isHidden = message == nil
        retry.isHidden = message == nil || status == .ownershipConflict
        retry.title = status.permitsRetry ? String(localized: "Retry save") : String(localized: "Save Recovery Copy…")
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        if ready { view.window?.makeFirstResponder(textView) }
    }
    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if ready, !textView.hasMarkedText(), textView.string == state.text, let replacementString {
            pendingEdit = (affectedCharRange, replacementString.utf16.count)
        } else { pendingEdit = nil }
        return true
    }
    public func textDidChange(_ notification: Notification) {
        commitText()
        refreshGutterAfterLayout()
    }
    public func textViewDidChangeSelection(_ notification: Notification) { refreshGutterAfterLayout() }
    private func refreshGutterAfterLayout() {
        DispatchQueue.main.async { [weak self] in self?.ruler?.needsDisplay = true }
    }
    private func commitText() {
        guard ready, !textView.hasMarkedText(), textView.string != state.text else { return }
        let edit = pendingEdit; pendingEdit = nil
        let transaction = DocumentTransaction(baseRevision: state.revision, origin: .native,
            mutation: .edit(text: textView.string, range: edit?.0, replacementLength: edit?.1))
        do {
            let result = try coordinator.apply(transaction)
            recordUndo(result.before, selection: NSRange(location: min(edit?.0.location ?? 0, result.before.text.utf16.count), length: 0))
        } catch {
            // Preserve typed text: a range that AppKit revised during composition uses the normalized path.
            do {
                let result = try coordinator.apply(DocumentTransaction(baseRevision: state.revision, origin: .native,
                    mutation: .edit(text: textView.string, range: nil, replacementLength: nil)))
                recordUndo(result.before, selection: NSRange(location: 0, length: 0))
            } catch { notice.stringValue = String(localized: "This edit could not be recorded. Copy your text to preserve it."); notice.isHidden = false }
        }
    }
    private func recordUndo(_ snapshot: DocumentSnapshot, selection: NSRange) {
        textView.history.registerUndo(withTarget: self) { target in
            let origin: MutationOrigin = target.textView.history.isUndoing ? .undo : .redo
            let currentSelection = target.textView.selectedRange()
            do {
                let result = try target.coordinator.apply(DocumentTransaction(baseRevision: target.state.revision, origin: origin,
                    undoPolicy: .replay, mutation: .restore(snapshot)))
                target.recordUndo(result.before, selection: currentSelection)
                target.display(result, selection: selection)
            } catch { assertionFailure("Invalid undo snapshot: \(error)") }
        }
    }
    /// Future commands and captures submit transactions here; they never receive NSTextStorage.
    @discardableResult public func apply(_ transaction: DocumentTransaction) throws -> TransactionResult {
        guard ready else { throw DocumentError.invalidState }
        return try coordinator.apply(transaction)
    }
    private func display(_ result: TransactionResult, selection: NSRange, preserveAnchors: Bool = false) {
        let viewport = scroll.contentView.bounds.origin
        var selected = selection
        var topAnchor: (UUID, CGFloat)?
        if preserveAnchors {
            func mapped(_ offset: Int) -> Int {
                guard let old = result.before.lines.last(where: { $0.location <= offset }),
                      let new = result.after.lines.first(where: { $0.id == old.id }) else { return min(offset, result.after.text.utf16.count) }
                return new.location + min(offset - old.location, new.length)
            }
            let start = mapped(selection.location), end = mapped(NSMaxRange(selection))
            selected = NSRange(location: min(start, end), length: abs(end - start))
            if let manager = textView.textLayoutManager, let content = manager.textContentManager,
               let visible = manager.textViewportLayoutController.viewportRange,
               let fragment = manager.textLayoutFragment(for: visible.location) {
                let offset = content.offset(from: content.documentRange.location, to: visible.location)
                if let line = result.before.lines.last(where: { $0.location <= offset }) {
                    topAnchor = (line.id, viewport.y - fragment.layoutFragmentFrame.minY)
                }
            }
        }
        textView.string = result.after.text
        textView.setSelectedRange(NSRange(location: min(selected.location, result.after.text.utf16.count), length: min(selected.length, max(0, result.after.text.utf16.count - selected.location))))
        var position = viewport
        if let (id, relativeY) = topAnchor, let line = result.after.lines.first(where: { $0.id == id }),
           let manager = textView.textLayoutManager, let content = manager.textContentManager,
           let location = content.location(content.documentRange.location, offsetBy: line.location) {
            manager.ensureLayout(for: NSTextRange(location: location))
            if let fragment = manager.textLayoutFragment(for: location) { position.y = fragment.layoutFragmentFrame.minY + relativeY }
        }
        scroll.contentView.scroll(to: position)
        ruler.lines = result.after.lines
        refreshGutterAfterLayout()
    }
    @objc public func save() {
        if persistence.status.permitsRetry { persistence.retry() }
        else { saveRecoveryCopy() }
    }
    @objc public func saveRecoveryCopy() {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = "Save Recovery Copy"
        panel.message = "Preserve your current text and line metadata in a separate recovery file."
        panel.nameFieldStringValue = "Jort Recovery.json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.persistence.saveRecoveryCopy(snapshot: self.state, to: url) { result in
                switch result {
                case .success:
                    self.notice.stringValue = "Recovery copy saved to \(url.lastPathComponent)."
                case .failure(let error):
                    self.notice.stringValue = "Couldn’t save recovery copy: \(String(describing: error))"
                }
                self.notice.isHidden = false
            }
        }
    }
}

/// Uses TextKit 2's already-visible fragments; scrolling never forces whole-document layout.
@MainActor public final class LineRuler: NSRulerView {
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
    public required init(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func update() { needsDisplay = true }
    /// Coordinates are in the text container; include the extra, zero-length EOF row.
    public func visibleRows() -> [(number: Int, y: CGFloat)] {
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
    public override func drawHashMarksAndLabels(in rect: NSRect) {
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
