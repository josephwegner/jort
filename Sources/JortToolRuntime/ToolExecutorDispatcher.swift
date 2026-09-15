import Foundation
import JortToolContracts

public struct ToolExecutorDispatcher: ToolExecuting {
  public var modelAvailable: @Sendable () async -> Bool
  public var provider: @Sendable () -> any ModelProvider
  public var authenticationFailed: @Sendable () async -> Void
  public init(
    modelAvailable: @escaping @Sendable () async -> Bool = { false },
    provider: (@Sendable () -> any ModelProvider)? = nil,
    authenticationFailed: @escaping @Sendable () async -> Void = {}
  ) {
    self.modelAvailable = modelAvailable
    self.provider = provider ?? { UnavailableModelProvider() }
    self.authenticationFailed = authenticationFailed
  }
  public func validate(_ package: ToolPackage, input: ToolExecutionInput) async
    -> ToolExecutionResult
  {
    if package.manifest.executorType == .javascript {
      return await ToolRuntime.execute(package, input: input, validationOnly: true)
    }
    do { _ = try ModelRequest(package: package, content: input.content) } catch {
      return .init(error: "Check this tool’s instructions and selected model in Tools Settings.")
    }
    guard await modelAvailable() else {
      return .init(failure: ModelFailure.disconnected.toolFailure)
    }
    return .init(output: "")
  }
  public func execute(_ package: ToolPackage, input: ToolExecutionInput) async
    -> ToolExecutionResult
  {
    if package.manifest.executorType == .javascript {
      return await ToolRuntime.execute(package, input: input)
    }
    do {
      try Task.checkCancellation()
      let request = try ModelRequest(package: package, content: input.content)
      let output = try await provider().execute(request)
      try Task.checkCancellation()
      return .init(output: try request.validateOutput(output))
    } catch let failure as ModelFailure {
      if failure == .authentication { await authenticationFailed() }
      return .init(failure: failure.toolFailure)
    } catch is CancellationError { return .init(failure: ModelFailure.cancelled.toolFailure) } catch
    {
      return .init(failure: ModelFailure.malformed.toolFailure)
    }
  }
}

private struct UnavailableModelProvider: ModelProvider {
  func execute(_ request: ModelRequest) async throws -> String { throw ModelFailure.disconnected }
}

extension ModelFailure {
  var toolFailure: ToolFailure {
    let code: ToolFailureCode
    switch self {
    case .disconnected: code = .unavailable
    case .authentication: code = .authentication
    case .offline: code = .offline
    case .timeout: code = .timeout
    case .cancelled: code = .cancelled
    case .malformed: code = .malformedResponse
    case .limit: code = .outputLimit
    case .credentialStore: code = .credentialStore
    case .authorization: code = .authorization
    }
    return .init(code, message: message)
  }
}
