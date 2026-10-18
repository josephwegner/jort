import Foundation
import JortToolContracts

extension ToolInvocation {
  /// Context fragments in document order. The scope remains the lock/hash envelope.
  public func contextRanges(in snapshot: DocumentSnapshot) -> [NSRange] {
    guard inputMode == "contextual", let scope = scope.resolve(in: snapshot),
      NSMaxRange(scope) <= snapshot.utf16Count
    else { return [] }
    if let call {
      guard let range = call.resolve(in: snapshot), range.location >= scope.location,
        NSMaxRange(range) <= NSMaxRange(scope)
      else { return [] }
    }
    var ranges = scope.length > 0 ? [scope] : []
    for anchor in [call, output].compactMap({ $0 }) {
      guard let excluded = anchor.resolve(in: snapshot), NSMaxRange(excluded) <= snapshot.utf16Count
      else { return [] }
      ranges = ranges.flatMap { range -> [NSRange] in
        let intersection = NSIntersectionRange(range, excluded)
        guard intersection.length > 0 else { return [range] }
        return [
          NSRange(location: range.location, length: intersection.location - range.location),
          NSRange(
            location: NSMaxRange(intersection), length: NSMaxRange(range) - NSMaxRange(intersection)
          ),
        ].filter { $0.length > 0 }
      }
    }
    return ranges
  }

  public func inlineInput(in snapshot: DocumentSnapshot) -> String? {
    guard !inputMode.hasPrefix("ephemeral"), let call = call?.resolve(in: snapshot),
      let token = token.resolve(in: snapshot), call.location == token.location,
      NSMaxRange(call) >= NSMaxRange(token), NSMaxRange(call) <= snapshot.utf16Count,
      let text = try? snapshot.text(
        in: NSRange(
          location: NSMaxRange(token), length: NSMaxRange(call) - NSMaxRange(token)))
    else { return nil }
    return ToolInputNormalization.submitted(text)
  }

  /// Capture exact canonical input using document-owned anchors. Ephemeral input
  /// is supplied separately and never becomes part of this record.
  public func capturedContent(in snapshot: DocumentSnapshot, prompt: String?) -> String? {
    guard let scope = scope.resolve(in: snapshot),
      let token = token.resolve(in: snapshot),
      token.location >= scope.location, NSMaxRange(token) <= NSMaxRange(scope),
      NSMaxRange(scope) <= snapshot.utf16Count
    else { return nil }
    if inputMode.hasPrefix("ephemeral") { return prompt.map(ToolInputNormalization.submitted) }
    if inputMode == "contextual" {
      guard let text = try? snapshot.text(in: scope) else { return nil }
      if let call {
        guard let excluded = call.resolve(in: snapshot), excluded.location == token.location,
          NSMaxRange(excluded) >= NSMaxRange(token), NSMaxRange(excluded) <= NSMaxRange(scope)
        else { return nil }
        guard let fragments = try? contextRanges(in: snapshot).map({ try snapshot.text(in: $0) })
        else { return nil }
        let content = fragments.joined()
        return entryContract == 2 ? content : ToolInputNormalization.submitted(content)
      }
      if entryContract == 2 {
        var excluded = token
        if let separator = acceptanceSeparator?.resolve(in: snapshot),
          separator.location == NSMaxRange(token), NSMaxRange(separator) <= NSMaxRange(scope),
          separator.length == 1, (try? snapshot.text(in: separator)) == " "
        {
          excluded.length += 1
        }
        return (text as NSString).replacingCharacters(
          in: NSRange(location: excluded.location - scope.location, length: excluded.length),
          with: "")
      }
      return ToolInputNormalization.submitted(
        (text as NSString).replacingCharacters(
          in: NSRange(location: token.location - scope.location, length: token.length), with: ""))
    }
    let end = call?.resolve(in: snapshot).map(NSMaxRange) ?? NSMaxRange(scope)
    guard end >= NSMaxRange(token), end <= NSMaxRange(scope),
      let text = try? snapshot.text(
        in: NSRange(
          location: NSMaxRange(token),
          length: end - NSMaxRange(token)))
    else { return nil }
    return ToolInputNormalization.submitted(text)
  }
}
