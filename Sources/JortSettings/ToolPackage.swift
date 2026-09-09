import Foundation

public enum ToolInputMode: String, Codable, CaseIterable, Sendable {
    case contained, contextual, ephemeralSingleLine, ephemeralMultiline
    public var isEphemeral: Bool { self == .ephemeralSingleLine || self == .ephemeralMultiline }
    public var defaultOperation: ToolOutputOperation {
        self == .contextual ? .replaceContext : (isEphemeral ? .insertAtInvocation : .replaceInvocation)
    }
}

public enum ToolOutputOperation: String, Codable, CaseIterable, Sendable {
    case replaceInvocation = "replace-invocation"
    case replaceContext = "replace-context"
    case insertAtInvocation = "insert-at-invocation"
}

/// Version one packages export `default async function(input)` from tool.js.
/// `input` has content, a captured UTC clock string, a captured UUID, and cancellation state.
public struct ToolManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var id: String
    public var version: Int
    public var name: String
    public var command: String
    public var description: String
    public var entryContract: Int = 1
    public var inputMode: ToolInputMode
    public var outputOperation: ToolOutputOperation
    public var maximumInputBytes: Int = 262_144
    public var maximumOutputBytes: Int = 262_144
    public var maximumOutputLines: Int = 10_000
    /// A bounded identity mapping, allowed only when entry/input/output contracts match.
    public var compatibleVersions: [Int]? = nil

    public init(id: String, version: Int = 1, name: String, command: String, description: String = "",
                inputMode: ToolInputMode = .contained, outputOperation: ToolOutputOperation? = nil) {
        self.id = id; self.version = version; self.name = name; self.command = command
        self.description = description; self.inputMode = inputMode
        self.outputOperation = outputOperation ?? inputMode.defaultOperation
    }

    public func validate() throws {
        guard schemaVersion == 1, entryContract == 1 else { throw ToolPackageError.unsupportedContract }
        guard version > 0, id.utf8.count <= 256,
              id.range(of: #"^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$"#, options: .regularExpression) != nil,
              command.range(of: #"^/[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 256, description.utf8.count <= 4096,
              (1...1_048_576).contains(maximumInputBytes),
              (1...1_048_576).contains(maximumOutputBytes),
              (1...100_000).contains(maximumOutputLines),
              (compatibleVersions?.count ?? 0) <= 32,
              compatibleVersions?.allSatisfy({ $0 > 0 && $0 < version }) ?? true,
              outputOperation != .replaceContext || inputMode == .contextual else {
            throw ToolPackageError.invalidManifest
        }
    }
}

public enum ToolPackageError: Error, Equatable, Sendable {
    case unsupportedContract, invalidManifest, invalidSource, sizeLimit, invalidPath, conflict, unavailable
}

public struct ToolPackage: Equatable, Sendable {
    public var manifest: ToolManifest
    public var source: String
    public init(manifest: ToolManifest, source: String) { self.manifest = manifest; self.source = source }
    public func validate() throws {
        try manifest.validate()
        guard !source.isEmpty, source.utf8.count <= SettingsLimits.maximumSourceBytes,
              !source.contains("\0") else { throw ToolPackageError.invalidSource }
    }

    public static func load(from directory: URL) throws -> Self {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ToolPackageError.invalidPath }
        func read(_ name: String, limit: Int) throws -> Data {
            let url = directory.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ToolPackageError.invalidPath }
            guard let size = values.fileSize, size <= limit else { throw ToolPackageError.sizeLimit }
            let data = try Data(contentsOf: url)
            guard data.count <= limit else { throw ToolPackageError.sizeLimit }
            return data
        }
        let manifest = try JSONDecoder().decode(ToolManifest.self, from: read("tool.json", limit: 16_384))
        guard let source = String(data: try read("tool.js", limit: SettingsLimits.maximumSourceBytes), encoding: .utf8) else {
            throw ToolPackageError.invalidSource
        }
        let package = Self(manifest: manifest, source: source)
        try package.validate()
        return package
    }
}
