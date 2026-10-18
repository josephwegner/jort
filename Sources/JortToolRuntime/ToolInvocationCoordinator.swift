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
  private var dispatchedGenerations: Set<InvocationGeneration> = []
  private let executor: any ToolExecuting
  private let hostActions: (any ToolHostActionExecuting)?
  public init(executor: any ToolExecuting, hostActions: (any ToolHostActionExecuting)? = nil) {
    self.executor = executor
    self.hostActions = hostActions
  }
  public func hasJob(_ id: UUID) -> Bool { jobs[id] != nil }
  public func remove(_ id: UUID) {
    if let run = runs[id], run.state.actionStatus == .dispatched {
      send(run.state.identity, .cancel)
    }
    if var run = runs[id] { _ = run.state.reduce(.documentInvalidated) }
    jobs.removeValue(forKey: id)?.cancel()
    runs.removeValue(forKey: id)
  }
  public func submit(
    identity: InvocationGeneration, package: ToolPackage, input: ToolExecutionInput,
    apply: @escaping @MainActor (InvocationDocumentEffect) -> Bool,
    warning: @escaping @MainActor (String) -> Void
  ) {
    guard jobs[identity.invocationID] == nil, runs.count < 1000,
      runs[identity.invocationID]?.state.identity != identity,
      !dispatchedGenerations.contains(identity)
    else { return }
    guard
      package.manifest.entryContract == 2 || package.manifest.inputMode != .contextual
        || !input.content.isEmpty
    else {
      warning("Enter content within the tool’s input limit.")
      return
    }
    let request: ToolExecutionRequest
    do {
      let prepared = try ToolExecutorDispatcher.prepareInput(input, for: package.manifest)
      request = try ToolExecutionRequest(identity: identity, package: package, input: prepared)
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
      jobs.removeValue(forKey: id)?.cancel()
      runs.removeValue(forKey: id)
      return
    }
    for effect in effects {
      switch effect {
      case .document(let effect):
        let accepted = run.apply(effect)
        send(identity, .acknowledge(effect, accepted: accepted))
      case .cancel: jobs.removeValue(forKey: id)?.cancel()
      case .hostAction(_, let action):
        let request = run.request
        guard runs[id]?.state.identity == identity,
          runs[id]?.state.actionStatus == .dispatched
        else { continue }
        guard dispatchedGenerations.count < 10_000,
          dispatchedGenerations.insert(identity).inserted
        else {
          send(identity, .cancel)
          continue
        }
        guard let hostActions else {
          send(
            identity,
            .hostFailed(identity, message: "This action is unavailable.", cancelled: false))
          continue
        }
        jobs[id] = Task { [weak self] in
          guard !Task.isCancelled else { return }
          let result = request.bounded(
            await hostActions.execute(action: action, identity: identity, input: request.input))
          guard !Task.isCancelled, self?.runs[id]?.state.identity == identity else { return }
          self?.jobs.removeValue(forKey: id)
          if let report = result.report {
            self?.send(identity, .hostAcknowledged(identity, message: report))
          } else if let failure = result.failure {
            if [.protocolError, .malformedResponse, .internalError, .timeout, .outputLimit]
              .contains(failure.code)
            {
              self?.send(identity, .cancel)
              // Keep the conservative unknown/no-replay state, but do not
              // replace the host's actionable explanation with generic text.
              self?.send(identity, .completionMessage(failure.message))
            } else {
              self?.send(
                identity,
                .hostFailed(
                  identity, message: failure.message,
                  cancelled: failure.code == .cancelled))
            }
          } else {
            // A malformed acknowledgement cannot prove that an external effect failed.
            self?.send(identity, .cancel)
          }
        }
      case .validate:
        let executor = executor, request = run.request
        jobs[id] = Task { [weak self] in
          let result: ToolExecutionResult
          if let generationAware = executor as? any GenerationAwareToolExecuting {
            result = await generationAware.validate(request)
          } else {
            result = await executor.validate(request.package, input: request.input)
          }
          guard !Task.isCancelled, self?.runs[id]?.state.identity == identity else { return }
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
          let raw: ToolExecutionResult
          if let generationAware = executor as? any GenerationAwareToolExecuting {
            raw = await generationAware.execute(request)
          } else {
            raw = await executor.execute(request.package, input: request.input)
          }
          let result = request.bounded(raw)
          indicator.cancel()
          guard !Task.isCancelled, self?.runs[id]?.state.identity == identity else { return }
          self?.jobs.removeValue(forKey: id)
          if let error = result.error {
            self?.send(identity, .failure(identity, message: error))
          } else if let output = result.output {
            if let landmark = result.landmark {
              self?.send(identity, .landmarkResult(identity, output: output, landmark: landmark))
            } else {
              self?.send(identity, .result(identity, output: output))
            }
          } else if let report = result.report {
            self?.send(identity, .report(identity, message: report))
          } else if let action = result.action {
            guard request.package.manifest.entryContract == 2,
              request.package.manifest.executorType == .javascript,
              request.package.manifest.hostActions?.contains(action.kind) == true,
              action.isValid, action.content == request.input.content,
              action.content.utf8.count <= request.package.manifest.maximumInputBytes
            else {
              self?.send(
                identity, .failure(identity, message: "The tool requested an unauthorized action."))
              return
            }
            self?.send(identity, .hostAction(identity, action))
          } else {
            self?.send(identity, .failure(identity, message: "Invalid tool result."))
          }
        }
      }
    }
  }
}
