import Foundation
import JortToolContracts

public struct ToolDocumentPlan: Sendable {
  public let transaction: DocumentTransaction
  public let undoSnapshot: DocumentSnapshot?
  public let restoration: ToolInvocationRestoration?
}

extension ToolInvocation {
  public var packageReference: InvocationPackageReference {
    .init(
      id: packageID, version: packageVersion, executor: executor ?? "javascript",
      entryContract: entryContract, inputMode: inputMode, outputOperation: outputOperation)
  }
  public var lifecycle: InvocationLifecycleState {
    .init(
      identity: .init(invocationID: id, generation: generation), phase: phase,
      actionStatus: actionStatus)
  }
}

@MainActor public enum ToolDocumentEffects {
  public static func accept(
    _ effect: InvocationDocumentEffect, package: ToolPackage,
    token range: NSRange, space: Bool, in snapshot: DocumentSnapshot
  ) throws -> ToolDocumentPlan? {
    guard effect.operation == .accept else { throw DocumentError.invalidState }
    try package.validate()
    guard range.location >= 0, range.length >= 0, range.location <= snapshot.utf16Count,
      range.length <= snapshot.utf16Count - range.location
    else { throw DocumentError.invalidRange }
    guard snapshot.invocations.count < 1000,
      !snapshot.invocations.contains(where: { $0.id == effect.identity.invocationID }),
      !snapshot.invocations.contains(where: {
        guard let scope = $0.scope.resolve(in: snapshot) else { return true }
        return NSIntersectionRange(scope, range).length > 0
      })
    else { return nil }
    let builder = Builder(state: snapshot)
    try builder.accept(package, range: range, space: space, identity: effect.identity)
    return builder.plan
  }

  public static func prepare(
    _ effect: InvocationDocumentEffect, in snapshot: DocumentSnapshot,
    expected: ToolInvocation, submission: ToolInvocation? = nil
  ) throws -> ToolDocumentPlan {
    guard effect.identity.invocationID == expected.id,
      snapshot.invocations.first(where: { $0.id == expected.id }) == expected,
      expected.validated(in: snapshot),
      effect.operation == .submit || effect.identity.generation == expected.generation
    else { throw DocumentError.invalidState }
    let builder = Builder(state: snapshot)
    switch effect.operation {
    case .accept: throw DocumentError.invalidState
    case .submit:
      guard expected.phase == .inputting else { throw DocumentError.invalidState }
      guard expected.actionStatus == nil || effect.identity.generation != expected.generation else {
        throw DocumentError.invalidState
      }
      var value = submission ?? expected
      guard value.id == expected.id, value.packageID == expected.packageID,
        value.token == expected.token, value.scope == expected.scope,
        value.sourceHash == expected.sourceHash, value.generation == expected.generation,
        value.phase == .inputting
      else { throw DocumentError.invalidState }
      value.generation = effect.identity.generation
      value.phase = .submitted
      value.message = nil
      value.actionStatus = nil
      value.actionKind = nil
      value.outputLandmark = nil
      try builder.update(value)
    case .processing:
      guard expected.phase == .submitted else { throw DocumentError.invalidState }
      var value = expected
      value.phase = .processing
      try builder.update(value)
    case .failure(let message):
      guard [.submitted, .processing].contains(expected.phase) else {
        throw DocumentError.invalidState
      }
      var value = expected
      value.phase = .error
      value.message = message
      try builder.update(value)
    case .publish(let output):
      guard [.submitted, .processing].contains(expected.phase) else {
        throw DocumentError.invalidState
      }
      try builder.publish(expected, output: output)
    case .publishLandmarked(let output, let landmark):
      guard [.submitted, .processing].contains(expected.phase), expected.entryContract == 2,
        Landmark.isValidEmoji(landmark.emoji),
        ToolInvocation.outputLineOffset(landmark.line, in: output) != nil
      else { throw DocumentError.invalidState }
      try builder.publish(expected, output: output, landmark: landmark)
    case .report(let message):
      guard expected.entryContract == 2, [.submitted, .processing].contains(expected.phase),
        expected.actionStatus == nil, message.utf8.count <= 1_048_576
      else { throw DocumentError.invalidState }
      var value = expected
      value.phase = .completed
      value.message = message
      try builder.update(value)
    case .dispatchAction(let action):
      guard expected.entryContract == 2, expected.executor == "javascript",
        [.submitted, .processing].contains(expected.phase), expected.actionStatus == nil,
        ["clipboard.rich", "file.export", "notification.schedule"].contains(action.kind)
      else { throw DocumentError.invalidState }
      var value = expected
      value.actionStatus = .dispatched
      value.actionKind = action.kind
      value.message = "Action dispatched. Its outcome is not yet known."
      try builder.update(value)
    case .actionAcknowledged(let message):
      guard expected.actionStatus == .dispatched, message.utf8.count <= 1_048_576 else {
        throw DocumentError.invalidState
      }
      var value = expected
      value.actionStatus = .acknowledged
      value.phase = .completed
      value.message = message
      try builder.update(value)
    case .actionFailed(let message, let cancelled):
      guard expected.actionStatus == .dispatched else { throw DocumentError.invalidState }
      var value = expected
      value.phase = .inputting
      value.actionStatus = cancelled ? .cancelled : .failed
      value.message = UTF8Bounds.prefix(message, maximumBytes: 512)
      try builder.update(value)
    case .actionUnknown:
      guard expected.actionStatus == .dispatched else { throw DocumentError.invalidState }
      var value = expected
      value.phase = .completed
      value.actionStatus = .unknown
      value.message = "The action’s outcome is unknown. It has not been retried."
      try builder.update(value)
    case .done:
      guard expected.phase == .completed else { throw DocumentError.invalidState }
      try builder.done(expected)
    case .completionMessage(let message):
      guard expected.phase == .completed, message.utf8.count <= 512 else {
        throw DocumentError.invalidState
      }
      var value = expected
      value.message = message
      try builder.update(value)
    case .reconcile(let version, let interrupted):
      var value = expected
      value.packageVersion = version
      if interrupted {
        if expected.actionStatus == .dispatched {
          value.phase = .completed
          value.actionStatus = .unknown
          value.message = "The action’s outcome is unknown. It has not been retried."
        } else {
          value.phase = .error
          value.message = "Execution was interrupted."
        }
      }
      try builder.update(value)
    case .preserveOutput:
      guard expected.phase == .pending else { throw DocumentError.invalidState }
      try builder.merge(expected.id, outputOperation: "replace-invocation")
    case .merge: try builder.merge(expected.id)
    case .dismiss: try builder.dismiss(expected.id)
    case .remove: try builder.cancel(expected.id)
    }
    guard let plan = builder.plan else { throw DocumentError.invalidState }
    return plan
  }
}

