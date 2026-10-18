import Foundation

public enum ModelConnectionState: String, Codable, Sendable {
  case notConnected, connecting, connected, unableToVerify, needsAttention
}
public enum ModelConnectionFailure: String, Codable, Sendable, Equatable {
  case authorization, authentication, offline, timeout, cancelled, malformed
  case credentialStore, unavailableIdentity

  public var message: String {
    switch self {
    case .authorization: "Authorization could not be completed. Connect again in Models Settings."
    case .authentication: "OpenRouter rejected the connection. Check Models Settings."
    case .offline: "Unable to reach OpenRouter. Check your connection."
    case .timeout: "OpenRouter timed out. Try connecting again."
    case .cancelled: "Connection cancelled."
    case .malformed: "OpenRouter returned an unsupported response."
    case .credentialStore:
      "Jort could not save or verify the secure connection in Keychain. Check Connection or reconnect in Models Settings."
    case .unavailableIdentity:
      "This app cannot access its secure connection. Use a correctly signed Jort build."
    }
  }
}
public struct ModelConnectionStatus: Codable, Equatable, Sendable {
  public var state: ModelConnectionState = .notConnected
  public var lastVerified: Date?
  public var expiration: Date?
  public var credentialMigration: ModelCredentialMigrationOutcome?
  public var failure: ModelConnectionFailure?
  public init(
    state: ModelConnectionState = .notConnected, lastVerified: Date? = nil, expiration: Date? = nil,
    credentialMigration: ModelCredentialMigrationOutcome? = nil,
    failure: ModelConnectionFailure? = nil
  ) {
    self.state = state
    self.lastVerified = lastVerified
    self.expiration = expiration
    self.credentialMigration = credentialMigration
    self.failure = failure
  }
}

public protocol ModelConnection: Sendable {
  func currentStatus() async -> ModelConnectionStatus
  func available() async -> Bool
  func connect(openBrowser: @escaping @Sendable (URL) async -> Bool) async throws
  func check() async throws
  func disconnect() async throws
}
public protocol ModelConnectionSettings: Sendable {
  func readConnectionStatus() async -> String?
  func writeConnectionStatus(_ value: String) async
}
