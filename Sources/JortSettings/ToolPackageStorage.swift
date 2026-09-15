import JortToolContracts
import Foundation
import Darwin

public enum ToolPublicationStage: String, CaseIterable, Sendable {
  case stagingCreate, manifestWrite, manifestSync, implementationWrite, implementationSync
  case stagingSync, verification, generationRename, generationSync
  case recoveryWrite, indexWrite, indexSync, indexRename, indexDirectorySync, memoryPublication
  case cleanup
}

public enum ToolPublicationError: Error, Equatable, Sendable, LocalizedError {
  case io(Int32)
  case uncertain
  public var errorDescription: String? {
    switch self {
    case .io(let code): return "Tool storage failed (\(code))."
    case .uncertain:
      return
        "The visible tool catalog changed, but durable saving could not be confirmed. Your draft and recovery files were kept."
    }
  }
}

/// All child operations are relative to an opened, non-link directory. Cleanup never recurses.
struct ToolPackageStorage {
  let root: URL
  func directory() throws -> Int32 {
    let existed = FileManager.default.fileExists(atPath: root.path)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if !existed {
      let parent = Darwin.open(
        root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      guard parent >= 0 else { throw ToolPublicationError.io(errno) }
      defer { close(parent) }
      try sync(parent)
    }
    let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw ToolPublicationError.io(errno) }
    return fd
  }
  func sync(_ fd: Int32) throws {
    guard fsync(fd) == 0 else { throw ToolPublicationError.io(errno) }
  }
  func write(_ data: Data, name: String, parent: Int32, beforeSync: () throws -> Void = {}) throws {
    guard data.count <= 1_048_576 else { throw ToolPackageError.sizeLimit }
    let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw ToolPublicationError.io(errno) }
    defer { close(fd) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw ToolPublicationError.io(errno) }
        offset += count
      }
    }
    try beforeSync()
    try sync(fd)
  }
  func read(_ name: String, parent: Int32) throws -> Data {
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw ToolPublicationError.io(errno) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size <= 1_048_576
    else { throw ToolPackageError.sizeLimit }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw ToolPublicationError.io(errno) }
      if count == 0 { return data }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= 1_048_576 else { throw ToolPackageError.sizeLimit }
    }
  }
  func children(_ parent: Int32, limit: Int = 20_000) throws -> [String] {
    let copy = dup(parent)
    guard copy >= 0 else { throw ToolPublicationError.io(errno) }
    guard let stream = fdopendir(copy) else {
      close(copy)
      throw ToolPublicationError.io(errno)
    }
    defer { closedir(stream) }
    rewinddir(stream)
    var names: [String] = []
    errno = 0
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      names.append(name)
      guard names.count <= limit else { throw ToolPackageError.sizeLimit }
      errno = 0
    }
    guard errno == 0 else { throw ToolPublicationError.io(errno) }
    return names
  }
  func makeDirectory(_ name: String, parent: Int32) throws -> Int32 {
    guard mkdirat(parent, name, 0o700) == 0 else { throw ToolPublicationError.io(errno) }
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw ToolPublicationError.io(errno) }
    return fd
  }
  func rename(_ name: String, to destination: String, parent: Int32, replacing: Bool = false) throws
  {
    guard renameatx_np(parent, name, parent, destination, replacing ? 0 : UInt32(RENAME_EXCL)) == 0
    else {
      throw ToolPublicationError.io(errno)
    }
  }
  /// Unexpected files, subdirectories and links preserve the whole candidate directory.
  func removePackage(_ name: String, parent: Int32, allowed: Set<String>) throws {
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw ToolPublicationError.io(errno) }
    defer { close(fd) }
    let names = try children(fd, limit: 8)
    for child in names {
      var info = stat()
      guard allowed.contains(child), fstatat(fd, child, &info, AT_SYMLINK_NOFOLLOW) == 0,
        info.st_mode & S_IFMT == S_IFREG
      else { throw ToolPackageError.invalidPath }
    }
    for child in names {
      guard unlinkat(fd, child, 0) == 0 else { throw ToolPublicationError.io(errno) }
    }
    guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw ToolPublicationError.io(errno) }
  }
}
