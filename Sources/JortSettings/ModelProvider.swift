import Foundation

public enum ModelFailure: Error, Equatable, Sendable {
    case disconnected, authentication, offline, timeout, cancelled, malformed, limit, credentialStore, authorization
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
              let model = ModelCatalog.bundled.model(id: package.manifest.modelID ?? "") else { throw ModelFailure.malformed }
        guard content.utf8.count <= package.manifest.maximumInputBytes else { throw ModelFailure.limit }
        self.id = id; toolID = package.manifest.id; version = package.manifest.version
        modelID = model.id; instructions = package.instructions; self.content = content
        maximumTokens = min(model.maximumOutputTokens, package.manifest.maximumOutputBytes)
        maximumBytes = package.manifest.maximumOutputBytes; maximumLines = package.manifest.maximumOutputLines
    }
    public func validateOutput(_ output: String) throws -> String {
        guard output.utf8.count <= maximumBytes, !output.contains("\0") else { throw ModelFailure.limit }
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

public actor FakeModelProvider: ModelProvider {
    public enum Behavior: Sendable { case success(String), failure(ModelFailure), delayed(String, Duration), late(String, Duration) }
    public let behavior: Behavior
    public private(set) var requests: [ModelRequest] = []
    public init(_ behavior: Behavior) { self.behavior = behavior }
    public func execute(_ request: ModelRequest) async throws -> String {
        requests.append(request)
        let output: String
        switch behavior {
        case .success(let text): output = text
        case .failure(let failure): throw failure
        case .delayed(let text, let delay): try await Task.sleep(for: delay); output = text
        case .late(let text, let delay): try? await Task.sleep(for: delay); output = text
        }
        return try request.validateOutput(output)
    }
}

public struct ToolExecutorDispatcher: Sendable {
    public var modelAvailable: @Sendable () async -> Bool
    public var provider: @Sendable () -> any ModelProvider
    public var authenticationFailed: @Sendable () async -> Void
    public init(modelAvailable: @escaping @Sendable () async -> Bool = { false },
                provider: @escaping @Sendable () -> any ModelProvider = { FakeModelProvider(.failure(.disconnected)) },
                authenticationFailed: @escaping @Sendable () async -> Void = {}) {
        self.modelAvailable = modelAvailable; self.provider = provider; self.authenticationFailed = authenticationFailed
    }
    public func validate(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult {
        if package.manifest.executorType == .javascript { return await ToolRuntime.execute(package, input: input, validationOnly: true) }
        do { _ = try ModelRequest(package: package, content: input.content) }
        catch { return .init(error: "Check this tool’s instructions and selected model in Tools Settings.") }
        guard await modelAvailable() else { return .init(error: ModelFailure.disconnected.message) }
        return .init(output: "")
    }
    public func execute(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult {
        if package.manifest.executorType == .javascript { return await ToolRuntime.execute(package, input: input) }
        do {
            try Task.checkCancellation()
            let request = try ModelRequest(package: package, content: input.content)
            let output = try await provider().execute(request)
            try Task.checkCancellation()
            return .init(output: try request.validateOutput(output))
        } catch let failure as ModelFailure {
            if failure == .authentication { await authenticationFailed() }
            return .init(error: failure.message)
        } catch is CancellationError { return .init(error: ModelFailure.cancelled.message) }
        catch { return .init(error: ModelFailure.malformed.message) }
    }
}
