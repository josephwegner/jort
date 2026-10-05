import Foundation

public struct ToolExecutionInput: Codable, Sendable {
  public let content: String
  public let clock: String
  public let uuid: String
  public let arguments: [String: ToolArgumentValue]
  public let localTime: ToolLocalTime?
  public let entropy: [UInt8]?
  public let analysis: ToolTextAnalysis?
  public let cancelled = false
  public init(
    content: String, date: Date = Date(), uuid: UUID = UUID(),
    arguments: [String: ToolArgumentValue] = [:], localTime: ToolLocalTime? = nil,
    entropy: [UInt8]? = nil, analysis: ToolTextAnalysis? = nil
  ) {
    self.content = content
    self.clock = ISO8601DateFormatter().string(from: date)
    self.uuid = uuid.uuidString.lowercased()
    self.arguments = arguments
    self.localTime = localTime
    self.entropy = entropy
    self.analysis = analysis
  }
  private init(
    content: String, clock: String, uuid: String,
    arguments: [String: ToolArgumentValue], localTime: ToolLocalTime?, entropy: [UInt8]?,
    analysis: ToolTextAnalysis?
  ) {
    self.content = content
    self.clock = clock
    self.uuid = uuid
    self.arguments = arguments
    self.localTime = localTime
    self.entropy = entropy
    self.analysis = analysis
  }
  public func withArguments(_ arguments: [String: ToolArgumentValue]) -> Self {
    .init(
      content: content, clock: clock, uuid: uuid, arguments: arguments,
      localTime: localTime, entropy: entropy, analysis: analysis)
  }
}

public struct ToolExecutionResult: Codable, Equatable, Sendable {
  private enum Value: Equatable, Sendable {
    case output(String), report(String), action(ToolHostAction), failure(ToolFailure)
  }
  private let value: Value
  public let landmark: ToolOutputLandmark?
  public var output: String? { if case .output(let text) = value { text } else { nil } }
  public var failure: ToolFailure? { if case .failure(let error) = value { error } else { nil } }
  public var error: String? { failure?.message }
  public var report: String? { if case .report(let text) = value { text } else { nil } }
  public var action: ToolHostAction? { if case .action(let action) = value { action } else { nil } }
  public init(failure: ToolFailure) {
    value = .failure(failure)
    landmark = nil
  }
  public init(report: String) {
    landmark = nil
    value =
      report.utf8.count <= 1_048_576 && !report.contains("\0")
      ? .report(report)
      : .failure(.init(.malformedResponse, message: "Invalid tool report."))
  }
  public init(action: ToolHostAction) {
    landmark = nil
    value =
      action.isValid
      ? .action(action)
      : .failure(.init(.malformedResponse, message: "Invalid tool action."))
  }
  public init(output: String? = nil, error: String? = nil, landmark: ToolOutputLandmark? = nil) {
    self.landmark =
      output != nil && error == nil && output!.utf8.count <= 1_048_576
        && !output!.contains("\0")
        && (landmark.map({ $0.isValid && $0.line < ToolTextAnalysis.logicalLines(output!).count })
          ?? true)
      ? landmark : nil
    if let output, error == nil, output.utf8.count <= 1_048_576 {
      if !output.contains("\0"),
        landmark.map({ $0.isValid && $0.line < ToolTextAnalysis.logicalLines(output).count })
          ?? true
      {
        value = .output(output)
      } else {
        value = .failure(.init(.malformedResponse, message: "Invalid tool landmark or output."))
      }
    } else if let error, output == nil {
      value = .failure(.init(.implementation, message: error))
    } else {
      value = .failure(.init(.malformedResponse, message: "Invalid tool result."))
    }
  }
  private enum CodingKeys: String, CodingKey { case output, error, report, action, landmark }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let output = try container.decodeIfPresent(String.self, forKey: .output)
    let error = try container.decodeIfPresent(String.self, forKey: .error)
    let report = try container.decodeIfPresent(String.self, forKey: .report)
    let action = try container.decodeIfPresent(ToolHostAction.self, forKey: .action)
    let landmark = try container.decodeIfPresent(ToolOutputLandmark.self, forKey: .landmark)
    let keys = try decoder.container(keyedBy: ResultKey.self).allKeys.map(\.stringValue)
    guard Set(keys).isSubset(of: Set(["output", "error", "report", "action", "landmark"])),
      [output != nil, error != nil, report != nil, action != nil].filter({ $0 }).count == 1,
      landmark == nil || output != nil
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Expected exactly one result."))
    }
    if let report {
      self.init(report: report)
    } else if let action {
      self.init(action: action)
    } else {
      self.init(output: output, error: error, landmark: landmark)
    }
    if failure?.code == .malformedResponse {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid result payload."))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(output, forKey: .output)
    try container.encodeIfPresent(error, forKey: .error)
    try container.encodeIfPresent(report, forKey: .report)
    try container.encodeIfPresent(action, forKey: .action)
    try container.encodeIfPresent(landmark, forKey: .landmark)
  }
}

private struct ResultKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

public protocol ToolPackageValidator: Sendable {
  func validatePackage(_ package: ToolPackage) async throws
}

public protocol ToolExecuting: Sendable {
  func validate(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult
  func execute(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult
}

/// Executors that cross a process boundary receive the immutable generation as
/// part of the request, rather than reconstructing identity at dispatch time.
public protocol GenerationAwareToolExecuting: ToolExecuting {
  func validate(_ request: ToolExecutionRequest) async -> ToolExecutionResult
  func execute(_ request: ToolExecutionRequest) async -> ToolExecutionResult
}

public struct UnavailableToolValidator: ToolPackageValidator {
  public init() {}
  public func validatePackage(_ package: ToolPackage) async throws {
    throw ToolPackageError.unavailable
  }
}

public struct UnavailableToolExecutor: ToolExecuting {
  public init() {}
  public func validate(_ package: ToolPackage, input: ToolExecutionInput) async
    -> ToolExecutionResult
  {
    .init(error: "Tool execution is unavailable.")
  }
  public func execute(_ package: ToolPackage, input: ToolExecutionInput) async
    -> ToolExecutionResult
  {
    .init(error: "Tool execution is unavailable.")
  }
}

@MainActor public protocol ToolInvocationCoordinating: AnyObject {
  var transient: InvocationTransientState { get set }
  func hasJob(_ id: UUID) -> Bool
  func remove(_ id: UUID)
  func submit(
    identity: InvocationGeneration, package: ToolPackage, input: ToolExecutionInput,
    apply: @escaping @MainActor (InvocationDocumentEffect) -> Bool,
    warning: @escaping @MainActor (String) -> Void)
}

@MainActor public final class UnavailableInvocationCoordinator: ToolInvocationCoordinating {
  public var transient = InvocationTransientState()
  public init() {}
  public func hasJob(_ id: UUID) -> Bool { false }
  public func remove(_ id: UUID) {}
  public func submit(
    identity: InvocationGeneration, package: ToolPackage, input: ToolExecutionInput,
    apply: @escaping @MainActor (InvocationDocumentEffect) -> Bool,
    warning: @escaping @MainActor (String) -> Void
  ) { warning("Tool execution is unavailable.") }
}
