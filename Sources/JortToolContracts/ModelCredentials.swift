import Foundation

/// Nonsecret migration state suitable for connection diagnostics and recovery UI.
public enum ModelCredentialMigrationOutcome: String, Codable, Sendable, Equatable {
  case notRequired, migrated, cleanupIncomplete, conflict, preVerificationFailed,
    postCleanupVerificationFailed, unavailableIdentity

  public var message: String? {
    switch self {
    case .notRequired, .migrated: nil
    case .cleanupIncomplete:
      "The secure connection is usable, but the old Keychain entry could not be removed. Check Connection to retry cleanup."
    case .conflict:
      "Saved OpenRouter connections conflict. No model requests will run. Disconnect, then reconnect in Models Settings. If Disconnect fails, remove the legacy dev.jort.editor.openrouter entry in Keychain Access and retry."
    case .preVerificationFailed:
      "The saved connection could not be migrated safely. Unlock Keychain and check the connection again in Models Settings."
    case .postCleanupVerificationFailed:
      "The migrated connection could not be verified. Reconnect in Models Settings."
    case .unavailableIdentity:
      "This app cannot access its secure connection. Use a correctly signed Jort build and reconnect in Models Settings."
    }
  }

  public var blocksUse: Bool {
    switch self {
    case .notRequired, .migrated, .cleanupIncomplete: false
    default: true
    }
  }
}

public enum ModelCredentialStoreFailure: Error, Sendable, Equatable {
  case unavailableIdentity, preVerificationFailed, postCleanupVerificationFailed, conflict

  public var migrationOutcome: ModelCredentialMigrationOutcome {
    switch self {
    case .unavailableIdentity: .unavailableIdentity
    case .preVerificationFailed: .preVerificationFailed
    case .postCleanupVerificationFailed: .postCleanupVerificationFailed
    case .conflict: .conflict
    }
  }

  public var message: String { migrationOutcome.message! }
}

public protocol ModelCredentialStore: Sendable {
  func read() async throws -> String?
  func replace(with credential: String) async throws
  /// Commits a new value only if the previously observed value still matches.
  func replaceIfCurrent(_ expected: String?, with credential: String) async throws -> Bool
  /// Restores a prior value only while this store still contains the value
  /// written by the caller. Implementations must compare and mutate without
  /// allowing another operation on the store to interleave.
  func restoreIfCurrent(_ expected: String, with previous: String?) async throws -> Bool
  func remove() async throws
  func migrationOutcome() async -> ModelCredentialMigrationOutcome
}

extension ModelCredentialStore {
  public func migrationOutcome() async -> ModelCredentialMigrationOutcome { .notRequired }
  /// Unknown stores fail closed instead of attempting a non-atomic mutation.
  public func replaceIfCurrent(_ expected: String?, with credential: String) async throws -> Bool {
    false
  }
  public func restoreIfCurrent(_ expected: String, with previous: String?) async throws -> Bool {
    false
  }
}
