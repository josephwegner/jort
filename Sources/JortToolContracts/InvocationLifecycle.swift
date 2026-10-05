import Foundation

/// Correlates asynchronous outcomes and acknowledgements without consulting a clock.
public struct InvocationGeneration: Equatable, Hashable, Sendable {
  public let invocationID: UUID
  public let generation: UUID
  public init(invocationID: UUID, generation: UUID) {
    self.invocationID = invocationID
    self.generation = generation
  }
}

public enum ToolInvocationPhase: String, Codable, Sendable {
  case inputting, submitted, processing, error, pending, completed
}

/// Dispatch survives restoration; an absent acknowledgement never authorizes replay.
public enum ToolActionStatus: String, Codable, Sendable {
  case dispatched, acknowledged, unknown, failed, cancelled
}

public enum InvocationDocumentOperation: Equatable, Sendable {
  case accept, submit, processing, failure(String), publish(String), merge, dismiss, remove
  case reconcile(version: Int, interrupted: Bool), preserveOutput
  case publishLandmarked(String, ToolOutputLandmark)
  case report(String), dispatchAction(ToolHostAction), actionAcknowledged(String)
  case actionFailed(String, cancelled: Bool), actionUnknown, done
  case completionMessage(String)
}

public struct InvocationDocumentEffect: Equatable, Sendable {
  public let identity: InvocationGeneration
  public let sequence: UInt64
  public let operation: InvocationDocumentOperation
}

public struct InvocationLifecycleState: Equatable, Sendable {
  public let identity: InvocationGeneration
  public private(set) var phase: ToolInvocationPhase
  public private(set) var warning: String?
  public private(set) var validating = false
  public private(set) var terminal = false
  public private(set) var removed = false
  public private(set) var pendingEffect: InvocationDocumentEffect?
  public private(set) var actionStatus: ToolActionStatus?
  private var sequence: UInt64 = 0

  public init(
    identity: InvocationGeneration, phase: ToolInvocationPhase,
    actionStatus: ToolActionStatus? = nil
  ) {
    self.identity = identity
    self.phase = phase
    self.actionStatus = actionStatus
    terminal = phase == .pending || phase == .error || phase == .completed || actionStatus != nil
  }

  public enum Action: Equatable, Sendable {
    case accept
    case submit
    case validation(InvocationGeneration, error: String?)
    case processing(InvocationGeneration)
    case result(InvocationGeneration, output: String)
    case landmarkResult(InvocationGeneration, output: String, landmark: ToolOutputLandmark)
    case report(InvocationGeneration, message: String)
    case hostAction(InvocationGeneration, ToolHostAction)
    case hostAcknowledged(InvocationGeneration, message: String)
    case hostFailed(InvocationGeneration, message: String, cancelled: Bool)
    case failure(InvocationGeneration, message: String)
    case cancel
    case merge
    case done
    case completionMessage(String)
    case dismiss
    case restored(hasLiveJob: Bool)
    case reconcile(InvocationPackageReference, candidate: ToolManifest?, hasLiveJob: Bool)
    case detach
    case documentInvalidated
    case acknowledge(InvocationDocumentEffect, accepted: Bool)
  }
  public enum Effect: Equatable, Sendable {
    case validate(InvocationGeneration)
    case execute(InvocationGeneration)
    case cancel(InvocationGeneration)
    case hostAction(InvocationGeneration, ToolHostAction)
    case document(InvocationDocumentEffect)
  }

