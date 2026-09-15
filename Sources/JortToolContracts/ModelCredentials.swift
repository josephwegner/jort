import Foundation

public protocol ModelCredentialStore: Sendable {
  func read() async throws -> String?
  func replace(with credential: String) async throws
  func remove() async throws
}
