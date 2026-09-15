import Foundation

public protocol ToolDefinitionValidator: Sendable {
  func diagnostics(for definition: UserToolDefinition) async -> [ToolDiagnostic]
}

public struct StructuralToolValidator: ToolDefinitionValidator {
  public init() {}
  public func diagnostics(for definition: UserToolDefinition) async -> [ToolDiagnostic] {
    SettingsValidation.diagnostics(for: definition)
  }
}

public protocol SettingsStore: Sendable {
  func load() async throws -> SettingsSnapshot
  func currentSnapshot() async -> SettingsSnapshot
  func updates() async -> AsyncStream<SettingsSnapshot>
  func setPreference(key: String, value: String?) async throws -> SettingsSnapshot
  func setTemplateEnabled(id: ToolID, enabled: Bool?) async throws -> SettingsSnapshot
  func save(_ definition: UserToolDefinition, expectedRevision: RecordRevision?) async throws
    -> SettingsSnapshot
  func delete(id: ToolID, expectedRevision: RecordRevision) async throws -> SettingsSnapshot
  func close() async throws
  func recoveryDirectory() async -> URL?
}

public extension SettingsStore {
  func recoveryDirectory() async -> URL? { nil }
}

public protocol ToolCatalog: Sendable {
  func executableTools() async -> [ExecutableTool]
  func updates() async -> AsyncStream<SettingsSnapshot>
}

public struct ToolCatalogBuilder: Sendable {
  public init() {}

  public func configuredTools(templates: [ToolTemplate], snapshot: SettingsSnapshot)
    -> [ConfiguredTool]
  {
    let overridden = Set(snapshot.customTools.map(\.id))
    var tools: [ConfiguredTool] = templates.prefix(SettingsLimits.maximumTemplates).filter {
      !overridden.contains($0.id)
    }.map { template in
      ConfiguredTool(
        manifest: template.manifest, instructions: template.instructions, id: template.id,
        origin: .bundledTemplate, templateVersion: template.version,
        recordRevision: nil, basedOnTemplateID: nil, displayName: template.displayName,
        commandName: SettingsValidation.normalizedCommandName(template.commandName),
        summary: template.summary,
        source: template.source,
        isEnabled: snapshot.templateOverrides[template.id] ?? template.defaultEnabled,
        diagnostics: SettingsValidation.diagnostics(for: template))
    }
    tools += snapshot.customTools.map { definition in
      ConfiguredTool(
        manifest: definition.manifest, instructions: definition.instructions, id: definition.id,
        origin: .custom, templateVersion: nil,
        recordRevision: definition.revision, basedOnTemplateID: definition.basedOnTemplateID,
        displayName: definition.displayName,
        commandName: SettingsValidation.normalizedCommandName(definition.commandName),
        summary: definition.summary, source: definition.source, isEnabled: definition.isEnabled,
        diagnostics: SettingsValidation.diagnostics(for: definition))
    }
    let grouped = Dictionary(grouping: tools.indices, by: { tools[$0].commandName })
    for (_, indexes) in grouped where indexes.count > 1 {
      for index in indexes {
        tools[index].diagnostics.append(
          .init(
            severity: .error, field: .catalog, message: "Command name conflicts with another tool.")
        )
      }
    }
    return tools.sorted {
      if $0.origin != $1.origin { return $0.origin == .bundledTemplate }
      let order = $0.displayName.localizedStandardCompare($1.displayName)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }

  public func executableTools(templates: [ToolTemplate], snapshot: SettingsSnapshot)
    -> [ExecutableTool]
  {
    guard snapshot.availability == .ready else { return [] }
    return configuredTools(templates: templates, snapshot: snapshot).filter(\.isExecutable).map {
      ExecutableTool(
        manifest: $0.manifest, instructions: $0.instructions, id: $0.id,
        commandName: $0.commandName, source: $0.source, catalogRevision: snapshot.revision)
    }
  }

  public func newDraft(avoiding names: Set<String>) -> ToolDraft {
    ToolDraft(
      definition: UserToolDefinition(
        displayName: "Untitled Tool",
        commandName: availableName(base: "untitled-tool", avoiding: names),
        source: "export default async function(input) {\n  return {output: input.content};\n}\n",
        isEnabled: true))
  }

  public func duplicate(_ template: ToolTemplate, avoiding names: Set<String>) -> ToolDraft {
    let base = SettingsValidation.normalizedCommandName(template.commandName) + "-copy"
    var definition = UserToolDefinition(
      basedOnTemplateID: template.id,
      displayName: template.displayName + " Copy",
      commandName: availableName(base: base, avoiding: names),
      summary: template.summary, source: template.source, isEnabled: false)
    definition.manifest = template.manifest
    definition.instructions = template.instructions
    return ToolDraft(definition: definition)
  }

  private func availableName(base: String, avoiding names: Set<String>) -> String {
    if !names.contains(base) { return base }
    for suffix in 2...9_999 where !names.contains("\(base)-\(suffix)") {
      return "\(base)-\(suffix)"
    }
    return "tool-\(UUID().uuidString.prefix(8).lowercased())"
  }
}

public struct BundledTemplateEnvelope: Codable, Sendable {
  public var schemaVersion: Int
  public var templates: [ToolTemplate]
  public init(schemaVersion: Int = 1, templates: [ToolTemplate]) {
    self.schemaVersion = schemaVersion
    self.templates = templates
  }
}

public enum BundledTemplateLoader {
  public static func load(from url: URL?) throws -> [ToolTemplate] {
    guard let url else { return [] }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= SettingsLimits.maximumDecodedBytes else {
      throw SettingsStoreError.sizeLimit
    }
    let envelope = try JSONDecoder().decode(BundledTemplateEnvelope.self, from: data)
    guard envelope.schemaVersion == 1, envelope.templates.count <= SettingsLimits.maximumTemplates
    else { throw SettingsStoreError.unsupportedVersion }
    let ids = Set(envelope.templates.map(\.id)),
      names = Set(
        envelope.templates.map { SettingsValidation.normalizedCommandName($0.commandName) })
    guard ids.count == envelope.templates.count, names.count == envelope.templates.count,
      envelope.templates.allSatisfy({ SettingsValidation.diagnostics(for: $0).isEmpty })
    else { throw SettingsStoreError.invalidData }
    return envelope.templates.sorted(by: { $0.id < $1.id })
  }
}