  /// Pending mutations are acknowledged before execution or a dependent mutation.
  /// The first terminal event reserves the generation, including before publication.
  public mutating func reduce(_ action: Action) -> [Effect] {
    func bounded(_ text: String) -> String { UTF8Bounds.prefix(text, maximumBytes: 512) }
    func matches(_ identity: InvocationGeneration) -> Bool { self.identity == identity }
    guard !removed else { return [] }
    switch action {
    case .acknowledge(let effect, let accepted):
      guard pendingEffect == effect else { return [] }
      pendingEffect = nil
      guard accepted else {
        validating = false
        terminal = true
        warning = "The document changed. Submit again."
        return [.cancel(identity)]
      }
      switch effect.operation {
      case .accept: break
      case .submit:
        phase = .submitted
        return [.execute(identity)]
      case .processing: phase = .processing
      case .failure: phase = .error
      case .publish, .publishLandmarked: phase = .pending
      case .report: phase = .completed
      case .dispatchAction(let action):
        actionStatus = .dispatched
        return [.hostAction(identity, action)]
      case .actionAcknowledged:
        actionStatus = .acknowledged
        phase = .completed
      case .actionFailed(_, let cancelled):
        actionStatus = cancelled ? .cancelled : .failed
        phase = .inputting
      case .actionUnknown:
        actionStatus = .unknown
        phase = .completed
      case .completionMessage: break
      case .dismiss:
        phase = .inputting
        // A later submission must create a fresh generation, never revive this one.
        terminal = true
        warning = nil
      case .merge, .remove, .preserveOutput, .done: removed = true
      case .reconcile(_, let interrupted):
        if interrupted {
          phase = actionStatus == .dispatched ? .completed : .error
          if actionStatus == .dispatched { actionStatus = .unknown }
          terminal = true
        }
      }
      return []
    case .detach:
      terminal = true
      return [.cancel(identity)] + document(.remove)
    case .documentInvalidated:
      removed = true
      pendingEffect = nil
      return [.cancel(identity)]
    case .cancel:
      if actionStatus == .dispatched, pendingEffect == nil {
        return [.cancel(identity)] + document(.actionUnknown)
      }
      guard !terminal else { return [] }
      terminal = true
      validating = false
      return [.cancel(identity)] + document(.remove)
    case .accept:
      guard phase == .inputting, !validating, !terminal, pendingEffect == nil else { return [] }
      return document(.accept)
    case .submit:
      guard phase == .inputting, !terminal, !validating, pendingEffect == nil else { return [] }
      warning = nil
      validating = true
      return [.validate(identity)]
    case .validation(let token, let error):
      guard matches(token), validating, !terminal, phase == .inputting, pendingEffect == nil else {
        return []
      }
      validating = false
      if let error {
        warning = bounded(error)
        return []
      }
      return document(.submit)
    case .processing(let token):
      guard matches(token), phase == .submitted, !terminal, pendingEffect == nil else { return [] }
      return document(.processing)
    case .result(let token, let output):
      guard matches(token), [.submitted, .processing].contains(phase), !terminal else { return [] }
      terminal = true
      return document(.publish(output))
    case .landmarkResult(let token, let output, let landmark):
      guard matches(token), [.submitted, .processing].contains(phase), !terminal else { return [] }
      terminal = true
      return document(.publishLandmarked(output, landmark))
    case .report(let token, let message):
      guard matches(token), [.submitted, .processing].contains(phase), !terminal else { return [] }
      terminal = true
      return document(.report(message))
    case .hostAction(let token, let action):
      guard matches(token), [.submitted, .processing].contains(phase), !terminal,
        actionStatus == nil
      else { return [] }
      terminal = true
      return document(.dispatchAction(action))
    case .hostAcknowledged(let token, let message):
      guard matches(token), actionStatus == .dispatched, pendingEffect == nil else { return [] }
      return document(.actionAcknowledged(message))
    case .hostFailed(let token, let message, let cancelled):
      guard matches(token), actionStatus == .dispatched, pendingEffect == nil else { return [] }
      return document(.actionFailed(bounded(message), cancelled: cancelled))
    case .failure(let token, let message):
      guard matches(token), [.submitted, .processing].contains(phase), !terminal else { return [] }
      terminal = true
      return document(.failure(bounded(message)))
    case .merge:
      guard phase == .pending, pendingEffect == nil else { return [] }
      return document(.merge)
    case .done:
      guard phase == .completed, pendingEffect == nil else { return [] }
      return document(.done)
    case .completionMessage(let message):
      guard phase == .completed, pendingEffect == nil else { return [] }
      return document(.completionMessage(bounded(message)))
    case .dismiss:
      guard pendingEffect == nil else { return [] }
      if actionStatus == .dispatched {
        return [.cancel(identity)] + document(.actionUnknown)
      }
      if phase == .inputting { return document(.remove) }
      terminal = true
      return [.cancel(identity)] + document(.dismiss)
    case .reconcile(let reference, let candidate, let hasLiveJob):
      guard pendingEffect == nil else { return [] }
      if hasLiveJob, [.submitted, .processing].contains(phase) { return [] }
      if actionStatus == .dispatched { return document(.actionUnknown) }
      if phase == .completed { return [] }
      if let candidate, reference.accepts(candidate) {
        let interrupted = [.submitted, .processing].contains(phase)
        guard candidate.version != reference.version || interrupted else { return [] }
        return document(.reconcile(version: candidate.version, interrupted: interrupted))
      }
      terminal = true
      return [.cancel(identity)] + document(phase == .pending ? .preserveOutput : .remove)
    case .restored(let hasLiveJob):
      guard !hasLiveJob, [.submitted, .processing].contains(phase), pendingEffect == nil else {
        return []
      }
      terminal = true
      return document(
        actionStatus == .dispatched ? .actionUnknown : .failure("Execution was interrupted."))
    }
  }

  private mutating func document(_ operation: InvocationDocumentOperation) -> [Effect] {
    sequence += 1
    let effect = InvocationDocumentEffect(
      identity: identity, sequence: sequence, operation: operation)
    pendingEffect = effect
    return [.document(effect)]
  }
}
