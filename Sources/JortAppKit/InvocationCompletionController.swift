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
    snapshot: DocumentSnapshot, selection: NSRange, packages catalog: [ToolPackage],
    acceptsCompletion: Bool
  ) {
    guard completionArmed, !suppressedCompletion, acceptsCompletion, selection.length == 0 else {
      completion = nil
      return
    }
    let caret = selection.location
    guard caret >= 0, caret <= snapshot.utf16Count else {
      completion = nil
      return
    }
    let start = max(0, caret - 65)
    guard let prefix = try? snapshot.text(in: NSRange(location: start, length: caret - start)),
      let slash = prefix.lastIndex(of: "/")
    else {
      completion = nil
      return
    }
    let offset = start + prefix[..<slash].utf16.count
    guard
      offset == 0
        || (try? snapshot.utf16(in: NSRange(location: offset - 1, length: 1)).first).flatMap({ $0 })
          .flatMap(UnicodeScalar.init).map({
            CharacterSet.whitespacesAndNewlines.contains($0)
          }) == true
    else {
      completion = nil
      return
    }
    guard let query = try? snapshot.text(in: NSRange(location: offset, length: caret - offset))
    else {
      completion = nil
      return
    }
    let packages = catalog.filter { $0.manifest.command.hasPrefix(query) }
    let range = NSRange(location: offset, length: caret - offset)
    let selected = completion?.0 == range ? min(completion?.2 ?? 0, max(0, packages.count - 1)) : 0
    completion = packages.isEmpty ? nil : (range, packages, selected)
  }

}
