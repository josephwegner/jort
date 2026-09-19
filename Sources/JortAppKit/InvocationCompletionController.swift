import JortToolContracts
import AppKit
import JortDocument
import JortSettings

/// Keyboard completion state is synchronous; its native rows mount next turn.
@MainActor final class InvocationCompletionController {
  var completion: (NSRange, [ToolPackage], Int)?
  var suppressedCompletion = false
  var completionArmed = false
  func update(
    text value: String, selection: NSRange, packages catalog: [ToolPackage], acceptsCompletion: Bool
  ) {
    guard completionArmed, !suppressedCompletion, acceptsCompletion, selection.length == 0 else {
      completion = nil
      return
    }
    let text = value as NSString, caret = selection.location
    guard caret <= text.length else {
      completion = nil
      return
    }
    let start = max(0, caret - 65)
    let prefix = text.substring(with: NSRange(location: start, length: caret - start))
    guard let slash = prefix.lastIndex(of: "/") else {
      completion = nil
      return
    }
    let offset = start + prefix[..<slash].utf16.count
    guard
      offset == 0
        || UnicodeScalar(text.character(at: offset - 1)).map({
          CharacterSet.whitespacesAndNewlines.contains($0)
        }) == true
    else {
      completion = nil
      return
    }
    let query = text.substring(with: NSRange(location: offset, length: caret - offset))
    let packages = catalog.filter { $0.manifest.command.hasPrefix(query) }
    let range = NSRange(location: offset, length: caret - offset)
    let selected = completion?.0 == range ? min(completion?.2 ?? 0, max(0, packages.count - 1)) : 0
    completion = packages.isEmpty ? nil : (range, packages, selected)
  }

}
