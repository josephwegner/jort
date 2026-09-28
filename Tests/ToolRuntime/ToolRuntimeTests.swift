@testable import JortToolRuntime
import JortToolContracts
import XCTest

private actor RecordingBroker: JavaScriptBrokerTransport {
  var requests: [(JavaScriptRequestPayload, JavaScriptOperation)] = []
  var cancelled: [(String, String)] = []
  var response = ToolExecutionResult(output: "ok")
  var delay: Duration?
  func setDelay(_ value: Duration?) { delay = value }
  func setResponse(_ value: ToolExecutionResult) { response = value }
  func requestCount() -> Int { requests.count }
  func requestOperations() -> [JavaScriptOperation] { requests.map(\.1) }
  func cancellationCount() -> Int { cancelled.count }
  func send(_ request: JavaScriptRequestPayload, operation: JavaScriptOperation) async
    -> ToolExecutionResult
  {
    requests.append((request, operation))
    if let delay { try? await Task.sleep(for: delay) }
    return response
  }
  func cancel(invocationID: String, generation: String) async {
    cancelled.append((invocationID, generation))
  }
}

final class ToolRuntimeTests: XCTestCase {
  private func package(
    source: String = "export default async function(input) { return {output: input.content}; }"
  ) -> ToolPackage {
    .init(
      manifest: .init(id: "dev.jort.test", name: "Test", command: "/test"),
      source: source)
  }

  func testBrokerClientSendsNormalizedBoundedPrimitiveValues() async throws {
    let transport = RecordingBroker()
    let client = JavaScriptBrokerClient(transport: transport)
    let identity = InvocationGeneration(invocationID: UUID(), generation: UUID())
    let result = await ToolRuntime.execute(
      package(), input: .init(content: "🌲"), client: client, identity: identity)
    XCTAssertEqual(result.output, "ok")
    let sent = await transport.requests
    XCTAssertEqual(sent.count, 1)
    XCTAssertEqual(sent[0].1, .execute)
    XCTAssertEqual(sent[0].0.invocationID, identity.invocationID.uuidString.lowercased())
    XCTAssertEqual(sent[0].0.generation, identity.generation.uuidString.lowercased())
    XCTAssertEqual(String(data: sent[0].0.input, encoding: .utf8), "🌲")
    XCTAssertEqual(String(data: sent[0].0.source, encoding: .utf8), package().source)
  }

  func testValidationUsesTheBrokerRatherThanAnInProcessFallback() async throws {
    let transport = RecordingBroker()
    let client = JavaScriptBrokerClient(transport: transport)
    let result = await ToolRuntime.execute(
      package(), input: .init(content: "captured invocation"), validationOnly: true,
      client: client)
    XCTAssertEqual(result.output, "ok")
    let firstOperations = await transport.requestOperations()
    XCTAssertEqual(firstOperations, [.validateInput])
    let sent = await transport.requests
    XCTAssertEqual(String(data: sent[0].0.input, encoding: .utf8), "captured invocation")
    let emptyInputResult = await ToolRuntime.execute(
      package(), input: .init(content: ""), validationOnly: true, client: client)
    XCTAssertEqual(emptyInputResult.output, "ok")
    try await RuntimePackageValidator(client: client).validatePackage(package())
    let finalOperations = await transport.requestOperations()
    XCTAssertEqual(finalOperations, [.validateInput, .validateInput, .validate])
  }

  func testUnavailableBrokerIsATypedFailure() async {
    let client = JavaScriptBrokerClient(transport: UnavailableJavaScriptBrokerTransport())
    let result = await ToolRuntime.execute(package(), input: .init(content: ""), client: client)
    XCTAssertEqual(result.failure?.code, .unavailable)
    XCTAssertNil(result.output)
  }

  func testCancellationInvalidatesGenerationAtBrokerBoundary() async throws {
    let transport = RecordingBroker()
    await transport.setDelay(.seconds(2))
    let client = JavaScriptBrokerClient(transport: transport)
    let identity = InvocationGeneration(invocationID: UUID(), generation: UUID())
    let package = package()
    let task = Task {
      await ToolRuntime.execute(
        package, input: .init(content: ""), client: client, identity: identity)
    }
    try await Task.sleep(for: .milliseconds(10))
    task.cancel()
    _ = await task.value
    try await Task.sleep(for: .milliseconds(10))
    let cancellationCount = await transport.cancellationCount()
    XCTAssertEqual(cancellationCount, 1)
  }

