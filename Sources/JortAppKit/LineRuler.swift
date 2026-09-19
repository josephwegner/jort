import AppKit
import JortDocument

/// Uses TextKit 2's already-visible fragments; scrolling never forces whole-document layout.
@MainActor public final class LineRuler: NSRulerView {
  var invalidatePresentation: (() -> Void)?
  private let fallbackCoordinator = PresentationCoordinator()
  private var preparedLabels: [(String, NSPoint)] = []
  var readOnly = false
  weak var editor: NSTextView?
  weak var presentation: LinePresentationLayout?
  var lines: [LineMeta] = [] { didSet { needsDisplay = true } }
  var landmarks: [Landmark] = [] {
    didSet {
      rebuildIndex()
      requestPresentation()
      needsDisplay = true
    }
  }
  var modeState = LandmarkModeState() {
    didSet {
      requestPresentation()
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
  private let clearButton = LandmarkClearButton(
    title: LocalizedCopy.text("LineRuler.clear", fallback: "Clear"), target: nil, action: nil)
  private let mounts = RulerControlMounts()
  private var hits: [(id: UUID, frame: NSRect)] = []
  init(scrollView: NSScrollView, textView: NSTextView) {
    editor = textView
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    fallbackCoordinator.prepare = { [weak self] _ in
      { [weak self] in
        self?.refreshControls()
        self?.needsDisplay = true
      }
    }
    clientView = textView
    ruleThickness = EditorMetrics.gutterWidth
    clipsToBounds = true
    clearButton.target = self
    clearButton.action = #selector(clearAll)
    clearButton.isBordered = false
    clearButton.font = .systemFont(ofSize: 10)
    clearButton.setAccessibilityLabel(
      LocalizedCopy.text("LineRuler.clear_all_landmarks", fallback: "Clear all landmarks"))
    clearButton.toolTip = LocalizedCopy.text(
      "LineRuler.clear_all_landmarks", fallback: "Clear all landmarks")
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
    requestPresentation()

    needsDisplay = true
  }
  private var lastLayoutBounds: NSRect?
  public override func layout() {
    super.layout()
    guard lastLayoutBounds != bounds else { return }
    lastLayoutBounds = bounds
    requestPresentation()
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
    requestPresentation()
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
    guard sender.superview === self,
      let id = (sender as? LandmarkEntryButton)?.lineID,
      lines.contains(where: { $0.id == id })
    else { return }
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
      (
        marked
          ? LocalizedCopy.text("LineRuler.change_landmark", fallback: "Change Landmark…")
          : LocalizedCopy.text("LineRuler.add_landmark", fallback: "Add Landmark…"),
        #selector(editEntry(_:))
      )
    ]
      + (marked
        ? [
          (
            LocalizedCopy.text("LineRuler.clear_landmark", fallback: "Clear Landmark"),
            #selector(clearEntry(_:))
          ),
          (
            LocalizedCopy.text(
              "LineRuler.move_landmark_to_current_line", fallback: "Move Landmark to Current Line"),
            #selector(moveEntry(_:))
          ),
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
      return presentation.snapshot.bands.map { ($0.number, $0.textY) }
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
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    for (text, point) in preparedLabels {
      let label = text as NSString
      let size = label.size(withAttributes: attrs)
      label.draw(
        at: NSPoint(x: (ruleThickness - size.width) / 2, y: point.y + 7), withAttributes: attrs)
    }
  }
  func requestPresentation() {
    if let invalidatePresentation {
      invalidatePresentation()
    } else {
      fallbackCoordinator.invalidate(.layout)
    }
  }
  func refreshControls() {
    guard let editor else { return }
    preparedLabels = []
    if !landmarkMode {
      for row in visibleRows() {
        guard lines.indices.contains(row.number - 1), emojiByLine[lines[row.number - 1].id] == nil
        else { continue }
        let point = convert(NSPoint(x: 0, y: editor.textContainerOrigin.y + row.y), from: editor)
        guard point.y >= bounds.minY else { continue }
        preparedLabels.append((String(row.number), point))
      }
    }
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
    mounts.reconcile(ids: Set(entries.map(\.id)))
    var ordered: [NSView] = []
    for entry in entries {
      let button = mounts.button(for: entry.id, in: self) {
        let button = LandmarkEntryButton(
          title: "", target: self, action: #selector(activateEntry(_:)))
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        return button
      }
      ordered.append(button)
      button.frame = entry.frame
      button.title = entry.label
      button.menu = readOnly ? nil : menu(for: entry.id)
      (button as? LandmarkEntryButton)?.lineID = entry.id
      button.tag = hits.count
      hits.append((entry.id, entry.frame))
      let action =
        readOnly
        ? LocalizedCopy.text("landmarks.historical", fallback: "historical landmark")
        : landmarkMode
          ? LocalizedCopy.text("landmarks.navigate", fallback: "navigate")
          : LocalizedCopy.text("landmarks.change", fallback: "change landmark")
      let name = LocalizedCopy.format(
        "landmarks.entry", fallback: "%@, line %ld, %@", entry.label, entry.number, action)
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
    if !clearButton.isHidden { ordered.append(clearButton) }
    setAccessibilityChildren(ordered)
  }
  func frame(for id: UUID) -> NSRect? { hits.first(where: { $0.id == id })?.frame }
}

@MainActor private final class LandmarkEntryButton: NSButton {
  var lineID: UUID?
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
