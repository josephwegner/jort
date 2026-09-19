import Darwin
import Foundation

/// The role, never persisted metadata, supplies the direct-child filename.
struct BoundedRecoveryReader {
  let directory: URL
  var inject: @Sendable (StoreStage) throws -> Void = { _ in }

  func read(_ role: RecoverySourceRole) throws -> Data {
    let folder = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard folder >= 0 else { throw RecoveryRejection(role: role, reason: .io) }
    defer { Darwin.close(folder) }
    // NONBLOCK prevents a FIFO from blocking before fstat can reject its type.
    let file = openat(folder, role.rawValue, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard file >= 0 else {
      let reason: RecoveryRejectionReason =
        errno == ENOENT ? .missing : errno == ELOOP ? .symbolicLink : .io
      throw RecoveryRejection(role: role, reason: reason)
    }
    defer { Darwin.close(file) }
    var before = stat()
    guard fstat(file, &before) == 0 else { throw RecoveryRejection(role: role, reason: .io) }
    guard before.st_mode & S_IFMT == S_IFREG else {
      throw RecoveryRejection(role: role, reason: .nonRegular)
    }
    guard before.st_nlink == 1 else { throw RecoveryRejection(role: role, reason: .hardLink) }
    guard before.st_size >= 0, before.st_size <= role.limit else {
      throw RecoveryRejection(role: role, reason: .oversized)
    }
    try inject(.boundedReadOpened)
    var result = Data()
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = min(chunk.count, role.limit + 1 - result.count)
      let received = chunk.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, count) }
      if received < 0 {
        if errno == EINTR { continue }
        throw RecoveryRejection(role: role, reason: .io)
      }
      if received == 0 { break }
      guard received <= role.limit - result.count else {
        throw RecoveryRejection(role: role, reason: .changed)
      }
      result.append(contentsOf: chunk.prefix(received))
      try inject(.boundedReadChunk)
    }
    var after = stat()
    guard fstat(file, &after) == 0 else { throw RecoveryRejection(role: role, reason: .io) }
    guard before.st_size == result.count, after.st_size == before.st_size,
      after.st_nlink == 1,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw RecoveryRejection(role: role, reason: .changed) }
    return result
  }
}
