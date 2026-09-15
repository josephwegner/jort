import Foundation

public enum ModelConnectionState: String, Codable, Sendable {
  case notConnected, connecting, connected, unableToVerify, needsAttention
}
public struct ModelConnectionStatus: Codable, Equatable, Sendable {
  public var state: ModelConnectionState = .notConnected
  public var lastVerified: Date?
  public var expiration: Date?
  public init(
    state: ModelConnectionState = .notConnected, lastVerified: Date? = nil, expiration: Date? = nil
  ) {
    self.state = state
    self.lastVerified = lastVerified
    self.expiration = expiration
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
