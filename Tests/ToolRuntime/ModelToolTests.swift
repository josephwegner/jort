@testable import JortToolRuntime
import JortToolContracts
import XCTest
import SQLite3
@testable import JortSettings

private actor RecordingTransport: OpenRouterTransport {
  var responses: [Result<Data, ModelFailure>]
  var requests: [URLRequest] = []
  init(_ responses: [Result<Data, ModelFailure>]) { self.responses = responses }
  func send(_ request: URLRequest, maximumBytes: Int) throws -> Data {
    requests.append(request)
    guard !responses.isEmpty else { throw ModelFailure.offline }
    let data = try responses.removeFirst().get()
    guard data.count <= maximumBytes else { throw ModelFailure.limit }
    return data
  }
}

final class ModelToolTests: StoreTestCase {
  private func package(mode: ToolInputMode = .contained) -> ToolPackage {
    var manifest = ToolManifest(
      id: "dev.test.model", name: "Model", command: "/model", inputMode: mode)
    manifest.schemaVersion = 2
    manifest.executor = .model
    manifest.modelID = ModelCatalog.defaultModelID
    return .init(manifest: manifest, instructions: "Only transform the provided input.")
  }
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    removeAfterStoresClose(url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func data(_ string: String) -> Data { Data(string.utf8) }
  func testLegacyDecodingAndDiscriminatedImplementation() throws {
    let manifest = ToolManifest(id: "dev.test.legacy", name: "Legacy", command: "/legacy")
    let decoded = try JSONDecoder().decode(ToolManifest.self, from: JSONEncoder().encode(manifest))
    XCTAssertEqual(decoded.executorType, .javascript)
    XCTAssertNoThrow(
      try ToolRuntime.validate(
        .init(
          manifest: decoded,
          source: "export default async function(input) { return {output: input.content}; }")))
    XCTAssertNoThrow(try ToolRuntime.validate(package()))
    XCTAssertEqual(package().source, "")
    XCTAssertThrowsError(
      try ToolPackage(manifest: package().manifest, source: "executable").validate())
    var invalid = package()
    invalid.manifest.schemaVersion = 1
    XCTAssertThrowsError(try invalid.validate())
    invalid = package()
    invalid.implementation = .model(instructions: "\0")
    XCTAssertThrowsError(try invalid.validate())
  }
  func testPackageRoundTripUnknownModelAndConflictingCommands() async throws {
    let directory = try root(),
      registry = ToolPackageRegistry(
        validator: RuntimePackageValidator(),
        bundledDirectory: directory.appendingPathComponent("empty"), installedDirectory: directory)
    var value = package()
    _ = try await registry.save(value)
    let reloaded = try await ToolPackageRegistry(
      validator: RuntimePackageValidator(),
      bundledDirectory: directory.appendingPathComponent("empty"), installedDirectory: directory
    ).inspect()
    XCTAssertEqual(reloaded.executable, [value])
    value.manifest.id = "dev.test.conflict"
    do {
      _ = try await registry.save(value)
      XCTFail()
    } catch { XCTAssertEqual(error as? ToolPackageError, .conflict) }
    value = package()
    value.manifest.modelID = "removed/model"
    let unavailable = try await registry.save(value)
    XCTAssertTrue(unavailable.executable.isEmpty)
    XCTAssertEqual(unavailable.packages.first?.package.manifest.modelID, "removed/model")
  }
  func testModelSettingsPersistenceAndAncestry() async throws {
    let directory = try root(),
      registry = ToolPackageRegistry(
        validator: RuntimePackageValidator(),
        bundledDirectory: directory.appendingPathComponent("empty"),
        installedDirectory: directory.appendingPathComponent("tools"))
    let preferences = ownStore(SQLiteSettingsStore(directory: directory)),
      store = ownStore(PackageSettingsStore(registry: registry, preferences: preferences))
    _ = try await store.load()
    var definition = UserToolDefinition(
      id: ToolID("dev.test.custom"), basedOnTemplateID: ToolID("dev.jort.ask"),
      displayName: "Custom", commandName: "custom", source: "", isEnabled: false)
    definition.manifest = package().manifest
    definition.instructions = package().instructions
    let saved = try await store.save(definition, expectedRevision: nil)
    XCTAssertEqual(saved.customTools.first?.instructions, definition.instructions)
    XCTAssertEqual(saved.customTools.first?.basedOnTemplateID, definition.basedOnTemplateID)
    XCTAssertEqual(saved.customTools.first?.isEnabled, false)
    XCTAssertEqual(saved.customTools.first?.id, definition.id)
    try await store.close()
  }
  func testCatalogBoundsFilteringAndPreservedUnavailableSelection() throws {
    XCTAssertEqual(
      ModelCatalog.bundled.filter("anthropic").map(\.id), ["anthropic/claude-sonnet-4.6"])
    XCTAssertTrue(ModelCatalog.bundled.filter("does not exist").isEmpty)
    XCTAssertEqual(
      try ModelCatalog.decode(JSONEncoder().encode(ModelCatalog.bundled)), ModelCatalog.bundled)
    XCTAssertThrowsError(try ModelCatalog.decode(Data(repeating: 0, count: 65_537)))
    var definition = UserToolDefinition(displayName: "Model", commandName: "model", source: "")
    definition.manifest = package().manifest
    definition.instructions = "Do something"
    XCTAssertTrue(SettingsValidation.diagnostics(for: definition).isEmpty)
    definition.manifest?.modelID = "removed/model"
    XCTAssertTrue(SettingsValidation.diagnostics(for: definition).contains(where: \.isBlocking))
    XCTAssertEqual(definition.manifest?.modelID, "removed/model")
  }
  func testPreflightDoesNotInitializeProviderAndDispatcherCapturesExactInput() async throws {
    let fake = FakeModelProvider(.success("answer"))
    let disconnected = ToolExecutorDispatcher(provider: { fake })
    let warning = await disconnected.validate(package(), input: .init(content: "秘密\ntext"))
    XCTAssertNotNil(warning.error)
    let none = await fake.requests
    XCTAssertTrue(none.isEmpty)
    let connected = ToolExecutorDispatcher(modelAvailable: { true }, provider: { fake })
    let validated = await connected.validate(package(), input: .init(content: "秘密\ntext"))
    XCTAssertNil(validated.error)
    let result = await connected.execute(package(), input: .init(content: "秘密\ntext"))
    XCTAssertEqual(result.output, "answer")
    let captured = await fake.requests
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(captured.first?.content, "秘密\ntext")
    XCTAssertEqual(captured.first?.instructions, package().instructions)
  }
  func testOpenRouterRequestAndMalformedResponseBounds() async throws {
    let transport = RecordingTransport([
      .success(
        data(
          #"{"choices":[{"finish_reason":"stop","message":{"content":"answer","tool_calls":null,"function_call":null}}],"usage":{"completion_tokens":2}}"#
        ))
    ])
    let provider = OpenRouterProvider(
      credentials: MemoryModelCredentialStore("secret"), transport: transport)
    let request = try ModelRequest(package: package(), content: "exact")
    let result = try await provider.execute(request)
    XCTAssertEqual(result, "answer")
    let requests = await transport.requests, http = try XCTUnwrap(requests.first)
    XCTAssertEqual(http.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(http.httpBody)) as? [String: Any])
    XCTAssertEqual(Set(body.keys), Set(["model", "messages", "max_tokens", "stream"]))
    XCTAssertEqual(body["stream"] as? Bool, false)
    XCTAssertEqual((body["messages"] as? [[String: String]])?.last?["content"], "exact")
    for malformed in [
      #"{"choices":[]}"#,
      #"{"choices":[{"finish_reason":"tool_calls","message":{"content":"","tool_calls":[]}}],"usage":{"completion_tokens":1}}"#,
      #"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}],"usage":{"completion_tokens":1}}"#,
    ] {
      XCTAssertThrowsError(try OpenRouterProvider.decode(data(malformed), request: request))
    }
    var limited = package()
    limited.manifest.maximumOutputLines = 1
    limited.manifest.maximumOutputBytes = 12
    let bound = try ModelRequest(package: limited, content: "")
    XCTAssertThrowsError(try bound.validateOutput("a\nb"))
    XCTAssertThrowsError(try bound.validateOutput(String(repeating: "é", count: 7)))
  }
  func testCancellationDropsLateFakeOutput() async throws {
    let fake = FakeModelProvider(.late("late", .seconds(2)))
    let dispatcher = ToolExecutorDispatcher(modelAvailable: { true }, provider: { fake }),
      value = package()
    let task = Task { await dispatcher.execute(value, input: .init(content: "input")) }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    let result = await task.value
    XCTAssertNil(result.output)
    XCTAssertEqual(result.error, ModelFailure.cancelled.message)
  }
  func testPKCECorrelationExpirationAndEntropy() throws {
    let attempt = try PKCEAttempt(), other = try PKCEAttempt()
    XCTAssertEqual(attempt.verifier.count, 43)
    XCTAssertEqual(attempt.challenge.count, 43)
    XCTAssertNotEqual(attempt.verifier, other.verifier)
    XCTAssertNotEqual(attempt.nonce, other.nonce)
    XCTAssertEqual(try attempt.code(from: "/callback/\(attempt.nonce)?code=test"), "test")
    for target in [
      "/callback/wrong?code=test", "/callback/\(attempt.nonce)?code=a&code=b",
      "/callback/\(attempt.nonce)?code=",
    ] {
      XCTAssertThrowsError(try attempt.code(from: target))
    }
    XCTAssertThrowsError(
      try attempt.code(from: "/callback/\(attempt.nonce)?code=test", now: attempt.expiresAt))
    XCTAssertEqual(attempt.authorizationURL(port: 1234).host, "openrouter.ai")
  }
  func testVerifiedReplacementRollbackAndSecretIsolation() async throws {
    let directory = try root(), settings = ownStore(SQLiteSettingsStore(directory: directory))
    _ = try await settings.load()
    let credentials = MemoryModelCredentialStore("old-secret")
    let transport = RecordingTransport([
      .success(data(#"{"key":"new-secret"}"#)), .success(data(#"{"data":{"label":"new-secret"}}"#)),
      .success(data(#"{"key":"bad-secret"}"#)), .failure(.authentication),
    ])
    let connection = OpenRouterConnection(
      credentials: credentials, settings: settings, transport: transport)
    try await connection.exchange(code: "auth-code", attempt: PKCEAttempt())
    let first = await credentials.read()
    XCTAssertEqual(first, "new-secret")
    do {
      try await connection.exchange(code: "auth-code-2", attempt: PKCEAttempt())
      XCTFail()
    } catch {}
    let retained = await credentials.read()
    XCTAssertEqual(retained, "new-secret")
    let snapshot = await settings.currentSnapshot()
    let status = snapshot.preferences["openrouter.connection"] ?? ""
    for secret in ["old-secret", "new-secret", "bad-secret", "auth-code"] {
      XCTAssertFalse(status.contains(secret))
    }
    try await connection.disconnect()
    let removed = await credentials.read()
    XCTAssertNil(removed)
    try await settings.close()
  }
  func testKeychainFaultAndOfflineCheckPreserveCredential() async throws {
    let credentials = MemoryModelCredentialStore("original")
    await credentials.setFailWrites(true)
    let transport = RecordingTransport([
      .success(data(#"{"key":"replacement"}"#)), .success(data(#"{"data":{"label":"label"}}"#)),
      .failure(.offline),
    ])
    let connection = OpenRouterConnection(credentials: credentials, transport: transport)
    do {
      try await connection.exchange(code: "code", attempt: PKCEAttempt())
      XCTFail()
    } catch { XCTAssertEqual(error as? ModelFailure, .credentialStore) }
    let retained = await credentials.read()
    XCTAssertEqual(retained, "original")
    do {
      try await connection.check()
      XCTFail()
    } catch {}
    let status = await connection.currentStatus()
    XCTAssertEqual(status.state, .unableToVerify)
  }
  func testBundledTemplatesContractsAndDuplication() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Jort/Resources/Tools")
    for (name, mode, operation) in [
      ("ask", ToolInputMode.ephemeralMultiline, ToolOutputOperation.insertAtInvocation),
      ("rewrite", .contextual, .replaceContext),
    ] {
      let package = try ToolPackage.load(from: root.appendingPathComponent(name))
      XCTAssertEqual(package.manifest.inputMode, mode)
      XCTAssertEqual(package.manifest.outputOperation, operation)
      XCTAssertEqual(package.manifest.executorType, .model)
      var template = ToolTemplate(
        id: ToolID(package.manifest.id), displayName: name, commandName: name, source: "")
      template.manifest = package.manifest
      template.instructions = package.instructions
      let draft = ToolCatalogBuilder().duplicate(template, avoiding: [name])
      XCTAssertEqual(draft.definition.instructions, package.instructions)
      XCTAssertEqual(draft.definition.basedOnTemplateID, template.id)
    }
  }
}

extension ModelToolTests {
  func testOAuthReplayCancellationAndMalformedExchange() async throws {
    let credentials = MemoryModelCredentialStore("original")
    let transport = RecordingTransport([
      .success(data(#"{"key":"new"}"#)), .success(data(#"{"data":{"label":"label"}}"#)),
      .success(data(#"{"key":null}"#)),
    ])
    let connection = OpenRouterConnection(credentials: credentials, transport: transport),
      attempt = try PKCEAttempt()
    try await connection.exchange(code: "code", attempt: attempt)
    do {
      try await connection.exchange(code: "code", attempt: attempt)
      XCTFail("replayed attempt")
    } catch { XCTAssertEqual(error as? ModelFailure, .authorization) }
    do {
      try await connection.exchange(code: "code", attempt: PKCEAttempt())
      XCTFail("malformed key")
    } catch { XCTAssertEqual(error as? ModelFailure, .malformed) }
    let retained = await credentials.read()
    XCTAssertEqual(retained, "new")
    let task = Task { try await connection.connect(openBrowser: { _ in false }) }
    do {
      try await task.value
      XCTFail()
    } catch {}
    let unchanged = await credentials.read()
    XCTAssertEqual(unchanged, "new")
  }
  func testLoopbackCallbackSuccessAndOneShotConsumption() async throws {
    let callback = try LoopbackOAuthCallback(), attempt = try PKCEAttempt()
    let receiver = Task { try await callback.receive(attempt) }
    let url = URL(
      string: "http://127.0.0.1:\(callback.port)/callback/\(attempt.nonce)?code=bounded-code")!
    let (_, response) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let code = try await receiver.value
    XCTAssertEqual(code, "bounded-code")
    do {
      _ = try await callback.receive(attempt)
      XCTFail()
    } catch { XCTAssertEqual(error as? ModelFailure, .authorization) }
  }
  func testLoopbackCancellationAndExpiredAttempt() async throws {
    let callback = try LoopbackOAuthCallback(), attempt = try PKCEAttempt()
    let receiver = Task { try await callback.receive(attempt) }
    try await Task.sleep(for: .milliseconds(20))
    receiver.cancel()
    do {
      _ = try await receiver.value
      XCTFail()
    } catch {}
    let expired = try LoopbackOAuthCallback()
    do {
      _ = try await expired.receive(PKCEAttempt(now: Date().addingTimeInterval(-200)))
      XCTFail()
    } catch { XCTAssertEqual(error as? ModelFailure, .timeout) }
  }
  func testModelFilteringValidationAndDispatchPerformance() async throws {
    let value = package(), fake = FakeModelProvider(.success("answer"))
    let dispatcher = ToolExecutorDispatcher(modelAvailable: { true }, provider: { fake })
    var filtering: [Double] = [], validation: [Double] = [], dispatch: [Double] = []
    for _ in 0..<100 {
      var start = CFAbsoluteTimeGetCurrent()
      _ = ModelCatalog.bundled.filter("GPT")
      filtering.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
      start = CFAbsoluteTimeGetCurrent()
      _ = try ModelRequest(package: value, content: "input")
      validation.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
      start = CFAbsoluteTimeGetCurrent()
      let result = await dispatcher.execute(value, input: .init(content: "input"))
      dispatch.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
      XCTAssertEqual(result.output, "answer")
    }
    func p95(_ values: [Double]) -> Double { values.sorted()[94] }
    print(
      "PERF Model ms p95: filtering=\(p95(filtering)), validation=\(p95(validation)), dispatch=\(p95(dispatch))"
    )
    XCTAssertLessThan(p95(filtering), 100)
    XCTAssertLessThan(p95(validation), 100)
    XCTAssertLessThan(p95(dispatch), 100)
  }
}

extension ModelToolTests {
  func testCatalogProjectionRetainsModelImplementationAndConflicts() throws {
    var definition = UserToolDefinition(
      id: ToolID("dev.test.model"), displayName: "Model", commandName: "model", source: "",
      isEnabled: true)
    definition.manifest = package().manifest
    definition.instructions = package().instructions
    let builder = ToolCatalogBuilder(), snapshot = SettingsSnapshot(customTools: [definition])
    let projection = builder.executableTools(templates: [], snapshot: snapshot)
    XCTAssertEqual(projection.first?.manifest?.executorType, .model)
    XCTAssertEqual(projection.first?.instructions, package().instructions)
    var other = definition
    other.id = ToolID("dev.test.other")
    XCTAssertTrue(
      builder.executableTools(templates: [], snapshot: .init(customTools: [definition, other]))
        .isEmpty)
  }
  func testUnsupportedOriginIsRejectedBeforeCredentialTransmission() async throws {
    for address in [
      "http://openrouter.ai/api/v1/key", "https://example.com/api/v1/key",
      "https://openrouter.ai:8443/api/v1/key", "https://openrouter.ai/not-an-endpoint",
    ] {
      do {
        _ = try await BoundedOpenRouterTransport().send(
          URLRequest(url: URL(string: address)!), maximumBytes: 1024)
        XCTFail()
      } catch { XCTAssertEqual(error as? ModelFailure, .malformed) }
    }
  }
}

extension ModelToolTests {
  func testSQLiteModelDefinitionRoundTrip() async throws {
    let directory = try root(), store = ownStore(SQLiteSettingsStore(directory: directory))
    _ = try await store.load()
    var definition = UserToolDefinition(
      id: ToolID("dev.test.model"), displayName: "Model", commandName: "model", source: "",
      isEnabled: true)
    definition.manifest = package().manifest
    definition.instructions = package().instructions
    _ = try await store.save(definition, expectedRevision: nil)
    try await store.close()
    let reopened = ownStore(SQLiteSettingsStore(directory: directory)),
      snapshot = try await reopened.load()
    XCTAssertEqual(snapshot.customTools.first?.instructions, definition.instructions)
    XCTAssertEqual(snapshot.customTools.first?.manifest, definition.manifest)
    try await reopened.close()
  }
}

extension ModelToolTests {
  func testSQLiteVersionOneMigrationPreservesLegacySourceIdentityAndAncestry() async throws {
    let directory = try root(), location = directory.appendingPathComponent("Settings")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    var db: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open(location.appendingPathComponent("Settings.sqlite").path, &db), SQLITE_OK)
    let sql = """
      CREATE TABLE settings_meta (id INTEGER PRIMARY KEY, catalog_revision INTEGER NOT NULL);
      INSERT INTO settings_meta VALUES(1,7);
      CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE template_overrides (id TEXT PRIMARY KEY, enabled INTEGER NOT NULL);
      INSERT INTO template_overrides VALUES('dev.jort.calc',0);
      CREATE TABLE custom_tools (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, template_id TEXT, display_name TEXT NOT NULL, command_name TEXT NOT NULL, summary TEXT NOT NULL, source TEXT NOT NULL, enabled INTEGER NOT NULL);
      CREATE UNIQUE INDEX custom_tool_command_name ON custom_tools(command_name COLLATE NOCASE);
      INSERT INTO custom_tools VALUES('dev.test.legacy',3,'dev.jort.calc','Legacy','legacy','Original','export default async function(input) { return {output: input.content}; }',1);
      PRAGMA user_version=1;
      """
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    let store = ownStore(SQLiteSettingsStore(directory: directory)),
      snapshot = try await store.load()
    let definition = try XCTUnwrap(snapshot.customTools.first)
    XCTAssertEqual(definition.id, ToolID("dev.test.legacy"))
    XCTAssertEqual(definition.revision, RecordRevision(3))
    XCTAssertEqual(definition.basedOnTemplateID, ToolID("dev.jort.calc"))
    XCTAssertTrue(definition.isEnabled)
    XCTAssertEqual(
      definition.source, "export default async function(input) { return {output: input.content}; }")
    XCTAssertNil(definition.manifest)
    XCTAssertNil(definition.instructions)
    XCTAssertEqual(snapshot.templateOverrides[ToolID("dev.jort.calc")], false)
    try await store.close()
  }
}
