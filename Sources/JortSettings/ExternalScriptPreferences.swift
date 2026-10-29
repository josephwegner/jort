import Foundation

/// Local settings only: never part of a tool package or an invocation document.
/// Callers must still enforce submission, phase, and live runtime permission.
public struct ExternalScriptPreferences: Equatable, Sendable {
  public let isAllowed: Bool
  public let pythonInterpreterPath: String?

  public static func permissionKey(for toolID: ToolID) -> String {
    "tool.externalExecution.\(toolID.rawValue)"
  }

  public static func interpreterKey(for toolID: ToolID) -> String {
    "tool.interpreterPath.\(toolID.rawValue)"
  }

  public init(toolID: ToolID, preferences: [String: String]) {
    isAllowed = preferences[Self.permissionKey(for: toolID)] == "true"
    let path = preferences[Self.interpreterKey(for: toolID)]
    // Preserve malformed nonempty values so launch policy fails closed rather
    // than silently falling back to a different interpreter.
    pythonInterpreterPath = path == "" ? nil : path
  }
}

extension SettingsSnapshot {
  public func externalScriptPreferences(for toolID: ToolID) -> ExternalScriptPreferences {
    .init(toolID: toolID, preferences: preferences)
  }
}
