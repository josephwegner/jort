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
      input.clock.utf8.count <= 128, input.uuid.utf8.count <= 64,
      input.instruction.map({ $0.utf8.count <= 16_384 && !$0.contains("\0") }) ?? true,
      package.manifest.executorType != .javascript || input.instruction == nil
    else {
      throw ToolFailure(.invalidInput, message: "Enter content within the tool’s input limit.")
    }
    self.identity = identity
    self.package = package
    let definitions = package.manifest.arguments ?? []
    let arguments: [String: ToolArgumentValue]
    if package.manifest.entryContract == 2 {
      if package.manifest.inputMode == .contained, !definitions.isEmpty, input.arguments.isEmpty {
        arguments = try ToolArguments.parse(input.content, definitions: definitions)
      } else {
        arguments = try ToolArguments.validate(input.arguments, definitions: definitions)
      }
    } else {
      arguments = input.arguments
    }
    self.input = input.withArguments(arguments)
    try validateCapturedInput()
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
    let metadata =
      package.manifest.entryContract == 2
      ? try JSONEncoder().encode(CapturedMetadata(input)) : Data()
    return try JavaScriptRequestPayload(
      invocationID: identity.invocationID.uuidString.lowercased(),
      generation: identity.generation.uuidString.lowercased(), contract: manifest, source: source,
      input: content, clock: Data(input.clock.utf8), uuid: Data(input.uuid.utf8),
      metadata: metadata,
      deadlineMilliseconds: deadlineMilliseconds,
      maximumOutputBytes: package.manifest.maximumOutputBytes,
      maximumOutputLines: package.manifest.maximumOutputLines)
  }
  public func bounded(_ result: ToolExecutionResult) -> ToolExecutionResult {
    if let action = result.action {
      guard package.manifest.entryContract == 2, package.manifest.executorType == .javascript,
        package.manifest.hostActions?.contains(action.kind) == true,
        action.isValid, action.content == input.content
      else {
        return .init(
          failure: .init(.malformedResponse, message: "Invalid or undeclared host action."))
      }
    }
    if package.manifest.entryContract == 1
      && (result.report != nil || result.action != nil || result.landmark != nil)
    {
      return .init(failure: .init(.malformedResponse, message: "Unsupported tool result."))
    }
    guard let output = result.output ?? result.report ?? result.action?.content else {
      return result
    }
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
  private func validateCapturedInput() throws {
    let requested = Set(package.manifest.capturedData ?? [])
    guard input.entropy?.count ?? 0 <= 16_384,
      (input.localTime?.isValid ?? true),
      !requested.contains("localTime") || input.localTime != nil,
      !requested.contains("entropy") || input.entropy != nil,
      !requested.contains("analysis") || input.analysis != nil,
      input.localTime == nil || requested.contains("localTime"),
      input.entropy == nil || requested.contains("entropy"),
      input.analysis == nil || requested.contains("analysis")
    else { throw ToolFailure(.invalidInput, message: "Invalid or missing captured tool data.") }
    if let analysis = input.analysis {
      let count = ToolTextAnalysis.logicalLines(input.content).count
      guard analysis.characters == input.content.count,
        analysis.charactersWithoutWhitespace == input.content.filter({ !$0.isWhitespace }).count,
        analysis.words >= 0, analysis.words <= input.content.utf16.count,
        analysis.alphabeticalOrder.count == count,
        Set(analysis.alphabeticalOrder) == Set(0..<count),
        analysis.alphabeticalRanks.count == count,
        analysis.alphabeticalRanks.allSatisfy({ $0 >= 0 && $0 < count }), count <= 100_000
      else { throw ToolFailure(.invalidInput, message: "Invalid text analysis.") }
    }
    guard
      try JSONEncoder().encode(CapturedMetadata(input)).count
        <= JavaScriptRequestPayload.maximumMetadataBytes
    else {
      throw ToolFailure(.invalidInput, message: "Captured tool data exceeds the metadata limit.")
    }
  }
}

private struct CapturedMetadata: Encodable {
  let arguments: [String: ToolArgumentValue]
  let localTime: ToolLocalTime?
  let entropy: [UInt8]?
  let analysis: ToolTextAnalysis?
  init(_ input: ToolExecutionInput) {
    arguments = input.arguments
    localTime = input.localTime
    entropy = input.entropy
    analysis = input.analysis
  }
}

/// Protocol-v1 client payload. Its fields map one-for-one to broker primitive
/// values; do not turn this into a general Codable application request.
public struct JavaScriptRequestPayload: Sendable, Equatable {
  public static let protocolVersion = 2
  public static let maximumContractBytes = 16 * 1024
  public static let maximumSourceBytes = 256 * 1024
  public static let maximumMetadataBytes = 1_048_576
  public static let maximumEnvelopeBytes = 2_621_440
  public let protocolVersion: Int
  public let invocationID: String
  public let generation: String
  public let contract: Data
  public let source: Data
  public let input: Data
  public let clock: Data
  public let uuid: Data
  public let metadata: Data
  public let deadlineMilliseconds: Int
  public let maximumOutputBytes: Int
  public let maximumOutputLines: Int

  public init(
    invocationID: String, generation: String, contract: Data, source: Data, input: Data,
    clock: Data, uuid: Data, metadata: Data = Data(), deadlineMilliseconds: Int,
    maximumOutputBytes: Int,
    maximumOutputLines: Int
  ) throws {
    guard UUID(uuidString: invocationID) != nil, UUID(uuidString: generation) != nil,
      contract.count <= Self.maximumContractBytes, source.count <= Self.maximumSourceBytes,
      clock.count <= 128, uuid.count <= 64, input.count <= 1_048_576,
      metadata.count + clock.count + uuid.count <= Self.maximumMetadataBytes,
      (1...30_000).contains(deadlineMilliseconds), (1...1_048_576).contains(maximumOutputBytes),
      (1...100_000).contains(maximumOutputLines),
      contract.count.addingReportingOverflow(source.count).overflow == false,
      contract.count + source.count <= Self.maximumEnvelopeBytes,
      128 + contract.count + source.count + input.count + clock.count + uuid.count + metadata.count
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
    self.metadata = metadata
    self.deadlineMilliseconds = deadlineMilliseconds
    self.maximumOutputBytes = maximumOutputBytes
    self.maximumOutputLines = maximumOutputLines
  }
}
