import Foundation
import Darwin
import JortDocument

/// Only manifest-advertised bytes are recovery candidates. The active slot is never overwritten.
struct RecoveryCheckpoints {
  static let names = ["Recovery-0.json", "Recovery-1.json", "Recovery-manifest.json"]
  struct Entry: Codable, Equatable {
    let slot: Int
    let revision: Int64
    let documentID: UUID
    let checksum: String
  }
  struct Manifest: Codable {
    let version: Int
    let entries: [Entry]
  }
  let directory: URL
  let inject: @Sendable (StoreStage) throws -> Void
  private var manifestURL: URL { directory.appendingPathComponent(Self.names[2]) }

  private func manifest() throws -> Manifest? {
    let data: Data
    do {
      data = try BoundedRecoveryReader(directory: directory, inject: inject).read(.manifest)
    } catch let error as RecoveryRejection where error.reason == .missing { return nil }
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    guard manifest.version <= 1 else { throw StoreError.unsupportedVersion }
    guard manifest.version == 1, !manifest.entries.isEmpty, manifest.entries.count <= 2,
      Set(manifest.entries.map(\.slot)).count == manifest.entries.count,
      manifest.entries.allSatisfy({ (0...1).contains($0.slot) && $0.revision >= 0 }),
      Set(manifest.entries.map(\.documentID)).count == 1
    else { throw StoreError.invalidPayload }
    return manifest
  }
  struct Attempt {
    let snapshot: DocumentSnapshot?
    let role: RecoverySourceRole?
    let rejections: [RecoveryRejection]
    let unsupported: Bool
  }
  func attempt() -> Attempt {
    var rejected: [RecoveryRejection] = []
    func rejection(_ error: Error, role: RecoverySourceRole) -> RecoveryRejection {
      if let value = error as? RecoveryRejection { return value }
      let reason: RecoveryRejectionReason
      switch error as? StoreError {
      case .unsupportedVersion: reason = .unsupportedVersion
      case .checksumMismatch: reason = .checksumMismatch
      case .sizeLimit: reason = .oversized
      case .io, .injected, .sqlite: reason = .io
      default: reason = .malformed
      }
      return RecoveryRejection(role: role, reason: reason)
    }
    let declared: Manifest?
    do { declared = try manifest() } catch {
      let value = rejection(error, role: .manifest)
      rejected.append(value)
      if value.reason == .unsupportedVersion {
        return Attempt(snapshot: nil, role: nil, rejections: rejected, unsupported: true)
      }
      declared = nil
    }
    if let declared {
      for entry in declared.entries.sorted(by: { $0.revision > $1.revision }) {
        let role: RecoverySourceRole = entry.slot == 0 ? .slot0 : .slot1
        do {
          let data = try BoundedRecoveryReader(directory: directory, inject: inject).read(role)
          guard PersistenceFormat.checksum(data) == entry.checksum else {
            throw RecoveryRejection(role: role, reason: .checksumMismatch)
          }
          let snapshot = try PersistenceFormat.decode(data, reportChecksumMismatch: true).snapshot
          guard snapshot.documentID == entry.documentID, snapshot.revision == entry.revision else {
            throw RecoveryRejection(role: role, reason: .malformed)
          }
          return Attempt(snapshot: snapshot, role: role, rejections: rejected, unsupported: false)
        } catch {
          let value = rejection(error, role: role)
          rejected.append(value)
          if value.reason == .unsupportedVersion {
            return Attempt(snapshot: nil, role: nil, rejections: rejected, unsupported: true)
          }
        }
      }
    } else if rejected.isEmpty {
      rejected.append(RecoveryRejection(role: .manifest, reason: .missing))
    }
    do {
      let data = try BoundedRecoveryReader(directory: directory, inject: inject).read(.legacy)
      let snapshot = try PersistenceFormat.decode(data, reportChecksumMismatch: true).snapshot
      return Attempt(snapshot: snapshot, role: .legacy, rejections: rejected, unsupported: false)
    } catch {
      let value = rejection(error, role: .legacy)
      rejected.append(value)
      return Attempt(
        snapshot: nil, role: nil, rejections: rejected,
        unsupported: value.reason == .unsupportedVersion)
    }
  }
  func recover() throws -> DocumentSnapshot {
    let result = attempt()
    if result.unsupported { throw StoreError.unsupportedVersion }
    guard let snapshot = result.snapshot else { throw StoreError.invalidPayload }
    return snapshot
  }
  private func verified(_ entry: Entry) throws -> DocumentSnapshot? {
    do {
      let data = try BoundedRecoveryReader(directory: directory, inject: inject).read(
        entry.slot == 0 ? .slot0 : .slot1)
      guard PersistenceFormat.checksum(data) == entry.checksum else { return nil }
      let snapshot = try PersistenceFormat.decode(data, reportChecksumMismatch: true).snapshot
      guard snapshot.revision == entry.revision, snapshot.documentID == entry.documentID else {
        return nil
      }
      return snapshot
    } catch StoreError.unsupportedVersion { throw StoreError.unsupportedVersion } catch {
      return nil
    }
  }
  func publish(_ data: Data, snapshot: DocumentSnapshot) throws {
    let previous = try manifest()?.entries ?? []
    var retained: [Entry] = []
    for entry in previous.sorted(by: { $0.revision > $1.revision })
    where entry.documentID == snapshot.documentID {
      if try verified(entry) != nil {
        retained = [entry]
        break
      }
    }
    let slot = retained.first.map { 1 - $0.slot } ?? 0
    try inject(.checkpointWrite)
    try publishFile(data, to: directory.appendingPathComponent(Self.names[slot]))
    try inject(.checkpointVerify)
    let stored = try BoundedRecoveryReader(directory: directory, inject: inject).read(
      slot == 0 ? .slot0 : .slot1)
    guard stored == data, try PersistenceFormat.decode(stored).snapshot == snapshot else {
      throw StoreError.invalidPayload
    }
    let entry = Entry(
      slot: slot, revision: snapshot.revision, documentID: snapshot.documentID,
      checksum: PersistenceFormat.checksum(data))
    let value = Manifest(version: 1, entries: [entry] + retained)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try inject(.checkpointManifest)
    try publishFile(encoder.encode(value), to: manifestURL)
    try inject(.checkpointPublished)
    guard try manifest()?.entries == value.entries else { throw StoreError.invalidPayload }
  }
  private func publishFile(_ data: Data, to destination: URL) throws {
    let temporary = directory.appendingPathComponent(".Checkpoint-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary, options: .withoutOverwriting)
    let file = Darwin.open(temporary.path, O_RDONLY | O_NOFOLLOW)
    guard file >= 0 else { throw StoreError.io("checkpoint open: \(errno)") }
    defer { Darwin.close(file) }
    try inject(.checkpointFileSync)
    guard fsync(file) == 0 else { throw StoreError.io("checkpoint sync: \(errno)") }
    try inject(.checkpointRename)
    guard Darwin.rename(temporary.path, destination.path) == 0 else {
      throw StoreError.io("checkpoint rename: \(errno)")
    }
    let folder = Darwin.open(directory.path, O_RDONLY)
    guard folder >= 0 else { throw StoreError.io("checkpoint directory: \(errno)") }
    defer { Darwin.close(folder) }
    try inject(.checkpointDirectorySync)
    guard fsync(folder) == 0 else { throw StoreError.io("checkpoint directory sync: \(errno)") }
  }
}
