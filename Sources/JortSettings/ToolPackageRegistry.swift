import Foundation

public struct RegisteredToolPackage: Identifiable, Equatable, Sendable {
    public var id: String { package.manifest.id }
    public let package: ToolPackage
    public let isOverride: Bool
    public let isBundled: Bool
    public let isEnabled: Bool
}

public enum ToolPackageOrigin: String, Equatable, Sendable {
    case bundled, installed
}

public enum ToolPackageValidation: String, Equatable, Sendable {
    case valid, invalid, conflicting
}

public struct ToolPackageCandidate: Equatable, Sendable {
    public let packageID: String?
    public let origin: ToolPackageOrigin
    public let isOverride: Bool
    public let isEnabled: Bool
    public let validation: ToolPackageValidation
    public let diagnostic: String?
}

public struct ToolRegistrySnapshot: Equatable, Sendable {
    public var packages: [RegisteredToolPackage] = []
    public var candidates: [ToolPackageCandidate] = []
    public var diagnostics: [String] = []
    public var executable: [ToolPackage] { packages.filter(\.isEnabled).map(\.package) }
}

/// Package files are immutable generations. An atomic index swap publishes an edit;
/// old generations remain available for recovery, and shipped files are never written.
public actor ToolPackageRegistry {
    private struct Index: Codable {
        var schemaVersion = 1
        var installed: [String: String] = [:]
        var disabled: Set<String> = []
    }
    private struct ResolutionCandidate {
        var inspection: ToolPackageCandidate
        var package: ToolPackage?
    }
    public let bundledDirectory: URL
    public let installedDirectory: URL
    private var index = Index()
    private var loaded = false
    private var snapshot = ToolRegistrySnapshot()

    public init(bundledDirectory: URL, installedDirectory: URL) {
        self.bundledDirectory = bundledDirectory; self.installedDirectory = installedDirectory
    }

    public func inspect() throws -> ToolRegistrySnapshot {
        if !loaded { try reload() }
        return snapshot
    }

    public func reload() throws {
        let url = installedDirectory.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 1_048_576 else { throw ToolPackageError.sizeLimit }
            let candidate = try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
            guard candidate.schemaVersion == 1, candidate.installed.count <= 1000,
                  candidate.disabled.count <= 2000 else { throw ToolPackageError.unsupportedContract }
            index = candidate
        }
        snapshot = resolve(index); loaded = true
    }

    public func install(from directory: URL) throws -> ToolRegistrySnapshot {
        try save(ToolPackage.load(from: directory))
    }

    public func save(_ package: ToolPackage, enabled: Bool? = nil, replacingVersion: Int? = nil, requireAbsent: Bool = false) throws -> ToolRegistrySnapshot {
        if !loaded { try reload() }
        try ToolRuntime.validate(package)
        let id = package.manifest.id
        if requireAbsent, index.installed[id] != nil { throw ToolPackageError.conflict }
        if let replacingVersion, snapshot.packages.first(where: { $0.id == id && !$0.isBundled })?.package.manifest.version != replacingVersion { throw ToolPackageError.conflict }
        guard index.installed[id] != nil || index.installed.count < 1000 else { throw ToolPackageError.sizeLimit }
        guard !snapshot.packages.contains(where: { $0.id != id && $0.package.manifest.command == package.manifest.command }) else {
            throw ToolPackageError.conflict
        }
        let generation = UUID().uuidString.lowercased()
        let directory = installedDirectory.appendingPathComponent(generation, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(package.manifest).write(to: directory.appendingPathComponent("tool.json"), options: .atomic)
        try Data(package.source.utf8).write(to: directory.appendingPathComponent("tool.js"), options: .atomic)
        var next = index; next.installed[id] = generation
        if let enabled { if enabled { next.disabled.remove(id) } else { next.disabled.insert(id) } }
        try commit(next)
        return snapshot
    }

    public func setEnabled(id: String, enabled: Bool) throws -> ToolRegistrySnapshot {
        if !loaded { try reload() }
        guard snapshot.packages.contains(where: { $0.id == id }) else { throw ToolPackageError.unavailable }
        var next = index
        if enabled { next.disabled.remove(id) } else { next.disabled.insert(id) }
        try commit(next); return snapshot
    }

    public func remove(id: String) throws -> ToolRegistrySnapshot {
        if !loaded { try reload() }
        guard index.installed[id] != nil else { throw ToolPackageError.unavailable }
        var next = index; next.installed.removeValue(forKey: id); next.disabled.remove(id)
        try commit(next); return snapshot
    }

    public func restore(id: String) throws -> ToolRegistrySnapshot { try remove(id: id) }

    private func commit(_ next: Index) throws {
        try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: installedDirectory.appendingPathComponent("index.json"), options: .atomic)
        index = next; snapshot = resolve(next)
    }

    private func resolve(_ index: Index) -> ToolRegistrySnapshot {
        var result = ToolRegistrySnapshot()
        var candidates: [ResolutionCandidate] = []
        var bundles: [String: [Int]] = [:]
        func diagnostic(_ value: String) -> String { String(value.prefix(256)) }
        func manifestID(at directory: URL) -> String? {
            let manifest = directory.appendingPathComponent("tool.json")
            guard let directoryValues = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
                  let values = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 16_384,
                  let data = try? Data(contentsOf: manifest), data.count <= 16_384,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String, id.utf8.count <= 256 else { return nil }
            return id
        }
        func appendDiagnostic(_ value: String) { result.diagnostics.append(diagnostic(value)) }
        let urls = (try? FileManager.default.contentsOfDirectory(at: bundledDirectory,
            includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(1000) {
            do {
                let package = try ToolPackage.load(from: url); try ToolRuntime.validate(package)
                let candidate = ResolutionCandidate(inspection: .init(packageID: package.manifest.id, origin: .bundled,
                    isOverride: false, isEnabled: !index.disabled.contains(package.manifest.id), validation: .valid, diagnostic: nil), package: package)
                bundles[package.manifest.id, default: []].append(candidates.count); candidates.append(candidate)
            } catch {
                let message = diagnostic("Invalid bundled package: \(url.lastPathComponent.prefix(80))")
                let id = manifestID(at: url)
                candidates.append(.init(inspection: .init(packageID: id, origin: .bundled,
                    isOverride: false, isEnabled: id.map { !index.disabled.contains($0) } ?? true,
                    validation: .invalid, diagnostic: message), package: nil))
                appendDiagnostic(message)
            }
        }
        var resolved: [String: RegisteredToolPackage] = [:]
        var resolvedCandidate: [String: Int] = [:]
        for (id, indices) in bundles {
            if indices.count == 1, let package = candidates[indices[0]].package {
                resolved[id] = .init(package: package, isOverride: false, isBundled: true, isEnabled: !index.disabled.contains(id))
                resolvedCandidate[id] = indices[0]
            } else {
                let message = diagnostic("Duplicate bundled ID: \(id.prefix(80))")
                for index in indices {
                    candidates[index].inspection = .init(packageID: id, origin: .bundled, isOverride: false,
                        isEnabled: candidates[index].inspection.isEnabled, validation: .conflicting, diagnostic: message)
                }
                appendDiagnostic(message)
            }
        }
        let bundledIDs = Set(candidates.compactMap(\.inspection.packageID))
        for (id, generation) in index.installed.sorted(by: { $0.key < $1.key }) {
            let isOverride = bundledIDs.contains(id)
            do {
                guard UUID(uuidString: generation) != nil else { throw ToolPackageError.invalidPath }
                let package = try ToolPackage.load(from: installedDirectory.appendingPathComponent(generation))
                guard package.manifest.id == id else { throw ToolPackageError.invalidManifest }
                try ToolRuntime.validate(package)
                let candidate = ResolutionCandidate(inspection: .init(packageID: id, origin: .installed,
                    isOverride: isOverride, isEnabled: !index.disabled.contains(id), validation: .valid, diagnostic: nil), package: package)
                resolved[id] = .init(package: package, isOverride: isOverride, isBundled: false, isEnabled: !index.disabled.contains(id))
                resolvedCandidate[id] = candidates.count; candidates.append(candidate)
            } catch {
                let message = diagnostic("Invalid installed package: \(id.prefix(80))")
                candidates.append(.init(inspection: .init(packageID: id, origin: .installed, isOverride: isOverride,
                    isEnabled: !index.disabled.contains(id), validation: .invalid, diagnostic: message), package: nil))
                appendDiagnostic(message)
            }
        }
        let groups = Dictionary(grouping: resolved.values, by: { $0.package.manifest.command })
        for (command, packages) in groups.sorted(by: { $0.key < $1.key }) {
            if packages.count == 1 { result.packages.append(packages[0]) }
            else {
                let message = diagnostic("Command conflict: \(command.prefix(80))")
                for package in packages {
                    if let index = resolvedCandidate[package.id] {
                        candidates[index].inspection = .init(packageID: package.id, origin: candidates[index].inspection.origin,
                            isOverride: candidates[index].inspection.isOverride, isEnabled: candidates[index].inspection.isEnabled,
                            validation: .conflicting, diagnostic: message)
                    }
                }
                appendDiagnostic(message)
            }
        }
        result.packages.sort { $0.package.manifest.command < $1.package.manifest.command }
        result.candidates = candidates.map(\.inspection)
        result.diagnostics = Array(result.diagnostics.sorted().prefix(100))
        return result
    }
}