  func testAdmissionIsCappedAtFourAndFIFO() async throws {
    let admission = JavaScriptAdmissionController()
    let ids = (0..<5).map { _ in UUID() }
    var granted: [UUID] = []
    for id in ids.prefix(4) {
      let acquired = await admission.acquire(id: id)
      XCTAssertTrue(acquired)
      granted.append(id)
    }
    let fifth = Task { await admission.acquire(id: ids[4]) }
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertFalse(fifth.isCancelled)
    await admission.release()
    let fifthAcquired = await fifth.value
    XCTAssertTrue(fifthAcquired)
    XCTAssertEqual(granted.count, 4)
  }

  func testCancelledQueuedAdmissionIsNeverGranted() async throws {
    let admission = JavaScriptAdmissionController(capacity: 1)
    let firstAcquired = await admission.acquire(id: UUID())
    XCTAssertTrue(firstAcquired)

    let cancelledWaiter = Task { await admission.acquire(id: UUID()) }
    try await Task.sleep(for: .milliseconds(10))
    cancelledWaiter.cancel()
    let cancelledAcquired = await cancelledWaiter.value
    XCTAssertFalse(cancelledAcquired)

    let nextWaiter = Task { await admission.acquire(id: UUID()) }
    try await Task.sleep(for: .milliseconds(10))
    await admission.release()
    let nextAcquired = await nextWaiter.value
    XCTAssertTrue(nextAcquired)
  }

