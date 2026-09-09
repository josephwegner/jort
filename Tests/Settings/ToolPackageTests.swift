import XCTest
@testable import JortSettings

final class ToolPackageTests: XCTestCase {
    private var bundled: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Jort/Resources/Tools")
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JortPackageTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testManifestRejectsContractsPathsAndIncompatibleModes() throws {
        var manifest = ToolManifest(id: "dev.jort.test", name: "Test", command: "/test")
        XCTAssertNoThrow(try manifest.validate())
        manifest.id = "../escape"; XCTAssertThrowsError(try manifest.validate())
        manifest.id = "dev.jort.test"; manifest.entryContract = 2; XCTAssertThrowsError(try manifest.validate())
        manifest.entryContract = 1; manifest.outputOperation = .replaceContext; XCTAssertThrowsError(try manifest.validate())
        manifest.inputMode = .contextual; XCTAssertNoThrow(try manifest.validate())
        manifest.maximumOutputBytes = Int.max; XCTAssertThrowsError(try manifest.validate())
    }
    func testRegistryOverrideUpdateDisableRestoreAndRelaunch() async throws {
        let installed = try root()
        let registry = ToolPackageRegistry(bundledDirectory: bundled, installedDirectory: installed)
        let initial = try await registry.inspect(); XCTAssertEqual(initial.executable.count, 6)
        var edited = try XCTUnwrap(initial.executable.first { $0.manifest.command == "/calc" })
        edited.source = "export default async function() { return {output: 'custom'}; }"
        var snapshot = try await registry.save(edited)
        XCTAssertTrue(try XCTUnwrap(snapshot.packages.first { $0.id == edited.manifest.id }).isOverride)
        snapshot = try await registry.setEnabled(id: edited.manifest.id, enabled: false)
        XCTAssertEqual(snapshot.executable.count, 5)
        let reopened = ToolPackageRegistry(bundledDirectory: bundled, installedDirectory: installed)
        snapshot = try await reopened.inspect(); XCTAssertEqual(snapshot.executable.count, 5)
        XCTAssertEqual(snapshot.packages.first { $0.id == edited.manifest.id }?.package.source, edited.source)
        snapshot = try await reopened.restore(id: edited.manifest.id)
        XCTAssertEqual(snapshot.executable.count, 6)
        XCTAssertNotEqual(snapshot.packages.first { $0.id == edited.manifest.id }?.package.source, edited.source)
    }
    func testInvalidInstallDoesNotAffectRegistryAndConflictIsRejected() async throws {
        let registry = ToolPackageRegistry(bundledDirectory: bundled, installedDirectory: try root())
        let original = try await registry.inspect()
        let bad = ToolPackage(manifest: .init(id: "org.user.test", name: "Test", command: "/calc"), source: "export default async function() {}")
        do { _ = try await registry.save(bad); XCTFail("Expected conflict") } catch { XCTAssertEqual(error as? ToolPackageError, .conflict) }
        var invalid = bad; invalid.manifest.command = "/custom"; invalid.source = "export default !!!"
        do { _ = try await registry.save(invalid); XCTFail("Expected invalid source") } catch { }
        let after = try await registry.inspect(); XCTAssertEqual(original, after)
    }
    func testMalformedBundleIsolationAndSymlinkRejection() async throws {
        let directory = try root()
        let bad = directory.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundled.appendingPathComponent("calc"), to: directory.appendingPathComponent("calc"))
        let registry = ToolPackageRegistry(bundledDirectory: directory, installedDirectory: try root())
        let snapshot = try await registry.inspect()
        XCTAssertEqual(snapshot.executable.count, 1); XCTAssertEqual(snapshot.diagnostics.count, 1)
        let symlink = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: bundled.appendingPathComponent("calc"))
        XCTAssertThrowsError(try ToolPackage.load(from: symlink))
    }
    func testBundledCalculatorGrammarAndFailures() async throws {
        let package = try ToolPackage.load(from: bundled.appendingPathComponent("calc"))
        for (input, expected) in [("3+3", "6"), ("2^3^2", "512"), ("-2^2", "-4"), ("(-2)^2", "4"), ("2^-2", "0.25"), (".5 + 2 * (3 - 1)", "4.5"), ("5%2", "1")] {
            let result = await ToolRuntime.execute(package, input: .init(content: input))
            XCTAssertEqual(result.output, expected, input)
        }
        for input in ["", "1/0", "1%0", "2***3", "2(3)", "1e3", "2^99999", "1+", String(repeating: "-", count: 1000) + "1"] {
            let result = await ToolRuntime.execute(package, input: .init(content: input))
            XCTAssertNotNil(result.error, input)
        }
    }
    func testBundledExactLinesClockUUIDAndEmptyOutput() async throws {
        for (name, input, expected) in [
            ("sort", "b\na\nb\n", "a\nb\nb\n"), ("sort", "🌲\nA\na", "A\na\n🌲"),
            ("dedupe", "a\n\na\n\nb\n", "a\n\nb\n"), ("dedupe", "", ""),
            ("date", " ", "1970-01-01"), ("time", "", "00:00:00Z"),
            ("uuid", "", "00000000-0000-0000-0000-000000000001")
        ] {
            let package = try ToolPackage.load(from: bundled.appendingPathComponent(name))
            let result = await ToolRuntime.execute(package, input: .init(content: input, date: Date(timeIntervalSince1970: 0), uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
            XCTAssertEqual(result.output, expected, name)
        }
    }

    func testSettingsUsesRegistryForEditableOverridesAndConflicts() async throws {
        let directory = try root()
        let registry = ToolPackageRegistry(bundledDirectory: bundled, installedDirectory: directory.appendingPathComponent("Tools"))
        let store = PackageSettingsStore(registry: registry, preferences: SQLiteSettingsStore(directory: directory))
        _ = try await store.load()
        let catalog = try await registry.inspect()
        let original = try XCTUnwrap(catalog.executable.first { $0.manifest.command == "/calc" })
        var definition = UserToolDefinition(id: ToolID(original.manifest.id), displayName: "My Calculator", commandName: "calc",
            source: "export default async function(input) { return {output: input.content}; }", isEnabled: true)
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
        do { _ = try await store.save(definition, expectedRevision: definition.revision); XCTFail("Expected conflict") } catch { }
        let executable = try await registry.inspect().executable
        XCTAssertEqual(executable.first { $0.manifest.id == original.manifest.id }?.manifest, edited.manifest)
        snapshot = try await store.delete(id: edited.id, expectedRevision: edited.revision)
        XCTAssertTrue(snapshot.customTools.isEmpty)
        let restored = try await registry.inspect().executable
        XCTAssertEqual(restored.first { $0.manifest.id == original.manifest.id }, original)
        try await store.close()
    }

    func testLegacySettingsScriptsRemainEditableUntilExplicitMigration() async throws {
        let directory = try root()
        let preferences = SQLiteSettingsStore(directory: directory)
        _ = try await preferences.load()
        let legacy = UserToolDefinition(id: ToolID("legacy-uuid"), displayName: "Legacy", commandName: "legacy", source: "return input;", isEnabled: true)
        _ = try await preferences.save(legacy, expectedRevision: nil)
        let registry = ToolPackageRegistry(bundledDirectory: bundled, installedDirectory: directory.appendingPathComponent("Tools"))
        let store = PackageSettingsStore(registry: registry, preferences: preferences)
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
            let registry = ToolPackageRegistry(bundledDirectory: bundled, installedDirectory: installed)
            let snapshot = try await registry.inspect(); XCTAssertEqual(snapshot.executable.count, 6)
            discovery.append(clock() - start)
            start = clock(); try ToolRuntime.validate(package); validation.append(clock() - start)
            start = clock(); let result = await ToolRuntime.execute(package, input: .init(content: "3+3")); startup.append(clock() - start)
            XCTAssertEqual(result.output, "6")
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] * 1000 }
        print("PERF Tools ms p95: discovery=\(p95(discovery)), validation=\(p95(validation)), host-startup+calc=\(p95(startup))")
    }
}
