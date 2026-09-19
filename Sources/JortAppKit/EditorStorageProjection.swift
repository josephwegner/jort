import JortDocument
import JortPersistence
import Foundation

public enum EditorStartupPhase: Equatable {
  case loading, resolvingLoadedSnapshot, ready, recoveryEditing(StoreError), ownershipConflict
}

/// Startup/storage facts only. The workspace remains the native transaction adapter.
@MainActor final class EditorStorageProjection {
  var phase: EditorStartupPhase = .loading
  var loadedForReconciliation: DocumentSnapshot?
  struct Notice {
    let message: String?
    let canRetry: Bool
    let actionTitle: String
  }
  func notice(for status: PersistenceState, historyMessage: String?) -> Notice {
    let message: String?
    switch status {
    case .loadBlockedFuture:
      message = LocalizedCopy.text(
        "EditorStorageProjection.this_store_needs_a_newer_version_of_jort_existing_files_are_uncha",
        fallback: "This store needs a newer version of Jort. Existing files are unchanged.")
    case .loadFailed:
      message = LocalizedCopy.text(
        "EditorStorageProjection.storage_could_not_be_opened_your_typing_stays_in_memory_save_a_re",
        fallback:
          "Storage could not be opened. Original files are unchanged. Your typing stays in memory; save a recovery copy to keep it."
      )
    case .ownershipConflict:
      message = LocalizedCopy.text(
        "EditorStorageProjection.this_canvas_is_already_open_in_another_jort_process",
        fallback: "This canvas is already open in another Jort process.")
    default:
      message =
        status.failure == nil
        ? nil
        : LocalizedCopy.text(
          "EditorStorageProjection.couldn_t_save_your_text_is_still_here_retry_with_s",
          fallback: "Couldn’t save. Your text is still here. Retry with ⌘S.")
    }
    return Notice(
      message: message ?? historyMessage,
      canRetry: message != nil && status != .ownershipConflict,
      actionTitle: status.permitsRetry
        ? LocalizedCopy.text("EditorStorageProjection.retry_save", fallback: "Retry save")
        : LocalizedCopy.text(
          "EditorStorageProjection.save_recovery_copy", fallback: "Save Recovery Copy…"))
  }
}
