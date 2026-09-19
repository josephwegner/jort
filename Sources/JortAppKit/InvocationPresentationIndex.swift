import Foundation
import JortDocument

/// Rebuilt for a committed document projection; viewport queries use interval
/// bounds so scrolling never measures every invocation in the document.
struct InvocationPresentationIndex {
  private struct Entry {
    let invocation: ToolInvocation
    let range: NSRange
    let prefixEnd: Int
  }
  private var entries: [Entry] = []
  private var revision: Int64 = -1
  mutating func update(_ snapshot: DocumentSnapshot) {
    guard revision != snapshot.revision else { return }
    revision = snapshot.revision
    let ranges = snapshot.invocations.compactMap { invocation -> (ToolInvocation, NSRange)? in
      guard let scope = invocation.scope.resolve(in: snapshot.lines),
        let token = invocation.token.resolve(in: snapshot.lines)
      else { return nil }
      return (
        invocation,
        NSUnionRange(
          NSUnionRange(scope, token), invocation.output?.resolve(in: snapshot.lines) ?? scope)
      )
    }.sorted { $0.1.location < $1.1.location }
    var end = 0
    entries = ranges.map { invocation, range in
      end = max(end, NSMaxRange(range))
      return Entry(invocation: invocation, range: range, prefixEnd: end)
    }
  }
  func visible(in range: NSRange) -> [ToolInvocation] {
    var low = 0, high = entries.count
    while low < high {
      let middle = (low + high) / 2
      if entries[middle].prefixEnd < range.location { low = middle + 1 } else { high = middle }
    }
    var result: [ToolInvocation] = []
    for entry in entries.dropFirst(low) {
      if entry.range.location > NSMaxRange(range) { break }
      if NSMaxRange(entry.range) >= range.location { result.append(entry.invocation) }
    }
    return result
  }
}
