import JortToolContracts
import Foundation
import Darwin

public struct RegisteredToolPackage: Identifiable, Equatable, Sendable {
  public var id: String { package.manifest.id }
  public let package: ToolPackage
  public let isOverride: Bool
  public let isBundled: Bool
  public let isEnabled: Bool
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
  public var executable: [ToolPackage] {
    packages.filter {
      $0.isEnabled
        && ($0.package.manifest.executorType == .javascript
          || ModelCatalog.bundled.model(id: $0.package.manifest.modelID ?? "") != nil)
    }.map(\.package)
  }
}

/// Package files are immutable generations. An atomic index swap publishes an edit;
/// old generations remain available for recovery, and shipped files are never written.
public actor ToolPackageRegistry {
  struct InstalledGenerations: Codable {
    var current: String
    var previous: [String] = []
  }
  private struct LegacyIndex: Codable {
    var schemaVersion: Int
    var installed: [String: String]
    var disabled: Set<String>
  }
  private struct Index: Codable {
    var schemaVersion = 2
    var installed: [String: InstalledGenerations] = [:]
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
  private let validator: any ToolPackageValidator
  private let inject: @Sendable (ToolPublicationStage) throws -> Void
  private var storage: ToolPackageStorage { ToolPackageStorage(root: installedDirectory) }
  private var recoveryHeld = false
  private var trusted = false
  private var snapshot = ToolRegistrySnapshot()

  public init(
    validator: any ToolPackageValidator = UnavailableToolValidator(),
    bundledDirectory: URL, installedDirectory: URL,
    inject: @escaping @Sendable (ToolPublicationStage) throws -> Void = { _ in }
  ) {
    self.validator = validator
    self.inject = inject
    self.bundledDirectory = bundledDirectory
    self.installedDirectory = installedDirectory
  }

  private var operationActive = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private func acquire() async {
    if !operationActive {
      operationActive = true
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }
  private func release() {
    if waiting.isEmpty { operationActive = false } else { waiting.removeFirst().resume() }
  }
  public func inspect() async throws -> ToolRegistrySnapshot {
    await acquire()
    defer { release() }
    return try await inspectLocked()
  }
  public func reload() async throws {
    await acquire()
    defer { release() }
    try await reloadLocked()
  }
  public func save(
    _ package: ToolPackage, enabled: Bool? = nil,
    replacingVersion: Int? = nil, requireAbsent: Bool = false
  ) async throws -> ToolRegistrySnapshot {
    await acquire()
    defer { release() }
    return try await saveLocked(
      package, enabled: enabled, replacingVersion: replacingVersion, requireAbsent: requireAbsent)
  }
  public func setEnabled(id: String, enabled: Bool) async throws -> ToolRegistrySnapshot {
    await acquire()
    defer { release() }
    return try await setEnabledLocked(id: id, enabled: enabled)
  }
  public func remove(id: String) async throws -> ToolRegistrySnapshot {
    await acquire()
    defer { release() }
    return try await removeLocked(id: id)
  }

  private func inspectLocked() async throws -> ToolRegistrySnapshot {
    if !loaded { try await reloadLocked() }
    return snapshot
  }

  private func reloadLocked() async throws {
    loaded = false
    trusted = false
    let parent = try storage.directory()
    defer { close(parent) }
    let names = try storage.children(parent)
    recoveryHeld = names.contains { $0.hasPrefix("Recovery-") }
    guard names.contains("index.json") else {
      index = Index()
      snapshot = await resolve(index)
      loaded = true
      if recoveryHeld { addRecoveryDiagnostic() }
      return
    }
    let data = try storage.read("index.json", parent: parent)
    struct Header: Decodable { let schemaVersion: Int }
    let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
    let candidate: Index
    if version == 1 {
      let legacy = try JSONDecoder().decode(LegacyIndex.self, from: data)
      candidate = Index(
        installed: legacy.installed.mapValues {
          InstalledGenerations(current: $0)
        }, disabled: legacy.disabled)
      try validate(candidate)
      for (id, generations) in candidate.installed {
        let package = try ToolPackage.load(
          from: installedDirectory.appendingPathComponent(generations.current))
        guard package.manifest.id == id else { throw ToolPackageError.invalidManifest }
        try package.validate()
        try await validator.validatePackage(package)
      }
      // Kept until a later successful v2 reopen, never during migration itself.
      if names.contains("index.pre-v2.json") {
        guard try storage.read("index.pre-v2.json", parent: parent) == data else {
          throw ToolPackageError.invalidManifest
        }
      } else {
        try storage.write(data, name: "index.pre-v2.json", parent: parent)
        try storage.sync(parent)
      }
      try await commit(candidate)
    } else {
      guard version == 2 else { throw ToolPackageError.unsupportedContract }
      candidate = try JSONDecoder().decode(Index.self, from: data)
      try validate(candidate)
      index = candidate
      snapshot = await resolve(candidate)
      trusted = true
      if !recoveryHeld,
        !snapshot.candidates.contains(where: { $0.origin == .installed && $0.validation != .valid }
        ), names.contains("index.pre-v2.json")
      {
        _ = unlinkat(parent, "index.pre-v2.json", 0)
      }
      cleanup()
    }
    loaded = true
  }

  private func validate(_ value: Index) throws {
    guard value.schemaVersion == 2, value.installed.count <= 1000,
      value.disabled.count <= 2000,
      value.disabled.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
    else {
      throw ToolPackageError.unsupportedContract
    }
    var seen = Set<UUID>()
    for (id, generations) in value.installed {
      guard !id.isEmpty, id.utf8.count <= 256, generations.previous.count <= 5 else {
        throw ToolPackageError.invalidManifest
      }
      for name in [generations.current] + generations.previous {
        guard name.count == 36, let uuid = UUID(uuidString: name), seen.insert(uuid).inserted else {
          throw ToolPackageError.invalidPath
        }
      }
    }
  }

  public func install(from directory: URL) async throws -> ToolRegistrySnapshot {
    try await save(ToolPackage.load(from: directory))
  }

  private func saveLocked(
    _ package: ToolPackage, enabled: Bool? = nil, replacingVersion: Int? = nil,
    requireAbsent: Bool = false
  ) async throws -> ToolRegistrySnapshot {
    try package.validate()
    try await validator.validatePackage(package)
    if !loaded { try await reloadLocked() }
    let id = package.manifest.id
    if requireAbsent, index.installed[id] != nil { throw ToolPackageError.conflict }
    if let replacingVersion,
      snapshot.packages.first(where: { $0.id == id && !$0.isBundled })?.package.manifest.version
        != replacingVersion
    {
      throw ToolPackageError.conflict
    }
    guard index.installed[id] != nil || index.installed.count < 1000 else {
      throw ToolPackageError.sizeLimit
    }
    guard
      !snapshot.packages.contains(where: {
        $0.id != id && $0.package.manifest.command == package.manifest.command
      })
    else {
      throw ToolPackageError.conflict
    }
    // Refuse exhausted recovery capacity before writing another generation.
    let preflight = try storage.directory()
    defer { close(preflight) }
    let children = try storage.children(preflight)
    guard children.filter({ $0.hasPrefix("Recovery-") }).count < 32 else {
      throw ToolPackageError.sizeLimit
    }
    let generation = UUID().uuidString.lowercased()
    let staging = ".staging-" + generation
    let parent = try storage.directory()
    defer { close(parent) }
    try inject(.stagingCreate)
    let folder = try storage.makeDirectory(staging, parent: parent)
    defer { close(folder) }
    try inject(.manifestWrite)
    try storage.write(JSONEncoder().encode(package.manifest), name: "tool.json", parent: folder) {
      try inject(.manifestSync)
    }
    try inject(.implementationWrite)
    try storage.write(
      Data((package.manifest.executorType == .model ? package.instructions : package.source).utf8),
      name: package.manifest.executorType == .model ? "instructions.txt" : "tool.js", parent: folder
    ) { try inject(.implementationSync) }
    try inject(.stagingSync)
    try storage.sync(folder)
    try inject(.verification)
    let verified = try ToolPackage.load(from: installedDirectory.appendingPathComponent(staging))
    try verified.validate()
    guard verified == package else { throw ToolPackageError.invalidManifest }
    try inject(.generationRename)
    try storage.rename(staging, to: generation, parent: parent)
    try inject(.generationSync)
    try storage.sync(parent)
    var next = index
    let old = index.installed[id]
    // Only previously valid current packages become retained history.
    let validCurrent = snapshot.packages.contains { $0.id == id && !$0.isBundled }
    let history = old.map { (validCurrent ? [$0.current] : []) + $0.previous } ?? []
    next.installed[id] = InstalledGenerations(
      current: generation, previous: Array(history.prefix(5)))
    if let enabled { if enabled { next.disabled.remove(id) } else { next.disabled.insert(id) } }
    try await commit(next)
    return snapshot
  }

  private func setEnabledLocked(id: String, enabled: Bool) async throws -> ToolRegistrySnapshot {
    if !loaded { try await reloadLocked() }
    guard snapshot.packages.contains(where: { $0.id == id }) else {
      throw ToolPackageError.unavailable
    }
    var next = index
    if enabled { next.disabled.remove(id) } else { next.disabled.insert(id) }
    try await commit(next)
    return snapshot
  }

  private func removeLocked(id: String) async throws -> ToolRegistrySnapshot {
    if !loaded { try await reloadLocked() }
    guard index.installed[id] != nil else { throw ToolPackageError.unavailable }
    var next = index
    next.installed.removeValue(forKey: id)
    next.disabled.remove(id)
    try await commit(next)
    return snapshot
  }

  public func restore(id: String) async throws -> ToolRegistrySnapshot { try await remove(id: id) }

  private func commit(_ next: Index) async throws {
    try validate(next)
    let parent = try storage.directory()
    defer { close(parent) }
    let names = try storage.children(parent)
    guard names.filter({ $0.hasPrefix("Recovery-") }).count < 32 else {
      throw ToolPackageError.sizeLimit
    }
    let data = try JSONEncoder().encode(next)
    let token = UUID().uuidString.lowercased()
    let hold = "Recovery-" + token
    try inject(.recoveryWrite)
    let recovery = try storage.makeDirectory(hold, parent: parent)
    defer { close(recovery) }
    if names.contains("index.json") {
      try storage.write(
        storage.read("index.json", parent: parent), name: "prior-index.json", parent: recovery)
    }
    try storage.write(data, name: "attempted-index.json", parent: recovery)
    try storage.sync(recovery)
    try storage.sync(parent)
    let temporary = ".index-" + token
    var replaced = false
    do {
      try inject(.indexWrite)
      try storage.write(data, name: temporary, parent: parent) { try inject(.indexSync) }
      try inject(.indexRename)
      try storage.rename(temporary, to: "index.json", parent: parent, replacing: true)
      replaced = true
      try inject(.indexDirectorySync)
      try storage.sync(parent)
      try inject(.memoryPublication)
      index = next
      snapshot = await resolve(next)
      trusted = true
    } catch {
      if replaced {
        recoveryHeld = true
        trusted = false
        if let visible = try? JSONDecoder().decode(
          Index.self, from: storage.read("index.json", parent: parent)),
          (try? validate(visible)) != nil
        {
          index = visible
          snapshot = await resolve(visible)
        }
        addRecoveryDiagnostic()
        loaded = true
        throw ToolPublicationError.uncertain
      }
      // Before rename the old authority is unchanged. Failure to remove this hold is conservative.
      try? storage.removePackage(
        hold, parent: parent, allowed: ["prior-index.json", "attempted-index.json"])
      _ = unlinkat(parent, temporary, 0)
      throw error
    }
    do {
      try storage.removePackage(
        hold, parent: parent, allowed: ["prior-index.json", "attempted-index.json"])
      try storage.sync(parent)
    } catch {
      snapshot.diagnostics.append("Recovery files were retained; use Show Recovery Files.")
    }
    recoveryHeld = (try? storage.children(parent).contains { $0.hasPrefix("Recovery-") }) ?? true
    cleanup()
  }

  private func addRecoveryDiagnostic() {
    snapshot.diagnostics.append(
      "Tool recovery files are preserved. Use Show Recovery Files before repairing the catalog.")
  }

  private func cleanup() {
    guard trusted else { return }
    if recoveryHeld {
      addRecoveryDiagnostic()
      return
    }
    do {
      let parent = try storage.directory()
      defer { close(parent) }
      let names = try storage.children(parent)
      let referenced = Set(index.installed.values.flatMap { [$0.current] + $0.previous })
      var removalFailed = false
      for name in names {
        let staging =
          name.hasPrefix(".staging-") && name.count == 45
          && UUID(uuidString: String(name.dropFirst(9))) != nil
        guard
          staging
            || (name.count == 36 && UUID(uuidString: name) != nil && !referenced.contains(name))
        else { continue }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
          info.st_mode & S_IFMT == S_IFDIR
        else { continue }
        do {
          try inject(.cleanup)
          try storage.removePackage(
            name, parent: parent, allowed: ["tool.json", "tool.js", "instructions.txt"])
        } catch { removalFailed = true }
      }
      try storage.sync(parent)
      if removalFailed { throw ToolPackageError.invalidPath }
    } catch {
      snapshot.diagnostics.append(
        "Some obsolete tool files could not be removed. Cleanup will retry on reload or save.")
    }
    snapshot.diagnostics = Array(snapshot.diagnostics.prefix(100))
  }

  private func resolve(_ index: Index) async -> ToolRegistrySnapshot {
    var result = ToolRegistrySnapshot()
    var candidates: [ResolutionCandidate] = []
    var bundles: [String: [Int]] = [:]
    func diagnostic(_ value: String) -> String { String(value.prefix(256)) }
    func manifestID(at directory: URL) -> String? {
      let manifest = directory.appendingPathComponent("tool.json")
      guard
        let directoryValues = try? directory.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ]),
        directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
        let values = try? manifest.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]),
        values.isRegularFile == true, values.isSymbolicLink != true,
        (values.fileSize ?? Int.max) <= 16_384,
        let data = try? Data(contentsOf: manifest), data.count <= 16_384,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let id = object["id"] as? String, id.utf8.count <= 256
      else { return nil }
      return id
    }
    func appendDiagnostic(_ value: String) { result.diagnostics.append(diagnostic(value)) }
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: bundledDirectory,
        includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
    for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(1000) {
      do {
        let package = try ToolPackage.load(from: url)
        try package.validate()
        try await validator.validatePackage(package)
        let candidate = ResolutionCandidate(
          inspection: .init(
            packageID: package.manifest.id, origin: .bundled,
            isOverride: false, isEnabled: !index.disabled.contains(package.manifest.id),
            validation: .valid, diagnostic: nil), package: package)
        bundles[package.manifest.id, default: []].append(candidates.count)
        candidates.append(candidate)
      } catch {
        let message = diagnostic("Invalid bundled package: \(url.lastPathComponent.prefix(80))")
        let id = manifestID(at: url)
        candidates.append(
          .init(
            inspection: .init(
              packageID: id, origin: .bundled,
              isOverride: false, isEnabled: id.map { !index.disabled.contains($0) } ?? true,
              validation: .invalid, diagnostic: message), package: nil))
        appendDiagnostic(message)
      }
    }
    var resolved: [String: RegisteredToolPackage] = [:]
    var resolvedCandidate: [String: Int] = [:]
    for (id, indices) in bundles {
      if indices.count == 1, let package = candidates[indices[0]].package {
        resolved[id] = .init(
          package: package, isOverride: false, isBundled: true,
          isEnabled: !index.disabled.contains(id))
        resolvedCandidate[id] = indices[0]
      } else {
        let message = diagnostic("Duplicate bundled ID: \(id.prefix(80))")
        for index in indices {
          candidates[index].inspection = .init(
            packageID: id, origin: .bundled, isOverride: false,
            isEnabled: candidates[index].inspection.isEnabled, validation: .conflicting,
            diagnostic: message)
        }
        appendDiagnostic(message)
      }
    }
    let bundledIDs = Set(candidates.compactMap(\.inspection.packageID))
    for (id, generations) in index.installed.sorted(by: { $0.key < $1.key }) {
      let generation = generations.current
      let isOverride = bundledIDs.contains(id)
      do {
        guard UUID(uuidString: generation) != nil else { throw ToolPackageError.invalidPath }
        let package = try ToolPackage.load(
          from: installedDirectory.appendingPathComponent(generation))
        guard package.manifest.id == id else { throw ToolPackageError.invalidManifest }
        try package.validate()
        try await validator.validatePackage(package)
        let candidate = ResolutionCandidate(
          inspection: .init(
            packageID: id, origin: .installed,
            isOverride: isOverride, isEnabled: !index.disabled.contains(id), validation: .valid,
            diagnostic: nil), package: package)
        resolved[id] = .init(
          package: package, isOverride: isOverride, isBundled: false,
          isEnabled: !index.disabled.contains(id))
        resolvedCandidate[id] = candidates.count
        candidates.append(candidate)
      } catch {
        let message = diagnostic("Invalid installed package: \(id.prefix(80))")
        candidates.append(
          .init(
            inspection: .init(
              packageID: id, origin: .installed, isOverride: isOverride,
              isEnabled: !index.disabled.contains(id), validation: .invalid, diagnostic: message),
            package: nil))
        appendDiagnostic(message)
      }
    }
    let groups = Dictionary(grouping: resolved.values, by: { $0.package.manifest.command })
    for (command, packages) in groups.sorted(by: { $0.key < $1.key }) {
      if packages.count == 1 {
        result.packages.append(packages[0])
      } else {
        let message = diagnostic("Command conflict: \(command.prefix(80))")
        for package in packages {
          if let index = resolvedCandidate[package.id] {
            candidates[index].inspection = .init(
              packageID: package.id, origin: candidates[index].inspection.origin,
              isOverride: candidates[index].inspection.isOverride,
              isEnabled: candidates[index].inspection.isEnabled,
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
