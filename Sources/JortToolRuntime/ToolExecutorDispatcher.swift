import Foundation
import JortToolContracts

public struct ToolExecutorDispatcher: GenerationAwareToolExecuting {
  /// Capture once before validation, so execution observes the same immutable services.
  public static func prepareInput(_ input: ToolExecutionInput, for manifest: ToolManifest) throws
    -> ToolExecutionInput
  {
    guard manifest.executorType != .javascript || input.instruction == nil else {
      throw ToolFailure(
        .invalidInput, message: "JavaScript tools do not accept an inline instruction.")
    }
    guard manifest.entryContract == 2 else { return input }
    guard let date = ISO8601DateFormatter().date(from: input.clock) else {
      throw ToolFailure(.invalidInput, message: "Invalid captured submission time.")
    }
    let requested = manifest.capturedData ?? []
    let localTime =
      requested.contains("localTime")
      ? (input.localTime ?? ToolLocalTime(date: date)) : nil
    let locale = Locale(identifier: input.localTime?.locale ?? Locale.current.identifier)
    let analysis =
      requested.contains("analysis")
      ? try (input.analysis ?? ToolTextAnalysis.capture(content: input.content, locale: locale))
      : nil
    var entropy = requested.contains("entropy") ? input.entropy : nil
    if requested.contains("entropy"), entropy == nil {
      var random = SystemRandomNumberGenerator()
      entropy = (0..<16_384).map { _ in UInt8.random(in: .min ... .max, using: &random) }
    }
    return .init(
      content: input.content, date: date, uuid: UUID(uuidString: input.uuid) ?? UUID(),
      arguments: input.arguments, localTime: localTime, entropy: entropy, analysis: analysis,
      instruction: input.instruction)
  }
  public var modelAvailable: @Sendable () async -> Bool
  public var provider: @Sendable () -> any ModelProvider
  public var authenticationFailed: @Sendable () async -> Void
  public var javaScript: JavaScriptBrokerClient
  public init(
    modelAvailable: @escaping @Sendable () async -> Bool = { false },
    provider: (@Sendable () -> any ModelProvider)? = nil,
    javaScript: JavaScriptBrokerClient = .shared,
    authenticationFailed: @escaping @Sendable () async -> Void = {}
  ) {
    self.modelAvailable = modelAvailable
    self.provider = provider ?? { UnavailableModelProvider() }
    self.javaScript = javaScript
    self.authenticationFailed = authenticationFailed
  }
  public func validate(_ package: ToolPackage, input: ToolExecutionInput) async
    -> ToolExecutionResult
  {
    if package.manifest.executorType == .javascript {
      guard input.instruction == nil else {
        return .init(
          failure: .init(
            .invalidInput, message: "JavaScript tools do not accept an inline instruction."))
      }
      return await ToolRuntime.execute(
        package, input: input, validationOnly: true, client: javaScript)
    }
    do {
      _ = try modelRequest(package, input: input)
    } catch let failure as ToolFailure {
      return .init(failure: failure)
    } catch let failure as ModelFailure {
      // Input limits are actionable at submission time. Package/model failures
      // are configuration problems and must not expose implementation details.
      if failure == .limit { return .init(failure: failure.toolFailure) }
      return .init(
        failure: .init(
          .invalidPackage,
          message:
            "This model tool is unavailable. Check its instructions and selected model in Tools Settings."
        ))
    } catch {
      return .init(
        failure: .init(
          .invalidPackage,
          message:
            "This model tool is unavailable. Check its instructions and selected model in Tools Settings."
        ))
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
      guard input.instruction == nil else {
        return .init(
          failure: .init(
            .invalidInput, message: "JavaScript tools do not accept an inline instruction."))
      }
      return await ToolRuntime.execute(package, input: input, client: javaScript)
    }
    do {
      try Task.checkCancellation()
      let request = try modelRequest(package, input: input)
      let output = try await provider().execute(request)
      try Task.checkCancellation()
      return .init(output: try request.validateOutput(output))
    } catch let failure as ModelCredentialStoreFailure {
      return .init(failure: .init(.credentialStore, message: failure.message))
    } catch let failure as ModelFailure {
      if failure == .authentication { await authenticationFailed() }
      return .init(failure: failure.toolFailure)
    } catch is CancellationError { return .init(failure: ModelFailure.cancelled.toolFailure) } catch
    {
      return .init(failure: ModelFailure.malformed.toolFailure)
    }
  }

  public func validate(_ request: ToolExecutionRequest) async -> ToolExecutionResult {
    if request.package.manifest.executorType == .javascript {
      return await javaScript.validate(request)
    }
    return await validate(request.package, input: request.input)
  }

  public func execute(_ request: ToolExecutionRequest) async -> ToolExecutionResult {
    if request.package.manifest.executorType == .javascript {
      return await javaScript.execute(request)
    }
    return await execute(request.package, input: request.input)
  }

  private func modelRequest(_ package: ToolPackage, input: ToolExecutionInput) throws
    -> ModelRequest
  {
    guard package.manifest.entryContract == 2, !input.arguments.isEmpty else {
      return try ModelRequest(
        package: package, content: input.content, instruction: input.instruction)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let values = String(decoding: try encoder.encode(input.arguments), as: UTF8.self)
    var captured = package
    captured.implementation = .model(
      instructions: package.instructions
        + "\n\nExplicit submitted arguments (JSON):\n" + values)
    return try ModelRequest(
      package: captured, content: input.content, instruction: input.instruction)
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
