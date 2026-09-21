import AppKit
import JortDocument

/// Presentation-only attributes; never submits a document transaction.
@MainActor final class InvocationStyleReconciler {
  private var styled: [NSRange] = []
  private let decorationAttribute = NSAttributedString.Key("JortToolDecoration")
  private var styledRevision: Int64 = -1
  private var styledViewport: NSRange?
  var hasStyles: Bool { !styled.isEmpty }
  func invalidate() { styledRevision = -1 }
  func clearChanged(
    before: DocumentSnapshot, after: DocumentSnapshot, storage: NSTextStorage,
    paragraphStyle: NSParagraphStyle?, documentFont: NSFont
  ) {
    let remaining = Dictionary(uniqueKeysWithValues: after.invocations.map { ($0.id, $0) })
    for invocation in before.invocations where remaining[invocation.id] != invocation {
      guard let scope = invocation.scope.resolve(in: before) else { continue }
      let range = NSUnionRange(scope, invocation.output?.resolve(in: before) ?? scope)
      guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
      storage.removeAttribute(.kern, range: range)
      storage.removeAttribute(.paragraphStyle, range: range)
      storage.removeAttribute(decorationAttribute, range: range)
      if let paragraphStyle {
        storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
      }
      storage.addAttribute(.font, value: documentFont, range: range)
    }
    invalidate()
  }
  func reconcile(
    snapshot: DocumentSnapshot, storage: NSTextStorage,
    visibleRange: NSRange, invocations: [ToolInvocation],
    paragraphStyle: NSParagraphStyle?, documentFont: NSFont, hasMarkedText: Bool
  ) -> Bool {
    guard !hasMarkedText else { return false }
    if styledRevision != snapshot.revision || styledViewport != visibleRange {
      // Attribute runs move with native edits; cached numeric ranges do not.
      var oldRuns: [NSRange] = []
      storage.enumerateAttribute(
        decorationAttribute,
        in: NSIntersectionRange(visibleRange, NSRange(location: 0, length: storage.length))
      ) { value, range, _ in
        if value != nil { oldRuns.append(range) }
      }
      storage.beginEditing()
      for range in oldRuns {
        storage.removeAttribute(.kern, range: range)
        storage.removeAttribute(.paragraphStyle, range: range)
        if let paragraph = paragraphStyle {
          storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        storage.addAttribute(.font, value: documentFont, range: range)
        storage.removeAttribute(decorationAttribute, range: range)
      }
      styled = []
      for invocation in invocations {
        guard let token = invocation.token.resolve(in: snapshot),
          let scope = invocation.scope.resolve(in: snapshot)
        else { continue }
        storage.addAttribute(
          .font, value: NSFontManager.shared.convert(documentFont, toHaveTrait: .boldFontMask),
          range: token)
        storage.addAttribute(decorationAttribute, value: true, range: token)
        styled.append(token)
        if invocation.inputMode.hasPrefix("ephemeral"), invocation.phase == .inputting { continue }
        let output = invocation.output?.resolve(in: snapshot)
        let leading = output.map { leadingActions($0, snapshot: snapshot) } ?? false
        let controlOffset =
          output.map { leading ? $0.location : NSMaxRange($0) }
          ?? NSMaxRange(invocation.inputMode == "contextual" ? token : scope)
        if let output, output.location < storage.length,
          leadingIndent(output, snapshot: snapshot)
            || output.length == 0 && startsLine(output, snapshot: snapshot)
        {
          let padding = storage.mutableString.rangeOfComposedCharacterSequence(
            at: output.location)
          let paragraph =
            (paragraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
          paragraph.firstLineHeadIndent += output.length == 0 ? 78 : 54
          storage.addAttribute(.paragraphStyle, value: paragraph, range: padding)
          storage.addAttribute(decorationAttribute, value: true, range: padding)
          styled.append(padding)
        } else if controlOffset > 0 && controlOffset <= storage.length {
          let padding = storage.mutableString.rangeOfComposedCharacterSequence(
            at: controlOffset - 1)
          storage.addAttribute(.kern, value: output?.length == 0 ? 78 : 54, range: padding)
          styled.append(padding)
          storage.addAttribute(decorationAttribute, value: true, range: padding)
          if endsLine(controlOffset, snapshot: snapshot),
            !startsLine(NSRange(location: controlOffset, length: 0), snapshot: snapshot)
          {
            // TextKit omits trailing kern at a paragraph's end. Keep
            // room for the accessory even at a narrow viewport edge.
            let paragraph =
              (paragraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
              ?? NSMutableParagraphStyle()
            paragraph.tailIndent -= output?.length == 0 ? 82 : 64
            storage.addAttribute(.paragraphStyle, value: paragraph, range: padding)
          }
        }
      }
      storage.endEditing()
      styledRevision = snapshot.revision
      styledViewport = visibleRange
      return true
    }
    return false
  }
  private func leadingActions(_ output: NSRange, snapshot: DocumentSnapshot) -> Bool {
    // Long results keep their actions at the source/output seam rather than
    // requiring a scroll to the end. Short inline results retain trailing actions.
    output.length > 40 || (try? snapshot.text(in: output).contains("\n")) == true
  }
  private func leadingIndent(_ output: NSRange, snapshot: DocumentSnapshot) -> Bool {
    output.length > 0 && leadingActions(output, snapshot: snapshot)
      && startsLine(output, snapshot: snapshot)
  }
  private func startsLine(_ output: NSRange, snapshot: DocumentSnapshot) -> Bool {
    guard output.location > 0,
      let unit = try? snapshot.utf16(in: NSRange(location: output.location - 1, length: 1)).first
    else { return false }
    return [10, 13, 0x85, 0x2028, 0x2029].contains(unit)
  }
  private func endsLine(_ offset: Int, snapshot: DocumentSnapshot) -> Bool {
    if offset == snapshot.utf16Count { return true }
    guard let unit = try? snapshot.utf16(in: NSRange(location: offset, length: 1)).first else {
      return false
    }
    return [10, 13, 0x85, 0x2028, 0x2029].contains(unit)
  }
}