  func testBrokerBusyResponseFailsClosedWithoutRetry() async {
    let transport = RecordingBroker()
    await transport.setResponse(
      .init(failure: .init(.busy, message: "Broker capacity is exhausted.")))
    let client = JavaScriptBrokerClient(transport: transport)

    let result = await ToolRuntime.execute(
      package(), input: .init(content: "input"), client: client)

    XCTAssertEqual(result.failure?.code, .busy)
    XCTAssertNil(result.output)
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testBrokerTerminalFailureCodesRemainTypedAndDoNotRetry() async {
    let cases: [ToolFailureCode] = [
      .unavailable, .busy, .launch, .sandboxBootstrap, .cpuLimit, .engineLimit, .crash,
      .timeout, .cancelled, .outputLimit, .protocolError, .malformedResponse, .internalError,
    ]

    for code in cases {
      let transport = RecordingBroker()
      await transport.setResponse(
        .init(failure: .init(code, message: "Bounded \(code.rawValue) failure.")))
      let client = JavaScriptBrokerClient(transport: transport)

      let result = await ToolRuntime.execute(
        package(), input: .init(content: "input"), client: client)

      XCTAssertEqual(result.failure?.code, code, "code: \(code)")
      XCTAssertNil(result.output, "code: \(code)")
      let requestCount = await transport.requestCount()
      XCTAssertEqual(requestCount, 1, "code: \(code)")
    }
  }

  func testDirectWorkerLoopAndStackFailuresAreTypedAndSanitized() async {
    let cases: [(source: String, code: ToolFailureCode)] = [
      ("export default async function() { while (true) {} }", .timeout),
      (
        "function recurse() { return recurse(); } export default async function() { return recurse(); }",
        .implementation
      ),
    ]

    for value in cases {
      let result = await ToolRuntime.testExecute(
        package(source: value.source), input: .init(content: ""), timeout: 0.05)
      XCTAssertEqual(result.failure?.code, value.code, "source: \(value.source)")
      XCTAssertEqual(result.error, "JavaScript failed or exceeded its resource limit.")
      XCTAssertNil(result.output)
    }
  }

  func testDirectWorkerDeniesDynamicEvaluationAndFunctionConstructors() async {
    for expression in [
      "eval('1')", "(0, eval)('1')", "Function('return 1')()",
      "(()=>{}).constructor('return 1')()", "(async()=>{}).constructor('return 1')()",
      "(function*(){}).constructor('return 1')()",
    ] {
      let result = await ToolRuntime.testExecute(
        package(
          source: "export default async function() { return {output: String(\(expression))}; }"),
        input: .init(content: ""))
      XCTAssertNil(result.output, expression)
      XCTAssertNotNil(result.failure, expression)
    }
  }

  func testDirectWorkerHasNoAmbientAuthorityAndRejectsImports() async {
    let ambient = await ToolRuntime.testExecute(
      package(
        source:
          "export default async function() { return {output: [typeof fetch, typeof process, typeof require, typeof std, typeof os, typeof Date, typeof Math.random].join(',')}; }"
      ), input: .init(content: ""))
    XCTAssertEqual(ambient.output, Array(repeating: "undefined", count: 7).joined(separator: ","))

    let imported = await ToolRuntime.testExecute(
      package(source: "export default async function() { return await import('std'); }"),
      input: .init(content: ""))
    XCTAssertNil(imported.output)
    XCTAssertNotNil(imported.failure)
  }

  func testDirectWorkerPreservesUTF8AndEnforcesInputAndOutputByteLimits() async {
    var inputLimited = package()
    inputLimited.manifest.maximumInputBytes = 4
    let exactInput = await ToolRuntime.testExecute(inputLimited, input: .init(content: "🌲"))
    XCTAssertEqual(exactInput.output, "🌲")
    let oversizedInput = await ToolRuntime.testExecute(inputLimited, input: .init(content: "🌲a"))
    XCTAssertEqual(oversizedInput.failure?.code, .invalidInput)

    var outputLimited = package(source: "export default async function() { return {output: '🌲'}; }")
    outputLimited.manifest.maximumOutputBytes = 4
    let exactOutput = await ToolRuntime.testExecute(outputLimited, input: .init(content: ""))
    XCTAssertEqual(exactOutput.output, "🌲")
    outputLimited.source = "export default async function() { return {output: '🌲a'}; }"
    let oversizedOutput = await ToolRuntime.testExecute(outputLimited, input: .init(content: ""))
    XCTAssertEqual(oversizedOutput.failure?.code, .outputLimit)
  }

  func testDirectWorkerCountsAllOutputLineSeparatorsAndCRLFOnce() async {
    for separator in ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
      let codePoints = separator.unicodeScalars.map { String($0.value) }.joined(separator: ",")
      var exact = package(
        source:
          "export default async function() { return {output: 'a' + String.fromCodePoint(\(codePoints)) + 'b'}; }"
      )
      exact.manifest.maximumOutputLines = 2
      let accepted = await ToolRuntime.testExecute(exact, input: .init(content: ""))
      XCTAssertEqual(accepted.output, "a\(separator)b")

      exact.source =
        "export default async function() { return {output: 'a' + String.fromCodePoint(\(codePoints)) + 'b' + String.fromCodePoint(\(codePoints)) + 'c'}; }"
      let rejected = await ToolRuntime.testExecute(exact, input: .init(content: ""))
      XCTAssertEqual(rejected.failure?.code, .outputLimit)
    }
  }

  func testDirectWorkerReturnsOnlyTheFirstDuplicateResolution() async {
    let duplicate = await ToolRuntime.testExecute(
      package(
        source:
          "export default async function() { return new Promise(resolve => { resolve({output:'first'}); resolve({output:'second'}); throw Error('late'); }); }"
      ), input: .init(content: ""))
    XCTAssertEqual(duplicate.output, "first")

    let immutableInput = await ToolRuntime.testExecute(
      package(
        source:
          "export default async function(input) { input.content = 'mutated'; return {output: input.content}; }"
      ), input: .init(content: "original"))
    XCTAssertNil(immutableInput.output)
    XCTAssertNotNil(immutableInput.failure)
  }

  func testConcurrentDirectWorkerCancellationsStayIsolated() async {
    let source =
      "export default async function() { await Promise.resolve(); return {output: 'ok'}; }"
    let value = package(source: source)
    var jobs: [(cancelled: Bool, task: Task<ToolExecutionResult, Never>)] = []
    for index in 0..<16 {
      let task = Task { await ToolRuntime.testExecute(value, input: .init(content: "")) }
      let cancelled = index.isMultiple(of: 2)
      if cancelled { task.cancel() }
      jobs.append((cancelled, task))
    }
    for job in jobs {
      let result = await job.task.value
      if job.cancelled {
        XCTAssertTrue(result.output == "ok" || result.failure?.code == .cancelled)
      } else {
        XCTAssertEqual(result.output, "ok")
      }
    }
  }
}
