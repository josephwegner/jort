import AppKit
import JortPersistence

extension EditorViewController: NSMenuItemValidation {
  public func addStorageCommands(to menu: NSMenu) {
    for (title, action, key) in [
      (LocalizedCopy.text("storage.save", fallback: "Save"), #selector(saveDocument), "s"),
      (
        LocalizedCopy.text("storage.export", fallback: "Save Recovery Copy…"),
        #selector(saveRecoveryCopy), ""
      ),
      (
        LocalizedCopy.text("storage.clear", fallback: "Clear History and Recovery Data…"),
        #selector(clearHistoryAndRecoveryData), ""
      ),
      (
        LocalizedCopy.text("storage.cleanup_retry", fallback: "Retry Cleanup"),
        #selector(retryStorageCleanup), ""
      ),
      (
        LocalizedCopy.text("storage.rejected_clear", fallback: "Remove Rejected Recovery Files…"),
        #selector(removeRejectedRecoveryFiles), ""
      ),
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = self
      menu.addItem(item)
    }
    menu.addItem(.separator())
  }

  public func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(saveDocument) {
      item.title =
        persistence.status.failure == nil
        ? LocalizedCopy.text("storage.save", fallback: "Save")
        : LocalizedCopy.text("storage.retry", fallback: "Retry Save")
      if let revision = persistence.pendingRevision {
        item.setAccessibilityHelp(
          LocalizedCopy.format(
            "storage.save_revision", fallback: "Save the latest document revision, %lld.", revision)
        )
      } else {
        item.setAccessibilityHelp(item.title)
      }
      guard startupPhase == .ready, persistence.canSave else { return false }
      switch persistence.status {
      case .dirty, .writing, .retryScheduled, .saveFailed: return true
      case .clean: return persistence.requiresHistoryRetry
      default: return false
      }
    }
    if item.action == #selector(saveRecoveryCopy) {
      return coordinator != nil && startupPhase != .ownershipConflict
    }
    if item.action == #selector(clearHistoryAndRecoveryData) {
      return startupPhase == .ready && persistence.canPurge
    }
    if item.action == #selector(retryStorageCleanup) { return persistence.canRetryCleanup }
    if item.action == #selector(removeRejectedRecoveryFiles) {
      return persistence.canCleanRejectedRecovery
    }
    return true
  }

  @objc public func saveDocument() {
    guard startupPhase == .ready else { return }
    finishComposition()
    persistence.saveImmediately { [weak self] outcome in
      guard let self else { return }
      switch outcome {
      case .saved, .coalesced, .retried:
        self.notice.stringValue = LocalizedCopy.text("storage.saved", fallback: "Saved.")
        self.notice.isHidden = false
      default: self.present(self.persistence.status)
      }
    }
  }
  @objc public func clearHistoryAndRecoveryData() {
    guard persistence.canPurge, let window = view.window else { return }
    let alert = NSAlert()
    alert.messageText = LocalizedCopy.text(
      "storage.clear_title", fallback: "Clear history and recovery data?")
    alert.informativeText = LocalizedCopy.text(
      "storage.clear_detail",
      fallback:
        "Your current document will remain. All older history revisions, milestones, recovery checkpoints, and diagnostic backups managed by Jort on this Mac will be deleted. New edits can create new history and recovery data. This does not erase physical disk blocks, exported copies, filesystem snapshots, Time Machine, or other external backups."
    )
    alert.addButton(withTitle: LocalizedCopy.text("storage.cancel", fallback: "Cancel"))
    alert.addButton(
      withTitle: LocalizedCopy.text(
        "storage.clear_confirm", fallback: "Clear History and Recovery Data"))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertSecondButtonReturn, let self else { return }
      self.finishComposition()
      self.dismissHistory()
      Task { _ = await self.persistence.clearHistoryAndRecoveryData() }
    }
  }
  @objc public func retryStorageCleanup() {
    Task { _ = await persistence.retryCleanup() }
  }
  @objc public func removeRejectedRecoveryFiles() {
    guard persistence.canCleanRejectedRecovery, let window = view.window else { return }
    let alert = NSAlert()
    alert.messageText = LocalizedCopy.text(
      "storage.rejected_title", fallback: "Remove rejected recovery files?")
    alert.informativeText = LocalizedCopy.text(
      "storage.rejected_detail",
      fallback:
        "Only unusable recovery files identified during this load attempt will be removed. The SQLite document, diagnostic backups, and other files will remain unchanged. Your typing stays in memory; save a recovery copy to keep it."
    )
    alert.addButton(withTitle: LocalizedCopy.text("storage.cancel", fallback: "Cancel"))
    alert.addButton(withTitle: LocalizedCopy.text("storage.remove", fallback: "Remove"))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertSecondButtonReturn, let self else { return }
      Task {
        let remaining = await self.persistence.cleanupRejectedRecovery()
        self.notice.stringValue =
          remaining.isEmpty
          ? LocalizedCopy.text(
            "storage.rejected_removed",
            fallback: "Rejected recovery files removed. Your document source remains unchanged.")
          : LocalizedCopy.text(
            "storage.rejected_incomplete",
            fallback:
              "Some rejected recovery files could not be removed. Your document source remains unchanged."
          )
        self.notice.isHidden = false
      }
    }
  }
  func maintenanceMessage() -> String? {
    if persistence.purgePhase == .incomplete && !persistence.canRetryCleanup {
      return LocalizedCopy.text(
        "storage.not_cleared",
        fallback:
          "History and recovery data were not cleared. Your document is preserved. Try Clear History and Recovery Data again from File."
      )
    }
    if let phase = persistence.purgePhase {
      switch phase {
      case .preparing:
        return LocalizedCopy.text(
          "storage.preparing", fallback: "Preparing a current-only copy. You can keep typing.")
      case .swapping:
        return LocalizedCopy.text(
          "storage.swapping",
          fallback: "Installing the current document and clearing older managed copies…")
      case .cleaning:
        return LocalizedCopy.text("storage.cleaning", fallback: "Cleaning up older managed copies…")
      case .incomplete:
        return LocalizedCopy.text(
          "storage.cleanup_incomplete",
          fallback: "Cleanup is incomplete. Some managed copies remain. Retry Cleanup from File.")
      case .completed:
        return LocalizedCopy.text(
          "storage.completed",
          fallback: "History and recovery data cleared. Your current document was preserved.")
      }
    }
    if persistence.maintenanceWarning != nil {
      return LocalizedCopy.text(
        "storage.maintenance_warning",
        fallback: "Your document is available, but some diagnostic backups could not be cleaned up."
      )
    }
    if case .recovered = persistence.recoveryDisposition {
      return LocalizedCopy.text(
        "storage.automatically_recovered",
        fallback:
          "Your document was recovered automatically. A damaged diagnostic backup was preserved.")
    }
    return nil
  }

}
