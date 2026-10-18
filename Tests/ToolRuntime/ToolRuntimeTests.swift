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
  private func v2Package(_ body: String) -> ToolPackage {
    var value = package(source: "export default async function(input) { " + body + " }")
    value.manifest.schemaVersion = 3
    value.manifest.entryContract = 2
    value.manifest.executor = .javascript
    return value
  }

  func testProtocolTwoCapturesAreDeeplyFrozenAndArgumentsAreJSONPrimitives() async {
    var value = v2Package(
      """
      const values = [input, input.arguments, input.localTime, input.entropy,
        input.analysis, input.analysis.alphabeticalOrder, input.analysis.alphabeticalRanks];
      if (!values.every(Object.isFrozen)) return {error: 'Mutable capture'};
      return {report: typeof input.arguments.count + ':' + typeof input.arguments.separator};
      """)
    value.manifest.arguments = [
      .init(name: "count", type: .integer, label: "Count", defaultValue: .integer(2)),
      .init(name: "separator", type: .string, label: "Separator", defaultValue: .string(" · ")),
    ]
    value.manifest.capturedData = ["localTime", "entropy", "analysis"]
    value.manifest.inputMode = .contextual
    let result = await ToolRuntime.testExecute(value, input: .init(content: "Apple\napple"))
    XCTAssertEqual(result.report, "number:string", result.error ?? "")
    XCTAssertNil(result.output)
  }

  func testProtocolTwoRejectsMixedUnknownGetterAndUndeclaredActionResults() async {
    for body in [
      "return {output:'text', report:'count'};",
      "return {report:'count', extra:true};",
      "return {get output() { while(true) {} }};",
      "return {action:{kind:'file.export',content:input.content}};",
      "return {output:'text',landmark:{line:0,emoji:'📅',extra:1}};",
    ] {
      let result = await ToolRuntime.testExecute(v2Package(body), input: .init(content: "exact"))
      XCTAssertEqual(result.failure?.code, .protocolError, body)
      XCTAssertNil(result.output)
      XCTAssertNil(result.action)
    }
    let legacy = await ToolRuntime.testExecute(
      package(source: "export default async function() { return {report:'count'}; }"),
      input: .init(content: ""))
    XCTAssertEqual(legacy.failure?.code, .protocolError)
  }

  func testProtocolTwoActionIsInertExactContentAndAllowlisted() async {
    var value = v2Package(
      "return {action:{kind:'file.export',content:input.content,filename:'note.md'}};")
    value.manifest.hostActions = ["file.export"]
    let result = await ToolRuntime.testExecute(value, input: .init(content: "# exact\n"))
    XCTAssertEqual(
      result.action, .init(kind: "file.export", content: "# exact\n", filename: "note.md"))
    for body in [
      "return {action:{kind:'file.export',content:'different'}};",
      "return {action:{kind:'file.export',content:input.content,filename:'../note.md'}};",
      "return {action:{kind:'file.export',content:input.content,filename:'folder\\\\note.md'}};",
      "return {action:{kind:'file.export',content:input.content,extra:'value'}};",
    ] {
      value.source = "export default async function(input) { " + body + " }"
      let rejected = await ToolRuntime.testExecute(value, input: .init(content: "exact"))
      XCTAssertEqual(rejected.failure?.code, .protocolError, body)
    }
  }

  func testProtocolTwoCannotChangeValidatorIntrinsicsOrUseToJSONToChangeVariant() async {
    let value = v2Package(
      """
      let denied = 0;
      for (const object of [Object.prototype, String.prototype, Array.prototype, RegExp.prototype]) {
        try { object.untrusted = true; } catch { denied++; }
      }
      if (denied !== 4) return {error:'Mutable validator intrinsics'};
      return {output:'exact', toJSON() { return {action:{kind:'file.export',content:'stolen'}}; }};
      """)
    let result = await ToolRuntime.testExecute(value, input: .init(content: "exact"))
    XCTAssertEqual(result.failure?.code, .protocolError)
  }

  func testProtocolTwoIgnoresInheritedOptionalFieldsWithoutCallingGetters() async {
    let text = await ToolRuntime.testExecute(
      v2Package(
        """
        return Object.assign(Object.create({
          get landmark() { throw Error('Inherited getter must not run'); }
        }), {output:'exact'});
        """), input: .init(content: "exact"))
    XCTAssertEqual(text.output, "exact", text.error ?? "")
    XCTAssertNil(text.landmark)

    var value = v2Package(
      """
      const action = Object.assign(Object.create({
        get filename() { throw Error('Inherited getter must not run'); },
        get minutes() { throw Error('Inherited getter must not run'); }
      }), {kind:'file.export',content:input.content});
      return {action};
      """)
    value.manifest.hostActions = ["file.export"]
    let action = await ToolRuntime.testExecute(value, input: .init(content: "exact"))
    XCTAssertEqual(action.action, .init(kind: "file.export", content: "exact"), action.error ?? "")
  }

  func testProtocolTwoInheritedFieldsCannotSupplyRequiredAuthority() async {
    for body in [
      "return Object.create({output:'inherited'});",
      "return {action:Object.assign(Object.create({kind:'file.export'}),{content:input.content})};",
      "return {action:Object.assign(Object.create({content:input.content}),{kind:'file.export'})};",
      "return {action:Object.assign(Object.create({minutes:1}),{kind:'notification.schedule',content:input.content})};",
      "return {output:'text',landmark:Object.assign(Object.create({line:0}),{emoji:'📅'})};",
      "return {output:'text',landmark:Object.assign(Object.create({emoji:'📅'}),{line:0})};",
    ] {
      var value = v2Package(body)
      value.manifest.hostActions = ["file.export", "notification.schedule"]
      let result = await ToolRuntime.testExecute(value, input: .init(content: "exact"))
      XCTAssertEqual(result.failure?.code, .protocolError, body)
      XCTAssertNil(result.output)
      XCTAssertNil(result.action)
    }
  }

  func testProtocolTwoRegExpUsesInterruptAndTypedArraysUseHeapLimit() async {
    let regexp = await ToolRuntime.testExecute(
      v2Package(
        """
        return {output: String(/^(a+)+$/.test('a'.repeat(30000) + '!'))};
        """), input: .init(content: ""), timeout: 0.05)
    XCTAssertEqual(regexp.failure?.code, .timeout)
    let allocation = await ToolRuntime.testExecute(
      v2Package(
        """
        const bytes = new Uint8Array(20000000); return {output: String(bytes.length)};
        """), input: .init(content: ""))
    XCTAssertNotNil(allocation.failure)
    XCTAssertNil(allocation.output)
  }

  func testProtocolTwoReportsRespectTextLimitsAndJSONExpansionHasIndependentCap() async {
    var value = v2Package("return {report:'🌲a'};")
    value.manifest.maximumOutputBytes = 4
    let report = await ToolRuntime.testExecute(value, input: .init(content: ""))
    XCTAssertEqual(report.failure?.code, .outputLimit)
    value.manifest.maximumOutputBytes = 1_048_576
    value.source = "export default async function() { return {output:'\\t'.repeat(600000)}; }"
    let expansion = await ToolRuntime.testExecute(value, input: .init(content: ""))
    XCTAssertEqual(expansion.failure?.code, .outputLimit)
  }

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

  func testBrokerStatusUsesSafeActionablePublicMessages() {
    let privateDetail = "credential=private worker path=/tmp/secret"
    XCTAssertEqual(
      XPCJavaScriptBrokerTransport.publicFailureMessage(
        for: .unavailable, workerMessage: privateDetail),
      "JavaScript service is unavailable. Restart Jort and try again.")
    XCTAssertEqual(
      XPCJavaScriptBrokerTransport.publicFailureMessage(
        for: .timeout, workerMessage: privateDetail),
      "JavaScript tool timed out. Try again with less input.")
    XCTAssertEqual(
      XPCJavaScriptBrokerTransport.publicFailureMessage(
        for: .cancelled, workerMessage: privateDetail),
      "Cancelled.")
    XCTAssertEqual(
      XPCJavaScriptBrokerTransport.publicFailureMessage(
        for: .implementation, workerMessage: privateDetail),
      "JavaScript tool failed or exceeded its resource limit.")
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
          "export default async function() { return {output: [typeof fetch, typeof process, typeof require, typeof std, typeof os, typeof Date, typeof Math.random, typeof Atomics, typeof SharedArrayBuffer].join(',')}; }"
      ), input: .init(content: ""))
    XCTAssertEqual(ambient.output, Array(repeating: "undefined", count: 9).joined(separator: ","))

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
