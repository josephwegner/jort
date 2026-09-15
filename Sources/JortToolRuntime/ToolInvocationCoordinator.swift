import Foundation
import JortToolContracts

/// Task ownership is headless. UI/document integration acknowledges declarative
/// effects synchronously; neither views nor document storage enter captured requests.
@MainActor public final class ToolInvocationCoordinator: ToolInvocationCoordinating {
  private struct Run {
    var state: InvocationLifecycleState
    let request: ToolExecutionRequest
    let apply: @MainActor (InvocationDocumentEffect) -> Bool
    let warning: @MainActor (String) -> Void
  }
  public var transient = InvocationTransientState()
  private var runs: [UUID: Run] = [:]
  private var jobs: [UUID: Task<Void, Never>] = [:]
  private let executor: any ToolExecuting
  public init(executor: any ToolExecuting) { self.executor = executor }
  public func hasJob(_ id: UUID) -> Bool { jobs[id] != nil }
  public func remove(_ id: UUID) {
    if var run = runs[id] { _ = run.state.reduce(.documentInvalidated) }
    jobs.removeValue(forKey: id)?.cancel()
    runs.removeValue(forKey: id)
  }
  public func submit(
    identity: InvocationGeneration, package: ToolPackage, input: ToolExecutionInput,
    apply: @escaping @MainActor (InvocationDocumentEffect) -> Bool,
    warning: @escaping @MainActor (String) -> Void
  ) {
    guard jobs[identity.invocationID] == nil, runs.count < 1000 else { return }
    let request: ToolExecutionRequest
    do {
      request = try ToolExecutionRequest(identity: identity, package: package, input: input)
    } catch let failure as ToolFailure {
      warning(failure.message)
      return
    } catch {
      warning("Invalid tool package.")
      return
    }
    runs[identity.invocationID] = Run(
      state: .init(identity: identity, phase: .inputting), request: request, apply: apply,
      warning: warning)
    send(identity, .submit)
  }
  private func send(_ identity: InvocationGeneration, _ action: InvocationLifecycleState.Action) {
    let id = identity.invocationID
    guard var run = runs[id], run.state.identity == identity else { return }
    let effects = run.state.reduce(action)
    runs[id] = run
    if let warning = run.state.warning {
      run.warning(warning)
      remove(id)
      return
    }
    for effect in effects {
      switch effect {
      case .document(let effect):
        let accepted = run.apply(effect)
        send(identity, .acknowledge(effect, accepted: accepted))
      case .cancel: jobs.removeValue(forKey: id)?.cancel()
      case .validate:
        let executor = executor, request = run.request
        jobs[id] = Task { [weak self] in
          let result = await executor.validate(request.package, input: request.input)
          guard !Task.isCancelled else { return }
          self?.jobs.removeValue(forKey: id)
          self?.send(identity, .validation(identity, error: result.error))
        }
      case .execute:
        let executor = executor, request = run.request
        jobs[id] = Task { [weak self] in
          let indicator = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.send(identity, .processing(identity))
          }
          let result = request.bounded(
            await executor.execute(request.package, input: request.input))
          indicator.cancel()
          guard !Task.isCancelled else { return }
          self?.jobs.removeValue(forKey: id)
          if let error = result.error {
            self?.send(identity, .failure(identity, message: error))
          } else if let output = result.output {
            self?.send(identity, .result(identity, output: output))
          } else {
            self?.send(identity, .failure(identity, message: "Invalid tool result."))
          }
        }
      }
    }
  }
}
