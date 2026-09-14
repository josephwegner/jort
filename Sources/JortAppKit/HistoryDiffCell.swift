import AppKit
import JortDocument

@MainActor final class HistoryDiffTable: PaletteTable {
  var gutterWidth: CGFloat = 94 { didSet { needsDisplay = true } }
  override func drawBackground(inClipRect clipRect: NSRect) {
    super.drawBackground(inClipRect: clipRect)
    EditorMetrics.chrome.setFill()
    NSRect(x: 0, y: clipRect.minY, width: gutterWidth, height: clipRect.height).fill()
    EditorMetrics.separator.setFill()
    NSRect(x: gutterWidth - 1, y: clipRect.minY, width: 1, height: clipRect.height).fill()
  }
}

/// Separate gutter and content surfaces keep contiguous changed rows visually joined.
@MainActor final class HistoryDiffCell: NSTableCellView {
  private let kind: HistoryChangeLine.Kind
  private let gutterWidth: CGFloat
  init(line: HistoryChangeLine, digits: Int) {
    kind = line.kind
    let numberWidth = CGFloat(max(2, digits)) * 8 + 8
    gutterWidth = 26 + numberWidth * 2 + 20
    super.init(frame: .zero)
    let marker = line.kind == .added ? "+" : line.kind == .removed ? "−" : ""
    let emoji = field(line.emoji ?? "", alignment: .center)
    let old = field(line.oldOrdinal.map(String.init) ?? "", alignment: .right)
    let new = field(line.newOrdinal.map(String.init) ?? "", alignment: .right)
    let sign = field(marker, alignment: .center)
    let text = field(line.text.trimmingCharacters(in: .newlines), alignment: .left)
    textField = text
    old.textColor = .secondaryLabelColor
    new.textColor = .secondaryLabelColor
    let widths: [(NSTextField, CGFloat)] = [
      (emoji, 26), (old, numberWidth), (new, numberWidth), (sign, 20),
    ]
    var leading = leadingAnchor
    for (label, width) in widths {
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: leading),
        label.widthAnchor.constraint(equalToConstant: width),
      ])
      leading = label.trailingAnchor
    }
    text.lineBreakMode = .byTruncatingTail
    text.leadingAnchor.constraint(equalTo: leading, constant: 8).isActive = true
    let toolDescription = line.tools.map(\.label).joined(separator: ", ")
    if !line.tools.isEmpty {
      let badge = field(toolDescription, alignment: .right)
      badge.font = .systemFont(ofSize: 11, weight: .medium)
      badge.textColor =
        line.tools.contains { $0.phase == .pending } ? ToolPresentationColors.pending : .systemTeal
      badge.lineBreakMode = .byTruncatingTail
      badge.toolTip = toolDescription
      NSLayoutConstraint.activate([
        badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        badge.widthAnchor.constraint(equalToConstant: min(220, badge.intrinsicContentSize.width)),
        text.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -12),
      ])
    } else {
      text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true
    }
    let change = line.kind == .added ? "Added" : line.kind == .removed ? "Removed" : "Unchanged"
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(
      "\(change), landmark \(line.emoji ?? "none"), old line \(line.oldOrdinal.map(String.init) ?? "none"), new line \(line.newOrdinal.map(String.init) ?? "none"), \(text.stringValue)\(toolDescription.isEmpty ? "" : ", " + toolDescription)"
    )
  }
  required init?(coder: NSCoder) { fatalError() }
  private func field(_ value: String, alignment: NSTextAlignment) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    field.alignment = alignment
    field.translatesAutoresizingMaskIntoConstraints = false
    addSubview(field)
    field.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    return field
  }
  override func draw(_ dirtyRect: NSRect) {
    EditorMetrics.canvas.setFill()
    bounds.fill()
    let tint: NSColor? = kind == .added ? .systemGreen : kind == .removed ? .systemRed : nil
    tint?.withAlphaComponent(0.12).setFill()
    if tint != nil { bounds.fill() }
    let gutter = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
    EditorMetrics.chrome.setFill()
    gutter.fill()
    tint?.withAlphaComponent(0.07).setFill()
    if tint != nil { gutter.fill() }
    EditorMetrics.separator.setFill()
    NSRect(x: gutterWidth - 1, y: 0, width: 1, height: bounds.height).fill()
  }
}
