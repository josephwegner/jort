import Foundation
import JortToolContracts

/// The only Runtime seam for the private broker. Implementations must cross the
/// broker boundary; this module intentionally has no QuickJS dependency.
public protocol JavaScriptBrokerTransport: Sendable {
  func send(_ request: JavaScriptRequestPayload, operation: JavaScriptOperation) async
    -> ToolExecutionResult
  func cancel(invocationID: String, generation: String) async
}

public enum JavaScriptOperation: String, Sendable {
  /// Compile and inspect a package without invoking an exported function.
  case validate
  /// Invoke the package's input validator against captured invocation content.
  case validateInput
  case execute

  public var protocolTag: UInt32 {
    switch self {
    case .validate: 1
    case .execute: 2
    case .validateInput: 3
    }
  }
}

public struct UnavailableJavaScriptBrokerTransport: JavaScriptBrokerTransport {
  public init() {}
  public func send(_ request: JavaScriptRequestPayload, operation: JavaScriptOperation) async
    -> ToolExecutionResult
  {
    .init(failure: .init(.unavailable, message: "JavaScript execution is unavailable."))
  }
  public func cancel(invocationID: String, generation: String) async {}
}

/// FIFO admission is owned by Runtime so a broker restart cannot make the client
/// accidentally fan out unlimited work. A request remains cancellable while queued.
public actor JavaScriptAdmissionController {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }
  private let capacity: Int
  private var active = 0
  private var waiters: [Waiter] = []

  public init(capacity: Int = 4) { self.capacity = max(1, min(4, capacity)) }

  public func acquire(id: UUID) async -> Bool {
    guard !Task.isCancelled else { return false }
    if active < capacity {
      active += 1
      return true
    }
    return await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { continuation in
          guard !Task.isCancelled else {
            continuation.resume(returning: false)
            return
          }
          waiters.append(.init(id: id, continuation: continuation))
        }
      }, onCancel: { Task { await self.cancel(id: id) } })
  }

  public func cancel(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(returning: false)
  }

  public func release() {
    guard active > 0 else { return }
    active -= 1
    if !waiters.isEmpty {
      active += 1
      waiters.removeFirst().continuation.resume(returning: true)
    }
  }
}

public actor JavaScriptBrokerClient {
  public static let shared = JavaScriptBrokerClient(transport: XPCJavaScriptBrokerTransport())
  private let transport: any JavaScriptBrokerTransport
  private let admission: JavaScriptAdmissionController

  public init(
    transport: any JavaScriptBrokerTransport,
    admission: JavaScriptAdmissionController = .init()
  ) {
    self.transport = transport
    self.admission = admission
  }

  public func validate(_ request: ToolExecutionRequest, timeout: TimeInterval = 5)
    async -> ToolExecutionResult
  {
    await run(request, operation: .validateInput, timeout: timeout)
  }

  public func validatePackage(_ request: ToolExecutionRequest, timeout: TimeInterval = 5)
    async -> ToolExecutionResult
  {
    await run(request, operation: .validate, timeout: timeout)
  }

  public func execute(_ request: ToolExecutionRequest, timeout: TimeInterval = 5)
    async -> ToolExecutionResult
  {
    await run(request, operation: .execute, timeout: timeout)
  }

  private func run(
    _ request: ToolExecutionRequest, operation: JavaScriptOperation, timeout: TimeInterval
  )
    async -> ToolExecutionResult
  {
    let token = UUID()
    guard await admission.acquire(id: token) else {
      return .init(failure: .init(.cancelled, message: "Cancelled."))
    }
    defer { Task { await admission.release() } }
    let milliseconds = Int((max(0.01, min(30, timeout)) * 1_000).rounded())
    let payload: JavaScriptRequestPayload
    do { payload = try request.javascriptPayload(deadlineMilliseconds: milliseconds) } catch let
      failure as ToolFailure
    { return .init(failure: failure) } catch {
      return .init(failure: .init(.internalError, message: "Unable to prepare JavaScript."))
    }
    return await withTaskCancellationHandler(
      operation: {
        guard !Task.isCancelled else {
          return .init(failure: .init(.cancelled, message: "Cancelled."))
        }
        return await transport.send(payload, operation: operation)
      },
      onCancel: {
        Task {
          await self.transport.cancel(
            invocationID: payload.invocationID, generation: payload.generation)
        }
      })
  }
}

/// Compatibility facade for callers that have not yet been injected a dispatcher.
/// Its production transport is the lazy broker client, never an in-process engine.
public enum ToolRuntime {
  public static func validate(_ package: ToolPackage) throws { try package.validate() }

  public static func execute(
    _ package: ToolPackage, input: ToolExecutionInput, timeout: TimeInterval = 5,
    validationOnly: Bool = false, client: JavaScriptBrokerClient = .shared,
    identity: InvocationGeneration = .init(invocationID: UUID(), generation: UUID())
  ) async -> ToolExecutionResult {
    let request: ToolExecutionRequest
    do { request = try .init(identity: identity, package: package, input: input) } catch let failure
      as ToolFailure
    { return .init(failure: failure) } catch {
      return .init(failure: .init(.invalidPackage, message: "Invalid tool package."))
    }
    guard package.manifest.executorType == .javascript else {
      return .init(
        failure: .init(.invalidPackage, message: "Model tools require the model executor."))
    }
    return validationOnly
      ? await client.validate(request, timeout: timeout)
      : await client.execute(request, timeout: timeout)
  }
}

public struct RuntimePackageValidator: ToolPackageValidator {
  private let client: JavaScriptBrokerClient
  public init(client: JavaScriptBrokerClient = .shared) { self.client = client }
  public func validatePackage(_ package: ToolPackage) async throws {
    try package.validate()
    guard package.manifest.executorType == .javascript else { return }
    let request = try ToolExecutionRequest(validationOf: package)
    let result = await client.validatePackage(request)
    if let failure = result.failure { throw failure }
  }
}
