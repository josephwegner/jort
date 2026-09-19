import Darwin
import Foundation
import JortDocument

extension SQLiteStore {
  func maintainBackups(now: Date = Date()) {
    guard ownership != nil, connection != nil, !purgePending else { return }
    let manager = ManagedCopies(root: directory, inject: inject)
    do {
      _ = try connection!.read()
      let inventory = try manager.inventory()
      var issues = inventory.issues
      for prefix in ["PreMigration-", "Damaged-"] {
        let backups = inventory.copies.filter { $0.name.hasPrefix(prefix) }.sorted {
          $0.date == $1.date ? $0.name > $1.name : $0.date > $1.date
        }
        for (index, backup) in backups.enumerated()
        where index >= 2 || now.timeIntervalSince(backup.date) > 30 * 24 * 60 * 60 {
          do { try manager.remove(backup.name) } catch {
            issues.append(RemainingCopy(name: backup.name, reason: "cleanupFailed"))
          }
        }
      }
      maintenanceWarning = issues.isEmpty ? nil : MaintenanceWarning(remaining: issues)
    } catch {
      maintenanceWarning = MaintenanceWarning(remaining: [
        RemainingCopy(name: "", reason: "inventoryFailed")
      ])
    }
  }
}

extension SQLiteStore {
  public func cleanupRejectedRecovery() -> [RemainingCopy] {
    guard ownership != nil, connection == nil, !purgePending,
      case .rejected = recoveryDisposition, let source = rejectedRecoveryDirectory
    else { return [] }
    do {
      return try ManagedCopies(root: source, inject: inject).withRoot { fd in
        var remaining: [RemainingCopy] = []
        for (role, original) in rejectedRecoveryFiles {
          do {
            let current = try ManagedCopies.metadata(role.rawValue, at: fd)
            guard current.st_dev == original.st_dev, current.st_ino == original.st_ino,
              current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              current.st_mode & S_IFMT != S_IFDIR
            else { throw StoreError.invalidPayload }
            try inject(.cleanupRemove)
            guard unlinkat(fd, role.rawValue, 0) == 0 else {
              throw StoreError.io("Rejected recovery removal")
            }
            rejectedRecoveryFiles.removeValue(forKey: role)
          } catch {
            remaining.append(RemainingCopy(name: role.rawValue, reason: "changedOrRemovalFailed"))
          }
        }
        try ManagedCopies(root: source, inject: inject).sync(fd)
        return remaining
      }
    } catch { return [RemainingCopy(name: "", reason: "cleanupOrSyncFailed")] }
  }
}
