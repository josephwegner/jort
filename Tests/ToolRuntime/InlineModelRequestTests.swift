@testable import JortToolRuntime
import JortToolContracts
import XCTest
@testable import JortSettings

private actor InlineRequestTransport: OpenRouterTransport {
  private(set) var requests: [URLRequest] = []
  func send(_ request: URLRequest, maximumBytes: Int) throws -> Data {
    requests.append(request)
    return Data(
      #"{"choices":[{"finish_reason":"stop","message":{"content":"ok"}}],"usage":{"completion_tokens":1}}"#
        .utf8)
  }
}

final class InlineModelRequestTests: XCTestCase {
  private func package(executor: ToolExecutor = .model) -> ToolPackage {
    var manifest = ToolManifest(id: "dev.test.inline", name: "Inline", command: "/inline")
    manifest.schemaVersion = 2
    manifest.executor = executor
    if executor == .javascript {
      return .init(
        manifest: manifest,
        source: "export default async function(input) { return {output: input.content}; }")
    }
    manifest.modelID = ModelCatalog.defaultModelID
    return .init(manifest: manifest, instructions: "Follow the package instructions.")
  }

  func testInstructionIsIndependentFromContextAndAvailableWithoutArguments() async throws {
    let provider = FakeModelProvider(.success("ok"))
    let dispatcher = ToolExecutorDispatcher(modelAvailable: { true }, provider: { provider })
    let input = ToolExecutionInput(content: "captured context", instruction: "Rewrite this gently.")
    let result = await dispatcher.execute(package(), input: input)

    XCTAssertEqual(result.output, "ok")
    let requests = await provider.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.content, "captured context")
    XCTAssertEqual(request.instruction, "Rewrite this gently.")
    XCTAssertEqual(request.instructions, package().instructions)
  }

  func testPreparedInputAndWithArgumentsPreserveInstruction() throws {
    var value = package()
    value.manifest.entryContract = 2
    value.manifest.capturedData = []
    let original = ToolExecutionInput(content: "ctx", instruction: "do this")
    let prepared = try ToolExecutorDispatcher.prepareInput(original, for: value.manifest)
    XCTAssertEqual(prepared.instruction, "do this")
    XCTAssertEqual(prepared.withArguments(["x": .string("y")]).instruction, "do this")
    XCTAssertNil(original.withInstruction(nil).instruction)
  }

  func testInstructionBoundsNULAndJavaScriptBoundary() throws {
    let identity = InvocationGeneration(invocationID: UUID(), generation: UUID())
    XCTAssertNoThrow(
      try ToolExecutionRequest(
        identity: identity, package: package(),
        input: .init(content: "ctx", instruction: String(repeating: "a", count: 16_384))))
    for bad in [String(repeating: "é", count: 8_193), "bad\0request"] {
      XCTAssertThrowsError(
        try ToolExecutionRequest(
          identity: identity, package: package(), input: .init(content: "ctx", instruction: bad)))
    }
    XCTAssertThrowsError(
      try ToolExecutionRequest(
        identity: identity, package: package(executor: .javascript),
        input: .init(content: "ctx", instruction: "must not cross to JavaScript")))
  }

  func testCapturedRequestRetainsInstructionAndCancellationIsReported() async throws {
    let value = package()
    let request = try ToolExecutionRequest(
      identity: .init(invocationID: UUID(), generation: UUID()), package: value,
      input: .init(content: "context", instruction: "explicit request"))
    XCTAssertEqual(request.input.instruction, "explicit request")

    let provider = FakeModelProvider(.late("late", .seconds(2)))
    let dispatcher = ToolExecutorDispatcher(modelAvailable: { true }, provider: { provider })
    let task = Task { await dispatcher.execute(value, input: request.input) }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    let result = await task.value
    XCTAssertEqual(result.failure?.code, .cancelled)
  }

  func testOpenRouterSeparatesExplicitRequestAndPreservesLegacyPayload() async throws {
    let transport = InlineRequestTransport()
    let provider = OpenRouterProvider(
      credentials: MemoryModelCredentialStore("key"), transport: transport)
    try await provider.execute(ModelRequest(package: package(), content: "legacy context"))
    try await provider.execute(
      ModelRequest(
        package: package(), content: "captured context", instruction: "explicit request"))

    let requests = await transport.requests
    let firstBody = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
    let firstMessages = try XCTUnwrap(firstBody["messages"] as? [[String: String]])
    XCTAssertEqual(firstMessages[0]["content"], package().instructions)
    XCTAssertEqual(firstMessages[1]["content"], "legacy context")
    let secondBody = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: XCTUnwrap(requests[1].httpBody)) as? [String: Any])
    let secondMessages = try XCTUnwrap(secondBody["messages"] as? [[String: String]])
    XCTAssertEqual(secondMessages[0]["content"], package().instructions)
    XCTAssertEqual(
      secondMessages[1]["content"],
      "Explicit request:\nexplicit request\n\nContext:\ncaptured context")
  }
}
