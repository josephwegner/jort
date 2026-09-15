import XCTest
import JortToolContracts

final class InvocationLifecycleTests: XCTestCase {
  private func state(_ phase: ToolInvocationPhase = .inputting) -> InvocationLifecycleState {
    .init(identity: .init(invocationID: UUID(), generation: UUID()), phase: phase)
  }
  private func acknowledge(_ value: inout InvocationLifecycleState) -> [InvocationLifecycleState
    .Effect]
  {
    guard let effect = value.pendingEffect else {
      XCTFail("Missing document effect")
      return []
    }
    return value.reduce(.acknowledge(effect, accepted: true))
  }
  func testValidationAndExecutionWaitForDocumentAcknowledgement() {
    var value = state()
    XCTAssertEqual(value.reduce(.submit), [.validate(value.identity)])
    XCTAssertTrue(value.reduce(.submit).isEmpty)
    _ = value.reduce(.validation(value.identity, error: nil))
    XCTAssertEqual(value.phase, .inputting)
    XCTAssertEqual(value.pendingEffect?.operation, .submit)
    XCTAssertEqual(acknowledge(&value), [.execute(value.identity)])
    XCTAssertEqual(value.phase, .submitted)
    _ = value.reduce(.processing(value.identity))
    XCTAssertEqual(value.phase, .submitted)
    _ = acknowledge(&value)
    XCTAssertEqual(value.phase, .processing)
  }
  func testEveryTerminalOutcomeWinsOnceAndIgnoresLateOutcomes() {
    for winner in 0..<4 {
      var value = state(.submitted)
      let actions: [InvocationLifecycleState.Action] = [
        .result(value.identity, output: "exact\noutput"),
        .failure(value.identity, message: "Tool timed out."), .cancel,
        .failure(value.identity, message: "Executor failed."),
      ]
      XCTAssertFalse(value.reduce(actions[winner]).isEmpty)
      let reserved = value
      for action in actions { XCTAssertTrue(value.reduce(action).isEmpty) }
      XCTAssertEqual(value, reserved)
      _ = acknowledge(&value)
      XCTAssertEqual(value.phase, winner == 0 ? .pending : winner == 2 ? .submitted : .error)
      XCTAssertEqual(value.removed, winner == 2)
    }
  }
  func testStaleGenerationAndAcknowledgementsCannotStartExecution() {
    var value = state()
    _ = value.reduce(.submit)
    let stale = state().identity
    XCTAssertTrue(value.reduce(.validation(stale, error: nil)).isEmpty)
    _ = value.reduce(.validation(value.identity, error: nil))
    let effect = value.pendingEffect!
    _ = value.reduce(.acknowledge(effect, accepted: false))
    XCTAssertEqual(value.phase, .inputting)
    XCTAssertTrue(value.reduce(.acknowledge(effect, accepted: true)).isEmpty)
    XCTAssertTrue(value.reduce(.result(value.identity, output: "late")).isEmpty)
  }
  func testRestorationDoesNotRestartInterruptedJobsOrPublishedOutput() {
    for phase in [ToolInvocationPhase.submitted, .processing] {
      var value = state(phase)
      XCTAssertTrue(value.reduce(.restored(hasLiveJob: true)).isEmpty)
      _ = value.reduce(.restored(hasLiveJob: false))
      XCTAssertEqual(value.pendingEffect?.operation, .failure("Execution was interrupted."))
      _ = acknowledge(&value)
      XCTAssertEqual(value.phase, .error)
    }
    var pending = state(.pending)
    XCTAssertTrue(pending.reduce(.restored(hasLiveJob: false)).isEmpty)
  }
  func testMergeDismissAndValidationWarning() {
    var value = state()
    _ = value.reduce(.submit)
    _ = value.reduce(.validation(value.identity, error: "Revise input"))
    XCTAssertEqual(value.phase, .inputting)
    XCTAssertEqual(value.warning, "Revise input")
    var pending = state(.pending)
    _ = pending.reduce(.merge)
    XCTAssertEqual(pending.pendingEffect?.operation, .merge)
    _ = acknowledge(&pending)
    XCTAssertTrue(pending.removed)
    var failure = state(.error)
    _ = failure.reduce(.dismiss)
    _ = acknowledge(&failure)
    XCTAssertEqual(failure.phase, .inputting)
  }
}

