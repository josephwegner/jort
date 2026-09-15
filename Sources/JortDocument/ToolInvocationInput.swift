import Foundation
import JortToolContracts

extension ToolInvocation {
  /// Capture exact canonical input using document-owned anchors. Ephemeral input
  /// is supplied separately and never becomes part of this record.
  public func capturedContent(in snapshot: DocumentSnapshot, prompt: String?) -> String? {
    guard let scope = scope.resolve(in: snapshot.lines),
      let token = token.resolve(in: snapshot.lines),
      token.location >= scope.location, NSMaxRange(token) <= NSMaxRange(scope),
      NSMaxRange(scope) <= snapshot.text.utf16.count
    else { return nil }
    if inputMode.hasPrefix("ephemeral") { return prompt.map(ToolInputNormalization.submitted) }
    let text = snapshot.text as NSString
    if inputMode == "contextual" {
      return ToolInputNormalization.submitted(
        (text.substring(with: scope) as NSString).replacingCharacters(
          in: NSRange(location: token.location - scope.location, length: token.length), with: ""))
    }
    return ToolInputNormalization.submitted(
      text.substring(
        with: NSRange(location: NSMaxRange(token), length: NSMaxRange(scope) - NSMaxRange(token))))
  }
}
