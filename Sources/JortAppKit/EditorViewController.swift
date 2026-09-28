import JortToolContracts
import AppKit
import UniformTypeIdentifiers
import JortDocument
import JortPersistence
import JortSettings

@MainActor public final class EditorViewController: NSViewController, NSTextViewDelegate {
  public let persistence: PersistenceController
  let scroll = NSScrollView()
  let textView = JortTextView(usingTextLayoutManager: true)
  let notice = NSTextField(wrappingLabelWithString: "")
  let retry = NSButton(
    title: LocalizedCopy.text("EditorViewController.retry_save", fallback: "Retry save"),
    target: nil, action: nil)
  let footer = EditorFooter(frame: .zero)
  private(set) var modifierMonitor: Any?
  private let unloaded = DocumentSnapshot()
  public private(set) var coordinator: DocumentCoordinator!
  public var state: DocumentSnapshot { coordinator?.snapshot ?? unloaded }
  private let storageProjection = EditorStorageProjection()
  public private(set) var startupPhase: EditorStartupPhase {
    get { storageProjection.phase }
    set {
      storageProjection.phase = newValue
      onStartupPhase?(newValue)
    }
  }
  public var onStartupPhase: ((EditorStartupPhase) -> Void)?
  private var loadedForReconciliation: DocumentSnapshot? {
    get { storageProjection.loadedForReconciliation }
    set { storageProjection.loadedForReconciliation = newValue }
  }
  private var acceptsEditing: Bool { coordinator != nil && startupPhase != .ownershipConflict }
  private var pendingEdit: (range: NSRange, text: String?, length: Int, revision: Int64)?
  private var nativeReplacementInFlight = false
  private var ruler: LineRuler!
  let presentationCoordinator = PresentationCoordinator()
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
  public var toolInvocationCoordinator: any ToolInvocationCoordinating =
    UnavailableInvocationCoordinator()
  {
    didSet { toolController?.coordinator = toolInvocationCoordinator }
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
  public func finishComposition() { textView.unmarkText() }
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
    textView.setAccessibilityLabel(
      LocalizedCopy.text("EditorViewController.jort_document", fallback: "Jort document"))
    textView.setAccessibilityHelp(
      LocalizedCopy.text(
        "EditorViewController.your_private_plain_text_canvas_changes_save_automatically_on_this",
        fallback: "Your private plain text canvas. Changes save automatically on this Mac."))
    coordinator = try! DocumentCoordinator(snapshot: unloaded)
    textView.acceptedRevision = unloaded.revision
    textView.delegate = self
    textView.isSelectable = true
    textView.isEditable = true
    scroll.documentView = textView
    linePresentation = LinePresentationLayout(editor: textView)
    textView.lineAccessibilityChildren = { [weak self] in
      self?.linePresentation?.accessibilityChildren()
    }
    ruler = LineRuler(scrollView: scroll, textView: textView)
    ruler.presentation = linePresentation
    ruler.invalidatePresentation = { [weak self] in
      self?.presentationCoordinator.invalidate(.viewport)
    }
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
    textView.onCompositionCommit = { [weak self] in
      self?.commitText()
      self?.presentationCoordinator.invalidate(.document)
    }
    toolController = ToolInvocationController(editor: self)
    toolController.packages = toolPackages
    toolController.coordinator = toolInvocationCoordinator
    toolPresentation = ToolInvocationPresentation(editor: self)
    presentationCoordinator.prepare = { [weak self] _ in
      guard let self, !self.textView.hasMarkedText() else { return nil }
      return { [weak self] in
        guard let self else { return }
        let epoch = self.presentationCoordinator.epoch
        self.linePresentation.prepareViewportLayout()
        guard self.presentationCoordinator.epoch == epoch else { return }
        if self.toolPresentation.reconcileStyles() {
          self.presentationCoordinator.invalidate(.layout)
          return
        }
        self.linePresentation.capture(epoch: self.presentationCoordinator.epoch)
        self.toolPresentation.reconcileControls()
        self.linePresentation.refreshViews()
        self.ruler.refreshControls()
        self.ruler.needsDisplay = true
      }
    }
    textView.onLayout = { [weak self] in self?.presentationCoordinator.invalidate(.layout) }
    textView.onWindowGeometry = { [weak self] in self?.presentationCoordinator.invalidate(.window) }
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(accessibilityDisplayChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    textView.onAppearance = { [weak self] in self?.presentationCoordinator.invalidate(.appearance) }
    presentationCoordinator.invalidate(.document)
    textView.onToolKey = { [weak self] in self?.toolPresentation.handle($0) ?? false }
    textView.onToolDraw = { [weak self] in self?.toolPresentation.draw($0) }
    textView.toolAccessibilityChildren = { [weak self] in
      self?.toolPresentation.accessibilityChildren() ?? []
    }
    textView.onPaste = { [weak self] in self?.toolPresentation.abandonCompletion() }
    textView.onCommittedSlash = { [weak self] in self?.toolPresentation.armCommittedSlash() }
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
    persistence.onMaintenance = { [weak self] in
      guard let self else { return }
      self.present(self.persistence.status)
    }
    observeTransactions()
    persistence.load { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let snapshot):
        self.loadedForReconciliation = snapshot
        self.startupPhase = .resolvingLoadedSnapshot
        self.reconcileStartupIfPossible()
      case .failure(let error):
        if error == .ownership {
          self.startupPhase = .ownershipConflict
          self.textView.isEditable = false
        } else {
          self.startupPhase = .recoveryEditing(error)
        }
      }
    }
  }
  private func observeTransactions() {
    coordinator.onTransaction = { [weak self] result in
      guard let self else { return }
      if !result.before.invocations.isEmpty {
        let beforeInvocationIDs = Set(result.before.invocations.map(\.id))
        let survivingInvocationIDs = Set(result.after.invocations.map(\.id))
        let removedInvocationIDs = beforeInvocationIDs.subtracting(survivingInvocationIDs)
        if !removedInvocationIDs.isEmpty {
          // Geometry for surviving calls can shift when the removed call changes text.
          // Retire their old paths now; the scheduled pass rebuilds them after layout.
          let affectedSurvivorIDs =
            result.before.text == result.after.text
            ? Set<UUID>() : beforeInvocationIDs.intersection(survivingInvocationIDs)
          self.toolPresentation?.removePresentation(
            for: removedInvocationIDs, affectedSurvivorIDs: affectedSurvivorIDs)
        }
      }
      if result.transaction.origin != .native && result.transaction.undoPolicy == .register {
        self.recordUndo(result.before, selection: self.textView.selectedRange())
      }
      let requiresProjection: Bool
      switch result.transaction.mutation {
      case .patch: requiresProjection = true
      case .landmark, .removeLandmark, .clearLandmarks: requiresProjection = false
      default:
        requiresProjection =
          !self.nativeReplacementInFlight && self.textView.string != result.after.text
      }
      if requiresProjection {
        self.display(
          result, selection: self.textView.selectedRange(),
          preserveAnchors: result.transaction.origin != .startupMerge)
      }
      self.textView.acceptedRevision = result.after.revision
      DocumentInstrumentation.event("NativeTextVisibleState", revision: result.after.revision)
      self.linePresentation.update(lines: result.after.lines)
      self.ruler.lineView = result.after.lines
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
      if self.startupPhase == .ready {
        self.persistence.changed(result.after, historyReason: historyReason)
      }
      self.documentSearch?.documentChanged()
      self.toolController.documentChanged()
      self.refreshToolPresentation()
      if result.before.landmarks != result.after.landmarks, self.persistence.status.failure == nil {
        self.persistence.flush()
      }
    }
  }
  private func reconcileStartupIfPossible() {
    guard !textView.hasMarkedText(), let snapshot = loadedForReconciliation else { return }
    loadedForReconciliation = nil
    let draft = state.text
    let selection = textView.selectedRange()
    let viewport = scroll.contentView.bounds.origin
    pendingEdit = nil
    textView.history.removeAllActions()
    coordinator = try! DocumentCoordinator(snapshot: snapshot, committed: true)
    observeTransactions()
    let prefix = StartupMerge.prefix(draft: draft, stored: snapshot.text)
    if !prefix.isEmpty {
      textView.history.beginUndoGrouping()
      _ = try! coordinator.apply(
        .init(
          baseRevision: snapshot.revision, origin: .startupMerge,
          mutation: .replace(range: NSRange(location: 0, length: 0), text: prefix)))
      textView.history.setActionName(
        LocalizedCopy.text("EditorViewController.startup_typing", fallback: "Startup Typing"))
      textView.history.endUndoGrouping()
    } else {
      textView.string = snapshot.text
    }
    textView.acceptedRevision = state.revision
    let start = min(selection.location, draft.utf16.count)
    textView.setSelectedRange(
      NSRange(
        location: start,
        length: min(selection.length, draft.utf16.count - start)))
    scroll.contentView.scroll(to: viewport)
    linePresentation.update(lines: state.lines)
    ruler.lineView = state.lines
    ruler.landmarks = state.landmarks
    updateFooter()
    startupPhase = .ready
    if !prefix.isEmpty { persistence.changed(state) }
    if toolCatalogLoaded { toolController.reconcilePackages() }
  }
  func present(_ status: PersistenceState) {
    let projection = storageProjection.notice(
      for: status, historyMessage: persistence.historyMessage)
    let message = maintenanceMessage() ?? projection.message
    notice.stringValue = message ?? ""
    notice.toolTip = message
    notice.isHidden = message == nil
    retry.isHidden = !projection.canRetry
    retry.title = projection.actionTitle
    presentationCoordinator.invalidate(.storage)
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
    if acceptsEditing { view.window?.makeFirstResponder(textView) }
  }
  public override func viewDidDisappear() {
    super.viewDidDisappear()
    if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    modifierMonitor = nil
    NotificationCenter.default.removeObserver(self)
    clearHeldOption()
  }
  @objc private func accessibilityDisplayChanged() {
    presentationCoordinator.invalidate([.accessibility, .appearance])
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
          LocalizedCopy.text(
            "EditorViewController.only_the_selected_text_will_be_deleted_any_remaining_text_from_af",
            fallback:
              "Only the selected text will be deleted. Any remaining text from affected tool calls will become ordinary text."
          )
        alert.alertStyle = .warning
        alert.addButton(
          withTitle: LocalizedCopy.text("EditorViewController.delete", fallback: "Delete"))
        alert.addButton(
          withTitle: LocalizedCopy.text("EditorViewController.cancel", fallback: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
          guard response == .alertFirstButtonReturn, let self else { return }
          try? self.toolController.deletePending(in: affectedCharRange, expectedRevision: revision)
        }
      }
      return false
    }
    if acceptsEditing, let replacementString,
      affectedCharRange.location >= 0, affectedCharRange.length >= 0,
      let nativeLength = textView.textStorage?.length,
      affectedCharRange.location <= nativeLength,
      affectedCharRange.length <= nativeLength - affectedCharRange.location
    {
      if let pending = pendingEdit, pending.revision == state.revision,
        nativeLength == state.utf16Count - pending.range.length + pending.length
      {
        // Accumulate provisional IME replacements in the original root's coordinates.
        let delta = pending.length - pending.range.length
        let start = min(pending.range.location, affectedCharRange.location)
        let end = max(NSMaxRange(pending.range), NSMaxRange(affectedCharRange) - delta)
        pendingEdit = (
          NSRange(location: start, length: end - start), nil,
          end - start + delta - affectedCharRange.length + replacementString.utf16.count,
          pending.revision
        )
      } else if self.textView.acceptedRevision == state.revision,
        nativeLength == state.utf16Count
      {
        pendingEdit = (
          affectedCharRange, replacementString, replacementString.utf16.count, state.revision
        )
      } else {
        pendingEdit = nil
      }
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
    presentationCoordinator.invalidate([.layout, .interaction])
  }

  private func commitText() {
    let measurement = DocumentInstrumentation.begin("NativeCommit", revision: -1)
    defer { DocumentInstrumentation.end(measurement) }
    // Native input may still be closing an undo group or replacing marked text.
    // Reconcile only after that complete input operation has returned to AppKit.
    defer {
      if loadedForReconciliation != nil {
        DispatchQueue.main.async { [weak self] in self?.reconcileStartupIfPossible() }
      }
    }
    guard acceptsEditing, !textView.hasMarkedText() else { return }
    let edit = pendingEdit
    pendingEdit = nil
    let mutation: DocumentMutation
    if let edit, edit.revision == state.revision,
      textView.textStorage?.length == state.utf16Count - edit.range.length + edit.length
    {
      let replacement =
        edit.text
        ?? textView.textStorage!.attributedSubstring(
          from: NSRange(location: edit.range.location, length: edit.length)
        ).string
      guard (try? state.text(in: edit.range)) != replacement else { return }
      mutation = .replace(range: edit.range, text: replacement)
      nativeReplacementInFlight = true
    } else if let fallback = boundedNativeReplacement() {
      guard fallback.0.length != 0 || !fallback.1.isEmpty else { return }
      mutation = .replace(range: fallback.0, text: fallback.1)
      nativeReplacementInFlight = true
    } else {
      DocumentInstrumentation.event("NativeBulkReplacement", revision: state.revision)
      guard textView.string != state.text else { return }
      mutation = .edit(text: textView.string, range: nil, replacementLength: nil)
    }
    defer { nativeReplacementInFlight = false }
    let transaction = DocumentTransaction(
      baseRevision: state.revision, origin: .native, mutation: mutation)
    do {
      let result = try coordinator.apply(transaction)
      DocumentInstrumentation.event("NativeTextAccepted", revision: result.after.revision)
      recordUndo(
        result.before,
        selection: NSRange(
          location: min(edit?.range.location ?? 0, result.before.utf16Count), length: 0))
    } catch {
      nativeReplacementInFlight = false
      // Preserve typed text: a range that AppKit revised during composition uses the normalized path.
      do {
        let result = try coordinator.apply(
          DocumentTransaction(
            baseRevision: state.revision, origin: .native,
            mutation: .edit(text: textView.string, range: nil, replacementLength: nil)))
        recordUndo(result.before, selection: NSRange(location: 0, length: 0))
      } catch {
        notice.stringValue = LocalizedCopy.text(
          "EditorViewController.this_edit_could_not_be_recorded_copy_your_text_to_preserve_it",
          fallback: "This edit could not be recorded. Copy your text to preserve it.")
        notice.isHidden = false
      }
    }
  }
  /// Bound discovery work when an input service omitted shouldChangeTextIn.
  /// Unknown changes beyond this window use the explicit full-document path.
  private func boundedNativeReplacement() -> (NSRange, String)? {
    guard let storage = textView.textStorage else { return nil }
    let oldCount = state.utf16Count, newCount = storage.length
    let commonCount = min(oldCount, newCount), budget = 4096
    let prefixLimit = min(commonCount, budget)
    guard let leading = try? state.utf16(in: NSRange(location: 0, length: prefixLimit)) else {
      return nil
    }
    let native = storage.mutableString
    var prefix = 0
    while prefix < prefixLimit, leading[prefix] == native.character(at: prefix) { prefix += 1 }
    if prefix == prefixLimit, prefix < commonCount { return nil }
    let suffixLimit = min(commonCount - prefix, budget)
    guard
      let trailing = try? state.utf16(
        in: NSRange(location: oldCount - suffixLimit, length: suffixLimit))
    else { return nil }
    var suffix = 0
    while suffix < suffixLimit,
      trailing[suffixLimit - suffix - 1] == native.character(at: newCount - suffix - 1)
    { suffix += 1 }
    if suffix == suffixLimit, suffix < commonCount - prefix { return nil }
    let replaced = oldCount - prefix - suffix, inserted = newCount - prefix - suffix
    guard max(replaced, inserted) <= 65_536 else { return nil }
    return (
      NSRange(location: prefix, length: replaced),
      storage.attributedSubstring(from: NSRange(location: prefix, length: inserted)).string
    )
  }
  private func recordUndo(
    _ snapshot: DocumentSnapshot, selection: NSRange, viewport: NSPoint? = nil
  ) {
    let savedViewport = viewport ?? scroll.contentView.bounds.origin
    textView.history.register(before: snapshot, after: state) { [weak self] in
      guard let target = self else { return }
      MainActor.assumeIsolated {
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
  func refreshToolPresentation() { presentationCoordinator.invalidate([.document, .lifecycle]) }
  /// Future commands and captures submit transactions here; they never receive NSTextStorage.
  @discardableResult public func apply(_ transaction: DocumentTransaction) throws
    -> TransactionResult
  {
    guard acceptsEditing else { throw DocumentError.invalidState }
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
        if case .patch(let patch) = result.transaction.mutation {
          var mapped = offset
          for replacement in patch.replacements.reversed() {
            let edit = replacement.range, length = replacement.text.utf16.count
            if mapped <= edit.location { continue }
            if mapped >= NSMaxRange(edit) {
              mapped += length - edit.length
            } else {
              mapped = edit.location + min(mapped - edit.location, length)
            }
          }
          return mapped
        }
        guard let old = result.before.line(containingUTF16Offset: offset),
          let new = result.after.line(id: old.id)
        else { return min(offset, result.after.utf16Count) }
        return new.location + min(offset - old.location, new.length)
      }
      let start = mapped(selection.location), end = mapped(NSMaxRange(selection))
      selected = NSRange(location: min(start, end), length: abs(end - start))
      topAnchor = linePresentation.viewportAnchor()
    }
    linePresentation.update(lines: result.after.lines)
    if case .patch(let patch) = result.transaction.mutation, let storage = textView.textStorage {
      storage.beginEditing()
      toolPresentation?.clearChangedStyles(before: result.before, after: result.after)
      for replacement in patch.replacements.reversed() {
        storage.replaceCharacters(in: replacement.range, with: replacement.text)
      }
      storage.endEditing()
      toolPresentation?.invalidateStyles()
    } else if textView.string != result.after.text {
      textView.string = result.after.text
      toolPresentation?.invalidateStyles()
    }
    // Restore presentation before selection/scrolling can trigger a layout
    // pass; replay must never expose an intermediate unstyled snapshot.
    refreshToolPresentation()
    textView.setSelectedRange(
      NSRange(
        location: min(selected.location, result.after.utf16Count),
        length: min(selected.length, max(0, result.after.utf16Count - selected.location))))
    var position = viewport
    if let (id, relativeY) = topAnchor, let band = linePresentation.band(for: id) {
      position.y = band.frame.minY + relativeY
    }
    scroll.contentView.scroll(to: position)
    ruler.lineView = result.after.lines
    refreshGutterAfterLayout()
  }
  @objc public func save() {
    if persistence.status.permitsRetry { saveDocument() } else { saveRecoveryCopy() }
  }
  var currentLineID: UUID? {
    guard acceptsEditing else { return nil }
    return state.line(containingUTF16Offset: textView.selectedRange().location)?.id
  }
  private var canPresent: Bool {
    acceptsEditing && historyWorkspace == nil && documentSearch == nil && !textView.hasMarkedText()
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
    guard acceptsEditing, historyWorkspace == nil, !textView.hasMarkedText() else { return }
    textView.history.beginUndoGrouping()
    defer { textView.history.endUndoGrouping() }
    // Flush any committed native edit before deriving a metadata transaction.
    // Otherwise displaying a transaction based on the older model can erase it.
    commitText()
    guard textView.string == state.text else { return }
    do {
      try apply(.init(baseRevision: state.revision, origin: .metadata, mutation: mutation))
    } catch {
      notice.stringValue = LocalizedCopy.text(
        "EditorViewController.this_landmark_is_no_longer_available_choose_a_current_line",
        fallback: "This landmark is no longer available. Choose a current line.")
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
      self.ruler.requestPresentation()
      self.ruler.needsDisplay = true
    }
    picker.clear = { [weak self] in
      guard let self, let landmark else { return }
      self.mutateLandmark(.removeLandmark(landmark.id))
      self.ruler.requestPresentation()
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
        id: "settings.open",
        title: LocalizedCopy.text("EditorViewController.open_settings", fallback: "Open Settings"),
        keywords: LocalizedCopy.text(
          "EditorViewController.preferences_tools_configuration",
          fallback: "preferences tools configuration"),
        execute: { [weak self] in self?.openSettings?() }),
      PaletteAction(
        id: "history.open",
        title: LocalizedCopy.text(
          "EditorViewController.version_history", fallback: "Version History"),
        keywords: LocalizedCopy.text(
          "EditorViewController.revision_restore_snapshot_changes",
          fallback: "revision restore snapshot changes"),
        enabled: { [weak self] in self?.persistence.status.permitsRetry == true },
        execute: { [weak self] in self?.showHistory() }),
      PaletteAction(
        id: "search.document",
        title: LocalizedCopy.text(
          "EditorViewController.search_document", fallback: "Search Document"),
        keywords: LocalizedCopy.text(
          "EditorViewController.find_text_matches", fallback: "find text matches"),
        execute: { [weak self] in self?.showDocumentSearch() }),
      PaletteAction(
        id: "landmark.edit",
        title: LocalizedCopy.text(
          "EditorViewController.add_or_change_landmark", fallback: "Add or Change Landmark"),
        keywords: LocalizedCopy.text(
          "EditorViewController.emoji_bookmark", fallback: "emoji bookmark"),
        enabled: { [weak self] in self?.currentLineID != nil },
        execute: { [weak self] in self?.addOrChangeLandmark() }),
      PaletteAction(
        id: "landmark.clear",
        title: LocalizedCopy.text(
          "EditorViewController.clear_landmark_at_current_line",
          fallback: "Clear Landmark at Current Line"),
        enabled: { [weak self] in
          guard let self, let id = self.currentLineID else { return false }
          return self.state.landmarks.contains { !$0.detached && $0.lineID == id }
        }, execute: { [weak self] in self?.clearCurrentLandmark() }),
      PaletteAction(
        id: "landmark.next",
        title: LocalizedCopy.text(
          "EditorViewController.scroll_to_next_landmark", fallback: "Scroll to Next Landmark"),
        enabled: { [weak self] in self?.state.landmarks.contains { !$0.detached } == true },
        execute: { [weak self] in self?.nextLandmark() }),
      PaletteAction(
        id: "landmark.previous",
        title: LocalizedCopy.text(
          "EditorViewController.scroll_to_last_landmark", fallback: "Scroll to Last Landmark"),
        keywords: "previous",
        enabled: { [weak self] in self?.state.landmarks.contains { !$0.detached } == true },
        execute: { [weak self] in self?.previousLandmark() }),
    ]
    for package in toolPackages {
      actions.append(
        PaletteAction(
          id: "tool.\(package.manifest.id)",
          title: "Insert \(package.manifest.command) — \(package.manifest.name)",
          keywords: LocalizedCopy.text("EditorViewController.tool", fallback: "tool ")
            + package.manifest.description,
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
          keywords: LocalizedCopy.text(
            "EditorViewController.resolve_repair_landmark", fallback: "resolve repair landmark"),
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
            id: "delete.\(identity)", title: "Delete \(label)",
            keywords: LocalizedCopy.text(
              "EditorViewController.resolve_clear_landmark", fallback: "resolve clear landmark"),
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
          LocalizedCopy.text(
            "EditorViewController.history_could_not_be_opened_your_current_document_is_still_availa",
            fallback: "History could not be opened. Your current document is still available.")
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
      textView.history.setActionName(
        LocalizedCopy.text("EditorViewController.restore_version", fallback: "Restore Version"))
      textView.history.endUndoGrouping()
    } catch {
      textView.history.endUndoGrouping()
      throw error
    }
    dismissHistory(restored: true)
    persistence.flush()
  }
  @objc public func saveRecoveryCopy() {
    guard coordinator != nil, startupPhase != .ownershipConflict, let window = view.window else {
      return
    }
    finishComposition()
    let panel = NSSavePanel()
    panel.title = LocalizedCopy.text(
      "EditorViewController.save_recovery_copy", fallback: "Save Recovery Copy")
    panel.message = LocalizedCopy.text(
      "EditorViewController.preserve_your_current_text_and_line_metadata_in_a_separate_recove",
      fallback: "Preserve your current text and line metadata in a separate recovery file.")
    panel.nameFieldStringValue = LocalizedCopy.text(
      "EditorViewController.jort_recovery_json", fallback: "Jort Recovery.json")
    panel.allowedContentTypes = [.json]
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      self.persistence.saveRecoveryCopy(snapshot: self.state, to: url) { result in
        switch result {
        case .success:
          self.notice.stringValue = LocalizedCopy.format(
            "storage.recovery_saved", fallback: "Recovery copy saved to %@.", url.lastPathComponent)
        case .failure(let error):
          self.notice.stringValue = LocalizedCopy.format(
            "storage.recovery_failed", fallback: "Couldn’t save recovery copy: %@",
            String(describing: error))
        }
        self.notice.isHidden = false
      }
    }
  }
}
