import Foundation
import XCTest
import JortToolContracts
import JortToolRuntime

private actor ControlledExecutor: ToolExecuting {
  private var validations: [CheckedContinuation<ToolExecutionResult, Never>] = []
  private var executions: [CheckedContinuation<ToolExecutionResult, Never>] = []
  private(set) var inputs: [ToolExecutionInput] = []
  private(set) var packages: [ToolPackage] = []
  func validate(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult {
    inputs.append(input)
    return await withCheckedContinuation { validations.append($0) }
  }
  func execute(_ package: ToolPackage, input: ToolExecutionInput) async -> ToolExecutionResult {
    inputs.append(input)
    packages.append(package)
    return await withCheckedContinuation { executions.append($0) }
  }
  func validation(_ result: ToolExecutionResult) {
    validations.removeFirst().resume(returning: result)
  }
  func result(_ result: ToolExecutionResult) { executions.removeFirst().resume(returning: result) }
  var validating: Bool { !validations.isEmpty }
  var executing: Bool { !executions.isEmpty }
}

@MainActor final class CoordinatorTests: XCTestCase {
  private var package: ToolPackage {
    .init(
      manifest: .init(id: "dev.test.run", name: "Run", command: "/run"),
      source: "export default () => ({output:'ok'});")
  }
  private func wait(_ condition: () async -> Bool) async throws {
    for _ in 0..<500 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Coordinator did not reach expected state")
  }
  func testImmutableCaptureExactInputAndAcknowledgedPublication() async throws {
    let executor = ControlledExecutor()
    let owner = ToolInvocationCoordinator(executor: executor)
    let identity = InvocationGeneration(invocationID: UUID(), generation: UUID())
    let input = ToolExecutionInput(
      content: "  秘密\r\n", date: Date(timeIntervalSince1970: 0), uuid: UUID())
    var original = package
    let captured = original
    var operations: [InvocationDocumentOperation] = []
    owner.submit(
      identity: identity, package: original, input: input,
      apply: {
        operations.append($0.operation)
        return true
      }, warning: { XCTFail($0) })
    original.source = "changed"
    try await wait { await executor.validating }
    await executor.validation(.init(output: ""))
    try await wait { await executor.executing }
    XCTAssertEqual(operations, [.submit])
    let inputs = await executor.inputs, packages = await executor.packages
    XCTAssertEqual(inputs.map(\.content), [input.content, input.content])
    XCTAssertEqual(inputs.map(\.clock), [input.clock, input.clock])
    XCTAssertEqual(inputs.map(\.uuid), [input.uuid, input.uuid])
    XCTAssertEqual(packages, [captured])
    await executor.result(.init(output: "complete"))
    try await wait { operations.count == 2 }
    XCTAssertEqual(operations, [.submit, .publish("complete")])
  }
  func testRejectedSubmitNeverExecutesAndValidationFailureStaysEditable() async throws {
    for failure in [false, true] {
      let executor = ControlledExecutor()
      let coordinator = ToolInvocationCoordinator(executor: executor)
      var operations: [InvocationDocumentOperation] = [], warnings: [String] = []
      coordinator.submit(
        identity: .init(invocationID: UUID(), generation: UUID()), package: package,
        input: .init(content: "input"),
        apply: {
          operations.append($0.operation)
          return false
        },
        warning: { warnings.append($0) })
      try await wait { await executor.validating }
      await executor.validation(failure ? .init(error: "Revise") : .init(output: ""))
      try await wait { !warnings.isEmpty }
      let requests = await executor.packages
      XCTAssertTrue(requests.isEmpty)
      XCTAssertEqual(operations, failure ? [] : [.submit])
    }
  }
  func testContextualEmptyInputWarnsBeforeCreatingAnExecutionRequest() async {
    let executor = ControlledExecutor()
    let coordinator = ToolInvocationCoordinator(executor: executor)
    let contextual = ToolPackage(
      manifest: .init(
        id: "dev.test.contextual", name: "Contextual", command: "/contextual",
        inputMode: .contextual),
      source: "export default () => ({output:'ok'});")
    var warnings: [String] = []
    let identity = InvocationGeneration(invocationID: UUID(), generation: UUID())

    coordinator.submit(
      identity: identity, package: contextual, input: .init(content: ""),
      apply: { _ in
        XCTFail("Contextual empty input must not reach the document")
        return true
      }, warning: { warnings.append($0) })

    XCTAssertEqual(warnings, ["Enter content within the tool’s input limit."])
    XCTAssertFalse(coordinator.hasJob(identity.invocationID))
    let validating = await executor.validating
    XCTAssertFalse(validating)
  }
  func testCancellationIgnoresLateValidationAndExecution() async throws {
    for cancelValidation in [true, false] {
      let executor = ControlledExecutor()
      let coordinator = ToolInvocationCoordinator(executor: executor)
      let identity = InvocationGeneration(invocationID: UUID(), generation: UUID())
      var operations: [InvocationDocumentOperation] = []
      coordinator.submit(
        identity: identity, package: package, input: .init(content: "input"),
        apply: {
          operations.append($0.operation)
          return true
        }, warning: { XCTFail($0) })
      try await wait { await executor.validating }
      if !cancelValidation {
        await executor.validation(.init(output: ""))
        try await wait { await executor.executing }
      }
      coordinator.remove(identity.invocationID)
      if cancelValidation {
        await executor.validation(.init(output: ""))
      } else {
        await executor.result(.init(output: "late"))
      }
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(operations, cancelValidation ? [] : [.submit])
      XCTAssertFalse(coordinator.hasJob(identity.invocationID))
    }
  }
  func testInjectedExecutorCannotExceedOutputLimits() async throws {
    let executor = ControlledExecutor(), owner = ToolInvocationCoordinator(executor: executor)
    var package = package
    package.manifest.maximumOutputBytes = 2
    var operations: [InvocationDocumentOperation] = []
    owner.submit(
      identity: .init(invocationID: UUID(), generation: UUID()), package: package,
      input: .init(content: "x"),
      apply: {
        operations.append($0.operation)
        return true
      }, warning: { XCTFail($0) })
    try await wait { await executor.validating }
    await executor.validation(.init(output: ""))
    try await wait { await executor.executing }
    await executor.result(.init(output: "too large"))
    try await wait { operations.count == 2 }
    XCTAssertEqual(operations.last, .failure("Output exceeds the tool limit."))
  }

  func testTerminalBrokerFailuresDoNotPublishAndLeaveAnotherInvocationAvailable() async throws {
    let cases: [ToolFailureCode] = [
      .unavailable, .busy, .launch, .sandboxBootstrap, .cpuLimit, .engineLimit, .crash,
      .timeout, .cancelled, .outputLimit, .protocolError, .malformedResponse, .internalError,
    ]

    for code in cases {
      let executor = ControlledExecutor()
      let coordinator = ToolInvocationCoordinator(executor: executor)
      let failed = InvocationGeneration(invocationID: UUID(), generation: UUID())
      var operations: [InvocationDocumentOperation] = []
      coordinator.submit(
        identity: failed, package: package, input: .init(content: "input"),
        apply: {
          operations.append($0.operation)
          return true
        }, warning: { XCTFail("Unexpected warning: \($0)") })
      try await wait { await executor.validating }
      await executor.validation(.init(output: ""))
      try await wait { await executor.executing }
      await executor.result(
        .init(failure: .init(code, message: "Bounded \(code.rawValue) failure.")))
      try await wait { operations.count == 2 }

      XCTAssertEqual(
        operations, [.submit, .failure("Bounded \(code.rawValue) failure.")],
        "code: \(code)")
      XCTAssertFalse(coordinator.hasJob(failed.invocationID), "code: \(code)")
      XCTAssertFalse(
        operations.contains {
          if case .publish = $0 { return true }
          return false
        })

      let healthy = InvocationGeneration(invocationID: UUID(), generation: UUID())
      coordinator.submit(
        identity: healthy, package: package, input: .init(content: "unrelated"),
        apply: {
          operations.append($0.operation)
          return true
        }, warning: { XCTFail("Unexpected warning: \($0)") })
      try await wait { await executor.validating }
      await executor.validation(.init(output: ""))
      try await wait { await executor.executing }
      await executor.result(.init(output: "healthy"))
      try await wait { operations.count == 4 }
      XCTAssertEqual(
        Array(operations.suffix(2)), [.submit, .publish("healthy")], "code: \(code)")
      XCTAssertFalse(coordinator.hasJob(healthy.invocationID), "code: \(code)")
    }
  }
}

private final class ProviderCreationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() {
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

extension CoordinatorTests {
  func testProviderConstructionIsLazyAndFailuresRemainTyped() async throws {
    let creations = ProviderCreationCounter()
    let provider = FakeModelProvider(.failure(.authentication))
    let dispatcher = ToolExecutorDispatcher(
      modelAvailable: { true },
      provider: {
        creations.increment()
        return provider
      })
    XCTAssertEqual(creations.value, 0)
    var manifest = package.manifest
    manifest.schemaVersion = 2
    manifest.executor = .model
    manifest.modelID = ModelCatalog.defaultModelID
    let model = ToolPackage(manifest: manifest, instructions: "Translate only the submitted input.")
    let validation = await dispatcher.validate(model, input: .init(content: "exact"))
    XCTAssertNil(validation.error)
    XCTAssertEqual(creations.value, 0)
    let result = await dispatcher.execute(model, input: .init(content: "exact"))
    XCTAssertEqual(creations.value, 1)
    XCTAssertEqual(result.failure?.code, .authentication)
    XCTAssertEqual(result.error, ModelFailure.authentication.message)
  }
}
