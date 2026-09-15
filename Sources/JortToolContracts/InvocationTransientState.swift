import Foundation

/// Ephemeral input and warnings never enter document persistence or execution results.
public struct InvocationTransientState: Sendable {
  private var prompts: [UUID: String] = [:]
  private var warnings: [UUID: String] = [:]
  private var warningContent: [UUID: String] = [:]
  public init() {}
  public func prompt(for id: UUID) -> String? { prompts[id] }
  public func warning(for id: UUID) -> String? { warnings[id] }
  public mutating func setPrompt(_ text: String?, for id: UUID) {
    guard prompts[id] != nil || prompts.count < 1000 else { return }
    guard let text else {
      prompts.removeValue(forKey: id)
      return
    }
    // The editor displays the original text; an oversized prompt is never submitted.
    guard text.utf8.count <= 1_048_576 else {
      prompts.removeValue(forKey: id)
      setWarning("Enter content within the tool’s input limit.", content: nil, for: id)
      return
    }
    prompts[id] = text
  }
  public mutating func setWarning(_ message: String?, content: String?, for id: UUID) {
    guard warnings[id] != nil || warnings.count < 1000 else { return }
    warnings[id] = message.map { String($0.prefix(512)) }
    warningContent[id] = message == nil ? nil : content
  }
  public mutating func reconcile(_ id: UUID, inputting: Bool, content: String?) {
    if !inputting || content != warningContent[id] { setWarning(nil, content: nil, for: id) }
  }
  public mutating func remove(_ id: UUID) {
    prompts.removeValue(forKey: id)
    setWarning(nil, content: nil, for: id)
  }
}
