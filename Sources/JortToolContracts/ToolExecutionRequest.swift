import Foundation

public enum ToolFailureCode: String, Codable, Sendable {
  case invalidPackage, invalidInput, unavailable, implementation, cancelled, timeout, outputLimit
  case authentication, offline, malformedResponse, credentialStore, authorization
}

public struct ToolFailure: Error, Equatable, Sendable {
  public let code: ToolFailureCode
  public let message: String
  public init(_ code: ToolFailureCode, message: String) {
    self.code = code
    self.message = String(message.prefix(512))
  }
}

/// The only captured execution descriptor. No paths, stores, transports or credentials.
public struct ToolExecutionRequest: Sendable {
  public let identity: InvocationGeneration
  public let package: ToolPackage
  public let input: ToolExecutionInput
  public init(identity: InvocationGeneration, package: ToolPackage, input: ToolExecutionInput)
    throws
  {
    try package.validate()
    guard input.content.utf8.count <= package.manifest.maximumInputBytes,
      input.clock.utf8.count <= 128, input.uuid.utf8.count <= 64,
      package.manifest.inputMode != .contextual || !input.content.isEmpty
    else {
      throw ToolFailure(.invalidInput, message: "Enter content within the tool’s input limit.")
    }
    self.identity = identity
    self.package = package
    self.input = input
  }
  public func bounded(_ result: ToolExecutionResult) -> ToolExecutionResult {
    guard let output = result.output else { return result }
    let limits = package.manifest
    var lines = 1, previousCR = false
    guard output.utf8.count <= limits.maximumOutputBytes else {
      return .init(failure: .init(.outputLimit, message: "Output exceeds the tool limit."))
    }
    for unit in output.utf16 {
      if unit == 10 && !previousCR || [13, 0x85, 0x2028, 0x2029].contains(unit) { lines += 1 }
      previousCR = unit == 13
      if lines > limits.maximumOutputLines {
        return .init(failure: .init(.outputLimit, message: "Output exceeds the tool limit."))
      }
    }
    return result
  }
}
