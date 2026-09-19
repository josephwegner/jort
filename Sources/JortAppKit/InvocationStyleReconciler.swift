import AppKit
import JortDocument

/// Presentation-only attributes; never submits a document transaction.
@MainActor final class InvocationStyleReconciler {
  private var styled: [NSRange] = []
  private let decorationAttribute = NSAttributedString.Key("JortToolDecoration")
  private var styledRevision: Int64 = -1
  var hasStyles: Bool { !styled.isEmpty }
  func invalidate() { styledRevision = -1 }
  func reconcile(
    snapshot: DocumentSnapshot, storage: NSTextStorage,
    paragraphStyle: NSParagraphStyle?, documentFont: NSFont, hasMarkedText: Bool
  ) -> Bool {
    guard !hasMarkedText else { return false }
    if styledRevision != snapshot.revision {
      // Attribute runs move with native edits; cached numeric ranges do not.
      var oldRuns: [NSRange] = []
      storage.enumerateAttribute(
        decorationAttribute, in: NSRange(location: 0, length: storage.length)
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
      for invocation in snapshot.invocations {
        guard let token = invocation.token.resolve(in: snapshot.lines),
          let scope = invocation.scope.resolve(in: snapshot.lines)
        else { continue }
        storage.addAttribute(
          .font, value: NSFontManager.shared.convert(documentFont, toHaveTrait: .boldFontMask),
          range: token)
        storage.addAttribute(decorationAttribute, value: true, range: token)
        styled.append(token)
        if invocation.inputMode.hasPrefix("ephemeral"), invocation.phase == .inputting { continue }
        let output = invocation.output?.resolve(in: snapshot.lines)
        let leading = output.map { leadingActions($0, text: snapshot.text) } ?? false
        let controlOffset =
          output.map { leading ? $0.location : NSMaxRange($0) }
          ?? NSMaxRange(invocation.inputMode == "contextual" ? token : scope)
        if let output, output.location < storage.length,
          leadingIndent(output, text: snapshot.text)
            || output.length == 0 && startsLine(output, text: snapshot.text)
        {
          let padding = (snapshot.text as NSString).rangeOfComposedCharacterSequence(
            at: output.location)
          let paragraph =
            (paragraphStyle?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
          paragraph.firstLineHeadIndent += output.length == 0 ? 78 : 54
          storage.addAttribute(.paragraphStyle, value: paragraph, range: padding)
          storage.addAttribute(decorationAttribute, value: true, range: padding)
          styled.append(padding)
        } else if controlOffset > 0 && controlOffset <= storage.length {
          let padding = (snapshot.text as NSString).rangeOfComposedCharacterSequence(
            at: controlOffset - 1)
          storage.addAttribute(.kern, value: output?.length == 0 ? 78 : 54, range: padding)
          styled.append(padding)
          storage.addAttribute(decorationAttribute, value: true, range: padding)
          if endsLine(controlOffset, text: snapshot.text),
            !startsLine(NSRange(location: controlOffset, length: 0), text: snapshot.text)
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
      return true
    }
    return false
  }
  private func leadingActions(_ output: NSRange, text: String) -> Bool {
    // Long results keep their actions at the source/output seam rather than
    // requiring a scroll to the end. Short inline results retain trailing actions.
    output.length > 40 || (text as NSString).substring(with: output).contains("\n")
  }
  private func leadingIndent(_ output: NSRange, text: String) -> Bool {
    output.length > 0 && leadingActions(output, text: text) && startsLine(output, text: text)
  }
  private func startsLine(_ output: NSRange, text: String) -> Bool {
    output.location > 0
      && [10, 13, 0x85, 0x2028, 0x2029].contains(
        (text as NSString).character(at: output.location - 1))
  }
  private func endsLine(_ offset: Int, text: String) -> Bool {
    let text = text as NSString
    return offset == text.length
      || offset < text.length
        && [10, 13, 0x85, 0x2028, 0x2029].contains(text.character(at: offset))
  }
}
