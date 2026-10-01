import Foundation
import JortToolContracts
import Security

public enum ModelCredentialEnvironment: Sendable, Equatable { case production, development }

/// An immutable, identity-scoped protected credential namespace.
public struct ModelCredentialPolicy: Sendable, Equatable {
  public let environment: ModelCredentialEnvironment
  public let applicationIdentifierPrefix: String
  public let service: String
  public let account: String
  public let accessGroupSuffix: String
  public var accessGroup: String { applicationIdentifierPrefix + accessGroupSuffix }

  public init(environment: ModelCredentialEnvironment, applicationIdentifierPrefix: String) throws {
    guard Self.isValidPrefix(applicationIdentifierPrefix) else {
      throw ModelCredentialStoreFailure.unavailableIdentity
    }
    self.environment = environment
    self.applicationIdentifierPrefix = applicationIdentifierPrefix
    switch environment {
    case .production:
      service = "dev.jort.editor.openrouter.v2"
      account = "openrouter"
      accessGroupSuffix = "dev.jort.editor.credentials"
    case .development:
      service = "dev.jort.editor.development.openrouter.v2"
      account = "openrouter-development"
      accessGroupSuffix = "dev.jort.editor.development.credentials"
    }
  }

  private static func isValidPrefix(_ value: String) -> Bool {
    value.last == "." && value.count > 1
      && value.dropLast().allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber)
      }
  }

  /// Builds the production policy only from the effective signed entitlement
  /// facts supplied by composition/release inspection. This intentionally does
  /// not derive identity from a bundle path or an ambient Keychain item.
  public static func production(
    signedEntitlements: [String: Any], expectedTeamIdentifier: String
  ) throws -> ModelCredentialPolicy {
    guard expectedTeamIdentifier.count == 10,
      expectedTeamIdentifier.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
      let groups = signedEntitlements["keychain-access-groups"] as? [String],
      groups.count == 1
    else { throw ModelCredentialStoreFailure.unavailableIdentity }
    let expected = expectedTeamIdentifier + ".dev.jort.editor.credentials"
    guard groups[0] == expected else { throw ModelCredentialStoreFailure.unavailableIdentity }
    return try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: expectedTeamIdentifier + ".")
  }

  /// Resolves the namespace from this process's signed application identifier
  /// and effective keychain groups. Production additionally requires the
  /// release Team ID supplied by release composition.
  public static func forCurrentProcess(
    environment: ModelCredentialEnvironment,
    expectedProductionTeamIdentifier: String? = nil,
    identity: any ModelCredentialIdentityProvider = SystemModelCredentialIdentityProvider()
  ) throws -> ModelCredentialPolicy {
    guard
      let applicationIdentifier =
        identity.entitlement(named: "com.apple.application-identifier") as? String
        ?? identity.entitlement(named: "application-identifier") as? String
    else { throw ModelCredentialStoreFailure.unavailableIdentity }
    guard let groups = identity.entitlement(named: "keychain-access-groups") as? [String] else {
      throw ModelCredentialStoreFailure.unavailableIdentity
    }
    switch environment {
    case .production:
      guard let expectedProductionTeamIdentifier else {
        throw ModelCredentialStoreFailure.unavailableIdentity
      }
      let policy = try production(
        signedEntitlements: ["keychain-access-groups": groups],
        expectedTeamIdentifier: expectedProductionTeamIdentifier)
      guard
        applicationIdentifier
          == policy.applicationIdentifierPrefix + "dev.jort.editor"
      else {
        throw ModelCredentialStoreFailure.unavailableIdentity
      }
      return policy
    case .development:
      let suffix = "dev.jort.editor.development.credentials"
      guard groups.count == 1, groups[0].hasSuffix(suffix) else {
        throw ModelCredentialStoreFailure.unavailableIdentity
      }
      let prefix = String(groups[0].dropLast(suffix.count))
      guard isValidPrefix(prefix),
        applicationIdentifier == prefix + "dev.jort.editor"
      else { throw ModelCredentialStoreFailure.unavailableIdentity }
      return try ModelCredentialPolicy(
        environment: .development, applicationIdentifierPrefix: prefix)
    }
  }

}

public protocol ModelCredentialIdentityProvider: Sendable {
  func entitlement(named: String) -> Any?
}

public final class SystemModelCredentialIdentityProvider: ModelCredentialIdentityProvider,
  @unchecked Sendable
{
  public init() {}
  public func entitlement(named: String) -> Any? {
    guard let task = SecTaskCreateFromSelf(nil) else { return nil }
    return SecTaskCopyValueForEntitlement(task, named as CFString, nil)
  }
}

