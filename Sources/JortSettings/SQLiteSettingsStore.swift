import JortToolContracts
import Foundation
import SQLite3

public enum SettingsStoreStage: String, Sendable { case open, migrate, write, commit }
public enum SettingsStoreError: Error, Equatable, Sendable {
  case unavailable(String)
  case unsupportedVersion
  case invalidData
  case sizeLimit
  case conflict(current: RecordRevision?)
  case injected(SettingsStoreStage)
}

public actor SQLiteSettingsStore: SettingsStore, ToolCatalog {
  public static let schemaVersion = 2
  public let directory: URL
  public let templates: [ToolTemplate]
  public var databaseURL: URL { directory.appendingPathComponent("Settings/Settings.sqlite") }
  private let inject: @Sendable (SettingsStoreStage) throws -> Void
  private var connection: SettingsConnection?
  private var snapshot = SettingsSnapshot(availability: .loading)
  private var continuations: [UUID: AsyncStream<SettingsSnapshot>.Continuation] = [:]

  public init(
    directory: URL, templates: [ToolTemplate] = [],
    inject: @escaping @Sendable (SettingsStoreStage) throws -> Void = { _ in }
  ) {
    self.directory = directory
    self.templates = templates
    self.inject = inject
  }

  public func load() throws -> SettingsSnapshot {
    if connection != nil { return snapshot }
    do {
      try inject(.open)
      let url = databaseURL
      let exists = FileManager.default.fileExists(atPath: url.path)
      if exists {
        let version = try SettingsConnection.inspectVersion(url: url)
        guard version <= Self.schemaVersion else { throw SettingsStoreError.unsupportedVersion }
        if version < Self.schemaVersion {
          if version == 0 {
            guard try SettingsConnection.isRecognizedLegacyV0(url: url) else {
              throw SettingsStoreError.invalidData
            }
          } else if version != 1 {
            throw SettingsStoreError.invalidData
          }
          try preserveForMigration(url)
          try inject(.migrate)
        }
      }
      let opened = try SettingsConnection(url: url, create: !exists)
      if exists { try opened.migrateIfNeeded() }
      connection = opened
      snapshot = try opened.readSnapshot(availability: .ready)
      publish()
      return snapshot
    } catch {
      connection = nil
      snapshot.availability = .unavailable(Self.message(for: error))
      publish()
      throw error
    }
  }

  public func currentSnapshot() -> SettingsSnapshot { snapshot }

  public func updates() -> AsyncStream<SettingsSnapshot> {
    let id = UUID(), current = snapshot
    return AsyncStream { continuation in
      continuation.yield(current)
      continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
      continuations[id] = continuation
    }
  }

  public func executableTools() -> [ExecutableTool] {
    ToolCatalogBuilder().executableTools(templates: templates, snapshot: snapshot)
  }

  public func setPreference(key: String, value: String?) throws -> SettingsSnapshot {
    guard !key.isEmpty, key.utf8.count <= SettingsLimits.maximumNameBytes,
      value?.utf8.count ?? 0 <= SettingsLimits.maximumSummaryBytes
    else { throw SettingsStoreError.sizeLimit }
    return try mutate { try $0.setPreference(key: key, value: value) }
  }

  public func setTemplateEnabled(id: ToolID, enabled: Bool?) throws -> SettingsSnapshot {
    guard templates.contains(where: { $0.id == id }) else { throw SettingsStoreError.invalidData }
    return try mutate { try $0.setTemplateEnabled(id: id, enabled: enabled) }
  }

  public func save(_ definition: UserToolDefinition, expectedRevision: RecordRevision?) throws
    -> SettingsSnapshot
  {
    var definition = definition
    definition.commandName = SettingsValidation.normalizedCommandName(definition.commandName)
    let occupied = Set(
      templates.map { SettingsValidation.normalizedCommandName($0.commandName) }
        + snapshot.customTools.filter { $0.id != definition.id }.map {
          SettingsValidation.normalizedCommandName($0.commandName)
        })
    guard SettingsValidation.diagnostics(for: definition, occupiedNames: occupied).isEmpty,
      snapshot.customTools.count < SettingsLimits.maximumCustomTools
        || snapshot.customTools.contains(where: { $0.id == definition.id })
    else {
      throw SettingsStoreError.invalidData
    }
    return try mutate { try $0.save(definition, expectedRevision: expectedRevision) }
  }

  public func delete(id: ToolID, expectedRevision: RecordRevision) throws -> SettingsSnapshot {
    try mutate { try $0.delete(id: id, expectedRevision: expectedRevision) }
  }

  public func close() throws {
    try connection?.close()
    connection = nil
    continuations.values.forEach { $0.finish() }
    continuations.removeAll()
  }

  private func mutate(_ body: (SettingsConnection) throws -> Void) throws -> SettingsSnapshot {
    guard let connection else {
      throw SettingsStoreError.unavailable("Settings have not loaded safely.")
    }
    try inject(.write)
    do {
      try connection.transaction {
        try body(connection)
        try connection.advanceCatalogRevision()
        try inject(.commit)
      }
      snapshot = try connection.readSnapshot(availability: .ready)
      publish()
      return snapshot
    } catch { throw error }
  }

  private func preserveForMigration(_ url: URL) throws {
    let parent = url.deletingLastPathComponent()
    let copy = parent.appendingPathComponent("Settings-PreMigration-\(UUID()).sqlite")
    try FileManager.default.copyItem(at: url, to: copy)
    for suffix in ["-wal", "-shm"] {
      let companion = URL(fileURLWithPath: url.path + suffix)
      if FileManager.default.fileExists(atPath: companion.path) {
        try FileManager.default.copyItem(
          at: companion, to: URL(fileURLWithPath: copy.path + suffix))
      }
    }
  }

  private func publish() { continuations.values.forEach { $0.yield(snapshot) } }
  private func removeContinuation(_ id: UUID) { continuations[id] = nil }
  private static func message(for error: Error) -> String {
    switch error {
    case SettingsStoreError.unsupportedVersion:
      return "These settings were created by a newer version of Jort."
    case SettingsStoreError.invalidData:
      return "Settings contain invalid data and were preserved unchanged."
    case SettingsStoreError.sizeLimit: return "Settings exceed a supported size limit."
    default: return "Settings are unavailable: \(error.localizedDescription)"
    }
  }
}

