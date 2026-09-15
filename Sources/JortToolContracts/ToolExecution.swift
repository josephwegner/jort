import Foundation

public struct ToolExecutionInput: Codable, Sendable {
  public let content: String
  public let clock: String
  public let uuid: String
  public let cancelled = false
  public init(content: String, date: Date = Date(), uuid: UUID = UUID()) {
    self.content = content
    self.clock = ISO8601DateFormatter().string(from: date)
    self.uuid = uuid.uuidString.lowercased()
  }
}

public struct ToolExecutionResult: Codable, Equatable, Sendable {
  private enum Value: Equatable, Sendable { case output(String), failure(ToolFailure) }
  private let value: Value
  public var output: String? { if case .output(let text) = value { text } else { nil } }
  public var failure: ToolFailure? { if case .failure(let error) = value { error } else { nil } }
  public var error: String? { failure?.message }
  public init(failure: ToolFailure) { value = .failure(failure) }
  public init(output: String? = nil, error: String? = nil) {
    if let output, error == nil, output.utf8.count <= 1_048_576 {
      value = .output(output)
    } else if let error, output == nil {
      value = .failure(.init(.implementation, message: error))
    } else {
      value = .failure(.init(.malformedResponse, message: "Invalid tool result."))
    }
  }
  private enum CodingKeys: String, CodingKey { case output, error }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let output = try container.decodeIfPresent(String.self, forKey: .output)
    let error = try container.decodeIfPresent(String.self, forKey: .error)
    guard (output == nil) != (error == nil) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Expected exactly one result."))
    }
    self.init(output: output, error: error)
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(output, forKey: .output)
    try container.encodeIfPresent(error, forKey: .error)
  }
}

public protocol ToolPackageValidator: Sendable {
  func validatePackage(_ package: ToolPackage) async throws
}

public protocol ToolExecuting: Sendable {
  func validate(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult
  func execute(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult
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