/// Injectable boundary for deterministic, Keychain-free unit tests.
public protocol ModelCredentialSecurityAdapter: Sendable {
  func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
  func add(_ attributes: [String: Any]) -> OSStatus
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
  func delete(_ query: [String: Any]) -> OSStatus
}

public final class SystemModelCredentialSecurityAdapter: ModelCredentialSecurityAdapter,
  @unchecked Sendable
{
  public init() {}
  public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
    var result: CFTypeRef?
    return (SecItemCopyMatching(query as CFDictionary, &result), result as? Data)
  }
  public func add(_ attributes: [String: Any]) -> OSStatus {
    SecItemAdd(attributes as CFDictionary, nil)
  }
  public func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }
  public func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

public actor KeychainModelCredentialStore: ModelCredentialStore {
  private static let legacyService = "dev.jort.editor.openrouter"
  private static let legacyAccount = "openrouter"
  private let policy: ModelCredentialPolicy
  private let security: any ModelCredentialSecurityAdapter
  private var outcome: ModelCredentialMigrationOutcome = .notRequired

  public init(
    policy: ModelCredentialPolicy,
    security: any ModelCredentialSecurityAdapter = SystemModelCredentialSecurityAdapter()
  ) {
    self.policy = policy
    self.security = security
  }

  public func migrationOutcome() async -> ModelCredentialMigrationOutcome { outcome }

  public func read() throws -> String? {
    let protected = try readProtectedData()
    guard protected == nil || credential(from: protected) != nil else { throw protectedFailure() }
    guard policy.environment == .production else { return credential(from: protected) }
    if let protected {
      // Reconcile durable Keychain contents on every read, including after a
      // restart. An in-memory outcome can never authorize one of two secrets.
      try reconcileExistingProtectedCredential(protected)
      return credential(from: protected)
    }
    return try reconcileAbsentProtectedProductionCredential()
  }

  public func replace(with credential: String) throws {
    guard let data = validatedData(credential) else { throw ModelFailure.credentialStore }
    let attributes = protectedUpdateAttributes(data)
    switch security.update(protectedQuery(), attributes: attributes) {
    case errSecSuccess: return
    case errSecItemNotFound:
      guard security.add(protectedQuery(adding: protectedCreateAttributes(data))) == errSecSuccess
      else {
        throw protectedFailure()
      }
    default: throw protectedFailure()
    }
  }

  public func remove() throws {
    if policy.environment == .production {
      // Disconnect explicitly authorizes removal of both saved connections.
      // Remove the migration source first: retaining it after protected
      // deletion would silently reconnect on the next read or launch.
      let legacyStatus = security.delete(legacyQuery())
      guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
        throw ModelFailure.credentialStore
      }
      do {
        guard try readLegacy() == nil else { throw ModelFailure.credentialStore }
      } catch { throw ModelFailure.credentialStore }
    }
    let status = security.delete(protectedQuery())
    guard status == errSecSuccess || status == errSecItemNotFound else { throw protectedFailure() }
    outcome = .notRequired
  }

  private func reconcileAbsentProtectedProductionCredential() throws -> String? {
    let legacy: Data?
    do { legacy = try readLegacy() } catch {
      outcome = .preVerificationFailed
      throw ModelCredentialStoreFailure.preVerificationFailed
    }
    guard let legacy else {
      outcome = .notRequired
      return nil
    }
    guard let value = credential(from: legacy) else {
      outcome = .preVerificationFailed
      throw ModelCredentialStoreFailure.preVerificationFailed
    }
    return try migrate(value, legacy: legacy)
  }

  private func migrate(_ credential: String, legacy: Data) throws -> String {
    do { try replace(with: credential) } catch {
      outcome = .preVerificationFailed
      throw ModelCredentialStoreFailure.preVerificationFailed
    }
    let verified: Data?
    do { verified = try readProtectedData() } catch {
      outcome = .preVerificationFailed
      throw ModelCredentialStoreFailure.preVerificationFailed
    }
    guard verified == legacy else {
      outcome = .preVerificationFailed
      throw ModelCredentialStoreFailure.preVerificationFailed
    }
    let cleanupCompleted = try cleanupVerifiedLegacy(expected: legacy)
    if cleanupCompleted { outcome = .migrated }
    return credential
  }

  /// Returns `true` only after a matching protected read and an absent legacy
  /// read have both been observed *after* deleting the legacy item. A failed
  /// cleanup remains non-fatal because the already verified protected item is
  /// still authoritative; a failed final protected verification is fatal
  /// because there is no longer a source item to safely fall back to.
  private func cleanupVerifiedLegacy(expected: Data) throws -> Bool {
    do {
      guard try readLegacy() == expected else {
        outcome = .conflict
        throw ModelCredentialStoreFailure.conflict
      }
    } catch let error as ModelCredentialStoreFailure {
      outcome = error.migrationOutcome
      throw error
    } catch {
      outcome = .cleanupIncomplete
      return false
    }
    let status = security.delete(legacyQuery())
    guard status == errSecSuccess || status == errSecItemNotFound else {
      outcome = .cleanupIncomplete
      return false
    }
    do {
      if let remaining = try readLegacy() {
        guard remaining == expected else {
          outcome = .conflict
          throw ModelCredentialStoreFailure.conflict
        }
        outcome = .cleanupIncomplete
        return false
      }
    } catch let error as ModelCredentialStoreFailure where error == .conflict {
      throw error
    } catch {
      outcome = .cleanupIncomplete
      return false
    }
    do {
      guard try readProtectedData() == expected else {
        outcome = .postCleanupVerificationFailed
        throw ModelCredentialStoreFailure.postCleanupVerificationFailed
      }
    } catch let error as ModelCredentialStoreFailure {
      if error == .unavailableIdentity {
        outcome = .postCleanupVerificationFailed
        throw ModelCredentialStoreFailure.postCleanupVerificationFailed
      }
      throw error
    }
    return true
  }

  /// Matching durable values prove cleanup is safe even after a restart.
  /// A mismatch is always fatal; only a previously verified cleanup may remain
  /// usable when the legacy namespace is temporarily inaccessible.
  private func reconcileExistingProtectedCredential(_ protected: Data) throws {
    let legacy: Data?
    do {
      legacy = try readLegacy()
    } catch {
      if outcome == .cleanupIncomplete { return }
      outcome = .preVerificationFailed
      throw ModelCredentialStoreFailure.preVerificationFailed
    }
    guard let legacy else {
      outcome = outcome == .cleanupIncomplete ? .migrated : .notRequired
      return
    }
    guard legacy == protected else {
      outcome = .conflict
      throw ModelCredentialStoreFailure.conflict
    }
    let cleanupCompleted = try cleanupVerifiedLegacy(expected: protected)
    if cleanupCompleted { outcome = .migrated }
  }

  private func readProtectedData() throws -> Data? {
    let result = security.copyMatching(protectedReadQuery())
    if result.status == errSecItemNotFound { return nil }
    guard result.status == errSecSuccess, let data = result.data else { throw protectedFailure() }
    return data
  }
  private func readLegacy() throws -> Data? {
    let result = security.copyMatching(legacyReadQuery())
    if result.status == errSecItemNotFound { return nil }
    guard result.status == errSecSuccess, let data = result.data else {
      throw ModelCredentialStoreFailure.preVerificationFailed
    }
    return data
  }

  private func protectedQuery(adding attributes: [String: Any] = [:]) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: policy.service, kSecAttrAccount as String: policy.account,
      kSecAttrAccessGroup as String: policy.accessGroup,
      kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false,
    ]
    attributes.forEach { query[$0] = $1 }
    return query
  }
  private func protectedReadQuery() -> [String: Any] {
    var query = protectedQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    return query
  }
  private func protectedUpdateAttributes(_ data: Data) -> [String: Any] {
    [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
  }
  private func protectedCreateAttributes(_ data: Data) -> [String: Any] {
    [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecAttrAccessGroup as String: policy.accessGroup,
      kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false,
    ]
  }
  private func legacyQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.legacyService, kSecAttrAccount as String: Self.legacyAccount,
      kSecAttrSynchronizable as String: false,
    ]
  }
  private func legacyReadQuery() -> [String: Any] {
    var query = legacyQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    return query
  }
  private func validatedData(_ value: String) -> Data? {
    guard !value.isEmpty, value.utf8.count <= 4096, !value.contains("\n"), !value.contains("\r")
    else {
      return nil
    }
    return Data(value.utf8)
  }
  private func credential(from data: Data?) -> String? {
    guard let data, data.count <= 4096, let value = String(data: data, encoding: .utf8),
      validatedData(value) != nil
    else { return nil }
    return value
  }
  private func protectedFailure() -> Error {
    outcome = .unavailableIdentity
    return ModelCredentialStoreFailure.unavailableIdentity
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

/// Used by composition when the signed process identity cannot prove the
/// selected Keychain policy. It never falls back to memory or legacy storage.
public struct UnavailableModelCredentialStore: ModelCredentialStore, Sendable {
  public init() {}
  public func read() throws -> String? { throw ModelCredentialStoreFailure.unavailableIdentity }
  public func replace(with credential: String) throws {
    throw ModelCredentialStoreFailure.unavailableIdentity
  }
  public func remove() throws { throw ModelCredentialStoreFailure.unavailableIdentity }
}
