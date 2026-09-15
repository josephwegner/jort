import JortToolContracts
import Foundation
import Security

public actor KeychainModelCredentialStore: ModelCredentialStore {
  private let service: String
  public init(service: String = "dev.jort.editor.openrouter") { self.service = service }
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "openrouter", kSecAttrSynchronizable as String: false,
    ]
  }
  public func read() throws -> String? {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, data.count <= 4096,
      let credential = String(data: data, encoding: .utf8), !credential.isEmpty
    else { throw ModelFailure.credentialStore }
    return credential
  }
  public func replace(with credential: String) throws {
    guard !credential.isEmpty, credential.utf8.count <= 4096, !credential.contains("\n"),
      !credential.contains("\r")
    else { throw ModelFailure.credentialStore }
    let attributes: [String: Any] = [
      kSecValueData as String: Data(credential.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      attributes.forEach { item[$0] = $1 }
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
        throw ModelFailure.credentialStore
      }
    } else if status != errSecSuccess {
      throw ModelFailure.credentialStore
    }
  }
  public func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ModelFailure.credentialStore
    }
  }
}

public actor MemoryModelCredentialStore: ModelCredentialStore {
  private var credential: String?
  public var failWrites = false
  public init(_ credential: String? = nil) { self.credential = credential }
  public func read() -> String? { credential }
  public func setFailWrites(_ value: Bool) { failWrites = value }
  public func replace(with credential: String) throws {
    if failWrites { throw ModelFailure.credentialStore }
    self.credential = credential
  }
  public func remove() throws {
    if failWrites { throw ModelFailure.credentialStore }
    credential = nil
  }
}
