import AppKit
import UniformTypeIdentifiers
import JortDocument
import JortPersistence
import JortSettings

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
  var onTextChange: (() -> Void)?
  var onEscape: (() -> Bool)?
  var onToolKey: ((NSEvent) -> Bool)?
  var onToolDraw: ((NSRect) -> Void)?
  var isPasting = false
  var onPaste: (() -> Void)?
  var onCommittedSlash: (() -> Void)?
  public override func resetCursorRects() {
    super.resetCursorRects()
    // NSTextView installs an I-beam across its entire visible area, including
    // embedded controls. Partition that region instead of competing with it.
    discardCursorRects()
    var regions = [visibleRect]
    for button in subviews where button is NSButton && !button.isHidden {
      let hit = button.frame.intersection(visibleRect)
      guard !hit.isEmpty else { continue }
      regions = regions.flatMap { region -> [NSRect] in
        let cut = region.intersection(hit)
        guard !cut.isEmpty else { return [region] }
        return [
          NSRect(
            x: region.minX, y: region.minY, width: region.width, height: cut.minY - region.minY),
          NSRect(x: region.minX, y: cut.maxY, width: region.width, height: region.maxY - cut.maxY),
          NSRect(x: region.minX, y: cut.minY, width: cut.minX - region.minX, height: cut.height),
          NSRect(x: cut.maxX, y: cut.minY, width: region.maxX - cut.maxX, height: cut.height),
        ].filter { !$0.isEmpty }
      }
      addCursorRect(hit, cursor: .pointingHand)
    }
    for region in regions { addCursorRect(region, cursor: .iBeam) }
  }
  public override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    let point = convert(event.locationInWindow, from: nil)
    if subviews.contains(where: { $0 is NSButton && !$0.isHidden && $0.frame.contains(point) }) {
      NSCursor.pointingHand.set()
    }
  }
  public override func cursorUpdate(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if subviews.contains(where: { $0 is NSButton && !$0.isHidden && $0.frame.contains(point) }) {
      NSCursor.pointingHand.set()
    } else {
      super.cursorUpdate(with: event)
    }
  }
  public override func keyDown(with event: NSEvent) {
    if !hasMarkedText(), onToolKey?(event) == true { return }
    super.keyDown(with: event)
  }
  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if window?.firstResponder === self, event.modifierFlags.contains([.command, .option]),
      [123, 124, 125, 126].contains(event.keyCode),
      !hasMarkedText(), onToolKey?(event) == true
    {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
  public override func insertText(_ insertString: Any, replacementRange: NSRange) {
    let committed = (insertString as? NSAttributedString)?.string ?? (insertString as? String ?? "")
    if !isPasting, committed == "/" || (hasMarkedText() && committed.contains("/")) {
      onCommittedSlash?()
    }
    var attributes = typingAttributes
    attributes[.kern] = 0
    attributes.removeValue(forKey: NSAttributedString.Key("JortToolDecoration"))
    attributes[.font] = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    typingAttributes = attributes
    super.insertText(insertString, replacementRange: replacementRange)
  }
  public override func paste(_ sender: Any?) {
    pasteAsPlainText(sender)
  }
  public override func pasteAsPlainText(_ sender: Any?) {
    let previous = isPasting
    isPasting = true
    defer { isPasting = previous }
    onPaste?()
    super.pasteAsPlainText(sender)
  }
  public override func copy(_ sender: Any?) {
    let range = selectedRange()
    guard NSMaxRange(range) <= string.utf16.count else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString((string as NSString).substring(with: range), forType: .string)
  }
  public override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    onToolDraw?(rect)
  }
  public override func didChangeText() {
    super.didChangeText()
    onTextChange?()
  }
  public override func cancelOperation(_ sender: Any?) {
    if onEscape?() != true { super.cancelOperation(sender) }
  }
  var lineAccessibilityChildren: (() -> [Any]?)?
  var toolAccessibilityChildren: (() -> [Any])?
  public override func accessibilityChildren() -> [Any]? {
    let children = lineAccessibilityChildren?() ?? super.accessibilityChildren() ?? []
    let tools = toolAccessibilityChildren?() ?? []
    return children
      + tools.filter { tool in !children.contains { ($0 as AnyObject) === (tool as AnyObject) } }
  }
  public override func unmarkText() {
    let marked = markedRange()
    if !isPasting, marked.location != NSNotFound, NSMaxRange(marked) <= string.utf16.count,
      (string as NSString).substring(with: marked).contains("/")
    {
      onCommittedSlash?()
    }
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
  let footer = EditorFooter(frame: .zero)
  private(set) var modifierMonitor: Any?
  private let unloaded = DocumentSnapshot()
  public private(set) var coordinator: DocumentCoordinator!
  public var state: DocumentSnapshot { coordinator?.snapshot ?? unloaded }
  private var ready = false
  private var pendingEdit: (NSRange, Int)?
  private var ruler: LineRuler!
  private(set) var linePresentation: LinePresentationLayout!
  private(set) var palette: CommandPalette?
  private(set) var documentSearch: DocumentSearchController?
  private var emojiPicker: EmojiPicker?
  private(set) var historyWorkspace: HistoryWorkspaceController?
  private var openingHistory = false
  private var historySelection: NSRange?
  private var historyViewport: NSPoint?
  public var saveStatus: ((PersistenceState) -> Void)?
  public var openSettings: (() -> Void)?
  var toolController: ToolInvocationController!
  var toolPresentation: ToolInvocationPresentation!
  private var toolCatalogLoaded = false
  public var toolExecutorDispatcher = ToolExecutorDispatcher() {
    didSet { toolController?.dispatcher = toolExecutorDispatcher }
  }
  public var toolPackages: [ToolPackage] = [] {
    didSet {
      toolCatalogLoaded = true
      toolController?.packages = toolPackages
      toolController?.reconcilePackages()
      refreshToolPresentation()
      palette?.actions = paletteActions()
      palette?.reload()
    }
  }

  public init(persistence: PersistenceController) {
    self.persistence = persistence
    super.init(nibName: nil, bundle: nil)
  }
  public required init?(coder: NSCoder) { fatalError() }

  public override func loadView() {
    view = NSView()
    footer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(footer)
    footer.landmarks.target = self
    footer.landmarks.action = #selector(toggleLandmarkMode)
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
    textView.smartInsertDeleteEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.allowsUndo = false
    textView.history.levelsOfUndo = 200
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    textView.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
    textView.backgroundColor = NSColor(calibratedRed: 0.085, green: 0.094, blue: 0.106, alpha: 1)
    textView.insertionPointColor = NSColor(calibratedRed: 0.66, green: 0.80, blue: 0.66, alpha: 1)
    textView.selectedTextAttributes = [
      .backgroundColor: NSColor(calibratedRed: 0.24, green: 0.34, blue: 0.30, alpha: 1)
    ]
    textView.textContainerInset = EditorMetrics.contentInset
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 600, height: CGFloat.greatestFiniteMagnitude)
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 24
    paragraph.maximumLineHeight = 24
    paragraph.lineSpacing = 0
    textView.defaultParagraphStyle = paragraph
    textView.typingAttributes = [
      .font: textView.font!, .foregroundColor: textView.textColor!, .paragraphStyle: paragraph,
    ]
    textView.setAccessibilityLabel("Jort document")
    textView.setAccessibilityHelp(
      "Your private plain text canvas. Changes save automatically on this Mac.")
    coordinator = try! DocumentCoordinator(snapshot: unloaded)
    textView.delegate = self
    textView.isSelectable = true
    textView.isEditable = true
    ready = true
    scroll.documentView = textView
    linePresentation = LinePresentationLayout(editor: textView)
    textView.lineAccessibilityChildren = { [weak self] in
      self?.linePresentation?.accessibilityChildren()
    }
    ruler = LineRuler(scrollView: scroll, textView: textView)
    ruler.presentation = linePresentation
    ruler.onModeChange = { [weak self] in self?.updateFooter() }
    ruler.onEdit = { [weak self] id in self?.chooseLandmark(on: id) }
    ruler.onNavigate = { [weak self] id in self?.navigate(to: id) }
    ruler.onClear = { [weak self] id in
      guard let self,
        let landmark = self.state.landmarks.first(where: { !$0.detached && $0.lineID == id })
      else { return }
      self.mutateLandmark(.removeLandmark(landmark.id))
    }
    ruler.onClearAll = { [weak self] in self?.mutateLandmark(.clearLandmarks) }
    ruler.onMove = { [weak self] id in
      guard let self, let target = self.currentLineID,
        !self.state.landmarks.contains(where: { !$0.detached && $0.lineID == target }),
        let landmark = self.state.landmarks.first(where: { !$0.detached && $0.lineID == id })
      else { return }
      self.mutateLandmark(.landmark(landmark.attaching(to: target)))
    }
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
    retry.target = self
    retry.action = #selector(save)
    retry.isHidden = true
    notice.maximumNumberOfLines = 1
    notice.lineBreakMode = .byTruncatingTail
    footer.addSubview(notice)
    footer.addSubview(retry)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: view.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
      footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      footer.heightAnchor.constraint(equalToConstant: EditorMetrics.footerHeight),
      notice.leadingAnchor.constraint(equalTo: footer.landmarks.trailingAnchor, constant: 12),
      notice.trailingAnchor.constraint(lessThanOrEqualTo: retry.leadingAnchor, constant: -12),
      notice.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
      retry.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -8),
      retry.centerYAnchor.constraint(equalTo: notice.centerYAnchor),
    ])
    textView.onCompositionCommit = { [weak self] in self?.commitText() }
    toolController = ToolInvocationController(editor: self)
    toolController.packages = toolPackages
    toolController.dispatcher = toolExecutorDispatcher
    toolPresentation = ToolInvocationPresentation(editor: self)
    textView.onToolKey = { [weak self] in self?.toolPresentation.handle($0) ?? false }
    textView.onToolDraw = { [weak self] in self?.toolPresentation.draw($0) }
    textView.toolAccessibilityChildren = { [weak self] in
      self?.toolPresentation.accessibilityChildren() ?? []
    }
    textView.onPaste = { [weak self] in self?.toolPresentation.abandonCompletion() }
    textView.onCommittedSlash = { [weak self] in self?.toolPresentation.armCommittedSlash() }
    textView.onTextChange = { [weak self] in
      self?.commitText()
      self?.refreshGutterAfterLayout()
    }
    textView.onEscape = { [weak self] in
      if self?.toolPresentation.escape() == true { return true }
      guard let search = self?.documentSearch else { return false }
      search.dismiss()
      return true
    }
    persistence.onState = { [weak self] status in
      self?.present(status)
      self?.saveStatus?(status)
    }
    persistence.onCommit = { [weak self] revision in self?.coordinator?.markCommitted(revision) }
    persistence.onHistoryState = { [weak self] in
      guard let self else { return }
      self.present(self.persistence.status)
    }
    persistence.load { [weak self] result in
      guard let self else { return }
      if case .success(let snapshot) = result {
        if self.state == self.unloaded {
          self.coordinator = try! DocumentCoordinator(snapshot: snapshot, committed: true)
          self.textView.string = snapshot.text
        } else {
          self.persistence.changed(self.state)
        }
      }
      self.coordinator.onTransaction = { [weak self] result in
        guard let self else { return }
        if result.transaction.origin != .native && result.transaction.undoPolicy == .register {
          self.recordUndo(result.before, selection: self.textView.selectedRange())
        }
        if self.textView.string != result.after.text {
          self.display(result, selection: self.textView.selectedRange(), preserveAnchors: true)
        }
        self.linePresentation.update(lines: result.after.lines)
        self.ruler.lines = result.after.lines
        self.ruler.landmarks = result.after.landmarks
        self.updateFooter()
        self.palette?.actions = self.paletteActions()
        self.palette?.reload()
        let historyReason: HistoryBoundary?
        switch result.transaction.origin {
        case .restore: historyReason = .restore
        case .automation: historyReason = .bulk
        default: historyReason = result.before.landmarks != result.after.landmarks ? .landmark : nil
        }
        self.persistence.changed(result.after, historyReason: historyReason)
        self.documentSearch?.documentChanged()
        self.toolController.documentChanged()
        self.refreshToolPresentation()
        if result.before.landmarks != result.after.landmarks, self.persistence.status.failure == nil
        {
          self.persistence.flush()
        }
      }
      self.linePresentation.update(lines: self.state.lines)
      self.ruler.lines = self.state.lines
      self.ruler.landmarks = self.state.landmarks
      self.updateFooter()
      self.textView.history.removeAllActions()
      if self.toolCatalogLoaded { self.toolController.reconcilePackages() }
      self.view.window?.makeFirstResponder(self.textView)
    }
  }
  func present(_ status: PersistenceState) {
    let message: String?
    switch status {
    case .loadBlockedFuture:
      message = String(
        localized: "This store needs a newer version of Jort. Existing files are unchanged.")
    case .loadFailed:
      message = String(
        localized:
          "Storage could not be opened. Your typing stays in memory; save a recovery copy to keep it."
      )
    case .ownershipConflict:
      message = String(localized: "This canvas is already open in another Jort process.")
    default:
      message =
        status.failure == nil
        ? nil : String(localized: "Couldn’t save. Your text is still here. Retry with ⌘S.")
    }
    let visibleMessage = message ?? persistence.historyMessage
    notice.stringValue = visibleMessage ?? ""
    notice.toolTip = visibleMessage
    notice.isHidden = visibleMessage == nil
    retry.isHidden = message == nil || status == .ownershipConflict
    retry.title =
      status.permitsRetry
      ? String(localized: "Retry save") : String(localized: "Save Recovery Copy…")
  }

  public override func viewDidAppear() {
    super.viewDidAppear()
    if modifierMonitor == nil {
      modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
        [weak self] event in
        MainActor.assumeIsolated {
          guard let self, self.view.window?.isKeyWindow == true else { return }
          self.ruler.optionHeld = event.modifierFlags.contains(.option)
        }
        return event
      }
      NotificationCenter.default.addObserver(
        self, selector: #selector(clearHeldOption), name: NSApplication.didResignActiveNotification,
        object: nil)
      NotificationCenter.default.addObserver(
        self, selector: #selector(windowResigned(_:)), name: NSWindow.didResignKeyNotification,
        object: nil)
    }
    if ready { view.window?.makeFirstResponder(textView) }
  }
  public override func viewDidDisappear() {
    super.viewDidDisappear()
    if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    modifierMonitor = nil
    NotificationCenter.default.removeObserver(self)
    clearHeldOption()
  }
  @objc private func clearHeldOption() { ruler?.optionHeld = false }
  @objc private func windowResigned(_ notification: Notification) {
    if notification.object as? NSWindow === view.window { clearHeldOption() }
  }
  private func updateFooter() {
    footer.update(count: state.landmarks.filter { !$0.detached }.count, mode: ruler.modeState)
  }
  public func textView(
    _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
    replacementString: String?
  ) -> Bool {
    let locked = ToolRangeEditing.intersectingLocks(affectedCharRange, snapshot: state)
    if !locked.isEmpty {
      if replacementString == "", affectedCharRange.length > 0,
        locked.allSatisfy({ $0.phase == .pending }),
        let window = view.window, window.attachedSheet == nil
      {
        let revision = state.revision
        let alert = NSAlert()
        alert.messageText = "\(locked.count) mergeable responses will be deleted"
        alert.informativeText =
          "Only the selected text will be deleted. Any remaining text from affected tool calls will become ordinary text."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
          guard response == .alertFirstButtonReturn, let self else { return }
          try? self.toolController.deletePending(in: affectedCharRange, expectedRevision: revision)
        }
      }
      return false
    }
    if ready, !textView.hasMarkedText(), textView.string == state.text, let replacementString {
      pendingEdit = (affectedCharRange, replacementString.utf16.count)
    } else {
      pendingEdit = nil
    }
    return true
  }
  public func textDidChange(_ notification: Notification) {
    commitText()
    refreshGutterAfterLayout()
  }
  public func textViewDidChangeSelection(_ notification: Notification) {
    refreshGutterAfterLayout()
  }
  private func refreshGutterAfterLayout() {
    DispatchQueue.main.async { [weak self] in
      self?.ruler?.needsDisplay = true
      self?.linePresentation?.refreshViews()
      self?.refreshToolPresentation()
    }
  }
  private func commitText() {
    guard ready, !textView.hasMarkedText(), textView.string != state.text else { return }
    let edit = pendingEdit
    pendingEdit = nil
    let transaction = DocumentTransaction(
      baseRevision: state.revision, origin: .native,
      mutation: .edit(text: textView.string, range: edit?.0, replacementLength: edit?.1))
    do {
      let result = try coordinator.apply(transaction)
      recordUndo(
        result.before,
        selection: NSRange(
          location: min(edit?.0.location ?? 0, result.before.text.utf16.count), length: 0))
    } catch {
      // Preserve typed text: a range that AppKit revised during composition uses the normalized path.
      do {
        let result = try coordinator.apply(
          DocumentTransaction(
            baseRevision: state.revision, origin: .native,
            mutation: .edit(text: textView.string, range: nil, replacementLength: nil)))
        recordUndo(result.before, selection: NSRange(location: 0, length: 0))
      } catch {
        notice.stringValue = String(
          localized: "This edit could not be recorded. Copy your text to preserve it.")
        notice.isHidden = false
      }
    }
  }
  private func recordUndo(
    _ snapshot: DocumentSnapshot, selection: NSRange, viewport: NSPoint? = nil
  ) {
    let savedViewport = viewport ?? scroll.contentView.bounds.origin
    textView.history.registerUndo(withTarget: self) { target in
      let origin: MutationOrigin = target.textView.history.isUndoing ? .undo : .redo
      let currentSelection = target.textView.selectedRange()
      let currentViewport = target.scroll.contentView.bounds.origin
      do {
        let result = try target.coordinator.apply(
          DocumentTransaction(
            baseRevision: target.state.revision, origin: origin,
            undoPolicy: .replay, mutation: .restore(snapshot)))
        target.recordUndo(result.before, selection: currentSelection, viewport: currentViewport)
        target.display(result, selection: selection)
        target.scroll.contentView.scroll(to: savedViewport)
        if target.toolCatalogLoaded { target.toolController.reconcilePackages() }
      } catch { assertionFailure("Invalid undo snapshot: \(error)") }
    }
  }
  func registerToolUndo(_ snapshot: DocumentSnapshot, restoration: ToolInvocationRestoration?) {
    let selection = restoration?.selection?.resolve(in: snapshot.lines) ?? textView.selectedRange()
    let viewport = restoration.flatMap { value -> NSPoint? in
      guard let id = value.viewportLineID, let offset = value.viewportOffset,
        let band = linePresentation.band(for: id)
      else { return nil }
      return NSPoint(x: scroll.contentView.bounds.minX, y: band.frame.minY + CGFloat(offset))
    }
    recordUndo(snapshot, selection: selection, viewport: viewport)
  }
  func restoreToolPresentation(_ restoration: ToolInvocationRestoration?) {
    guard let restoration else { return }
    if let selection = restoration.selection?.resolve(in: state.lines) {
      textView.setSelectedRange(selection)
    }
    if let id = restoration.viewportLineID, let offset = restoration.viewportOffset,
      let band = linePresentation.band(for: id)
    {
      scroll.contentView.scroll(
        to: NSPoint(x: scroll.contentView.bounds.minX, y: band.frame.minY + CGFloat(offset)))
    }
  }
  func refreshToolPresentation() { toolPresentation?.refresh() }
  /// Future commands and captures submit transactions here; they never receive NSTextStorage.
  @discardableResult public func apply(_ transaction: DocumentTransaction) throws
    -> TransactionResult
  {
    guard ready else { throw DocumentError.invalidState }
    return try coordinator.apply(transaction)
  }
  private func display(
    _ result: TransactionResult, selection: NSRange, preserveAnchors: Bool = false
  ) {
    let viewport = scroll.contentView.bounds.origin
    var selected = selection
    var topAnchor: (UUID, CGFloat)?
    if preserveAnchors {
      func mapped(_ offset: Int) -> Int {
        if case .tools(_, let edit?, let length?) = result.transaction.mutation {
          if offset <= edit.location { return offset }
          if offset >= NSMaxRange(edit) { return offset + length - edit.length }
          return edit.location + min(offset - edit.location, length)
        }
        guard let old = result.before.lines.last(where: { $0.location <= offset }),
          let new = result.after.lines.first(where: { $0.id == old.id })
        else { return min(offset, result.after.text.utf16.count) }
        return new.location + min(offset - old.location, new.length)
      }
      let start = mapped(selection.location), end = mapped(NSMaxRange(selection))
      selected = NSRange(location: min(start, end), length: abs(end - start))
      topAnchor = linePresentation.viewportAnchor()
    }
    linePresentation.update(lines: result.after.lines)
    if textView.string != result.after.text {
      textView.string = result.after.text
      toolPresentation?.invalidateStyles()
    }
    // Restore presentation before selection/scrolling can trigger a layout
    // pass; replay must never expose an intermediate unstyled snapshot.
    refreshToolPresentation()
    textView.setSelectedRange(
      NSRange(
        location: min(selected.location, result.after.text.utf16.count),
        length: min(selected.length, max(0, result.after.text.utf16.count - selected.location))))
    var position = viewport
    if let (id, relativeY) = topAnchor, let band = linePresentation.band(for: id) {
      position.y = band.frame.minY + relativeY
    }
    scroll.contentView.scroll(to: position)
    ruler.lines = result.after.lines
    refreshGutterAfterLayout()
  }
  @objc public func save() {
    if persistence.status.permitsRetry { persistence.retry() } else { saveRecoveryCopy() }
  }
  var currentLineID: UUID? {
    guard ready else { return nil }
    return state.lines.last { $0.location <= textView.selectedRange().location }?.id
  }
  private var canPresent: Bool {
    ready && historyWorkspace == nil && documentSearch == nil && !textView.hasMarkedText()
      && (view.window?.firstResponder as? NSTextView)?.hasMarkedText() != true && emojiPicker == nil
      && view.window?.attachedSheet == nil
  }
  @objc public func showCommandPalette() {
    guard canPresent, palette == nil, let window = view.window else { return }
    let selection = textView.selectedRange(), viewport = scroll.contentView.bounds.origin
    let responder = window.firstResponder
    let palette = CommandPalette(parent: window)
    self.palette = palette
    palette.present(actions: paletteActions()) { [weak self, weak window, weak responder] in
      guard let self else { return }
      self.textView.setSelectedRange(selection)
      self.scroll.contentView.scroll(to: viewport)
      window?.makeKeyAndOrderFront(nil)
      window?.makeFirstResponder(responder ?? self.textView)
      self.palette = nil
    }
  }
  @objc public func toggleLandmarkMode() {
    if historyWorkspace == nil { ruler.toggleLatchedMode() }
  }
  @objc public func addOrChangeLandmark() { if let id = currentLineID { chooseLandmark(on: id) } }
  @objc public func clearCurrentLandmark() {
    guard let id = currentLineID,
      let landmark = state.landmarks.first(where: { !$0.detached && $0.lineID == id })
    else { return }
    mutateLandmark(.removeLandmark(landmark.id))
  }
  func mutateLandmark(_ mutation: DocumentMutation) {
    guard ready, historyWorkspace == nil, !textView.hasMarkedText() else { return }
    textView.history.beginUndoGrouping()
    defer { textView.history.endUndoGrouping() }
    // Flush any committed native edit before deriving a metadata transaction.
    // Otherwise displaying a transaction based on the older model can erase it.
    commitText()
    guard textView.string == state.text else { return }
    do {
      try apply(.init(baseRevision: state.revision, origin: .metadata, mutation: mutation))
    } catch {
      notice.stringValue = "This landmark is no longer available. Choose a current line."
      notice.isHidden = false
    }
  }
  func chooseLandmark(on id: UUID) {
    guard canPresent, let window = view.window, state.lines.contains(where: { $0.id == id }) else {
      return
    }
    let landmark = state.landmarks.first { !$0.detached && $0.lineID == id }
    let selection = textView.selectedRange(), viewport = scroll.contentView.bounds.origin
    let picker = EmojiPicker(parent: window, emoji: landmark?.emoji)
    emojiPicker = picker
    picker.commit = { [weak self] emoji in
      guard let self else { return }
      self.mutateLandmark(
        .landmark(Landmark(id: landmark?.id ?? LandmarkID(), lineID: id, emoji: emoji)))
      self.ruler.refreshControls()
      self.ruler.needsDisplay = true
    }
    picker.clear = { [weak self] in
      guard let self, let landmark else { return }
      self.mutateLandmark(.removeLandmark(landmark.id))
      self.ruler.refreshControls()
      self.ruler.needsDisplay = true
    }
    picker.finished = { [weak self] in
      guard let self else { return }
      self.emojiPicker = nil
      self.textView.setSelectedRange(selection)
      self.scroll.contentView.scroll(to: viewport)
      self.view.window?.makeFirstResponder(self.textView)
    }
    let anchor =
      ruler.frame(for: id)
      ?? NSRect(x: 0, y: ruler.bounds.minY + 24, width: ruler.ruleThickness, height: 24)
    picker.present(relativeTo: anchor, in: ruler)
  }
  func navigate(to id: UUID) {
    guard !textView.hasMarkedText(), let line = state.lines.first(where: { $0.id == id }) else {
      return
    }
    let range = NSRange(location: line.location, length: 0)
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
    linePresentation.refreshViews()
    view.window?.makeFirstResponder(textView)
  }
  @objc public func nextLandmark() { navigateLandmark(direction: 1) }
  @objc public func previousLandmark() { navigateLandmark(direction: -1) }
  private func navigateLandmark(direction: Int) {
    let ids = Set(state.landmarks.filter { !$0.detached }.map(\.lineID))
    let lines = state.lines.filter { ids.contains($0.id) },
      location = textView.selectedRange().location
    let destination =
      direction > 0
      ? (lines.first { $0.location > location } ?? lines.first)
      : (lines.last { $0.location < location } ?? lines.last)
    if let destination { navigate(to: destination.id) }
  }
  func paletteActions() -> [PaletteAction] {
    var actions = [
      PaletteAction(
        id: "settings.open", title: "Open Settings", keywords: "preferences tools configuration",
        execute: { [weak self] in self?.openSettings?() }),
      PaletteAction(
        id: "history.open", title: "Version History", keywords: "revision restore snapshot changes",
        enabled: { [weak self] in self?.persistence.status.permitsRetry == true },
        execute: { [weak self] in self?.showHistory() }),
      PaletteAction(
        id: "search.document", title: "Search Document", keywords: "find text matches",
        execute: { [weak self] in self?.showDocumentSearch() }),
      PaletteAction(
        id: "landmark.edit", title: "Add or Change Landmark", keywords: "emoji bookmark",
        enabled: { [weak self] in self?.currentLineID != nil },
        execute: { [weak self] in self?.addOrChangeLandmark() }),
      PaletteAction(
        id: "landmark.clear", title: "Clear Landmark at Current Line",
        enabled: { [weak self] in
          guard let self, let id = self.currentLineID else { return false }
          return self.state.landmarks.contains { !$0.detached && $0.lineID == id }
        }, execute: { [weak self] in self?.clearCurrentLandmark() }),
      PaletteAction(
        id: "landmark.next", title: "Scroll to Next Landmark",
        enabled: { [weak self] in self?.state.landmarks.contains { !$0.detached } == true },
        execute: { [weak self] in self?.nextLandmark() }),
      PaletteAction(
        id: "landmark.previous", title: "Scroll to Last Landmark", keywords: "previous",
        enabled: { [weak self] in self?.state.landmarks.contains { !$0.detached } == true },
        execute: { [weak self] in self?.previousLandmark() }),
    ]
    for package in toolPackages {
      actions.append(
        PaletteAction(
          id: "tool.\(package.manifest.id)",
          title: "Insert \(package.manifest.command) — \(package.manifest.name)",
          keywords: "tool " + package.manifest.description,
          enabled: { [weak self] in
            guard let self else { return false }
            return !self.textView.hasMarkedText() && self.textView.selectedRange().length == 0
              && self.toolController?.focused() == nil
          },
          execute: { [weak self] in
            guard let self else { return }
            try? self.toolController.accept(
              package, token: self.textView.selectedRange(), space: true)
          }))
    }
    let ordinals = Dictionary(
      uniqueKeysWithValues: state.lines.enumerated().map { ($0.element.id, $0.offset + 1) })
    for landmark in state.orderedLandmarks {
      let identity = landmark.id.rawValue.uuidString
      let label =
        landmark.detached
        ? "\(landmark.emoji) detached \(identity.prefix(8))"
        : "\(landmark.emoji) line \(ordinals[landmark.lineID] ?? 0)"
      if !landmark.detached {
        actions.append(
          PaletteAction(
            id: "navigate.\(identity)", title: "Go to \(label)", keywords: "landmark",
            execute: { [weak self] in self?.navigate(to: landmark.lineID) }))
      }
      actions.append(
        PaletteAction(
          id: "move.\(identity)", title: "Move \(label) to Current Line",
          keywords: "resolve repair landmark",
          enabled: { [weak self] in
            guard let self, let id = self.currentLineID else { return false }
            return self.state.landmarks.contains { $0.id == landmark.id }
              && !self.state.landmarks.contains { !$0.detached && $0.lineID == id }
          },
          execute: { [weak self] in
            guard let self, let id = self.currentLineID else { return }
            self.mutateLandmark(.landmark(landmark.attaching(to: id)))
          }))
      if landmark.detached {
        actions.append(
          PaletteAction(
            id: "delete.\(identity)", title: "Delete \(label)", keywords: "resolve clear landmark",
            execute: { [weak self] in self?.mutateLandmark(.removeLandmark(landmark.id)) }))
      }
    }
    return actions
  }

  @objc public func showDocumentSearch() {
    if let documentSearch {
      documentSearch.present()
      return
    }
    guard canPresent, !openingHistory, let window = view.window else { return }
    let search = DocumentSearchController()
    documentSearch = search
    addChild(search)
    search.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(search.view)
    let width = search.view.widthAnchor.constraint(equalToConstant: 360)
    width.priority = .defaultHigh
    NSLayoutConstraint.activate([
      width, search.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -24),
      search.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      search.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
    ])
    search.snapshot = { [weak self] in self?.state ?? DocumentSnapshot() }
    search.navigate = { [weak self] match in
      guard let self, !self.textView.hasMarkedText(), let range = match.resolve(in: self.state)
      else { return false }
      self.textView.setSelectedRange(range)
      self.textView.scrollRangeToVisible(range)
      self.view.window?.makeFirstResponder(self.textView)
      return true
    }
    search.onDismiss = { [weak self, weak window] in
      self?.documentSearch?.view.removeFromSuperview()
      self?.documentSearch?.removeFromParent()
      self?.documentSearch = nil
      window?.makeKeyAndOrderFront(nil)
      if let self { window?.makeFirstResponder(self.textView) }
    }
    search.present()
  }

  @objc public func showHistory() {
    guard canPresent, !openingHistory else { return }
    openingHistory = true
    Task { [weak self] in
      guard let self else { return }
      defer { openingHistory = false }
      do {
        let store = try await persistence.openHistory()
        guard canPresent else { return }
        let workspace = HistoryWorkspaceController(store: store)
        historySelection = textView.selectedRange()
        historyViewport = scroll.contentView.bounds.origin
        historyWorkspace = workspace
        workspace.onDismiss = { [weak self] in self?.dismissHistory() }
        workspace.onRestore = { [weak self] sequence in
          guard let self else { throw DocumentError.invalidState }
          try await self.restoreHistory(sequence: sequence)
        }
        addChild(workspace)
        workspace.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(workspace.view)
        NSLayoutConstraint.activate([
          workspace.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
          workspace.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
          workspace.view.topAnchor.constraint(equalTo: view.topAnchor),
          workspace.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        scroll.isHidden = true
        footer.isHidden = true
        textView.isEditable = false
        view.window?.makeFirstResponder(workspace.revisions)
      } catch {
        notice.stringValue =
          "History could not be opened. Your current document is still available."
        notice.isHidden = false
      }
    }
  }

  func dismissHistory(restored: Bool = false) {
    guard let workspace = historyWorkspace else { return }
    workspace.model.cancel()
    workspace.view.removeFromSuperview()
    workspace.removeFromParent()
    historyWorkspace = nil
    scroll.isHidden = false
    footer.isHidden = false
    textView.isEditable = true
    if !restored {
      if let selection = historySelection { textView.setSelectedRange(selection) }
      if let viewport = historyViewport { scroll.contentView.scroll(to: viewport) }
    }
    historySelection = nil
    historyViewport = nil
    present(persistence.status)
    view.window?.makeFirstResponder(textView)
  }

  func restoreHistory(sequence: Int64) async throws {
    guard let workspace = historyWorkspace else { throw DocumentError.invalidState }
    let before = state
    let revision = try await workspace.model.store.revision(sequence: sequence)
    guard revision.snapshot.documentID == before.documentID else {
      throw DocumentError.invalidState
    }
    try await persistence.preserveBeforeRestore(before)
    guard historyWorkspace === workspace, state.revision == before.revision else {
      throw DocumentError.staleRevision(expected: before.revision, actual: state.revision)
    }
    textView.history.beginUndoGrouping()
    do {
      try apply(
        .init(
          baseRevision: before.revision, origin: .restore, mutation: .restore(revision.snapshot)))
      if toolCatalogLoaded { toolController.reconcilePackages() }
      textView.history.setActionName("Restore Version")
      textView.history.endUndoGrouping()
    } catch {
      textView.history.endUndoGrouping()
      throw error
    }
    dismissHistory(restored: true)
    persistence.flush()
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
  var readOnly = false
  weak var editor: NSTextView?
  weak var presentation: LinePresentationLayout?
  var lines: [LineMeta] = [] { didSet { needsDisplay = true } }
  var landmarks: [Landmark] = [] {
    didSet {
      rebuildIndex()
      refreshControls()
      needsDisplay = true
    }
  }
  var modeState = LandmarkModeState() {
    didSet {
      refreshControls()
      needsDisplay = true
      onModeChange?()
    }
  }
  var landmarkMode: Bool {
    get { modeState.isVisible }
    set { modeState.latched = newValue }
  }
  var optionHeld: Bool {
    get { modeState.optionHeld }
    set { if modeState.optionHeld != newValue { modeState.optionHeld = newValue } }
  }
  var onModeChange: (() -> Void)?
  func toggleLatchedMode() { modeState.latched.toggle() }
  var onEdit: ((UUID) -> Void)?
  var onNavigate: ((UUID) -> Void)?
  var onClear: ((UUID) -> Void)?
  var onClearAll: (() -> Void)?
  var onMove: ((UUID) -> Void)?
  private var index: [(id: UUID, emoji: String, number: Int)] = []
  private var emojiByLine: [UUID: String] = [:]
  private var indexOffset = 0
  private var scrollAccumulator: CGFloat = 0
  private let clearButton = LandmarkClearButton(title: "Clear", target: nil, action: nil)
  private var entryButtons: [NSButton] = []
  private var hits: [(id: UUID, frame: NSRect)] = []
  init(scrollView: NSScrollView, textView: NSTextView) {
    editor = textView
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = EditorMetrics.gutterWidth
    clipsToBounds = true
    clearButton.target = self
    clearButton.action = #selector(clearAll)
    clearButton.isBordered = false
    clearButton.font = .systemFont(ofSize: 10)
    clearButton.setAccessibilityLabel("Clear all landmarks")
    clearButton.toolTip = "Clear all landmarks"
    clearButton.isHidden = true
    addSubview(clearButton)
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(update), name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)
  }
  public required init(coder: NSCoder) { fatalError() }
  deinit { NotificationCenter.default.removeObserver(self) }
  @objc private func update() {
    refreshControls()
    presentation?.refreshViews()
    needsDisplay = true
  }
  public override func layout() {
    super.layout()
    refreshControls()
  }
  @objc private func clearAll() {
    onClearAll?()
    landmarkMode = false
  }
  private func rebuildIndex() {
    emojiByLine = Dictionary(
      uniqueKeysWithValues: landmarks.filter { !$0.detached }.map { ($0.lineID, $0.emoji) })
    index = lines.enumerated().compactMap { position, line in
      emojiByLine[line.id].map { (line.id, $0, position + 1) }
    }
  }
  public override func scrollWheel(with event: NSEvent) {
    guard landmarkMode else {
      super.scrollWheel(with: event)
      return
    }
    guard event.momentumPhase.isEmpty else { return }
    if event.phase == .began { scrollAccumulator = 0 }
    let capacity = max(1, Int((bounds.height - 24) / 28))
    let delta =
      event.hasPreciseScrollingDeltas ? -event.scrollingDeltaY : -event.scrollingDeltaY * 28
    scrollAccumulator += delta
    let rows = Int(scrollAccumulator / 28)
    guard rows != 0 else { return }
    scrollAccumulator -= CGFloat(rows * 28)
    indexOffset = max(0, min(max(0, index.count - capacity), indexOffset + rows))
    refreshControls()
    needsDisplay = true
  }
  public override func mouseDown(with event: NSEvent) {
    guard !readOnly else { return }
    let point = convert(event.locationInWindow, from: nil)
    if let hit = hits.first(where: { $0.frame.contains(point) }) {
      if landmarkMode {
        landmarkMode = false
        onNavigate?(hit.id)
      } else {
        onEdit?(hit.id)
      }
    }
  }
  @objc private func activateEntry(_ sender: NSButton) {
    guard !readOnly else { return }
    guard hits.indices.contains(sender.tag) else { return }
    let id = hits[sender.tag].id
    if landmarkMode {
      landmarkMode = false
      onNavigate?(id)
    } else {
      onEdit?(id)
    }
  }
  public override func menu(for event: NSEvent) -> NSMenu? {
    guard !readOnly else { return nil }
    let point = convert(event.locationInWindow, from: nil)
    guard let hit = hits.first(where: { $0.frame.contains(point) }) else { return nil }
    return menu(for: hit.id)
  }
  private func menu(for id: UUID) -> NSMenu {
    let menu = NSMenu()
    let marked = emojiByLine[id] != nil
    for (title, action) in [
      (marked ? "Change Landmark…" : "Add Landmark…", #selector(editEntry(_:)))
    ]
      + (marked
        ? [
          ("Clear Landmark", #selector(clearEntry(_:))),
          ("Move Landmark to Current Line", #selector(moveEntry(_:))),
        ] : [])
    {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.representedObject = id
      menu.addItem(item)
    }
    return menu
  }
  @objc private func editEntry(_ item: NSMenuItem) {
    if let id = item.representedObject as? UUID { onEdit?(id) }
  }
  @objc private func clearEntry(_ item: NSMenuItem) {
    if let id = item.representedObject as? UUID { onClear?(id) }
  }
  @objc private func moveEntry(_ item: NSMenuItem) {
    if let id = item.representedObject as? UUID { onMove?(id) }
  }
  /// Coordinates are in the text container; include the extra, zero-length EOF row.
  public func visibleRows() -> [(number: Int, y: CGFloat)] {
    if let presentation, !presentation.lines.isEmpty {
      return presentation.visibleBands().map { ($0.number, $0.textY) }
    }
    guard let editor else { return [] }
    if editor.string.isEmpty { return [(1, 0)] }
    guard let manager = editor.textLayoutManager, let content = manager.textContentManager,
      let viewport = manager.textViewportLayoutController.viewportRange
    else { return [] }
    var rows: [(number: Int, y: CGFloat)] = []
    let visibleBottom =
      (editor.enclosingScrollView?.contentView.bounds.maxY ?? editor.visibleRect.maxY)
      - editor.textContainerOrigin.y
    manager.enumerateTextLayoutFragments(
      from: viewport.location, options: [.ensuresExtraLineFragment]
    ) { fragment in
      guard fragment.layoutFragmentFrame.minY <= visibleBottom else { return false }
      let paragraphOffset = content.offset(
        from: content.documentRange.location, to: fragment.rangeInElement.location)
      for line in fragment.textLineFragments {
        let offset = paragraphOffset + line.characterRange.location
        var low = 0, high = self.lines.count
        while low < high {
          let mid = (low + high) / 2
          if self.lines[mid].location < offset { low = mid + 1 } else { high = mid }
        }
        if low < self.lines.count, self.lines[low].location == offset,
          rows.last?.number != low + 1
        {
          rows.append((low + 1, fragment.layoutFragmentFrame.minY + line.typographicBounds.minY))
        }
      }
      return fragment.layoutFragmentFrame.maxY < visibleBottom
    }
    return rows
  }
  public override func drawHashMarksAndLabels(in rect: NSRect) {
    EditorMetrics.chrome.setFill()
    NSRect(x: 0, y: rect.minY, width: ruleThickness, height: rect.height).fill()
    EditorMetrics.separator.setFill()
    let pixel = EditorMetrics.pixel(in: self)
    NSRect(x: ruleThickness - pixel, y: rect.minY, width: pixel, height: rect.height).fill()
    refreshControls()
    guard !landmarkMode, let editor else { return }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    for row in visibleRows() {
      guard lines.indices.contains(row.number - 1), emojiByLine[lines[row.number - 1].id] == nil
      else { continue }
      let point = convert(NSPoint(x: 0, y: editor.textContainerOrigin.y + row.y), from: editor)
      guard point.y >= bounds.minY else { continue }
      let label = "\(row.number)" as NSString
      let size = label.size(withAttributes: attrs)
      label.draw(
        at: NSPoint(x: (ruleThickness - size.width) / 2, y: point.y + 7), withAttributes: attrs)
    }
  }
  func refreshControls() {
    guard let editor else { return }
    clearButton.frame = NSRect(x: 4, y: bounds.maxY - 24, width: 40, height: 20)
    clearButton.isHidden = !landmarkMode
    clearButton.isEnabled = !landmarks.isEmpty
    var entries: [(id: UUID, label: String, number: Int, frame: NSRect)] = []
    hits = []
    if landmarkMode {
      let capacity = max(1, Int((bounds.height - 24) / 28))
      indexOffset = min(indexOffset, max(0, index.count - capacity))
      for (offset, row) in index.dropFirst(indexOffset).prefix(capacity).enumerated() {
        entries.append(
          (
            row.id, row.emoji, row.number,
            NSRect(x: 4, y: bounds.minY + CGFloat(offset * 28), width: 40, height: 28)
          ))
      }
    }
    for row in landmarkMode ? [] : visibleRows() {
      guard lines.indices.contains(row.number - 1) else { continue }
      let point = convert(NSPoint(x: 0, y: editor.textContainerOrigin.y + row.y), from: editor)
      guard point.y >= bounds.minY else { continue }
      let id = lines[row.number - 1].id
      let frame = NSRect(x: (ruleThickness - 24) / 2, y: point.y + 2, width: 24, height: 24)
      if let emoji = emojiByLine[id] {
        entries.append((id, emoji, row.number, frame))
        continue
      }
      hits.append((id, frame))
    }
    while entryButtons.count > entries.count { entryButtons.removeLast().removeFromSuperview() }
    while entryButtons.count < entries.count {
      let button = LandmarkEntryButton(
        title: "", target: self, action: #selector(activateEntry(_:)))
      button.isBordered = false
      button.font = .systemFont(ofSize: 11)
      addSubview(button)
      entryButtons.append(button)
    }
    for (position, entry) in entries.enumerated() {
      let button = entryButtons[position]
      button.frame = entry.frame
      button.title = entry.label
      button.menu = readOnly ? nil : menu(for: entry.id)
      button.tag = hits.count
      hits.append((entry.id, entry.frame))
      let name =
        "\(entry.label), line \(entry.number), \(readOnly ? "historical landmark" : landmarkMode ? "navigate" : "change landmark")"
      button.setAccessibilityLabel(name)
      if landmarkMode, lines.indices.contains(entry.number - 1) {
        let line = lines[entry.number - 1]
        button.toolTip = (editor.string as NSString)
          .substring(with: NSRange(location: line.location, length: line.length))
          .trimmingCharacters(in: .newlines)
      } else {
        button.toolTip = name
      }
    }
  }
  func frame(for id: UUID) -> NSRect? { hits.first(where: { $0.id == id })?.frame }
}

@MainActor private final class LandmarkEntryButton: NSButton {
  override func draw(_ dirtyRect: NSRect) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 11)]
    let label = title as NSString
    let size = label.size(withAttributes: attributes)
    label.draw(
      at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
      withAttributes: attributes)
  }
}

@MainActor private final class LandmarkClearButton: NSButton {
  override func draw(_ dirtyRect: NSRect) {
    let warning = NSColor(
      srgbRed: 0xCD / 255, green: 0xA9 / 255, blue: 0x77 / 255, alpha: isEnabled ? 1 : 0.4)
    let outline = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: outline, xRadius: 4, yRadius: 4)
    warning.setStroke()
    path.lineWidth = 1
    path.stroke()

    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.systemFont(ofSize: 10),
      .foregroundColor: warning,
    ]
    let label = title as NSString
    let size = label.size(withAttributes: attributes)
    label.draw(
      at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
      withAttributes: attributes)
  }
}