@MainActor private final class Builder {
  let state: DocumentSnapshot
  var plan: ToolDocumentPlan?
  private var replacements: [DocumentPatch.Replacement] = []
  init(state: DocumentSnapshot) { self.state = state }
  func accept(_ package: ToolPackage, range: NSRange, space: Bool, identity: InvocationGeneration)
    throws
  {
    let before = state
    let manifest = package.manifest
    let command = manifest.command
    let replacement = command + (space ? " " : "")
    let plain = try replacing(before, range: range, with: replacement)
    var annotations = ToolRangeEditing.remap(
      before.invocations, from: before, to: plain, edit: range,
      replacementLength: replacement.utf16.count)
    let tokenRange = NSRange(location: range.location, length: command.utf16.count)
    var scopeRange = NSRange(
      location: range.location,
      length: manifest.inputMode.isEphemeral ? command.utf16.count : replacement.utf16.count)
    if manifest.inputMode == .contextual {
      guard let first = plain.line(containingUTF16Offset: tokenRange.location),
        let last = plain.line(
          containingUTF16Offset: max(tokenRange.location, NSMaxRange(tokenRange) - 1))
      else { throw DocumentError.missingAnchor }
      scopeRange = NSRange(
        location: first.location, length: last.location + last.length - first.location)
      while scopeRange.length > 0,
        let unit = try plain.utf16(in: NSRange(location: NSMaxRange(scopeRange) - 1, length: 1))
          .first,
        [10, 13].contains(unit)
      { scopeRange.length -= 1 }
      for other in annotations {
        guard let source = other.scope.resolve(in: plain) else { continue }
        let scope = NSUnionRange(source, other.output?.resolve(in: plain) ?? source)
        if NSMaxRange(scope) <= tokenRange.location && NSMaxRange(scope) > scopeRange.location {
          scopeRange.length -= NSMaxRange(scope) - scopeRange.location
          scopeRange.location = NSMaxRange(scope)
        } else if scope.location >= NSMaxRange(tokenRange)
          && scope.location < NSMaxRange(scopeRange)
        {
          scopeRange.length = scope.location - scopeRange.location
        }
      }
    }
    var invocation = ToolInvocation(
      packageID: manifest.id, packageVersion: manifest.version,
      entryContract: manifest.entryContract, inputMode: manifest.inputMode.rawValue,
      outputOperation: manifest.outputOperation.rawValue, command: command,
      token: try .init(tokenRange, snapshot: plain),
      scope: try .init(scopeRange, snapshot: plain),
      sourceHash: ToolInvocation.hash(try plain.text(in: scopeRange)))
    invocation.executor = manifest.executorType.rawValue
    invocation.id = identity.invocationID
    invocation.generation = identity.generation
    if space {
      invocation.acceptanceSeparator = try .init(
        NSRange(location: NSMaxRange(tokenRange), length: 1), snapshot: plain)
    }
    annotations.append(invocation)
    try commit(
      plain, edit: range, replacementLength: replacement.utf16.count, invocations: annotations)
  }
  func publish(
    _ invocation: ToolInvocation, output: String,
    landmark: ToolOutputLandmark? = nil
  ) throws {
    guard invocation.validated(in: state),
      let token = invocation.token.resolve(in: state),
      let scope = invocation.scope.resolve(in: state)
    else { throw DocumentError.invalidState }
    let before = state
    let offset = invocation.inputMode == "contained" ? NSMaxRange(scope) : NSMaxRange(token)
    let edit = NSRange(location: offset, length: 0)
    let plain = try replacing(before, range: edit, with: output)
    var annotations = ToolRangeEditing.remap(
      before.invocations.filter { $0.id != invocation.id }, from: before, to: plain, edit: edit,
      replacementLength: output.utf16.count)
    var pending = invocation
    pending.phase = .pending
    pending.token = try .init(token, snapshot: plain)
    pending.scope = try .init(
      NSRange(
        location: scope.location,
        length: scope.length + (invocation.inputMode == "contextual" ? output.utf16.count : 0)),
      snapshot: plain)
    pending.output = try .init(
      NSRange(location: offset, length: output.utf16.count), snapshot: plain)
    pending.outputHash = ToolInvocation.hash(output)
    pending.outputLandmark = landmark
    annotations.append(pending)
    // Publication's inverse is the editable pre-submit invocation, not a dead job.
    let inputting = restored(invocation)
    let undo = DocumentSnapshot(
      documentID: before.documentID, revision: before.revision,
      index: try before.indexed(), landmarks: before.landmarks,
      invocations: before.invocations.map { $0.id == invocation.id ? inputting : $0 })
    try commit(
      plain, edit: edit, replacementLength: output.utf16.count, invocations: annotations,
      undo: .none)
    plan = plan.map {
      ToolDocumentPlan(
        transaction: $0.transaction, undoSnapshot: undo, restoration: invocation.restoration)
    }
  }