extension InvocationLifecycleTests {
  func testPackageReconciliationAcrossAllPhasesAndInFlightCapture() {
    let reference = InvocationPackageReference(
      id: "dev.test.run", version: 1, executor: "javascript",
      entryContract: 1, inputMode: "contained", outputOperation: "replace-invocation")
    var candidate = ToolManifest(id: reference.id, version: 2, name: "Run", command: "/run")
    candidate.compatibleVersions = [1]
    for phase in [ToolInvocationPhase.inputting, .submitted, .processing, .error, .pending] {
      var compatible = state(phase)
      _ = compatible.reduce(.reconcile(reference, candidate: candidate, hasLiveJob: false))
      XCTAssertEqual(
        compatible.pendingEffect?.operation,
        .reconcile(version: 2, interrupted: phase == .submitted || phase == .processing))
      var missing = state(phase)
      _ = missing.reduce(.reconcile(reference, candidate: nil, hasLiveJob: false))
      XCTAssertEqual(
        missing.pendingEffect?.operation, phase == .pending ? .preserveOutput : .remove)
      if phase == .submitted || phase == .processing {
        var running = state(phase)
        XCTAssertTrue(
          running.reduce(.reconcile(reference, candidate: nil, hasLiveJob: true)).isEmpty)
      }
    }
  }
  func testDismissCannotReviveAnOldGenerationAndOldAcknowledgementCannotCommit() {
    var value = state(.submitted)
    _ = value.reduce(.processing(value.identity))
    let old = value.pendingEffect!
    _ = value.reduce(.result(value.identity, output: "winner"))
    let winning = value
    XCTAssertTrue(value.reduce(.acknowledge(old, accepted: true)).isEmpty)
    XCTAssertEqual(value, winning)
    _ = acknowledge(&value)
    _ = value.reduce(.dismiss)
    _ = acknowledge(&value)
    XCTAssertTrue(value.reduce(.submit).isEmpty)
    XCTAssertTrue(value.reduce(.result(value.identity, output: "late")).isEmpty)
  }
  func testExactNormalizationAndBoundedFailure() {
    for (source, expected) in [
      ("  x", " x"), ("\tx", "\tx"), ("\n x", "\n x"), (" 秘密\r\n", "秘密\r\n"),
    ] {
      XCTAssertEqual(ToolInputNormalization.submitted(source), expected)
    }
    let failure = ToolFailure(.implementation, message: String(repeating: "😀", count: 600))
    XCTAssertEqual(failure.message.utf8.count, 2048)
    XCTAssertEqual(ToolExecutionResult(failure: failure).failure?.code, .implementation)
  }
}

extension InvocationLifecycleTests {
  func testTransitionMatrixIsDeterministicAndNeverAcceptsStaleOutcomes() {
    for phase in [ToolInvocationPhase.inputting, .submitted, .processing, .error, .pending] {
      let initial = state(phase), stale = state().identity
      let actions: [InvocationLifecycleState.Action] = [
        .accept, .submit, .merge, .dismiss, .cancel, .detach, .documentInvalidated,
        .restored(hasLiveJob: false), .processing(initial.identity),
        .result(initial.identity, output: "ok"), .failure(initial.identity, message: "failed"),
      ]
      for action in actions {
        var first = initial, second = initial
        XCTAssertEqual(first.reduce(action), second.reduce(action))
        XCTAssertEqual(first, second)
        if let effect = first.pendingEffect {
          XCTAssertEqual(first.phase, phase, "Phase changed before document acknowledgement")
          _ = first.reduce(.acknowledge(effect, accepted: true))
          XCTAssertTrue(first.reduce(.acknowledge(effect, accepted: true)).isEmpty)
        }
      }
      for action in [
        InvocationLifecycleState.Action.processing(stale), .result(stale, output: "late"),
        .failure(stale, message: "late"), .validation(stale, error: nil),
      ] {
        var value = initial
        XCTAssertTrue(value.reduce(action).isEmpty)
        XCTAssertEqual(value, initial)
      }
    }
  }
}
