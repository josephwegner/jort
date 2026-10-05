import Foundation
import JortToolContracts

extension ToolInvocation {
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
    guard
      let text = try? snapshot.text(
        in: NSRange(
          location: NSMaxRange(token),
          length: NSMaxRange(scope) - NSMaxRange(token)))
    else { return nil }
    return ToolInputNormalization.submitted(text)
  }
}