private final class SettingsConnection {
  private var db: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  static func inspectVersion(url: URL) throws -> Int {
    var handle: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
    guard result == SQLITE_OK, let handle else {
      let message =
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to inspect settings"
      sqlite3_close_v2(handle)
      throw SettingsStoreError.unavailable(message)
    }
    defer { sqlite3_close_v2(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
      throw SettingsStoreError.invalidData
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw SettingsStoreError.invalidData }
    return Int(sqlite3_column_int(statement, 0))
  }

  static func isRecognizedLegacyV0(url: URL) throws -> Bool {
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK, let handle
    else {
      sqlite3_close_v2(handle)
      throw SettingsStoreError.invalidData
    }
    defer { sqlite3_close_v2(handle) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        -1, &statement, nil) == SQLITE_OK
    else { throw SettingsStoreError.invalidData }
    defer { sqlite3_finalize(statement) }
    var names: [String] = [], step = sqlite3_step(statement)
    while step == SQLITE_ROW {
      guard let text = sqlite3_column_text(statement, 0) else { return false }
      names.append(String(cString: text))
      step = sqlite3_step(statement)
    }
    return step == SQLITE_DONE && names == ["custom_tools", "preferences", "template_overrides"]
  }

  init(url: URL, create: Bool) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX
    let result = sqlite3_open_v2(url.path, &db, flags, nil)
    guard result == SQLITE_OK else {
      let error = failure(result)
      sqlite3_close_v2(db)
      db = nil
      throw error
    }
    do {
      try check(sqlite3_busy_timeout(db, 500))
      try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON")
      if create { try createSchema() }
    } catch {
      sqlite3_close_v2(db)
      db = nil
      throw error
    }
  }
  deinit { if let db { sqlite3_close_v2(db) } }

