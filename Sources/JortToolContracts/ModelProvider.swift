import Foundation

public enum ModelFailure: Error, Equatable, Sendable {
  case disconnected, authentication, offline, timeout, cancelled, malformed, limit, credentialStore,
    authorization
  public var message: String {
    switch self {
    case .disconnected: "Connect with OpenRouter in Models Settings before running this tool."
    case .authentication: "OpenRouter rejected the connection. Check Models Settings."
    case .offline: "Unable to reach OpenRouter. Check your connection."
    case .timeout: "OpenRouter timed out."
    case .cancelled: "Cancelled."
    case .malformed: "OpenRouter returned an unsupported response."
    case .limit: "The model request or response exceeds the tool limit."
    case .credentialStore: "Unable to access the secure connection in Keychain."
    case .authorization: "Authorization could not be completed. Connect again in Models Settings."
    }
  }
}

public struct ModelRequest: Equatable, Sendable {
  public let id: UUID
  public let toolID: String
  public let version: Int
  public let modelID: String
  public let instructions: String
  public let content: String
  public let maximumTokens: Int
  public let maximumBytes: Int
  public let maximumLines: Int
  public init(package: ToolPackage, content: String, id: UUID = UUID()) throws {
    try package.validate()
    guard package.manifest.executorType == .model,
      let model = ModelCatalog.bundled.model(id: package.manifest.modelID ?? "")
    else { throw ModelFailure.malformed }
    guard content.utf8.count <= package.manifest.maximumInputBytes else { throw ModelFailure.limit }
    self.id = id
    toolID = package.manifest.id
    version = package.manifest.version
    modelID = model.id
    instructions = package.instructions
    self.content = content
    maximumTokens = min(model.maximumOutputTokens, package.manifest.maximumOutputBytes)
    maximumBytes = package.manifest.maximumOutputBytes
    maximumLines = package.manifest.maximumOutputLines
  }
  public func validateOutput(_ output: String) throws -> String {
    guard output.utf8.count <= maximumBytes, !output.contains("\0") else {
      throw ModelFailure.limit
    }
    var lines = 1, previousCR = false
    for unit in output.utf16 {
      if unit == 10 && !previousCR || [13, 0x85, 0x2028, 0x2029].contains(unit) { lines += 1 }
      previousCR = unit == 13
      if lines > maximumLines { throw ModelFailure.limit }
    }
    return output
  }
}

public protocol ModelProvider: Sendable {
  func execute(_ request: ModelRequest) async throws -> String
}