  func dismiss(_ id: UUID) throws {
    guard var invocation = state.invocations.first(where: { $0.id == id }) else {
      return
    }
    if invocation.phase == .inputting {
      try cancel(id)
      return
    }
    let restoration = invocation.restoration
    let before = state
    if let output = invocation.output?.resolve(in: before) {
      let plain = try replacing(before, range: output, with: "")
      guard let token = invocation.token.resolve(in: before),
        let scope = invocation.scope.resolve(in: before)
      else { return }
      invocation.token = try .init(token, snapshot: plain)
      invocation.scope = try .init(
        NSRange(
          location: scope.location,
          length: scope.length - (invocation.inputMode == "contextual" ? output.length : 0)),
        snapshot: plain)
      invocation = restored(invocation, token: invocation.token, scope: invocation.scope)
      var values = ToolRangeEditing.remap(
        before.invocations.filter { $0.id != id }, from: before, to: plain, edit: output,
        replacementLength: 0)
      values.append(invocation)
      try commit(plain, edit: output, replacementLength: 0, invocations: values)
    } else {
      invocation = restored(invocation)
      try update(invocation)
    }
    plan = plan.map {
      ToolDocumentPlan(
        transaction: $0.transaction, undoSnapshot: $0.undoSnapshot, restoration: restoration)
    }
  }

