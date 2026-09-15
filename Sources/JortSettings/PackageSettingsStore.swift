import JortToolContracts
import Foundation
import CryptoKit

/// Adapts the existing Settings UI to the same package registry the editor consumes.
public actor PackageSettingsStore: SettingsStore {
  public let registry: ToolPackageRegistry
  private let preferences: SQLiteSettingsStore
  private var snapshot = SettingsSnapshot(availability: .loading)
  private var legacyTools: [UserToolDefinition] = []
  private var legacyIDs: [ToolID: ToolID] = [:]
  private var streams: [UUID: AsyncStream<SettingsSnapshot>.Continuation] = [:]
  public init(registry: ToolPackageRegistry, preferences: SQLiteSettingsStore) {
    self.registry = registry
    self.preferences = preferences
  }
  public func load() async throws -> SettingsSnapshot {
    let legacy = try await preferences.load()
    legacyIDs = [:]
    legacyTools = legacy.customTools.map { original in
      var value = original
      if original.id.rawValue.range(
        of: #"^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$"#, options: .regularExpression) == nil
      {
        let hash = SHA256.hash(data: Data(original.id.rawValue.utf8)).prefix(16).map {
          String(format: "%02x", $0)
        }.joined()
        value.id = ToolID("user.jort.legacy-" + hash)
      }
      legacyIDs[value.id] = original.id
      return value
    }
    do {
      try await registry.reload()
      return try await refresh(preferences: legacy.preferences)
    } catch {
      snapshot.availability = .unavailable(
        "Tool storage could not be opened. Use Show Recovery Files to preserve your package sources."
      )
      throw error
    }
  }
  public func recoveryDirectory() -> URL? { registry.installedDirectory }
  public func currentSnapshot() -> SettingsSnapshot { snapshot }
  public func updates() -> AsyncStream<SettingsSnapshot> {
    let id = UUID()
    return AsyncStream { continuation in
      streams[id] = continuation
      continuation.yield(snapshot)
      continuation.onTermination = { [weak self] _ in Task { await self?.removeStream(id) } }
    }
  }
  private func removeStream(_ id: UUID) { streams.removeValue(forKey: id) }
  public func setPreference(key: String, value: String?) async throws -> SettingsSnapshot {
    let value = try await preferences.setPreference(key: key, value: value)
    return try await refresh(preferences: value.preferences)
  }
  public func setTemplateEnabled(id: ToolID, enabled: Bool?) async throws -> SettingsSnapshot {
    do {
      _ = try await registry.setEnabled(id: id.rawValue, enabled: enabled ?? true)
    } catch ToolPublicationError.uncertain {
      _ = try? await refresh()
      throw ToolPublicationError.uncertain
    }
    return try await refresh()
  }
  public func save(_ definition: UserToolDefinition, expectedRevision: RecordRevision?) async throws
    -> SettingsSnapshot
  {
    let current = snapshot.customTools.first { $0.id == definition.id }
    guard current?.revision == expectedRevision else {
      throw SettingsStoreError.conflict(current: current?.revision)
    }
    var manifest =
      definition.manifest
      ?? ToolManifest(
        id: definition.id.rawValue, name: definition.displayName,
        command: "/" + SettingsValidation.normalizedCommandName(definition.commandName))
    manifest.id = definition.id.rawValue
    manifest.version = (current?.manifest?.version ?? 0) + 1
    manifest.name = definition.displayName
    manifest.command = "/" + SettingsValidation.normalizedCommandName(definition.commandName)
    manifest.description = definition.summary
    manifest.basedOnTemplateID = definition.basedOnTemplateID?.rawValue
    manifest.schemaVersion = 2
    manifest.executor = manifest.executorType
    let package =
      manifest.executorType == .model
      ? ToolPackage(manifest: manifest, instructions: definition.instructions ?? "")
      : ToolPackage(manifest: manifest, source: definition.source)
    do {
      _ = try await registry.save(
        package, enabled: definition.isEnabled,
        replacingVersion: current?.manifest?.version, requireAbsent: current == nil)
    } catch ToolPublicationError.uncertain {
      _ = try? await refresh()
      throw ToolPublicationError.uncertain
    }
    if let originalID = legacyIDs[definition.id], let revision = current?.revision {
      _ = try await preferences.delete(id: originalID, expectedRevision: revision)
      legacyIDs.removeValue(forKey: definition.id)
      legacyTools.removeAll { $0.id == definition.id }
    }
    return try await refresh()
  }
  public func delete(id: ToolID, expectedRevision: RecordRevision) async throws -> SettingsSnapshot
  {
    guard snapshot.customTools.first(where: { $0.id == id })?.revision == expectedRevision else {
      throw SettingsStoreError.conflict(
        current: snapshot.customTools.first(where: { $0.id == id })?.revision)
    }
    if let originalID = legacyIDs[id] {
      _ = try await preferences.delete(id: originalID, expectedRevision: expectedRevision)
      legacyIDs.removeValue(forKey: id)
      legacyTools.removeAll { $0.id == id }
    } else {
      do { _ = try await registry.remove(id: id.rawValue) } catch ToolPublicationError.uncertain {
        _ = try? await refresh()
        throw ToolPublicationError.uncertain
      }
    }
    return try await refresh()
  }
  public func close() async throws {
    streams.values.forEach { $0.finish() }
    streams = [:]
    try await preferences.close()
  }
  private func refresh(preferences: [String: String]? = nil) async throws -> SettingsSnapshot {
    let registry = try await registry.inspect()
    var value = SettingsSnapshot(
      revision: CatalogRevision(snapshot.revision.rawValue + 1),
      preferences: preferences ?? snapshot.preferences)
    value.maintenanceDiagnostics = registry.diagnostics
    for entry in registry.packages {
      if entry.isBundled {
        value.templateOverrides[ToolID(entry.id)] = entry.isEnabled
      } else {
        let manifest = entry.package.manifest
        var definition = UserToolDefinition(
          id: ToolID(entry.id), revision: RecordRevision(Int64(manifest.version)),
          basedOnTemplateID: manifest.basedOnTemplateID.map(ToolID.init(rawValue:))
            ?? (entry.isOverride ? ToolID(entry.id) : nil), displayName: manifest.name,
          commandName: String(manifest.command.dropFirst()), summary: manifest.description,
          source: entry.package.source, isEnabled: entry.isEnabled)
        definition.manifest = manifest
        definition.instructions =
          entry.package.manifest.executorType == .model ? entry.package.instructions : nil
        value.customTools.append(definition)
      }
    }
    let known = Set(value.customTools.map(\.id))
    value.customTools += legacyTools.filter { !known.contains($0.id) }
    snapshot = value
    streams.values.forEach { $0.yield(value) }
    return value
  }
}
