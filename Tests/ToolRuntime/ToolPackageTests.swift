@testable import JortToolRuntime
import JortToolContracts
import XCTest
@testable import JortSettings

final class ToolPackageTests: StoreTestCase {
  private var bundled: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Jort/Resources/Tools")
  }
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JortPackageTests-\(UUID())")
    removeAfterStoresClose(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  private func write(_ package: ToolPackage, named name: String, to root: URL) throws -> URL {
    let directory = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(package.manifest).write(
      to: directory.appendingPathComponent("tool.json"))
    try Data(package.source.utf8).write(to: directory.appendingPathComponent("tool.js"))
    return directory
  }
  private func writeIndex(installed: URL, entries: [String: String], disabled: Set<String> = [])
    throws
  {
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    let value: [String: Any] = [
      "schemaVersion": 1, "installed": entries, "disabled": Array(disabled),
    ]
    try JSONSerialization.data(withJSONObject: value).write(
      to: installed.appendingPathComponent("index.json"))
  }
  func testManifestRejectsContractsPathsAndIncompatibleModes() throws {
    var manifest = ToolManifest(id: "dev.jort.test", name: "Test", command: "/test")
    XCTAssertNoThrow(try manifest.validate())
    manifest.id = "../escape"
    XCTAssertThrowsError(try manifest.validate())
    manifest.id = "dev.jort.test"
    manifest.entryContract = 2
    XCTAssertThrowsError(try manifest.validate())
    manifest.entryContract = 1
    manifest.outputOperation = .replaceContext
    XCTAssertThrowsError(try manifest.validate())
    manifest.inputMode = .contextual
    XCTAssertNoThrow(try manifest.validate())
    manifest.maximumOutputBytes = Int.max
    XCTAssertThrowsError(try manifest.validate())
  }
  func testRegistryOverrideUpdateDisableRestoreAndRelaunch() async throws {
    let installed = try root()
    let registry = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: installed
    )
    let initial = try await registry.inspect()
    XCTAssertEqual(initial.executable.count, 8)
    var edited = try XCTUnwrap(initial.executable.first { $0.manifest.command == "/calc" })
    edited.source = "export default async function() { return {output: 'custom'}; }"
    var snapshot = try await registry.save(edited)
    XCTAssertTrue(try XCTUnwrap(snapshot.packages.first { $0.id == edited.manifest.id }).isOverride)
    snapshot = try await registry.setEnabled(id: edited.manifest.id, enabled: false)
    XCTAssertEqual(snapshot.executable.count, 7)
    let reopened = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: installed
    )
    snapshot = try await reopened.inspect()
    XCTAssertEqual(snapshot.executable.count, 7)
    XCTAssertEqual(
      snapshot.packages.first { $0.id == edited.manifest.id }?.package.source, edited.source)
    snapshot = try await reopened.restore(id: edited.manifest.id)
    XCTAssertEqual(snapshot.executable.count, 8)
    XCTAssertNotEqual(
      snapshot.packages.first { $0.id == edited.manifest.id }?.package.source, edited.source)
  }
  func testInvalidInstallDoesNotAffectRegistryAndConflictIsRejected() async throws {
    let registry = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled,
      installedDirectory: try root())
    let original = try await registry.inspect()
    let bad = ToolPackage(
      manifest: .init(id: "org.user.test", name: "Test", command: "/calc"),
      source: "export default async function() {}")
    do {
      _ = try await registry.save(bad)
      XCTFail("Expected conflict")
    } catch { XCTAssertEqual(error as? ToolPackageError, .conflict) }
    var invalid = bad
    invalid.manifest.command = "/custom"
    invalid.source = "export default !!!"
    do {
      _ = try await registry.save(invalid)
      XCTFail("Expected invalid source")
    } catch {}
    let after = try await registry.inspect()
    XCTAssertEqual(original, after)
  }
  func testMalformedBundleIsolationAndSymlinkRejection() async throws {
    let directory = try root()
    let bad = directory.appendingPathComponent("broken")
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: bundled.appendingPathComponent("calc"), to: directory.appendingPathComponent("calc"))
    let registry = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: directory,
      installedDirectory: try root())
    let snapshot = try await registry.inspect()
    XCTAssertEqual(snapshot.executable.count, 1)
    XCTAssertEqual(snapshot.diagnostics.count, 1)
    let invalid = try XCTUnwrap(snapshot.candidates.first { $0.validation == .invalid })
    XCTAssertNil(invalid.packageID)
    XCTAssertEqual(invalid.origin, .bundled)
    XCTAssertTrue(invalid.isEnabled)
    XCTAssertLessThanOrEqual(try XCTUnwrap(invalid.diagnostic).count, 256)
    let symlink = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(
      at: symlink, withDestinationURL: bundled.appendingPathComponent("calc"))
    XCTAssertThrowsError(try ToolPackage.load(from: symlink))
  }
  func testBundledCalculatorGrammarAndFailures() async throws {
    let package = try ToolPackage.load(from: bundled.appendingPathComponent("calc"))
    for (input, expected) in [
      ("3+3", "6"), ("2^3^2", "512"), ("-2^2", "-4"), ("(-2)^2", "4"), ("2^-2", "0.25"),
      (".5 + 2 * (3 - 1)", "4.5"), ("5%2", "1"),
    ] {
      let result = await ToolRuntime.execute(package, input: .init(content: input))
      XCTAssertEqual(result.output, expected, input)
    }
    for input in [
      "", "1/0", "1%0", "2***3", "2(3)", "1e3", "2^99999", "1+",
      String(repeating: "-", count: 1000) + "1",
    ] {
      let result = await ToolRuntime.execute(package, input: .init(content: input))
      XCTAssertNotNil(result.error, input)
    }
  }
  func testBundledExactLinesClockUUIDAndEmptyOutput() async throws {
    for (name, input, expected) in [
      ("sort", "b\na\nb\n", "a\nb\nb\n"), ("sort", "🌲\nA\na", "A\na\n🌲"),
      ("dedupe", "a\n\na\n\nb\n", "a\n\nb\n"), ("dedupe", "", ""),
      ("date", " ", "1970-01-01 "), ("time", "", "00:00:00Z"),
      ("date", " next\nline", "1970-01-01 next\nline"), ("time", " reminder", "00:00:00Z reminder"),
      ("uuid", " apples", "00000000-0000-0000-0000-000000000001 apples"),
      ("uuid", "", "00000000-0000-0000-0000-000000000001"),
    ] {
      let package = try ToolPackage.load(from: bundled.appendingPathComponent(name))
      let result = await ToolRuntime.execute(
        package,
        input: .init(
          content: input, date: Date(timeIntervalSince1970: 0),
          uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
      XCTAssertEqual(result.output, expected, name)
    }
  }

  func testSettingsUsesRegistryForEditableOverridesAndConflicts() async throws {
    let directory = try root()
    let registry = ToolPackageRegistry(
      validator: RuntimePackageValidator(),
      bundledDirectory: bundled, installedDirectory: directory.appendingPathComponent("Tools"))
    let store = ownStore(
      PackageSettingsStore(
        registry: registry, preferences: ownStore(SQLiteSettingsStore(directory: directory))))
    _ = try await store.load()
    let catalog = try await registry.inspect()
    let original = try XCTUnwrap(catalog.executable.first { $0.manifest.command == "/calc" })
    var definition = UserToolDefinition(
      id: ToolID(original.manifest.id), displayName: "My Calculator", commandName: "calc",
      source: "export default async function(input) { return {output: input.content}; }",
      isEnabled: true)
    definition.manifest = original.manifest
    var snapshot = try await store.save(definition, expectedRevision: nil)
    definition = try XCTUnwrap(snapshot.customTools.first)
    XCTAssertEqual(definition.basedOnTemplateID, definition.id)
    definition.manifest?.inputMode = .ephemeralMultiline
    definition.manifest?.outputOperation = .insertAtInvocation
    snapshot = try await store.save(definition, expectedRevision: definition.revision)
    let edited = try XCTUnwrap(snapshot.customTools.first)
    XCTAssertEqual(edited.manifest?.inputMode, .ephemeralMultiline)
    XCTAssertEqual(edited.revision, RecordRevision(2))
    do {
      _ = try await store.save(definition, expectedRevision: definition.revision)
      XCTFail("Expected conflict")
    } catch {}
    let executable = try await registry.inspect().executable
    XCTAssertEqual(
      executable.first { $0.manifest.id == original.manifest.id }?.manifest, edited.manifest)
    snapshot = try await store.delete(id: edited.id, expectedRevision: edited.revision)
    XCTAssertTrue(snapshot.customTools.isEmpty)
    let restored = try await registry.inspect().executable
    XCTAssertEqual(restored.first { $0.manifest.id == original.manifest.id }, original)
    try await store.close()
  }

  func testLegacySettingsScriptsRemainEditableUntilExplicitMigration() async throws {
    let directory = try root()
    let preferences = ownStore(SQLiteSettingsStore(directory: directory))
    _ = try await preferences.load()
    let legacy = UserToolDefinition(
      id: ToolID("legacy-uuid"), displayName: "Legacy", commandName: "legacy",
      source: "return input;", isEnabled: true)
    _ = try await preferences.save(legacy, expectedRevision: nil)
    let registry = ToolPackageRegistry(
      validator: RuntimePackageValidator(),
      bundledDirectory: bundled, installedDirectory: directory.appendingPathComponent("Tools"))
    let store = ownStore(PackageSettingsStore(registry: registry, preferences: preferences))
    let snapshot = try await store.load()
    var editable = try XCTUnwrap(snapshot.customTools.first)
    XCTAssertEqual(editable.source, legacy.source)
    XCTAssertTrue(editable.id.rawValue.hasPrefix("user.jort.legacy-"))
    let before = try await registry.inspect()
    XCTAssertFalse(before.executable.contains { $0.manifest.command == "/legacy" })
    editable.source = "export default async function(input) { return {output: input.content}; }"
    _ = try await store.save(editable, expectedRevision: editable.revision)
    let after = try await registry.inspect()
    XCTAssertTrue(after.executable.contains { $0.manifest.command == "/legacy" })
    let persisted = try await preferences.load()
    XCTAssertTrue(persisted.customTools.isEmpty)
    try await store.close()
  }

  func testPackageDiscoveryValidationAndRuntimeStartupDistributions() async throws {
    let installed = try root()
    let package = try ToolPackage.load(from: bundled.appendingPathComponent("calc"))
    var discovery: [Double] = [], validation: [Double] = [], startup: [Double] = []
    func clock() -> Double { ProcessInfo.processInfo.systemUptime }
    for _ in 0..<12 {
      var start = clock()
      let registry = ToolPackageRegistry(
        validator: RuntimePackageValidator(), bundledDirectory: bundled,
        installedDirectory: installed)
      let snapshot = try await registry.inspect()
      XCTAssertEqual(snapshot.executable.count, 8)
      discovery.append(clock() - start)
      start = clock()
      try ToolRuntime.validate(package)
      validation.append(clock() - start)
      start = clock()
      let result = await ToolRuntime.execute(package, input: .init(content: "3+3"))
      startup.append(clock() - start)
      XCTAssertEqual(result.output, "6")
    }
    func p95(_ values: [Double]) -> Double {
      values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] * 1000
    }
    print(
      "PERF Tools ms p95: discovery=\(p95(discovery)), validation=\(p95(validation)), host-startup+calc=\(p95(startup))"
    )
  }

  func testBundledUpgradeAndInvalidOverridePreserveUserFiles() async throws {
    let shipped = try root(), installed = try root()
    let calc = shipped.appendingPathComponent("calc")
    try FileManager.default.copyItem(at: bundled.appendingPathComponent("calc"), to: calc)
    let registry = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: shipped, installedDirectory: installed
    )
    let initial = try await registry.inspect()
    var user = try XCTUnwrap(initial.executable.first)
    user.source = "export default async function() { return {output:'custom'}; }"
    _ = try await registry.save(user)
    var upgraded = try ToolPackage.load(from: calc)
    upgraded.manifest.version = 2
    try JSONEncoder().encode(upgraded.manifest).write(
      to: calc.appendingPathComponent("tool.json"), options: .atomic)
    try await registry.reload()
    let preserved = try await registry.inspect()
    XCTAssertEqual(preserved.executable.first, user)
    let index = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: installed.appendingPathComponent("index.json"))) as? [String: Any])
    let generations = try XCTUnwrap(index["installed"] as? [String: [String: Any]])
    let source = installed.appendingPathComponent(
      try XCTUnwrap(generations[user.manifest.id]?["current"] as? String)
    )
    .appendingPathComponent("tool.js")
    try Data("broken script !!!".utf8).write(to: source, options: .atomic)
    try await registry.reload()
    let isolated = try await registry.inspect()
    XCTAssertEqual(isolated.executable.first, upgraded)
    let invalid = try XCTUnwrap(isolated.candidates.first { $0.origin == .installed })
    XCTAssertEqual(invalid.packageID, user.manifest.id)
    XCTAssertTrue(invalid.isOverride)
    XCTAssertEqual(invalid.validation, .invalid)
    XCTAssertTrue(invalid.isEnabled)
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "broken script !!!")
    _ = try await registry.restore(id: user.manifest.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  func testInspectionIdentifiesMalformedKnownAndUnknownBundles() async throws {
    let shipped = try root(), installed = try root()
    let known = shipped.appendingPathComponent("known"),
      unknown = shipped.appendingPathComponent("unknown")
    try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
    try Data(#"{"id":"org.test.known"}"#.utf8).write(to: known.appendingPathComponent("tool.json"))
    try Data("source".utf8).write(to: known.appendingPathComponent("tool.js"))
    try Data("not json".utf8).write(to: unknown.appendingPathComponent("tool.json"))
    try Data("source".utf8).write(to: unknown.appendingPathComponent("tool.js"))
    let snapshot = try await ToolPackageRegistry(
      validator: RuntimePackageValidator(),
      bundledDirectory: shipped, installedDirectory: installed
    ).inspect()
    XCTAssertTrue(snapshot.packages.isEmpty)
    XCTAssertTrue(snapshot.executable.isEmpty)
    XCTAssertEqual(snapshot.candidates.count, 2)
    XCTAssertEqual(snapshot.candidates.first { $0.packageID != nil }?.packageID, "org.test.known")
    XCTAssertNotNil(snapshot.candidates.first { $0.packageID == nil })
    XCTAssertTrue(
      snapshot.candidates.allSatisfy {
        $0.validation == .invalid && $0.isEnabled && $0.diagnostic != nil
      })
  }

  func testDuplicateBundledIDsExposeConflictingCandidates() async throws {
    let shipped = try root(), installed = try root()
    let package = try ToolPackage.load(from: bundled.appendingPathComponent("calc"))
    _ = try write(package, named: "first", to: shipped)
    _ = try write(package, named: "second", to: shipped)
    let snapshot = try await ToolPackageRegistry(
      validator: RuntimePackageValidator(),
      bundledDirectory: shipped, installedDirectory: installed
    ).inspect()
    XCTAssertTrue(snapshot.packages.isEmpty)
    XCTAssertTrue(snapshot.executable.isEmpty)
    XCTAssertEqual(
      snapshot.candidates.map(\.packageID), [package.manifest.id, package.manifest.id])
    XCTAssertTrue(
      snapshot.candidates.allSatisfy {
        $0.origin == .bundled && $0.validation == .conflicting && $0.isEnabled
      })
    XCTAssertEqual(snapshot.diagnostics, ["Duplicate bundled ID: \(package.manifest.id)"])
  }

  func testCommandConflictIncludesDisabledCandidateAndPreservesExecutableProjection() async throws {
    let shipped = try root(), installed = try root()
    let first = try ToolPackage.load(from: bundled.appendingPathComponent("calc"))
    var second = first
    second.manifest.id = "org.test.second"
    second.manifest.name = "Second"
    _ = try write(first, named: "first", to: shipped)
    _ = try write(second, named: "second", to: shipped)
    let unrelated = ToolPackage(
      manifest: .init(id: "org.test.unrelated", name: "Unrelated", command: "/other"),
      source: first.source)
    _ = try write(unrelated, named: "unrelated", to: shipped)
    try writeIndex(installed: installed, entries: [:], disabled: [second.manifest.id])
    let snapshot = try await ToolPackageRegistry(
      validator: RuntimePackageValidator(),
      bundledDirectory: shipped, installedDirectory: installed
    ).inspect()
    XCTAssertEqual(snapshot.packages.map(\.id), [unrelated.manifest.id])
    XCTAssertEqual(snapshot.executable, snapshot.packages.filter(\.isEnabled).map(\.package))
    let conflicts = snapshot.candidates.filter { $0.validation == .conflicting }
    XCTAssertEqual(Set(conflicts.compactMap(\.packageID)), [first.manifest.id, second.manifest.id])
    XCTAssertEqual(conflicts.first { $0.packageID == first.manifest.id }?.isEnabled, true)
    XCTAssertEqual(conflicts.first { $0.packageID == second.manifest.id }?.isEnabled, false)
  }
}

extension ToolPackageTests {
  private func custom(_ version: Int = 1) -> ToolPackage {
    ToolPackage(
      manifest: .init(
        id: "org.test.history", version: version, name: "History", command: "/history"),
      source: "export default async function() { return {output:'\(version)'}; }")
  }
  private func indexObject(_ root: URL) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("index.json"))) as? [String: Any])
  }
  private func generationNames(_ root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
      UUID(uuidString: $0) != nil
    }
  }
  func testRetainsNewestFiveAndDeletesOnlyAfterCatalogRemoval() async throws {
    let directory = try root()
    let registry = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    )
    var published: [String] = []
    for version in 1...9 {
      let state = try await registry.save(custom(version))
      XCTAssertEqual(
        state.executable.first { $0.manifest.id == custom().manifest.id }, custom(version))
      let installed = try XCTUnwrap(indexObject(directory)["installed"] as? [String: [String: Any]])
      let entry = try XCTUnwrap(installed[custom().manifest.id])
      XCTAssertEqual(entry["previous"] as? [String], Array(published.reversed().prefix(5)))
      published.append(try XCTUnwrap(entry["current"] as? String))
      XCTAssertEqual(try generationNames(directory).count, min(version, 6))
    }
    _ = try await registry.remove(id: custom().manifest.id)
    XCTAssertTrue(try generationNames(directory).isEmpty)
    let reopened = try await ToolPackageRegistry(
      validator: RuntimePackageValidator(),
      bundledDirectory: bundled, installedDirectory: directory
    ).inspect()
    XCTAssertFalse(reopened.executable.contains { $0.manifest.id == custom().manifest.id })
  }
  func testEveryPublicationBoundaryPreservesCompleteAuthority() async throws {
    enum Injected: Error { case failure }
    for stage in ToolPublicationStage.allCases where stage != .cleanup {
      let directory = try root()
      let initial = ToolPackageRegistry(
        validator: RuntimePackageValidator(), bundledDirectory: bundled,
        installedDirectory: directory)
      _ = try await initial.save(custom())
      let oldIndex = try Data(contentsOf: directory.appendingPathComponent("index.json"))
      let registry = ToolPackageRegistry(
        validator: RuntimePackageValidator(), bundledDirectory: bundled,
        installedDirectory: directory
      ) {
        if $0 == stage { throw Injected.failure }
      }
      _ = try await registry.inspect()
      let uncertain = stage == .indexDirectorySync || stage == .memoryPublication
      do {
        _ = try await registry.save(custom(2))
        XCTFail("Expected failure at \(stage)")
      } catch { if uncertain { XCTAssertEqual(error as? ToolPublicationError, .uncertain) } }
      let memory = try await registry.inspect()
      XCTAssertEqual(
        memory.executable.first { $0.manifest.id == custom().manifest.id },
        custom(uncertain ? 2 : 1), stage.rawValue)
      if !uncertain {
        XCTAssertEqual(
          try Data(contentsOf: directory.appendingPathComponent("index.json")), oldIndex)
      }
      let reopened = try await ToolPackageRegistry(
        validator: RuntimePackageValidator(),
        bundledDirectory: bundled, installedDirectory: directory
      ).inspect()
      XCTAssertEqual(
        reopened.executable.first { $0.manifest.id == custom().manifest.id },
        custom(uncertain ? 2 : 1))
      if uncertain {
        let hold = try XCTUnwrap(
          FileManager.default.contentsOfDirectory(atPath: directory.path).first {
            $0.hasPrefix("Recovery-")
          })
        XCTAssertEqual(
          try Data(contentsOf: directory.appendingPathComponent(hold + "/prior-index.json")),
          oldIndex)
        XCTAssertTrue(
          FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(hold + "/attempted-index.json").path))
        XCTAssertEqual(try generationNames(directory).count, 2)
        XCTAssertTrue(reopened.diagnostics.contains { $0.contains("recovery") })
      }
    }
  }
  func testMigrationImportsOnlyProvenCurrentAndKeepsBackupUntilReopen() async throws {
    let directory = try root(), current = UUID().uuidString, orphan = UUID().uuidString
    _ = try write(custom(), named: current, to: directory)
    _ = try write(custom(2), named: orphan, to: directory)
    try writeIndex(installed: directory, entries: [custom().manifest.id: current])
    let before = try Data(contentsOf: directory.appendingPathComponent("index.json"))
    _ = try await ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    )
    .inspect()
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent("index.pre-v2.json")), before)
    let object = try indexObject(directory)
    XCTAssertEqual(object["schemaVersion"] as? Int, 2)
    let entry = try XCTUnwrap(
      (object["installed"] as? [String: [String: Any]])?[custom().manifest.id])
    XCTAssertEqual(entry["previous"] as? [String], [])
    XCTAssertEqual(try generationNames(directory), [current])
    _ = try await ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    )
    .inspect()
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("index.pre-v2.json").path))
  }
  func testUntrustedIndexesPreserveAllFiles() async throws {
    let generation = UUID().uuidString
    let entry: [String: Any] = ["current": generation, "previous": []]
    let invalid: [[String: Any]] = [
      ["schemaVersion": 99, "installed": [:], "disabled": []],
      [
        "schemaVersion": 2, "installed": ["org.test.a": entry, "org.test.b": entry], "disabled": [],
      ],
      [
        "schemaVersion": 2,
        "installed": [
          "org.test.a": ["current": generation, "previous": (0..<6).map { _ in UUID().uuidString }]
        ], "disabled": [],
      ],
      [
        "schemaVersion": 2,
        "installed": ["org.test.a": ["current": generation, "previous": ["../escape"]]],
        "disabled": [],
      ],
      ["schemaVersion": 1, "installed": ["org.test.a": UUID().uuidString], "disabled": []],
    ]
    var fixtures = try invalid.map { try JSONSerialization.data(withJSONObject: $0) }
    fixtures.append(Data("broken json".utf8))
    for fixture in fixtures {
      let directory = try root()
      _ = try write(custom(), named: generation, to: directory)
      let stage = ".staging-" + UUID().uuidString.lowercased()
      _ = try write(custom(), named: stage, to: directory)
      try fixture.write(to: directory.appendingPathComponent("index.json"))
      do {
        _ = try await ToolPackageRegistry(
          validator: RuntimePackageValidator(), bundledDirectory: bundled,
          installedDirectory: directory
        )
        .inspect()
        XCTFail("Expected invalid index")
      } catch {}
      XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), fixture)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(stage).path))
      XCTAssertEqual(try generationNames(directory), [generation])
    }
  }
  func testInvalidCurrentDoesNotPromoteHistoryAndCleanupPreservesLinks() async throws {
    let directory = try root(), outside = try root()
    let current = UUID().uuidString, previous = UUID().uuidString
    _ = try write(custom(), named: previous, to: directory)
    let object: [String: Any] = [
      "schemaVersion": 2,
      "installed": [custom().manifest.id: ["current": current, "previous": [previous]]],
      "disabled": [],
    ]
    try JSONSerialization.data(withJSONObject: object).write(
      to: directory.appendingPathComponent("index.json"))
    let link = UUID().uuidString, nested = UUID().uuidString, orphan = UUID().uuidString
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent(link), withDestinationURL: outside)
    let nestedURL = try write(custom(), named: nested, to: directory)
    try FileManager.default.createSymbolicLink(
      at: nestedURL.appendingPathComponent("tool.js.link"), withDestinationURL: outside)
    _ = try write(custom(), named: orphan, to: directory)
    _ = try write(custom(), named: "unexpected", to: directory)
    _ = try write(custom(), named: ".staging-" + UUID().uuidString.lowercased(), to: directory)
    let registry = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    )
    let state = try await registry.inspect()
    XCTAssertFalse(state.executable.contains { $0.manifest.id == custom().manifest.id })
    XCTAssertTrue(
      state.candidates.contains {
        $0.packageID == custom().manifest.id && $0.validation == .invalid
      })
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(previous).path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(link).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("unexpected").path))
  }
  func testCleanupFailureIsNonfatalAndRetryReclaimsOrphans() async throws {
    enum Injected: Error { case failure }
    let directory = try root()
    let registry = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    ) {
      if $0 == .cleanup { throw Injected.failure }
    }
    var state = ToolRegistrySnapshot()
    for version in 1...8 { state = try await registry.save(custom(version)) }
    XCTAssertEqual(try generationNames(directory).count, 8)
    XCTAssertTrue(state.diagnostics.contains { $0.contains("Cleanup") })
    _ = try await ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    )
    .inspect()
    XCTAssertEqual(try generationNames(directory).count, 6)
  }
  func testFailedRemovalKeepsEveryGeneration() async throws {
    enum Injected: Error { case failure }
    let directory = try root()
    let registry = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    )
    for version in 1...3 { _ = try await registry.save(custom(version)) }
    let failing = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    ) {
      if $0 == .indexRename { throw Injected.failure }
    }
    do {
      _ = try await failing.remove(id: custom().manifest.id)
      XCTFail("Expected failed delete")
    } catch {}
    XCTAssertEqual(try generationNames(directory).count, 3)
    let state = try await failing.inspect()
    XCTAssertEqual(state.executable.first { $0.manifest.id == custom().manifest.id }, custom(3))
  }
}