  func merge(_ id: UUID, outputOperation: String? = nil) throws {
    guard let invocation = state.invocations.first(where: { $0.id == id }),
      invocation.phase == .pending,
      let output = invocation.output?.resolve(in: state),
      let token = invocation.token.resolve(in: state),
      let scope = invocation.scope.resolve(in: state)
    else { return }
    let before = state
    let range: NSRange, replacement: String
    if (outputOperation ?? invocation.outputOperation) == "replace-context" {
      range = scope
      replacement = try before.text(in: output)
    } else {
      range = invocation.inputMode == "contained" ? scope : token
      replacement = ""
    }
    let plain = try replacing(before, range: range, with: replacement)
    let annotations = ToolRangeEditing.remap(
      before.invocations.filter { $0.id != id }, from: before, to: plain, edit: range,
      replacementLength: replacement.utf16.count)
    var landmarks: [DocumentPatch.LandmarkChange] = []
    if let landmark = invocation.outputLandmark {
      let outputText = try before.text(in: output)
      guard let relative = ToolInvocation.outputLineOffset(landmark.line, in: outputText) else {
        throw DocumentError.invalidState
      }
      let start =
        (outputOperation ?? invocation.outputOperation) == "replace-context"
        ? range.location : output.location - range.length
      guard let line = plain.line(containingUTF16Offset: start + relative),
        Landmark.isValidEmoji(landmark.emoji),
        !plain.landmarks.contains(where: { !$0.detached && $0.lineID == line.id })
      else { throw DocumentError.invalidState }
      landmarks = [.upsert(Landmark(lineID: line.id, emoji: landmark.emoji))]
    }
    try commit(
      plain, edit: range, replacementLength: replacement.utf16.count, invocations: annotations,
      landmarks: landmarks)
  }

  func done(_ invocation: ToolInvocation) throws {
    guard let token = invocation.token.resolve(in: state) else { throw DocumentError.missingAnchor }
    var range = token
    if let separator = invocation.acceptanceSeparator?.resolve(in: state),
      separator.location == NSMaxRange(token), separator.length == 1,
      (try state.text(in: separator)) == " "
    {
      range.length += 1
    }
    let plain = try replacing(state, range: range, with: "")
    let values = ToolRangeEditing.remap(
      state.invocations.filter { $0.id != invocation.id }, from: state, to: plain,
      edit: range, replacementLength: 0)
    try commit(plain, edit: range, replacementLength: 0, invocations: values)
  }

  private func restored(
    _ invocation: ToolInvocation, token: ToolAnchoredRange? = nil,
    scope: ToolAnchoredRange? = nil
  ) -> ToolInvocation {
    guard let restoration = invocation.restoration else {
      var value = invocation
      value.phase = .inputting
      value.message = nil
      value.output = nil
      value.outputHash = nil
      value.outputLandmark = nil
      return value
    }
    var value = restoration.invocation(id: invocation.id)
    value.capturedArguments = invocation.capturedArguments ?? restoration.capturedArguments
    value.token = token ?? restoration.token
    value.scope = scope ?? restoration.scope
    return value
  }
  private func replacing(_ snapshot: DocumentSnapshot, range: NSRange, with text: String) throws
    -> DocumentSnapshot
  {
    let (replacement, preview) = try DocumentPatch.preview(snapshot, range: range, text: text)
    replacements.append(replacement)
    return preview
  }

  func cancel(_ id: UUID) throws {
    try commit(
      state, edit: nil, replacementLength: nil,
      invocations: state.invocations.filter { $0.id != id })
  }
  func update(_ invocation: ToolInvocation) throws {
    try commit(
      state, edit: nil, replacementLength: nil,
      invocations: state.invocations.map { $0.id == invocation.id ? invocation : $0 }, undo: .none)
  }
  private func commit(
    _ plain: DocumentSnapshot, edit: NSRange?, replacementLength: Int?,
    invocations: [ToolInvocation], undo: UndoPolicy = .register,
    landmarks: [DocumentPatch.LandmarkChange] = []
  ) throws {
    let patch = DocumentPatch(
      in: state, replacements: replacements,
      expectedInvocations: state.invocations,
      invocations: state.invocations.map { .remove($0.id) } + invocations.map { .upsert($0) },
      landmarks: landmarks)
    plan = ToolDocumentPlan(
      transaction: .init(
        baseRevision: state.revision, origin: .automation,
        undoPolicy: undo, mutation: .patch(patch)),
      undoSnapshot: nil, restoration: nil)
  }
}
