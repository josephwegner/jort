import Foundation

public enum RecoverySourceRole: String, Codable, CaseIterable, Sendable {
  case manifest = "Recovery-manifest.json"
  case legacy = "Recovery.json"
  case slot0 = "Recovery-0.json"
  case slot1 = "Recovery-1.json"
  var limit: Int { self == .manifest ? 64 * 1024 : PersistenceFormat.maximumBytes }
}

public enum RecoveryRejectionReason: String, Codable, Sendable {
  case missing, oversized, nonRegular, symbolicLink, hardLink, changed, malformed
  case checksumMismatch, unsupportedVersion, io
}

public struct RecoveryRejection: Error, Equatable, Sendable {
  public let role: RecoverySourceRole
  public let reason: RecoveryRejectionReason
}

public enum RecoveryDisposition: Equatable, Sendable {
  case none
  case recovered(RecoverySourceRole)
  case rejected([RecoveryRejection])
}

public enum ImmediateSaveOutcome: Equatable, Sendable {
  case clean(Int64), saved(Int64), coalesced(Int64), retried(Int64)
  case failed(StoreError), unavailable
}

public enum PurgePhase: String, Codable, Sendable {
  case preparing, swapping, cleaning, incomplete, completed
}

public struct RemainingCopy: Equatable, Codable, Sendable {
  public let name: String
  public let reason: String
}

public enum PurgeResult: Equatable, Sendable {
  case completed
  case incomplete([RemainingCopy])
  case failed(StoreError)
  case unavailable
}

public struct MaintenanceWarning: Equatable, Sendable {
  public let remaining: [RemainingCopy]
}
