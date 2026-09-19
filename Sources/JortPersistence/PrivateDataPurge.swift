import Darwin
import Foundation
import JortDocument
import SQLite3

/// Contains identity and hashes, never document text or caller-supplied paths.
struct PurgeMarker: Codable {
  let version: Int
  let operationID: UUID
  let documentID: UUID
  let revision: Int64
  let hash: String
  let originalHash: String
  let stage: String
  var phase: PurgePhase
  let targets: [String]

  func validate() throws {
    guard version == 1, revision >= 0, stage == ".Purge-\(operationID)",
      [hash, originalHash].allSatisfy({ $0.count == 64 && $0.allSatisfy { $0.isHexDigit } }),
      targets.count <= ManagedCopies.maximumEntries, Set(targets).count == targets.count,
      targets.contains(stage),
      targets.allSatisfy({ $0 != "Store" && (ManagedNames.bundle($0) || ManagedNames.file($0)) }),
      [.swapping, .cleaning].contains(phase)
    else { throw StoreError.io("Invalid purge marker shape") }
  }
}

extension SQLiteStore {
  private var markerURL: URL { directory.appendingPathComponent("Purge.json") }

  private func readPurgeMarker() throws -> PurgeMarker? {
    try ManagedCopies(root: directory).withRoot { root in
      let fd = openat(root, "Purge.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      if fd < 0 {
        if errno == ENOENT { return nil }
        throw StoreError.io("Purge marker open: \(errno)")
      }
      defer { Darwin.close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
        info.st_size >= 0, info.st_size <= 64 * 1024
      else { throw StoreError.invalidPayload }
      var bytes = [UInt8](repeating: 0, count: 64 * 1024 + 1)
      var count = 0
      while count < bytes.count {
        let readCount = bytes.withUnsafeMutableBytes {
          Darwin.read(fd, $0.baseAddress!.advanced(by: count), $0.count - count)
        }
        if readCount < 0 {
          if errno == EINTR { continue }
          throw StoreError.io("Purge marker read")
        }
        if readCount == 0 { break }
        count += readCount
      }
      guard count == info.st_size else { throw StoreError.invalidPayload }
      let marker = try JSONDecoder().decode(PurgeMarker.self, from: Data(bytes.prefix(count)))
      try marker.validate()
      return marker
    }
  }
  private func publishMarker(_ marker: PurgeMarker) throws {
    try marker.validate()
    let data = try JSONEncoder().encode(marker)
    guard data.count <= 64 * 1024 else { throw StoreError.sizeLimit }
    try inject(.purgeMarker)
    // The fixed marker contains no text; its atomic writer leaves no older content copy.
    try data.write(to: markerURL, options: .atomic)
    let fd = Darwin.open(markerURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw StoreError.io("Purge marker sync open") }
    defer { Darwin.close(fd) }
    guard fsync(fd) == 0 else { throw StoreError.io("Purge marker sync") }
    try ManagedCopies(root: directory, inject: inject).syncRoot()
    purgeMarker = marker
    purgePending = true
    try inject(.purgeMarkerPublished)
  }
  private func removeMarker() throws {
    let manager = ManagedCopies(root: directory, inject: inject)
    try manager.withRoot { fd in
      guard unlinkat(fd, "Purge.json", 0) == 0 || errno == ENOENT else {
        throw StoreError.io("Purge marker removal")
      }
      do { try manager.sync(fd) } catch {
        // Keep an on-disk retry record if durability of removal cannot be proved.
        if let purgeMarker { try? publishMarker(purgeMarker) }
        throw error
      }
    }
    try inject(.purgeMarkerRemoved)
    purgeMarker = nil
    purgePending = false
  }
  private func verifyCurrentOnly(_ url: URL, marker: PurgeMarker) throws -> DocumentSnapshot {
    try ManagedCopies(root: directory).withRoot {
      try ManagedCopies.validateBundle(url.lastPathComponent, at: $0)
    }
    let expected: Set<String> = ["Jort.sqlite", "Recovery-0.json", "Recovery-manifest.json"]
    try ManagedCopies(root: url).withRoot { fd in
      for name in try ManagedCopies.names(fd) {
        if name == "Jort.sqlite-shm" {
          guard try ManagedCopies.metadata(name, at: fd).st_size <= 32768 else {
            throw StoreError.invalidPayload
          }
        } else if name == "Jort.sqlite-wal" {
          guard try ManagedCopies.metadata(name, at: fd).st_size == 0 else {
            throw StoreError.io("Nonempty replacement companion: \(name)")
          }
        } else {
          guard expected.contains(name) else {
            throw StoreError.io("Unexpected replacement file: \(name)")
          }
        }
      }
    }
    let reader = try Connection(directory: url, create: false, readOnly: true)
    defer { try? reader.close() }
    let loaded = try reader.read()
    let data = try PersistenceFormat.encode(loaded.snapshot)
    guard try reader.purgeIdentity() == marker.operationID,
      loaded.sqlVersion == PersistenceFormat.sqliteVersion,
      loaded.payloadVersion == PersistenceFormat.payloadVersion,
      loaded.snapshot.documentID == marker.documentID, loaded.snapshot.revision == marker.revision,
      PersistenceFormat.checksum(data) == marker.hash,
      try reader.historyEntries(before: nil, limit: 1).isEmpty,
      try RecoveryCheckpoints(directory: url, inject: inject).recover() == loaded.snapshot
    else { throw StoreError.io("Current-only baseline verification failed") }
    _ = try reader.readHistorySettings()
    try reader.close()
    return loaded.snapshot
  }
  private func prepareCurrentOnly(_ snapshot: DocumentSnapshot, at stage: URL, operationID: UUID)
    throws
  {
    try inject(.replacementCreate)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
    let writer = try Connection(directory: stage, create: true)
    do {
      try writer.configureWrites()
      try writer.execute("CREATE TABLE purge_identity (id TEXT NOT NULL)")
      try writer.execute("INSERT INTO purge_identity VALUES ('\(operationID.uuidString)')")
      try writer.write(PersistenceFormat.encode(snapshot), inject: inject)
      if let settings = try? connection?.readHistorySettings() {
        try writer.writeHistorySettings(settings)
      }
      try RecoveryCheckpoints(directory: stage, inject: inject).publish(
        PersistenceFormat.encode(snapshot), snapshot: snapshot)
      try inject(.walCheckpoint)
      try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
      try writer.execute("PRAGMA journal_mode=DELETE")
      try inject(.close)
      try writer.close()
      try ManagedCopies(root: stage, inject: inject).withRoot { fd in
        for name in try ManagedCopies.names(fd) {
          let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
          guard file >= 0 else { throw StoreError.io("Purge file sync open") }
          let result = fsync(file)
          Darwin.close(file)
          guard result == 0 else { throw StoreError.io("Purge file sync") }
        }
        guard fsync(fd) == 0 else { throw StoreError.io("Purge stage sync") }
      }
    } catch {
      try? writer.close()
      throw error
    }
  }
  public func purge(
    _ snapshot: DocumentSnapshot, progress: @escaping @Sendable (PurgePhase) -> Void = { _ in }
  ) -> PurgeResult {
    guard ownership != nil, connection != nil, !purgePending else { return .unavailable }
    purgeWasAbandoned = false
    let manager = ManagedCopies(root: directory, inject: inject)
    let operationID = UUID()
    let stageName = ".Purge-\(operationID)"
    let stage = directory.appendingPathComponent(stageName)
    var swapped = false
    do {
      let original = try connection!.read().snapshot
      guard original.documentID == snapshot.documentID else { throw StoreError.invalidPayload }
      let inventory = try manager.inventory()
      guard inventory.issues.isEmpty else { return .incomplete(inventory.issues) }
      progress(.preparing)
      try prepareCurrentOnly(snapshot, at: stage, operationID: operationID)
      var marker = PurgeMarker(
        version: 1, operationID: operationID, documentID: snapshot.documentID,
        revision: snapshot.revision,
        hash: PersistenceFormat.checksum(try PersistenceFormat.encode(snapshot)),
        originalHash: PersistenceFormat.checksum(try PersistenceFormat.encode(original)),
        stage: stageName,
        phase: .swapping,
        targets: inventory.copies.filter { $0.name != "Store" }.map(\.name) + [stageName])
      _ = try verifyCurrentOnly(stage, marker: marker)
      try publishMarker(marker)
      try connection?.close()
      connection = nil
      progress(.swapping)
      try inject(.purgeSwap)
      guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, active.path, UInt32(RENAME_SWAP)) == 0
      else { throw StoreError.io("Purge swap: \(errno)") }
      swapped = true
      try inject(.purgeSwapped)
      try manager.syncRoot()
      try inject(.purgeReopen)
      _ = try verifyCurrentOnly(active, marker: marker)
      try inject(.purgeVerified)
      connection = try Connection(directory: active, create: false)
      try connection!.configureWrites()
      progress(.cleaning)
      marker.phase = .cleaning
      try publishMarker(marker)
      return finishPurgeCleanup()
    } catch {
      if swapped {
        purgePending = true
        return .incomplete([RemainingCopy(name: stageName, reason: "activationOrCleanupFailed")])
      }
      // A published pre-swap marker is reconciled before releasing the barrier.
      do {
        if try readPurgeMarker() != nil {
          try reconcilePurge()
        } else {
          try? manager.remove(stageName)
        }
      } catch {
        purgePending = true
        return .incomplete([RemainingCopy(name: stageName, reason: "preparationNeedsAttention")])
      }
      if connection == nil {
        connection = try? Connection(directory: active, create: false)
        try? connection?.configureWrites()
      }
      return .failed((error as? StoreError) ?? .io(String(describing: error)))
    }
  }
  public func retryPurgeCleanup() -> PurgeResult {
    guard ownership != nil else { return .unavailable }
    do {
      try reconcilePurge()
      if purgeWasAbandoned {
        connection = try Connection(directory: active, create: false)
        try connection!.configureWrites()
        return .failed(.io("Purge was not performed; original data remains"))
      }
      return purgePending ? finishPurgeCleanup() : .completed
    } catch { return .incomplete([RemainingCopy(name: "Purge.json", reason: "needsAttention")]) }
  }
  private func finishPurgeCleanup() -> PurgeResult {
    guard let marker = purgeMarker, marker.phase == .cleaning else { return .unavailable }
    let manager = ManagedCopies(root: directory, inject: inject)
    do {
      var issues: [RemainingCopy] = []
      let inventory = try manager.inventory()
      issues += inventory.issues
      for copy in inventory.copies where copy.name != "Store" {
        // New unknown managed copies cannot silently broaden a persisted operation.
        guard marker.targets.contains(copy.name) else {
          issues.append(RemainingCopy(name: copy.name, reason: "notAtBoundary"))
          continue
        }
        do { try manager.remove(copy.name) } catch {
          issues.append(RemainingCopy(name: copy.name, reason: "cleanupFailed"))
        }
      }
      let remaining = try manager.inventory()
      issues += remaining.issues
      issues += remaining.copies.filter { $0.name != "Store" }.map {
        RemainingCopy(name: $0.name, reason: "remaining")
      }
      guard issues.isEmpty else { return .incomplete(issues) }
      try manager.syncRoot()
      try removeMarker()
      maintenanceWarning = nil
      return .completed
    } catch {
      return .incomplete([RemainingCopy(name: "Purge.json", reason: "cleanupOrSyncFailed")])
    }
  }
  /// Never fall through to ordinary load/recovery when a swap relationship is ambiguous.
  func reconcilePurge() throws {
    guard let marker = try readPurgeMarker() else { return }
    purgePending = true
    purgeMarker = marker
    try connection?.close()
    connection = nil
    let activeIsReplacement: Bool
    do {
      _ = try verifyCurrentOnly(active, marker: marker)
      activeIsReplacement = true
    } catch {
      if marker.phase == .cleaning { throw error }
      activeIsReplacement = false
    }
    if activeIsReplacement {
      var cleaning = marker
      cleaning.phase = .cleaning
      try publishMarker(cleaning)
      connection = try Connection(directory: active, create: false)
      try connection!.configureWrites()
      _ = finishPurgeCleanup()
      return
    }
    // Only a verified original paired with an intact current-only stage proves pre-swap state.
    let stage = directory.appendingPathComponent(marker.stage)
    let stageExists = try ManagedCopies(root: directory).withRoot { fd in
      var info = stat()
      if fstatat(fd, marker.stage, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
      guard errno == ENOENT else { throw StoreError.io("Purge stage inspection") }
      return false
    }
    if stageExists { _ = try verifyCurrentOnly(stage, marker: marker) }
    try ManagedCopies(root: directory).withRoot {
      try ManagedCopies.validateBundle("Store", at: $0)
    }
    let reader = try Connection(directory: active, create: false)
    defer { try? reader.close() }
    let original = try reader.read().snapshot
    guard original.documentID == marker.documentID,
      PersistenceFormat.checksum(try PersistenceFormat.encode(original)) == marker.originalHash,
      (try? reader.purgeIdentity()) != marker.operationID, marker.phase == .swapping
    else { throw StoreError.io("Ambiguous purge state; both stores preserved") }
    try reader.close()
    if stageExists { try ManagedCopies(root: directory, inject: inject).remove(marker.stage) }
    try removeMarker()
    purgeWasAbandoned = true
  }
}

extension Connection {
  func purgeIdentity() throws -> UUID? {
    let statement = try prepare("SELECT id FROM purge_identity")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
      return nil
    }
    let value = UUID(uuidString: String(cString: text))
    guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
    return value
  }
}
