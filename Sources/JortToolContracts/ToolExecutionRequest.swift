import Foundation

public enum ToolFailureCode: String, Codable, Sendable {
  case invalidPackage, invalidInput, unavailable, implementation, cancelled, timeout, outputLimit
  case authentication, offline, malformedResponse, credentialStore, authorization
  case busy, peerIdentity, launch, sandboxBootstrap, cpuLimit, engineLimit, crash, protocolError,
    internalError
}

public struct ToolFailure: Error, Equatable, Sendable {
  public let code: ToolFailureCode
  public let message: String
  public init(_ code: ToolFailureCode, message: String) {
    self.code = code
    self.message = UTF8Bounds.prefix(message, maximumBytes: 512)
  }
}

/// Byte bounds in the JavaScript protocol are UTF-8 bounds, never grapheme counts.
public enum UTF8Bounds {
  public static func prefix(_ value: String, maximumBytes: Int) -> String {
    guard maximumBytes > 0 else { return "" }
    guard value.utf8.count > maximumBytes else { return value }
    var end = value.startIndex
    var used = 0
    while end < value.endIndex {
      let next = value.index(after: end)
      let count = value[end..<next].utf8.count
      guard used + count <= maximumBytes else { break }
      used += count
      end = next
    }
    return String(value[..<end])
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
      input.clock.utf8.count <= 128, input.uuid.utf8.count <= 64
    else {
      throw ToolFailure(.invalidInput, message: "Enter content within the tool’s input limit.")
    }
    self.identity = identity
    self.package = package
    self.input = input
  }

  /// Compile-only package validation has no invocation input. In particular,
  /// contextual tools must be authorable before any document context exists.
  public init(
    validationOf package: ToolPackage,
    identity: InvocationGeneration = .init(invocationID: UUID(), generation: UUID())
  ) throws {
    try package.validate()
    self.identity = identity
    self.package = package
    self.input = .init(content: "")
  }

  /// A deliberately primitive, normalized request payload. The broker receives no
  /// application object graph, path, credential, callback, or mutable reference.
  public func javascriptPayload(deadlineMilliseconds: Int) throws -> JavaScriptRequestPayload {
    guard package.manifest.executorType == .javascript else {
      throw ToolFailure(.invalidPackage, message: "Invalid JavaScript tool package.")
    }
    guard (1...30_000).contains(deadlineMilliseconds) else {
      throw ToolFailure(.invalidInput, message: "Invalid execution deadline.")
    }
    let manifest = try JSONEncoder().encode(package.manifest)
    let source = Data(package.source.utf8)
    let content = Data(input.content.utf8)
    return try JavaScriptRequestPayload(
      invocationID: identity.invocationID.uuidString.lowercased(),
      generation: identity.generation.uuidString.lowercased(), contract: manifest, source: source,
      input: content, clock: Data(input.clock.utf8), uuid: Data(input.uuid.utf8),
      deadlineMilliseconds: deadlineMilliseconds,
      maximumOutputBytes: package.manifest.maximumOutputBytes,
      maximumOutputLines: package.manifest.maximumOutputLines)
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

/// Protocol-v1 client payload. Its fields map one-for-one to broker primitive
/// values; do not turn this into a general Codable application request.
public struct JavaScriptRequestPayload: Sendable, Equatable {
  public static let protocolVersion = 1
  public static let maximumContractBytes = 16 * 1024
  public static let maximumSourceBytes = 256 * 1024
  public static let maximumMetadataBytes = 4 * 1024
  public static let maximumEnvelopeBytes = 1_572_864
  public let protocolVersion: Int
  public let invocationID: String
  public let generation: String
  public let contract: Data
  public let source: Data
  public let input: Data
  public let clock: Data
  public let uuid: Data
  public let deadlineMilliseconds: Int
  public let maximumOutputBytes: Int
  public let maximumOutputLines: Int

  public init(
    invocationID: String, generation: String, contract: Data, source: Data, input: Data,
    clock: Data, uuid: Data, deadlineMilliseconds: Int, maximumOutputBytes: Int,
    maximumOutputLines: Int
  ) throws {
    guard UUID(uuidString: invocationID) != nil, UUID(uuidString: generation) != nil,
      contract.count <= Self.maximumContractBytes, source.count <= Self.maximumSourceBytes,
      clock.count <= 128, uuid.count <= 64, input.count <= 1_048_576,
      (1...30_000).contains(deadlineMilliseconds), (1...1_048_576).contains(maximumOutputBytes),
      (1...100_000).contains(maximumOutputLines),
      contract.count.addingReportingOverflow(source.count).overflow == false,
      contract.count + source.count <= Self.maximumEnvelopeBytes,
      contract.count + source.count + input.count + clock.count + uuid.count
        <= Self.maximumEnvelopeBytes
    else { throw ToolFailure(.protocolError, message: "Invalid JavaScript request.") }
    self.protocolVersion = Self.protocolVersion
    self.invocationID = invocationID
    self.generation = generation
    self.contract = contract
    self.source = source
    self.input = input
    self.clock = clock
    self.uuid = uuid
    self.deadlineMilliseconds = deadlineMilliseconds
    self.maximumOutputBytes = maximumOutputBytes
    self.maximumOutputLines = maximumOutputLines
  }
}
