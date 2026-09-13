import Foundation

public struct CatalogModel: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let provider: String
    public let maximumOutputTokens: Int
}

/// Curated at release time. Browsing and validation never contact a provider.
public struct ModelCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let models: [CatalogModel]
    public static let defaultModelID = "openai/gpt-5.4-mini"
    public static let bundled = ModelCatalog(schemaVersion: 1, models: [
        .init(id: defaultModelID, name: "GPT-5.4 Mini", provider: "OpenAI", maximumOutputTokens: 8192),
        .init(id: "openai/gpt-5.4", name: "GPT-5.4", provider: "OpenAI", maximumOutputTokens: 8192),
        .init(id: "anthropic/claude-sonnet-4.6", name: "Claude Sonnet 4.6", provider: "Anthropic", maximumOutputTokens: 8192)
    ])
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw ToolPackageError.sizeLimit }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.models.count <= 100,
              Set(value.models.map(\.id)).count == value.models.count,
              value.models.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 &&
                  !$0.name.isEmpty && $0.name.utf8.count <= 128 && $0.provider.utf8.count <= 128 &&
                  (1...8192).contains($0.maximumOutputTokens) }) else { throw ToolPackageError.invalidManifest }
        return value
    }
    public func model(id: String) -> CatalogModel? { models.first { $0.id == id } }
    public func filter(_ query: String) -> [CatalogModel] {
        let query = String(query.prefix(256)).trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter { query.isEmpty || "\($0.name) \($0.provider)".localizedStandardContains(query) }
    }
}
