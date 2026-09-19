import Darwin
import Foundation

/// Exact names only; unknown data belongs to the caller, never to cleanup.
enum ManagedNames {
  static let files: Set<String> = [
    "Jort.sqlite", "Jort.sqlite-wal", "Jort.sqlite-shm", "Recovery.json", "Recovery-0.json",
    "Recovery-1.json", "Recovery-manifest.json", "HistoryRecoveryIncomplete",
  ]
  static let prefixes = [
    "PreMigration-", "Damaged-", ".Replacement-", ".Inspect-", ".HistoryInspect-", ".Purge-",
  ]
  static func uuid(_ value: String) -> Bool {
    value.count == 36 && UUID(uuidString: value) != nil
  }
  static func backupDate(_ name: String) -> Date? {
    guard let prefix = ["PreMigration-", "Damaged-"].first(where: name.hasPrefix) else {
      return nil
    }
    let suffix = String(name.dropFirst(prefix.count))
    guard suffix.count == 53, suffix[suffix.index(suffix.startIndex, offsetBy: 16)] == "-",
      uuid(String(suffix.suffix(36)))
    else { return nil }
    let formatter = dateFormatter()
    let stamp = String(suffix.prefix(16))
    guard let date = formatter.date(from: stamp), formatter.string(from: date) == stamp else {
      return nil
    }
    return date
  }
  static func dateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    formatter.isLenient = false
    return formatter
  }
  static func backup(_ prefix: String, now: Date = Date()) -> String {
    "\(prefix)-\(dateFormatter().string(from: now))-\(UUID())"
  }
  static func bundle(_ name: String) -> Bool {
    if name == "Store" { return true }
    guard let prefix = prefixes.first(where: name.hasPrefix) else { return false }
    return uuid(String(name.dropFirst(prefix.count))) || backupDate(name) != nil
  }
  static func file(_ name: String) -> Bool {
    files.contains(name) || name.hasPrefix(".Checkpoint-") && uuid(String(name.dropFirst(12)))
  }
  static func resemblesManaged(_ name: String) -> Bool {
    name == "Store" || prefixes.contains(where: name.hasPrefix) || name.hasPrefix(".Checkpoint-")
      || files.contains(name)
  }
}

struct ManagedCopy {
  let name: String
  let isDirectory: Bool
  let date: Date
}

struct ManagedInventory {
  let copies: [ManagedCopy]
  let issues: [RemainingCopy]
}

/// Every traversal and removal stays relative to descriptors within the owned root.
struct ManagedCopies {
  let root: URL
  var inject: @Sendable (StoreStage) throws -> Void = { _ in }
  static let maximumEntries = 4096

  func withRoot<T>(_ action: (Int32) throws -> T) throws -> T {
    let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw StoreError.io("Managed root open: \(errno)") }
    defer { Darwin.close(fd) }
    return try action(fd)
  }
  static func names(_ fd: Int32) throws -> [String] {
    let copy = dup(fd)
    guard copy >= 0 else { throw StoreError.io("Directory descriptor") }
    guard let stream = fdopendir(copy) else {
      Darwin.close(copy)
      throw StoreError.io("Directory enumeration")
    }
    defer { closedir(stream) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      if name == "." || name == ".." { continue }
      guard names.count < maximumEntries else { throw StoreError.sizeLimit }
      names.append(name)
      errno = 0
    }
    guard errno == 0 else { throw StoreError.io("Directory read: \(errno)") }
    return names.sorted()
  }
  static func metadata(_ name: String, at fd: Int32) throws -> stat {
    var info = stat()
    guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw StoreError.io("Managed metadata: \(errno)")
    }
    return info
  }
  static func validateBundle(_ name: String, at fd: Int32) throws {
    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard child >= 0 else { throw StoreError.io("Managed bundle open: \(errno)") }
    defer { Darwin.close(child) }
    for file in try names(child) {
      guard ManagedNames.file(file) else { throw StoreError.io("Unrecognized bundle entry") }
      let info = try metadata(file, at: child)
      guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
        throw StoreError.io("Linked or special bundle entry")
      }
    }
  }
  func inventory() throws -> ManagedInventory {
    try inject(.inventory)
    return try withRoot { fd in
      var copies: [ManagedCopy] = [], issues: [RemainingCopy] = []
      for name in try Self.names(fd) {
        let directory = ManagedNames.bundle(name)
        guard directory || ManagedNames.file(name) else {
          if ManagedNames.resemblesManaged(name) {
            issues.append(RemainingCopy(name: name, reason: "unrecognizedName"))
          }
          continue
        }
        do {
          let info = try Self.metadata(name, at: fd)
          guard
            directory
              ? info.st_mode & S_IFMT == S_IFDIR
              : info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
          else {
            throw StoreError.io("Linked or special managed entry")
          }
          if directory { try Self.validateBundle(name, at: fd) }
          let date =
            ManagedNames.backupDate(name)
            ?? Date(
              timeIntervalSince1970: TimeInterval(
                info.st_birthtimespec.tv_sec > 0
                  ? info.st_birthtimespec.tv_sec : info.st_mtimespec.tv_sec))
          copies.append(ManagedCopy(name: name, isDirectory: directory, date: date))
        } catch { issues.append(RemainingCopy(name: name, reason: "unsafeEntry")) }
      }
      return ManagedInventory(copies: copies, issues: issues)
    }
  }
  func remove(_ name: String) throws {
    guard name != "Store", ManagedNames.bundle(name) || ManagedNames.file(name) else {
      throw StoreError.invalidPayload
    }
    try withRoot { fd in
      let info = try Self.metadata(name, at: fd)
      try inject(.cleanupRemove)
      if ManagedNames.bundle(name) {
        guard info.st_mode & S_IFMT == S_IFDIR else { throw StoreError.invalidPayload }
        try Self.validateBundle(name, at: fd)
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw StoreError.io("Cleanup open: \(errno)") }
        defer { Darwin.close(child) }
        for file in try Self.names(child) {
          let value = try Self.metadata(file, at: child)
          guard ManagedNames.file(file), value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1
          else { throw StoreError.invalidPayload }
          try inject(.cleanupRemove)
          guard unlinkat(child, file, 0) == 0 else { throw StoreError.io("Cleanup file: \(errno)") }
        }
        guard fsync(child) == 0 else { throw StoreError.io("Cleanup bundle sync: \(errno)") }
        guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else {
          throw StoreError.io("Cleanup directory: \(errno)")
        }
      } else {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
          throw StoreError.invalidPayload
        }
        guard unlinkat(fd, name, 0) == 0 else { throw StoreError.io("Cleanup file: \(errno)") }
      }
      try sync(fd)
    }
  }
  func sync(_ fd: Int32) throws {
    try inject(.maintenanceDirectorySync)
    guard fsync(fd) == 0 else { throw StoreError.io("Managed directory sync: \(errno)") }
  }
  func syncRoot() throws { try withRoot { try sync($0) } }
}
