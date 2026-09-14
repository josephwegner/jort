import XCTest
import SQLite3
import JortDocument
import JortPersistence
@testable import JortSettings

final class SettingsTests: StoreTestCase {
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JortSettingsTests-\(UUID())")
    removeAfterStoresClose(url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private var template: ToolTemplate {
    ToolTemplate(
      id: ToolID("builtin.date"), displayName: "Date", commandName: "date",
      summary: "Insert a date", source: "export default function run() { return 'date'; }",
      defaultEnabled: true)
  }

  func testModelsNormalizeValidateUnicodeAndBounds() async throws {
    XCTAssertEqual(SettingsValidation.normalizedCommandName(" /MY-tool \n"), "my-tool")
    let unicode = UserToolDefinition(
      displayName: "Résumé 🌲", commandName: "resume", source: "return '🌲';")
    XCTAssertTrue(SettingsValidation.diagnostics(for: unicode).isEmpty)
    let invalid = UserToolDefinition(
      displayName: "", commandName: "9 bad",
      source: String(repeating: "x", count: SettingsLimits.maximumSourceBytes + 1))
    XCTAssertEqual(
      Set(SettingsValidation.diagnostics(for: invalid).map(\.field)),
      [.displayName, .commandName, .source])
    let snapshot = SettingsSnapshot(revision: CatalogRevision(2))
    XCTAssertGreaterThan(snapshot.revision, CatalogRevision(1))
    let sendable: any Sendable = snapshot
    XCTAssertNotNil(sendable)
  }

  func testSQLiteRoundTripRevisionsPreferencesOverridesAndDelete() async throws {
    let store = ownStore(SQLiteSettingsStore(directory: try root(), templates: [template]))
    var snapshot = try await store.load()
    XCTAssertEqual(snapshot, SettingsSnapshot())
    snapshot = try await store.setPreference(key: "sample", value: "value")
    snapshot = try await store.setTemplateEnabled(id: template.id, enabled: false)
    var tool = UserToolDefinition(
      displayName: "Uppercase", commandName: "/UPPER", source: "return input.toUpperCase();",
      isEnabled: true)
    snapshot = try await store.save(tool, expectedRevision: nil)
    tool = try XCTUnwrap(snapshot.customTools.first)
    XCTAssertEqual(tool.revision, RecordRevision(1))
    XCTAssertEqual(tool.commandName, "upper")
    tool.summary = "Updated"
    snapshot = try await store.save(tool, expectedRevision: tool.revision)
    let updated = try XCTUnwrap(snapshot.customTools.first)
    XCTAssertEqual(updated.revision, RecordRevision(2))
    XCTAssertEqual(snapshot.revision, CatalogRevision(4))
    do {
      _ = try await store.save(tool, expectedRevision: RecordRevision(1))
      XCTFail("Expected conflict")
    } catch SettingsStoreError.conflict(let current) { XCTAssertEqual(current, RecordRevision(2)) }
    snapshot = try await store.delete(id: updated.id, expectedRevision: updated.revision)
    XCTAssertTrue(snapshot.customTools.isEmpty)
    try await store.close()
    let reopened = ownStore(
      SQLiteSettingsStore(directory: await store.directory, templates: [template]))
    snapshot = try await reopened.load()
    XCTAssertEqual(snapshot.preferences["sample"], "value")
    XCTAssertEqual(snapshot.templateOverrides[template.id], false)
    try await reopened.close()
  }

  func testFailedTransactionRollsBackAndDoesNotPublish() async throws {
    let root = try root(),
      seed = ownStore(SQLiteSettingsStore(directory: root, templates: [template]))
    _ = try await seed.load()
    try await seed.close()
    let store = ownStore(
      SQLiteSettingsStore(directory: root, templates: [template]) {
        if $0 == .commit { throw SettingsStoreError.injected(.commit) }
      })
    let before = try await store.load()
    do {
      _ = try await store.setPreference(key: "x", value: "y")
      XCTFail("Expected injection")
    } catch {}
    let current = await store.currentSnapshot()
    XCTAssertEqual(current, before)
    try await store.close()
    let reopened = ownStore(SQLiteSettingsStore(directory: root, templates: [template]))
    let reloaded = try await reopened.load()
    XCTAssertNil(reloaded.preferences["x"])
    try await reopened.close()
  }

  func testSettingsMutationDoesNotTouchDocumentCurrentStateRecoveryOrHistory() async throws {
    let root = try root(), documentStore = ownStore(SQLiteStore(directory: root))
    let empty = try await documentStore.load()
    let timestamp = Date()
    let document = DocumentSnapshot(
      documentID: empty.documentID, text: "Keep me", revision: 1,
      lines: [LineMeta(location: 0, length: 7, createdAt: timestamp, lastEditedAt: timestamp)])
    _ = try await documentStore.save(document)
    _ = try await documentStore.retain(document, reason: "Before settings", timestamp: Date())
    let manifest = root.appendingPathComponent("Store/Recovery-manifest.json")
    let recoveryBefore = try Data(contentsOf: manifest),
      historyBefore = try await documentStore.revisions()
    let settingsStore = ownStore(SQLiteSettingsStore(directory: root, templates: [template]))
    _ = try await settingsStore.load()
    _ = try await settingsStore.setTemplateEnabled(id: template.id, enabled: false)
    let historyAfter = try await documentStore.revisions(),
      documentAfter = try await documentStore.load()
    XCTAssertEqual(try Data(contentsOf: manifest), recoveryBefore)
    XCTAssertEqual(historyAfter, historyBefore)
    XCTAssertEqual(documentAfter, document)
    try await settingsStore.close()
    try await documentStore.close()
  }

  func testUpdateStreamPublishesOnlyCommittedSnapshots() async throws {
    let store = ownStore(SQLiteSettingsStore(directory: try root()))
    _ = try await store.load()
    let stream = await store.updates()
    let task = Task { () -> [CatalogRevision] in
      var revisions: [CatalogRevision] = []
      for await value in stream {
        revisions.append(value.revision)
        if revisions.count == 2 { break }
      }
      return revisions
    }
    _ = try await store.setPreference(key: "theme", value: "dark")
    let revisions = await task.value
    XCTAssertEqual(revisions, [CatalogRevision(0), CatalogRevision(1)])
    try await store.close()
  }

  func testCorruptAndFutureStoresArePreservedAndFailClosed() async throws {
    let corruptRoot = try root(),
      corruptURL = corruptRoot.appendingPathComponent("Settings/Settings.sqlite")
    try FileManager.default.createDirectory(
      at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not sqlite".utf8).write(to: corruptURL)
    let corrupt = ownStore(SQLiteSettingsStore(directory: corruptRoot, templates: [template]))
    do {
      _ = try await corrupt.load()
      XCTFail("Expected corrupt failure")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: corruptURL), Data("not sqlite".utf8))
    let executable = await corrupt.executableTools()
    XCTAssertTrue(executable.isEmpty)

    let futureRoot = try root(),
      futureURL = futureRoot.appendingPathComponent("Settings/Settings.sqlite")
    try FileManager.default.createDirectory(
      at: futureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(futureURL.path, &db), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    let future = ownStore(SQLiteSettingsStore(directory: futureRoot, templates: [template]))
    do {
      _ = try await future.load()
      XCTFail("Expected future failure")
    } catch { XCTAssertEqual(error as? SettingsStoreError, .unsupportedVersion) }
    var readonly: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(futureURL.path, &readonly, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(readonly, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(sqlite3_column_int(statement, 0), 99)
    sqlite3_finalize(statement)
    sqlite3_close(readonly)
  }

  func testRecognizedLegacySchemaMigratesAfterPreservingCopy() async throws {
    let root = try root(), url = root.appendingPathComponent("Settings/Settings.sqlite")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    let legacy =
      "CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE template_overrides (id TEXT PRIMARY KEY, enabled INTEGER NOT NULL CHECK(enabled IN (0,1))); CREATE TABLE custom_tools (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, template_id TEXT, display_name TEXT NOT NULL, command_name TEXT NOT NULL, summary TEXT NOT NULL, source TEXT NOT NULL, enabled INTEGER NOT NULL CHECK(enabled IN (0,1))); INSERT INTO preferences VALUES('legacy','kept');"
    XCTAssertEqual(sqlite3_exec(db, legacy, nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    let store = ownStore(SQLiteSettingsStore(directory: root))
    let snapshot = try await store.load()
    XCTAssertEqual(snapshot.preferences["legacy"], "kept")
    let backups = try FileManager.default.contentsOfDirectory(
      atPath: url.deletingLastPathComponent().path
    ).filter { $0.hasPrefix("Settings-PreMigration-") }
    XCTAssertEqual(backups.count, 1)
    try await store.close()
  }

  func testCatalogOrderingUpgradeOverrideDuplicatesAndExecutableFiltering() {
    let builder = ToolCatalogBuilder(),
      second = ToolTemplate(
        id: ToolID("builtin.uuid"), version: 2, displayName: "UUID", commandName: "uuid",
        source: "return 'id';", defaultEnabled: false)
    let conflicting = UserToolDefinition(
      displayName: "My Date", commandName: "date", source: "return 'mine';", isEnabled: true)
    let valid = UserToolDefinition(
      displayName: "Slug", commandName: "slug", source: "return input;", isEnabled: true)
    let snapshot = SettingsSnapshot(
      revision: CatalogRevision(7), templateOverrides: [second.id: true],
      customTools: [valid, conflicting])
    let tools = builder.configuredTools(templates: [second, template], snapshot: snapshot)
    XCTAssertEqual(tools.prefix(2).map(\.origin), [.bundledTemplate, .bundledTemplate])
    XCTAssertTrue(tools.first(where: { $0.id == second.id })?.isEnabled == true)
    XCTAssertEqual(
      builder.executableTools(templates: [template, second], snapshot: snapshot).map(\.commandName)
        .sorted(), ["slug", "uuid"])
    let duplicate = builder.duplicate(template, avoiding: Set(tools.map(\.commandName)))
    XCTAssertEqual(duplicate.definition.commandName, "date-copy")
    XCTAssertEqual(duplicate.definition.basedOnTemplateID, template.id)
    let unavailable = SettingsSnapshot(
      revision: CatalogRevision(8), availability: .unavailable("no"))
    XCTAssertTrue(builder.executableTools(templates: [template], snapshot: unavailable).isEmpty)
  }

  func testTemplateEnvelopeRoundTripAndValidation() throws {
    let root = try root(), url = root.appendingPathComponent("templates.json")
    try JSONEncoder().encode(BundledTemplateEnvelope(templates: [template])).write(to: url)
    XCTAssertEqual(try BundledTemplateLoader.load(from: url), [template])
    try JSONEncoder().encode(BundledTemplateEnvelope(schemaVersion: 2, templates: [])).write(
      to: url)
    XCTAssertThrowsError(try BundledTemplateLoader.load(from: url))
  }

  func testLargeCatalogBuildPerformance() {
    let tools = (0..<900).map {
      UserToolDefinition(
        id: ToolID("custom.\($0)"), displayName: "Tool \($0)", commandName: "tool-\($0)",
        source: "return input;")
    }
    let snapshot = SettingsSnapshot(customTools: tools)
    measure {
      XCTAssertEqual(
        ToolCatalogBuilder().configuredTools(templates: [], snapshot: snapshot).count, 900)
    }
  }
}