  func close() throws {
    guard let db else { return }
    try check(sqlite3_close(db))
    self.db = nil
  }
  func failure(_ code: Int32) -> SettingsStoreError {
    .unavailable(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite closed (\(code))")
  }
  func check(_ result: Int32) throws { if result != SQLITE_OK { throw failure(result) } }
  func execute(_ sql: String) throws { try check(sqlite3_exec(db, sql, nil, nil, nil)) }
  func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
    guard let statement else { throw SettingsStoreError.invalidData }
    return statement
  }
  func version() throws -> Int {
    let statement = try prepare("PRAGMA user_version")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw SettingsStoreError.invalidData }
    return Int(sqlite3_column_int(statement, 0))
  }
  func createSchema() throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try execute(
        "CREATE TABLE settings_meta (id INTEGER PRIMARY KEY CHECK(id=1), catalog_revision INTEGER NOT NULL)"
      )
      try execute("INSERT INTO settings_meta(id,catalog_revision) VALUES(1,0)")
      try execute("CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
      try execute(
        "CREATE TABLE template_overrides (id TEXT PRIMARY KEY, enabled INTEGER NOT NULL CHECK(enabled IN (0,1)))"
      )
      try execute(
        "CREATE TABLE custom_tools (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, template_id TEXT, display_name TEXT NOT NULL, command_name TEXT NOT NULL, summary TEXT NOT NULL, source TEXT NOT NULL, enabled INTEGER NOT NULL CHECK(enabled IN (0,1)), manifest TEXT, instructions TEXT)"
      )
      try execute(
        "CREATE UNIQUE INDEX custom_tool_command_name ON custom_tools(command_name COLLATE NOCASE)")
      try execute("PRAGMA user_version=2")
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
  func migrateIfNeeded() throws {
    let current = try version()
    guard current <= SQLiteSettingsStore.schemaVersion else {
      throw SettingsStoreError.unsupportedVersion
    }
    if current == SQLiteSettingsStore.schemaVersion { return }
    guard current == 0 || current == 1 else { throw SettingsStoreError.unsupportedVersion }
    try execute("BEGIN IMMEDIATE")
    do {
      if current == 0 {
        try execute(
          "CREATE TABLE settings_meta (id INTEGER PRIMARY KEY CHECK(id=1), catalog_revision INTEGER NOT NULL)"
        )
        try execute("INSERT INTO settings_meta(id,catalog_revision) VALUES(1,0)")
        try execute(
          "CREATE UNIQUE INDEX custom_tool_command_name ON custom_tools(command_name COLLATE NOCASE)"
        )
      }
      try execute("ALTER TABLE custom_tools ADD COLUMN manifest TEXT")
      try execute("ALTER TABLE custom_tools ADD COLUMN instructions TEXT")
      try execute("PRAGMA user_version=2")
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
  func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try body()
      try execute("COMMIT")
    } catch {
      let primary = error
      try? execute("ROLLBACK")
      throw primary
    }
  }
  func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
    if let value {
      try check(sqlite3_bind_text(statement, index, value, -1, transient))
    } else {
      try check(sqlite3_bind_null(statement, index))
    }
  }
  func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
    guard let text = sqlite3_column_text(statement, column) else {
      throw SettingsStoreError.invalidData
    }
    return String(cString: text)
  }
  func setPreference(key: String, value: String?) throws {
    let sql =
      value == nil
      ? "DELETE FROM preferences WHERE key=?"
      : "INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(key, to: statement, at: 1)
    if let value { try bind(value, to: statement, at: 2) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(sqlite3_errcode(db)) }
  }
  func setTemplateEnabled(id: ToolID, enabled: Bool?) throws {
    let sql =
      enabled == nil
      ? "DELETE FROM template_overrides WHERE id=?"
      : "INSERT INTO template_overrides(id,enabled) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET enabled=excluded.enabled"
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(id.rawValue, to: statement, at: 1)
    if let enabled { try check(sqlite3_bind_int(statement, 2, enabled ? 1 : 0)) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(sqlite3_errcode(db)) }
  }
  func save(_ definition: UserToolDefinition, expectedRevision: RecordRevision?) throws {
    let current = try recordRevision(id: definition.id)
    guard current == expectedRevision else { throw SettingsStoreError.conflict(current: current) }
    let next = RecordRevision((current?.rawValue ?? 0) + 1)
    let sql =
      "INSERT INTO custom_tools(id,revision,template_id,display_name,command_name,summary,source,enabled,manifest,instructions) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,template_id=excluded.template_id,display_name=excluded.display_name,command_name=excluded.command_name,summary=excluded.summary,source=excluded.source,enabled=excluded.enabled,manifest=excluded.manifest,instructions=excluded.instructions"
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(definition.id.rawValue, to: statement, at: 1)
    try check(sqlite3_bind_int64(statement, 2, next.rawValue))
    try bind(definition.basedOnTemplateID?.rawValue, to: statement, at: 3)
    try bind(definition.displayName, to: statement, at: 4)
    try bind(definition.commandName, to: statement, at: 5)
    try bind(definition.summary, to: statement, at: 6)
    try bind(definition.source, to: statement, at: 7)
    try check(sqlite3_bind_int(statement, 8, definition.isEnabled ? 1 : 0))
    let manifest = try definition.manifest.map {
      String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
    }
    try bind(manifest, to: statement, at: 9)
    try bind(definition.instructions, to: statement, at: 10)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(sqlite3_errcode(db)) }
  }
  func delete(id: ToolID, expectedRevision: RecordRevision) throws {
    guard try recordRevision(id: id) == expectedRevision else {
      throw SettingsStoreError.conflict(current: try recordRevision(id: id))
    }
    let statement = try prepare("DELETE FROM custom_tools WHERE id=? AND revision=?")
    defer { sqlite3_finalize(statement) }
    try bind(id.rawValue, to: statement, at: 1)
    try check(sqlite3_bind_int64(statement, 2, expectedRevision.rawValue))
    guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
      throw SettingsStoreError.conflict(current: try recordRevision(id: id))
    }
  }
  func recordRevision(id: ToolID) throws -> RecordRevision? {
    let statement = try prepare("SELECT revision FROM custom_tools WHERE id=?")
    defer { sqlite3_finalize(statement) }
    try bind(id.rawValue, to: statement, at: 1)
    let step = sqlite3_step(statement)
    if step == SQLITE_DONE { return nil }
    guard step == SQLITE_ROW else { throw failure(step) }
    return RecordRevision(sqlite3_column_int64(statement, 0))
  }
  func advanceCatalogRevision() throws {
    try execute("UPDATE settings_meta SET catalog_revision=catalog_revision+1 WHERE id=1")
  }
  func readSnapshot(availability: SettingsAvailability) throws -> SettingsSnapshot {
    let meta = try prepare("SELECT catalog_revision FROM settings_meta WHERE id=1")
    defer { sqlite3_finalize(meta) }
    guard sqlite3_step(meta) == SQLITE_ROW else { throw SettingsStoreError.invalidData }
    let revision = CatalogRevision(sqlite3_column_int64(meta, 0))
    var preferences: [String: String] = [:]
    let preferenceRows = try prepare("SELECT key,value FROM preferences ORDER BY key")
    defer { sqlite3_finalize(preferenceRows) }
    var step = sqlite3_step(preferenceRows)
    while step == SQLITE_ROW {
      preferences[try text(preferenceRows, 0)] = try text(preferenceRows, 1)
      step = sqlite3_step(preferenceRows)
    }
    guard step == SQLITE_DONE else { throw failure(step) }
    var overrides: [ToolID: Bool] = [:]
    let overrideRows = try prepare("SELECT id,enabled FROM template_overrides ORDER BY id")
    defer { sqlite3_finalize(overrideRows) }
    step = sqlite3_step(overrideRows)
    while step == SQLITE_ROW {
      overrides[ToolID(try text(overrideRows, 0))] = sqlite3_column_int(overrideRows, 1) != 0
      step = sqlite3_step(overrideRows)
    }
    guard step == SQLITE_DONE else { throw failure(step) }
    var tools: [UserToolDefinition] = []
    let rows = try prepare(
      "SELECT id,revision,template_id,display_name,command_name,summary,source,enabled,manifest,instructions FROM custom_tools ORDER BY display_name COLLATE NOCASE,id"
    )
    defer { sqlite3_finalize(rows) }
    step = sqlite3_step(rows)
    while step == SQLITE_ROW {
      guard tools.count < SettingsLimits.maximumCustomTools else {
        throw SettingsStoreError.sizeLimit
      }
      let template = sqlite3_column_type(rows, 2) == SQLITE_NULL ? nil : ToolID(try text(rows, 2))
      var definition = UserToolDefinition(
        id: ToolID(try text(rows, 0)), revision: RecordRevision(sqlite3_column_int64(rows, 1)),
        basedOnTemplateID: template,
        displayName: try text(rows, 3), commandName: try text(rows, 4), summary: try text(rows, 5),
        source: try text(rows, 6), isEnabled: sqlite3_column_int(rows, 7) != 0)
      if sqlite3_column_type(rows, 8) != SQLITE_NULL {
        let data = Data(try text(rows, 8).utf8)
        guard data.count <= 16_384 else { throw SettingsStoreError.sizeLimit }
        definition.manifest = try JSONDecoder().decode(ToolManifest.self, from: data)
      }
      if sqlite3_column_type(rows, 9) != SQLITE_NULL { definition.instructions = try text(rows, 9) }
      // Keep unavailable catalog selections repairable after an app update.
      guard
        !SettingsValidation.diagnostics(for: definition).contains(where: {
          $0.field != .catalog && $0.isBlocking
        })
      else { throw SettingsStoreError.invalidData }
      tools.append(definition)
      step = sqlite3_step(rows)
    }
    guard step == SQLITE_DONE else { throw failure(step) }
    return SettingsSnapshot(
      revision: revision, preferences: preferences, templateOverrides: overrides,
      customTools: tools, availability: availability)
  }
}
