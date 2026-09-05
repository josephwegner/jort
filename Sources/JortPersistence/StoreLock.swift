import Foundation
import Darwin

/// OS-held ownership: no PID files, stale lock deletion, or NSRunningApplication races.
public final class StoreLock: Sendable {
    private let descriptor: Int32
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("Jort.lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreError.io("lock open: \(errno)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw StoreError.ownership }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
