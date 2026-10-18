@testable import JortToolRuntime
import JortToolContracts
import JortSettings
import XCTest

private actor FlowTransport: OpenRouterTransport {
  var responses: [Result<Data, ModelFailure>]
  private(set) var requests: [URLRequest] = []

  init(_ responses: [Result<Data, ModelFailure>]) { self.responses = responses }

  func send(_ request: URLRequest, maximumBytes: Int) throws -> Data {
    requests.append(request)
    guard !responses.isEmpty else { throw ModelFailure.offline }
    let data = try responses.removeFirst().get()
    guard data.count <= maximumBytes else { throw ModelFailure.limit }
    return data
  }
}

private actor FlowSettings: ModelConnectionSettings {
  private var value: String?
  func readConnectionStatus() -> String? { value }
  func writeConnectionStatus(_ value: String) { self.value = value }
}

private actor CallbackProbe {
  private var request: Task<Int, Error>?
  private var staleRequest: Task<Int, Error>?

  func open(_ authorizationURL: URL, invalidFirst: Bool = false) async -> Bool {
    guard let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false),
      let redirect = components.queryItems?.first(where: { $0.name == "callback_url" })?.value,
      var callback = URLComponents(string: redirect)
    else { return false }
    guard callback.host == "127.0.0.1" else { return false }
    callback.queryItems = [.init(name: "code", value: "test-authorization-code")]
    guard let url = callback.url else { return false }
    if invalidFirst {
      var stale = callback
      stale.path = "/callback/stale"
      guard let staleURL = stale.url else { return false }
      staleRequest = Task.detached {
        let (_, response) = try await URLSession.shared.data(from: staleURL)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    request = Task.detached {
      let (_, response) = try await URLSession.shared.data(from: url)
      return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
    return true
  }

  func responseStatus() async throws -> Int {
    guard let request else { throw ModelFailure.authorization }
    let status = try await request.value
    staleRequest?.cancel()
    return status
  }
}

private actor FaultingCredentialStore: ModelCredentialStore {
  private var credential: String?
  private var mismatchNextRead = false
  private var mismatchAfterWrite: Bool
  private let concurrentReplacementOnMismatch: Bool
  private let failRollback: Bool
  private var holdFirstWrite: Bool
  private var writeStarted = false
  private var writeStartedWaiter: CheckedContinuation<Void, Never>?
  private var writeRelease: CheckedContinuation<Void, Never>?

  init(
    _ credential: String? = nil, mismatchAfterWrite: Bool = false,
    holdFirstWrite: Bool = false, failRollback: Bool = false,
    concurrentReplacementOnMismatch: Bool = false
  ) {
    self.credential = credential
    self.mismatchAfterWrite = mismatchAfterWrite
    self.holdFirstWrite = holdFirstWrite
    self.failRollback = failRollback
    self.concurrentReplacementOnMismatch = concurrentReplacementOnMismatch
  }

  func read() -> String? {
    if mismatchNextRead {
      mismatchNextRead = false
      if concurrentReplacementOnMismatch { credential = "newer-valid-key" }
      return "mismatched-key"
    }
    return credential
  }

  func replace(with credential: String) async throws {
    self.credential = credential
  }

  func replaceIfCurrent(_ expected: String?, with credential: String) async throws -> Bool {
    if holdFirstWrite {
      holdFirstWrite = false
      await withCheckedContinuation { continuation in
        writeRelease = continuation
        writeStarted = true
        writeStartedWaiter?.resume()
        writeStartedWaiter = nil
      }
    }
    guard self.credential == expected else { return false }
    self.credential = credential
    if mismatchAfterWrite {
      mismatchNextRead = true
      mismatchAfterWrite = false
    }
    return true
  }

  func restoreIfCurrent(_ expected: String, with previous: String?) async throws -> Bool {
    if failRollback { throw ModelFailure.credentialStore }
    guard credential == expected else { return false }
    credential = previous
    return true
  }

  func remove() { credential = nil }

  func waitForWrite() async {
    if writeStarted { return }
    await withCheckedContinuation { writeStartedWaiter = $0 }
  }

  func releaseWrite() {
    writeRelease?.resume()
    writeRelease = nil
  }
}

private actor BrowserOpened {
  private var opened = false
  private var continuation: CheckedContinuation<Void, Never>?

  func mark() {
    opened = true
    continuation?.resume()
    continuation = nil
  }

  func wait() async {
    if opened { return }
    await withCheckedContinuation { continuation = $0 }
  }
}

final class OpenRouterConnectionFlowTests: XCTestCase {
  private func data(_ text: String) -> Data { Data(text.utf8) }

  private static func connect(_ connection: OpenRouterConnection, invalidFirst: Bool = false)
    async throws
  {
    let callback = CallbackProbe()
    try await connection.connect(openBrowser: { url in
      await callback.open(url, invalidFirst: invalidFirst)
    })
    let response = try await callback.responseStatus()
    XCTAssertEqual(response, 200)
  }

  func testCallbackExchangeVerificationStorageAndRestart() async throws {
    let credentials = MemoryModelCredentialStore()
    let settings = FlowSettings()
    let transport = FlowTransport([
      .success(data(#"{"key":"test-key"}"#)),
      .success(data(#"{"data":{"label":"test connection"}}"#)),
    ])
    let connection = OpenRouterConnection(
      credentials: credentials, settings: settings, transport: transport)

    try await Self.connect(connection, invalidFirst: true)
    let requests = await transport.requests
    XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v1/auth/keys", "/api/v1/key"])
    XCTAssertEqual(requests.first?.httpMethod, "POST")
    let body = try XCTUnwrap(requests.first?.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
    XCTAssertEqual(payload["code"], "test-authorization-code")
    XCTAssertEqual(payload["code_challenge_method"], "S256")
    XCTAssertNotNil(payload["code_verifier"])
    let storedKey = await credentials.read()
    let connectedStatus = await connection.currentStatus()
    let available = await connection.available()
    XCTAssertEqual(storedKey, "test-key")
    XCTAssertEqual(connectedStatus.state, .connected)
    XCTAssertTrue(available)

    let savedStatus = await settings.readConnectionStatus()
    let saved = try XCTUnwrap(savedStatus)
    XCTAssertFalse(saved.contains("test-key"))
    XCTAssertFalse(saved.contains("test-authorization-code"))
    XCTAssertFalse(saved.contains(try XCTUnwrap(payload["code_verifier"])))
    let restarted = OpenRouterConnection(credentials: credentials, settings: settings)
    let restored = await restarted.currentStatus()
    let restoredAvailability = await restarted.available()
    XCTAssertEqual(restored.state, .connected)
    XCTAssertTrue(restoredAvailability)
  }

  func testExchangeFailureRemainsActionableAfterRestart() async throws {
    let credentials = MemoryModelCredentialStore(), settings = FlowSettings()
    let connection = OpenRouterConnection(
      credentials: credentials, settings: settings,
      transport: FlowTransport([.failure(.authentication)]))

    do {
      try await Self.connect(connection)
      XCTFail("Exchange should fail")
    } catch { XCTAssertEqual(error as? ModelFailure, .authentication) }
    let storedKey = await credentials.read()
    XCTAssertNil(storedKey)
    let status = await connection.currentStatus()
    XCTAssertEqual(status.state, .needsAttention)
    XCTAssertEqual(status.failure, .authentication)
    let restarted = OpenRouterConnection(credentials: credentials, settings: settings)
    let restored = await restarted.currentStatus()
    XCTAssertEqual(restored.state, .needsAttention)
    XCTAssertEqual(restored.failure, .authentication)
  }

  func testFailedCredentialWriteRetainsSafeErrorAndExistingKey() async throws {
    let credentials = MemoryModelCredentialStore("existing-key"), settings = FlowSettings()
    await credentials.setFailWrites(true)
    let connection = OpenRouterConnection(
      credentials: credentials, settings: settings,
      transport: FlowTransport([
        .success(data(#"{"key":"replacement-key"}"#)),
        .success(data(#"{"data":{"label":"replacement"}}"#)),
      ]))

    do {
      try await Self.connect(connection)
      XCTFail("Credential replacement should fail")
    } catch { XCTAssertEqual(error as? ModelFailure, .credentialStore) }
    let storedKey = await credentials.read()
    let available = await connection.available()
    XCTAssertEqual(storedKey, "existing-key")
    XCTAssertTrue(available)
    let status = await connection.currentStatus()
    XCTAssertEqual(status.state, .connected)
    XCTAssertEqual(status.failure, .credentialStore)
    let savedStatus = await settings.readConnectionStatus() ?? ""
    XCTAssertFalse(savedStatus.contains("replacement-key"))

    await credentials.setFailWrites(false)
    try await credentials.remove()
    let missingCredentialStatus = await connection.currentStatus()
    XCTAssertEqual(missingCredentialStatus.state, .needsAttention)
    XCTAssertEqual(missingCredentialStatus.failure, .credentialStore)
  }

  func testReadbackMismatchRestoresWorkingReconnectCredential() async throws {
    let credentials = FaultingCredentialStore("working-key", mismatchAfterWrite: true)
    let connection = OpenRouterConnection(
      credentials: credentials,
      transport: FlowTransport([
        .success(data(#"{"key":"replacement-key"}"#)),
        .success(data(#"{"data":{"label":"replacement"}}"#)),
      ]))

    do {
      try await Self.connect(connection)
      XCTFail("Mismatched readback should reject connection")
    } catch { XCTAssertEqual(error as? ModelFailure, .credentialStore) }
    let retained = await credentials.read()
    let status = await connection.currentStatus()
    XCTAssertEqual(retained, "working-key")
    XCTAssertEqual(status.state, .connected)
    XCTAssertEqual(status.failure, .credentialStore)
  }

  func testFailedRollbackRequiresAttentionWithoutClaimingConnection() async throws {
    let credentials = FaultingCredentialStore(
      "working-key", mismatchAfterWrite: true, failRollback: true)
    let connection = OpenRouterConnection(
      credentials: credentials,
      transport: FlowTransport([
        .success(data(#"{"key":"replacement-key"}"#)),
        .success(data(#"{"data":{"label":"replacement"}}"#)),
      ]))

    do {
      try await Self.connect(connection)
      XCTFail("Failed recovery must not report success")
    } catch { XCTAssertEqual(error as? ModelFailure, .credentialStore) }
    let status = await connection.currentStatus()
    XCTAssertEqual(status.state, .needsAttention)
    XCTAssertEqual(status.failure, .credentialStore)
  }

  func testRollbackDoesNotOverwriteConcurrentCredentialUpdate() async throws {
    let credentials = FaultingCredentialStore(
      "working-key", mismatchAfterWrite: true, concurrentReplacementOnMismatch: true)
    let connection = OpenRouterConnection(
      credentials: credentials,
      transport: FlowTransport([
        .success(data(#"{"key":"replacement-key"}"#)),
        .success(data(#"{"data":{"label":"replacement"}}"#)),
      ]))

    do {
      try await Self.connect(connection)
      XCTFail("A concurrent credential update must not be overwritten")
    } catch { XCTAssertEqual(error as? ModelFailure, .credentialStore) }
    let retained = await credentials.read()
    let status = await connection.currentStatus()
    XCTAssertEqual(retained, "newer-valid-key")
    XCTAssertEqual(status.state, .needsAttention)
    XCTAssertEqual(status.failure, .credentialStore)
  }

  func testConditionalCommitDoesNotOverwriteConcurrentCredentialUpdate() async throws {
    let credentials = FaultingCredentialStore("working-key", holdFirstWrite: true)
    let connection = OpenRouterConnection(
      credentials: credentials,
      transport: FlowTransport([
        .success(data(#"{"key":"replacement-key"}"#)),
        .success(data(#"{"data":{"label":"replacement"}}"#)),
      ]))
    let callback = CallbackProbe()
    let pending = Task {
      try await connection.connect(openBrowser: { url in await callback.open(url) })
    }
    await credentials.waitForWrite()
    try await credentials.replace(with: "newer-valid-key")
    await credentials.releaseWrite()

    do {
      try await pending.value
      XCTFail("A concurrent credential update must not be overwritten")
    } catch { XCTAssertEqual(error as? ModelFailure, .credentialStore) }
    let retained = await credentials.read()
    let status = await connection.currentStatus()
    XCTAssertEqual(retained, "newer-valid-key")
    XCTAssertEqual(status.state, .connected)
    XCTAssertEqual(status.failure, .credentialStore)
  }

  func testCancellationDuringCredentialWriteRestoresPriorState() async throws {
    let credentials = FaultingCredentialStore(holdFirstWrite: true)
    let connection = OpenRouterConnection(
      credentials: credentials,
      transport: FlowTransport([
        .success(data(#"{"key":"new-key"}"#)),
        .success(data(#"{"data":{"label":"new"}}"#)),
      ]))
    let callback = CallbackProbe()
    let pending = Task {
      try await connection.connect(openBrowser: { url in await callback.open(url) })
    }
    await credentials.waitForWrite()
    pending.cancel()
    await credentials.releaseWrite()

    do {
      try await pending.value
      XCTFail("Cancellation during Keychain replacement should roll back")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? ModelFailure) == .cancelled)
    }
    let stored = await credentials.read()
    let status = await connection.currentStatus()
    XCTAssertNil(stored)
    XCTAssertEqual(status.state, .needsAttention)
    XCTAssertEqual(status.failure, .cancelled)
  }

  func testCancellationLeavesNoCredentialAndCanReconnect() async throws {
    let credentials = MemoryModelCredentialStore(), settings = FlowSettings()
    let opened = BrowserOpened()
    let connection = OpenRouterConnection(credentials: credentials, settings: settings)
    let pending = Task {
      try await connection.connect(openBrowser: { _ in
        await opened.mark()
        return true
      })
    }
    await opened.wait()
    pending.cancel()
    do {
      try await pending.value
      XCTFail("Cancelled callback should not connect")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? ModelFailure) == .cancelled)
    }
    let storedKey = await credentials.read()
    let cancelledStatus = await connection.currentStatus()
    XCTAssertNil(storedKey)
    XCTAssertEqual(cancelledStatus.failure, .cancelled)

    let transport = FlowTransport([
      .success(data(#"{"key":"fresh-key"}"#)),
      .success(data(#"{"data":{"label":"fresh"}}"#)),
    ])
    let reconnect = OpenRouterConnection(
      credentials: credentials, settings: settings, transport: transport)
    try await Self.connect(reconnect)
    let reconnectedStatus = await reconnect.currentStatus()
    XCTAssertEqual(reconnectedStatus.state, .connected)
    XCTAssertNil(reconnectedStatus.failure)
  }

  func testStaleCallbackCannotConsumeCurrentAttempt() async throws {
    let callback = try LoopbackOAuthCallback(), attempt = try PKCEAttempt()
    let receiver = Task { try await callback.receive(attempt) }
    var stale = URLRequest(
      url: URL(string: "http://127.0.0.1:\(callback.port)/callback/stale?code=ignored")!)
    stale.timeoutInterval = 2
    do {
      let (_, response) = try await URLSession.shared.data(for: stale)
      XCTAssertNotEqual((response as? HTTPURLResponse)?.statusCode, 200)
    } catch {}

    let valid = URL(
      string: "http://127.0.0.1:\(callback.port)/callback/\(attempt.nonce)?code=valid")!
    let (_, response) = try await URLSession.shared.data(from: valid)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let code = try await receiver.value
    XCTAssertEqual(code, "valid")
  }

  func testSavedCredentialReconcilesMissingStatusOnRestart() async {
    let credentials = MemoryModelCredentialStore("saved-key")
    let connection = OpenRouterConnection(credentials: credentials, settings: FlowSettings())
    let status = await connection.currentStatus()
    XCTAssertEqual(status.state, .connected)
    let available = await connection.available()
    XCTAssertTrue(available)
  }
}