extension ToolPackageTests {
  func testRecoveryHoldPreservesUnreferencedSourcesAcrossReloadAndLaterSave() async throws {
    enum Injected: Error { case failure }
    let directory = try root()
    _ = try await ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    )
    .save(custom())
    let failing = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    ) {
      if $0 == .indexDirectorySync { throw Injected.failure }
    }
    do {
      _ = try await failing.save(custom(2))
      XCTFail("Expected uncertainty")
    } catch {}
    let orphan = UUID().uuidString
    _ = try write(custom(99), named: orphan, to: directory)
    let reopened = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    )
    _ = try await reopened.inspect()
    _ = try await reopened.save(custom(3))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(orphan).path))
    XCTAssertEqual(try generationNames(directory).count, 4)
    let holds = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
      $0.hasPrefix("Recovery-")
    }
    XCTAssertEqual(holds.count, 1)
  }

  func testFailedMigrationBeforeReplacementPreservesOriginalIndexAndPackages() async throws {
    enum Injected: Error { case failure }
    let directory = try root(), current = UUID().uuidString, orphan = UUID().uuidString
    _ = try write(custom(), named: current, to: directory)
    _ = try write(custom(9), named: orphan, to: directory)
    try writeIndex(installed: directory, entries: [custom().manifest.id: current])
    let old = try Data(contentsOf: directory.appendingPathComponent("index.json"))
    let registry = ToolPackageRegistry(
      validator: RuntimePackageValidator(), bundledDirectory: bundled, installedDirectory: directory
    ) {
      if $0 == .indexRename { throw Injected.failure }
    }
    do {
      _ = try await registry.inspect()
      XCTFail("Expected migration failure")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), old)
    XCTAssertEqual(Set(try generationNames(directory)), [current, orphan])
  }

  func testDamagedPreviousPackageIsPreservedAndNeverUsedForExecution() async throws {
    let directory = try root(), current = UUID().uuidString, previous = UUID().uuidString
    _ = try write(custom(2), named: current, to: directory)
    let damaged = try write(custom(), named: previous, to: directory)
    try Data("broken".utf8).write(to: damaged.appendingPathComponent("tool.js"))
    let value: [String: Any] = [
      "schemaVersion": 2,
      "installed": [custom().manifest.id: ["current": current, "previous": [previous]]],
      "disabled": [],
    ]
    try JSONSerialization.data(withJSONObject: value).write(
      to: directory.appendingPathComponent("index.json"))
    let state = try await ToolPackageRegistry(
      validator: RuntimePackageValidator(),
      bundledDirectory: bundled, installedDirectory: directory
    ).inspect()
    XCTAssertEqual(state.executable.first { $0.manifest.id == custom().manifest.id }, custom(2))
    XCTAssertEqual(
      try String(contentsOf: damaged.appendingPathComponent("tool.js"), encoding: .utf8), "broken")
  }
}
