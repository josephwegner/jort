import Foundation

public struct ToolID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct RecordRevision: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public init(_ rawValue: Int64 = 0) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct CatalogRevision: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public init(_ rawValue: Int64 = 0) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ToolSourceRange: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}

public enum ToolDiagnosticSeverity: String, Codable, Sendable { case information, warning, error }
public enum ToolDiagnosticField: String, Codable, Sendable { case displayName, commandName, summary, source, catalog }

public struct ToolDiagnostic: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var severity: ToolDiagnosticSeverity
    public var field: ToolDiagnosticField
    public var message: String
    public var range: ToolSourceRange?
    public var isBlocking: Bool { severity == .error }
    public init(id: UUID = UUID(), severity: ToolDiagnosticSeverity, field: ToolDiagnosticField,
                message: String, range: ToolSourceRange? = nil) {
        self.id = id; self.severity = severity; self.field = field; self.message = message; self.range = range
    }
}

public struct ToolTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: ToolID
    public var version: Int
    public var displayName: String
    public var commandName: String
    public var summary: String
    public var source: String
    public var defaultEnabled: Bool
    public init(id: ToolID, version: Int = 1, displayName: String, commandName: String,
                summary: String = "", source: String, defaultEnabled: Bool = true) {
        self.id = id; self.version = version; self.displayName = displayName; self.commandName = commandName
        self.summary = summary; self.source = source; self.defaultEnabled = defaultEnabled
    }
}

public struct UserToolDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: ToolID
    public var revision: RecordRevision
    public var basedOnTemplateID: ToolID?
    public var displayName: String
    public var commandName: String
    public var summary: String
    public var source: String
    public var isEnabled: Bool
    public init(id: ToolID = ToolID(UUID().uuidString.lowercased()), revision: RecordRevision = RecordRevision(),
                basedOnTemplateID: ToolID? = nil, displayName: String, commandName: String,
                summary: String = "", source: String, isEnabled: Bool = false) {
        self.id = id; self.revision = revision; self.basedOnTemplateID = basedOnTemplateID
        self.displayName = displayName; self.commandName = commandName; self.summary = summary
        self.source = source; self.isEnabled = isEnabled
    }
}

public struct ToolDraft: Equatable, Sendable {
    public var definition: UserToolDefinition
    public let baseRevision: RecordRevision?
    public let original: UserToolDefinition?
    public var isDirty: Bool { original != definition }
    public init(definition: UserToolDefinition, baseRevision: RecordRevision? = nil, original: UserToolDefinition? = nil) {
        self.definition = definition; self.baseRevision = baseRevision; self.original = original
    }
    public static func new() -> ToolDraft {
        ToolDraft(definition: UserToolDefinition(displayName: "Untitled Tool", commandName: "untitled-tool", source: ""))
    }
}

public enum SettingsAvailability: Equatable, Sendable {
    case loading
    case ready
    case unavailable(String)
}

public struct SettingsSnapshot: Equatable, Sendable {
    public var revision: CatalogRevision
    public var preferences: [String: String]
    public var templateOverrides: [ToolID: Bool]
    public var customTools: [UserToolDefinition]
    public var availability: SettingsAvailability
    public init(revision: CatalogRevision = CatalogRevision(), preferences: [String: String] = [:],
                templateOverrides: [ToolID: Bool] = [:], customTools: [UserToolDefinition] = [],
                availability: SettingsAvailability = .ready) {
        self.revision = revision; self.preferences = preferences; self.templateOverrides = templateOverrides
        self.customTools = customTools; self.availability = availability
    }
}

public enum ToolOrigin: String, Sendable { case bundledTemplate, custom }

public struct ConfiguredTool: Identifiable, Equatable, Sendable {
    public var id: ToolID
    public var origin: ToolOrigin
    public var templateVersion: Int?
    public var recordRevision: RecordRevision?
    public var basedOnTemplateID: ToolID?
    public var displayName: String
    public var commandName: String
    public var summary: String
    public var source: String
    public var isEnabled: Bool
    public var diagnostics: [ToolDiagnostic]
    public var isExecutable: Bool { isEnabled && !diagnostics.contains(where: \.isBlocking) }
}

public struct ExecutableTool: Identifiable, Equatable, Sendable {
    public var id: ToolID
    public var commandName: String
    public var source: String
    public var catalogRevision: CatalogRevision
}

public enum SettingsLimits {
    public static let maximumCustomTools = 1_000
    public static let maximumTemplates = 1_000
    public static let maximumNameBytes = 256
    public static let maximumSummaryBytes = 4_096
    public static let maximumSourceBytes = 262_144
    public static let maximumDecodedBytes = 64 * 1_024 * 1_024
}

public enum SettingsValidation {
    public static func normalizedCommandName(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if result.first == "/" { result.removeFirst() }
        return result
    }

    public static func diagnostics(for definition: UserToolDefinition, occupiedNames: Set<String> = []) -> [ToolDiagnostic] {
        var diagnostics: [ToolDiagnostic] = []
        let display = definition.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = normalizedCommandName(definition.commandName)
        if display.isEmpty { diagnostics.append(.init(severity: .error, field: .displayName, message: "Display name is required.")) }
        if display.utf8.count > SettingsLimits.maximumNameBytes { diagnostics.append(.init(severity: .error, field: .displayName, message: "Display name is too long.")) }
        let commandScalars = command.unicodeScalars
        let validCommand = !command.isEmpty && command.utf8.count <= 64 && commandScalars.first.map {
            (97...122).contains(Int($0.value))
        } == true && commandScalars.allSatisfy {
            (97...122).contains(Int($0.value)) || (48...57).contains(Int($0.value)) || $0.value == 45
        }
        if !validCommand { diagnostics.append(.init(severity: .error, field: .commandName, message: "Use 1–64 lowercase letters, numbers, or hyphens, beginning with a letter.")) }
        if occupiedNames.contains(command) { diagnostics.append(.init(severity: .error, field: .commandName, message: "That command name is already in use.")) }
        if definition.summary.utf8.count > SettingsLimits.maximumSummaryBytes { diagnostics.append(.init(severity: .error, field: .summary, message: "Description is too long.")) }
        if definition.source.utf8.count > SettingsLimits.maximumSourceBytes { diagnostics.append(.init(severity: .error, field: .source, message: "JavaScript source exceeds 256 KiB.")) }
        if definition.source.unicodeScalars.contains(where: { $0.value == 0 }) { diagnostics.append(.init(severity: .error, field: .source, message: "JavaScript source cannot contain NUL characters.")) }
        return diagnostics
    }

    public static func diagnostics(for template: ToolTemplate) -> [ToolDiagnostic] {
        diagnostics(for: UserToolDefinition(id: template.id, displayName: template.displayName,
            commandName: template.commandName, summary: template.summary, source: template.source,
            isEnabled: template.defaultEnabled))
    }
}
