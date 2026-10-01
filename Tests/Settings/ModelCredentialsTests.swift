import Foundation
import Security
import JortToolContracts
import XCTest
@testable import JortSettings

final class ModelCredentialsTests: XCTestCase {
  func testUnavailableStoreFailsClosedForEveryOperation() async {
    let store = UnavailableModelCredentialStore()
    do {
      _ = try await store.read()
      XCTFail("Expected unavailable identity")
    } catch { XCTAssertEqual(error as? ModelCredentialStoreFailure, .unavailableIdentity) }
    do {
      try await store.replace(with: "credential")
      XCTFail("Expected unavailable identity")
    } catch { XCTAssertEqual(error as? ModelCredentialStoreFailure, .unavailableIdentity) }
    do {
      try await store.remove()
      XCTFail("Expected unavailable identity")
    } catch { XCTAssertEqual(error as? ModelCredentialStoreFailure, .unavailableIdentity) }
  }

  func testCurrentProcessFactoryUsesSignedEntitlementsAndRejectsWrongTeam() throws {
    let identity = CredentialIdentityFake([
      "application-identifier": "TEAM123456.dev.jort.editor",
      "keychain-access-groups": ["TEAM123456.dev.jort.editor.credentials"],
    ])
    let policy = try ModelCredentialPolicy.forCurrentProcess(
      environment: .production, expectedProductionTeamIdentifier: "TEAM123456", identity: identity)
    XCTAssertEqual(policy.accessGroup, "TEAM123456.dev.jort.editor.credentials")
    XCTAssertThrowsError(
      try ModelCredentialPolicy.forCurrentProcess(
        environment: .production, expectedProductionTeamIdentifier: "OTHER", identity: identity)
    ) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .unavailableIdentity)
    }
  }

  func testCurrentProcessFactoryRequiresApplicationIdentifier() {
    let productionIdentity = CredentialIdentityFake([
      "keychain-access-groups": ["TEAM123456.dev.jort.editor.credentials"]
    ])
    XCTAssertThrowsError(
      try ModelCredentialPolicy.forCurrentProcess(
        environment: .production, expectedProductionTeamIdentifier: "TEAM123456",
        identity: productionIdentity)
    ) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .unavailableIdentity)
    }

    let developmentIdentity = CredentialIdentityFake([
      "keychain-access-groups": ["TEAM123456.dev.jort.editor.development.credentials"]
    ])
    XCTAssertThrowsError(
      try ModelCredentialPolicy.forCurrentProcess(
        environment: .development, identity: developmentIdentity)
    ) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .unavailableIdentity)
    }
  }

  func testCurrentProcessFactoryRejectsWrongApplicationIdentifier() {
    let productionIdentity = CredentialIdentityFake([
      "application-identifier": "OTHER12345.dev.jort.editor",
      "keychain-access-groups": ["TEAM123456.dev.jort.editor.credentials"],
    ])
    XCTAssertThrowsError(
      try ModelCredentialPolicy.forCurrentProcess(
        environment: .production, expectedProductionTeamIdentifier: "TEAM123456",
        identity: productionIdentity)
    ) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .unavailableIdentity)
    }

    let developmentIdentity = CredentialIdentityFake([
      "application-identifier": "TEAM123456.dev.jort.another-app",
      "keychain-access-groups": ["TEAM123456.dev.jort.editor.development.credentials"],
    ])
    XCTAssertThrowsError(
      try ModelCredentialPolicy.forCurrentProcess(
        environment: .development, identity: developmentIdentity)
    ) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .unavailableIdentity)
    }
  }

  func testProtectedOperationsUseCompleteProductionNamespace() async throws {
    let security = CredentialSecurityFake(protected: Data("old-credential".utf8))
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    try await store.replace(with: "credential")
    _ = try await store.read()
    try await store.remove()

    let queries = security.queries
    XCTAssertFalse(queries.isEmpty)
    for query in queries where query[kSecAttrService as String] as? String == policy.service {
      XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
      XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
      XCTAssertEqual(
        query[kSecAttrAccessGroup as String] as? String, "TEAM123.dev.jort.editor.credentials")
      XCTAssertEqual(query[kSecAttrAccount as String] as? String, "openrouter")
    }
    XCTAssertEqual(
      security.lastAttributes?[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    XCTAssertEqual(
      security.updateAttributes.first?[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
  }

  func testSecurityAdapterUsesExactReadWriteAndLegacyQueryDictionaries() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)

    let migrated = try await store.read()
    XCTAssertEqual(migrated, "legacy-value")
    try await store.replace(with: "replacement-value")
    try await store.remove()

    let protectedBase: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.jort.editor.openrouter.v2",
      kSecAttrAccount as String: "openrouter",
      kSecAttrAccessGroup as String: "TEAM123.dev.jort.editor.credentials",
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false,
    ]
    let protectedRead = protectedBase.merging([
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]) { _, replacement in replacement }
    let legacyRead: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.jort.editor.openrouter",
      kSecAttrAccount as String: "openrouter",
      kSecAttrSynchronizable as String: false,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    let protectedCreate = protectedBase.merging([
      kSecValueData as String: Data("legacy-value".utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]) { _, replacement in replacement }
    let protectedUpdate: [String: Any] = [
      kSecValueData as String: Data("replacement-value".utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]

    XCTAssertTrue(security.queries.contains { dictionariesEqual($0, protectedRead) })
    XCTAssertTrue(security.queries.contains { dictionariesEqual($0, legacyRead) })
    XCTAssertTrue(security.queries.contains { dictionariesEqual($0, protectedCreate) })
    XCTAssertTrue(security.queries.contains { dictionariesEqual($0, protectedBase) })
    XCTAssertTrue(security.updateAttributes.contains { dictionariesEqual($0, protectedUpdate) })
  }

  func testDevelopmentNeverQueriesProductionOrLegacyNamespace() async throws {
    let security = CredentialSecurityFake()
    let policy = try ModelCredentialPolicy(
      environment: .development, applicationIdentifierPrefix: "DEV123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    let credential = try await store.read()
    XCTAssertNil(credential)
    XCTAssertFalse(
      security.queries.contains { query in
        query[kSecAttrService as String] as? String == "dev.jort.editor.openrouter"
          || query[kSecAttrService as String] as? String == "dev.jort.editor.openrouter.v2"
      })
    XCTAssertEqual(
      security.queries.first?[kSecAttrService as String] as? String,
      "dev.jort.editor.development.openrouter.v2")
  }

  func testProductionMigrationCopiesVerifiesThenDeletesLegacy() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    let credential = try await store.read()
    let outcome = await store.migrationOutcome()
    XCTAssertEqual(credential, "legacy-value")
    XCTAssertEqual(outcome, .migrated)
    XCTAssertEqual(security.protected, Data("legacy-value".utf8))
    XCTAssertNil(security.legacy)
    XCTAssertEqual(
      security.operations,
      [
        .copyProtected, .copyLegacy, .updateProtected, .addProtected,
        .copyProtected, .copyLegacy, .deleteLegacy, .copyLegacy,
        .copyProtected,
      ])
  }

  func testCleanupFailureKeepsProtectedCopyUsableAndRetriesExactCleanup() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    security.failLegacyDelete = true
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    let firstCredential = try await store.read()
    let outcome = await store.migrationOutcome()
    XCTAssertEqual(firstCredential, "legacy-value")
    XCTAssertEqual(outcome, .cleanupIncomplete)
    XCTAssertEqual(security.protected, Data("legacy-value".utf8))
    XCTAssertEqual(security.legacy, Data("legacy-value".utf8))
    security.failLegacyDelete = false
    let retriedCredential = try await store.read()
    XCTAssertEqual(retriedCredential, "legacy-value")
    XCTAssertNil(security.legacy)
    let retriedOutcome = await store.migrationOutcome()
    XCTAssertEqual(retriedOutcome, .migrated)
  }

  func testDisconnectAfterCleanupIncompleteAndRestartCannotRemigrateLegacy() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    security.failLegacyDelete = true
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    _ = try await store.read()
    let initialOutcome = await store.migrationOutcome()
    XCTAssertEqual(initialOutcome, .cleanupIncomplete)

    let restarted = KeychainModelCredentialStore(policy: policy, security: security)
    security.failLegacyDelete = false
    try await restarted.remove()
    XCTAssertEqual(
      Array(security.operations.suffix(3)), [.deleteLegacy, .copyLegacy, .deleteProtected])
    XCTAssertNil(security.protected)
    XCTAssertNil(security.legacy)
    let outcome = await restarted.migrationOutcome()
    XCTAssertEqual(outcome, .notRequired)
    let subsequent = KeychainModelCredentialStore(policy: policy, security: security)
    let credential = try await subsequent.read()
    XCTAssertNil(credential)
    XCTAssertEqual(security.operations.filter { $0 == .addProtected }.count, 1)
  }

  func testExplicitDisconnectRemovesConflictingCredentials() async throws {
    let security = CredentialSecurityFake(
      protected: Data("protected-value".utf8), legacy: Data("legacy-value".utf8))
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    await XCTAssertThrowsErrorAsync(try await store.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .conflict)
    }
    try await store.remove()
    let outcome = await store.migrationOutcome()
    XCTAssertEqual(outcome, .notRequired)
    XCTAssertNil(security.protected)
    XCTAssertNil(security.legacy)
    let restarted = KeychainModelCredentialStore(policy: policy, security: security)
    let credential = try await restarted.read()
    XCTAssertNil(credential)
  }

  func testDisconnectLegacyDeleteFailurePreservesProtectedAndConflict() async throws {
    let security = CredentialSecurityFake(
      protected: Data("protected-value".utf8), legacy: Data("legacy-value".utf8))
    security.failLegacyDelete = true
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    await XCTAssertThrowsErrorAsync(try await store.read()) { _ in }
    await XCTAssertThrowsErrorAsync(try await store.remove()) {
      XCTAssertEqual($0 as? ModelFailure, .credentialStore)
    }
    let outcome = await store.migrationOutcome()
    XCTAssertEqual(outcome, .conflict)
    XCTAssertEqual(security.protected, Data("protected-value".utf8))
    XCTAssertEqual(security.legacy, Data("legacy-value".utf8))
    XCTAssertFalse(security.operations.contains(.deleteProtected))
  }

  func testDisconnectUnconfirmedLegacyRemovalPreservesProtected() async throws {
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    for readFailure in [false, true] {
      let security = CredentialSecurityFake(
        protected: Data("protected-value".utf8), legacy: Data("legacy-value".utf8))
      if readFailure {
        security.legacyReadStatus = errSecAuthFailed
      } else {
        security.legacyValueAfterDelete = Data("reappeared-value".utf8)
      }
      let store = KeychainModelCredentialStore(policy: policy, security: security)
      await XCTAssertThrowsErrorAsync(try await store.remove()) {
        XCTAssertEqual($0 as? ModelFailure, .credentialStore)
      }
      XCTAssertEqual(security.protected, Data("protected-value".utf8))
      XCTAssertFalse(security.operations.contains(.deleteProtected))
    }
  }

  func testDevelopmentDisconnectNeverTouchesProductionLegacy() async throws {
    let security = CredentialSecurityFake(
      protected: Data("development-value".utf8), legacy: Data("production-value".utf8))
    security.failLegacyDelete = true
    let policy = try ModelCredentialPolicy(
      environment: .development, applicationIdentifierPrefix: "DEV123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    try await store.remove()
    XCTAssertEqual(security.operations, [.deleteProtected])
    XCTAssertNil(security.protected)
    XCTAssertEqual(security.legacy, Data("production-value".utf8))
    let credential = try await store.read()
    XCTAssertNil(credential)
    XCTAssertFalse(security.operations.contains(.copyLegacy))
  }

  func testCleanupRetryConflictBlocksBillableUseAcrossReadsAndRestart() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    security.failLegacyDelete = true
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    let initiallyReadCredential = try await store.read()
    XCTAssertEqual(initiallyReadCredential, "legacy-value")

    security.failLegacyDelete = false
    security.setLegacy(Data("replacement-value".utf8))
    for _ in 0..<2 {
      await XCTAssertThrowsErrorAsync(try await store.read()) {
        XCTAssertEqual($0 as? ModelCredentialStoreFailure, .conflict)
      }
    }
    let restarted = KeychainModelCredentialStore(policy: policy, security: security)
    await XCTAssertThrowsErrorAsync(try await restarted.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .conflict)
    }
    let retriedOutcome = await store.migrationOutcome()
    XCTAssertEqual(retriedOutcome, .conflict)
    XCTAssertEqual(security.legacy, Data("replacement-value".utf8))
    XCTAssertEqual(security.protected, Data("legacy-value".utf8))
    XCTAssertEqual(security.operations.filter { $0 == .deleteLegacy }.count, 1)
  }

  func testCleanupRetryPostDeleteOverwriteFailsClosed() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    security.failLegacyDelete = true
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    let initialCredential = try await store.read()
    XCTAssertEqual(initialCredential, "legacy-value")
    let initialOutcome = await store.migrationOutcome()
    XCTAssertEqual(initialOutcome, .cleanupIncomplete)

    security.failLegacyDelete = false
    security.protectedValueAfterLegacyDelete = Data("replacement-value".utf8)
    await XCTAssertThrowsErrorAsync(try await store.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .postCleanupVerificationFailed)
    }
    let finalOutcome = await store.migrationOutcome()
    XCTAssertEqual(finalOutcome, .postCleanupVerificationFailed)
    XCTAssertEqual(security.protected, Data("replacement-value".utf8))
    XCTAssertNil(security.legacy)
  }

  func testExistingProtectedCredentialConflictsWithDifferentLegacyBytes() async throws {
    let security = CredentialSecurityFake(
      protected: Data("new-value".utf8), legacy: Data([0xFF]))
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    await XCTAssertThrowsErrorAsync(try await store.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .conflict)
    }
    let outcome = await store.migrationOutcome()
    XCTAssertTrue(security.operations.contains(.copyLegacy))
    XCTAssertEqual(outcome, .conflict)
    XCTAssertEqual(security.protected, Data("new-value".utf8))
    XCTAssertEqual(security.legacy, Data([0xFF]))
  }

  func testCleanupIncompleteIsReconciledAfterRestart() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    security.failLegacyDelete = true
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    _ = try await store.read()
    security.failLegacyDelete = false
    let restarted = KeychainModelCredentialStore(policy: policy, security: security)
    let value = try await restarted.read()
    let outcome = await restarted.migrationOutcome()
    XCTAssertEqual(value, "legacy-value")
    XCTAssertEqual(outcome, .migrated)
    XCTAssertNil(security.legacy)
  }

  func testMigrationWriteFailurePreservesLegacyCredential() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    security.failProtectedAdd = true
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)

    await XCTAssertThrowsErrorAsync(try await store.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .preVerificationFailed)
    }
    XCTAssertNil(security.protected)
    XCTAssertEqual(security.legacy, Data("legacy-value".utf8))
  }

  func testMigrationReadbackFailurePreservesLegacyCredential() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    security.protectedReadDataOverride = Data("different-value".utf8)
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)

    await XCTAssertThrowsErrorAsync(try await store.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .preVerificationFailed)
    }
    XCTAssertEqual(security.protected, Data("legacy-value".utf8))
    XCTAssertEqual(security.legacy, Data("legacy-value".utf8))
  }

  func testPostCleanupProtectedOverwriteFailsWithoutRecreatingLegacy() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    security.protectedValueAfterLegacyDelete = Data("replacement-value".utf8)
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)

    await XCTAssertThrowsErrorAsync(try await store.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .postCleanupVerificationFailed)
    }
    let outcome = await store.migrationOutcome()
    XCTAssertEqual(outcome, .postCleanupVerificationFailed)
    XCTAssertEqual(security.protected, Data("replacement-value".utf8))
    XCTAssertNil(security.legacy)
    XCTAssertEqual(security.operations.filter { $0 == .addProtected }.count, 1)
  }

  func testPostCleanupProtectedReadFailureFailsWithoutRecreatingLegacy() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    security.failProtectedReadAfterLegacyDelete = true
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)

    await XCTAssertThrowsErrorAsync(try await store.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .postCleanupVerificationFailed)
    }
    let outcome = await store.migrationOutcome()
    XCTAssertEqual(outcome, .postCleanupVerificationFailed)
    XCTAssertEqual(security.protected, Data("legacy-value".utf8))
    XCTAssertNil(security.legacy)
  }

  func testConcurrentMigrationSerializesToOneProtectedWrite() async throws {
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)

    try await withThrowingTaskGroup(of: String?.self) { group in
      for _ in 0..<8 { group.addTask { try await store.read() } }
      for try await credential in group { XCTAssertEqual(credential, "legacy-value") }
    }
    XCTAssertEqual(security.operations.filter { $0 == .addProtected }.count, 1)
    XCTAssertEqual(security.operations.filter { $0 == .deleteLegacy }.count, 1)
    XCTAssertNil(security.legacy)
  }

  func testProtectedAndLegacyReadFailuresFailClosedAtTheirRespectiveBoundaries() async throws {
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")

    let protectedFailure = CredentialSecurityFake()
    protectedFailure.protectedReadStatus = errSecAuthFailed
    await XCTAssertThrowsErrorAsync(
      try await KeychainModelCredentialStore(policy: policy, security: protectedFailure).read()
    ) { XCTAssertEqual($0 as? ModelCredentialStoreFailure, .unavailableIdentity) }

    let legacyFailure = CredentialSecurityFake()
    legacyFailure.legacyReadStatus = errSecAuthFailed
    let legacyStore = KeychainModelCredentialStore(policy: policy, security: legacyFailure)
    await XCTAssertThrowsErrorAsync(try await legacyStore.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .preVerificationFailed)
    }
    let legacyOutcome = await legacyStore.migrationOutcome()
    XCTAssertEqual(legacyOutcome, .preVerificationFailed)
  }

  func testMalformedProtectedAndLegacyCredentialsFailClosedWithoutCrossNamespaceWrites()
    async throws
  {
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let malformedProtected = CredentialSecurityFake(protected: Data([0xFF]))
    await XCTAssertThrowsErrorAsync(
      try await KeychainModelCredentialStore(policy: policy, security: malformedProtected).read()
    ) { XCTAssertEqual($0 as? ModelCredentialStoreFailure, .unavailableIdentity) }
    XCTAssertFalse(malformedProtected.operations.contains(.copyLegacy))
    XCTAssertFalse(malformedProtected.operations.contains(.addProtected))

    let malformedLegacy = CredentialSecurityFake(legacy: Data([0xFF]))
    let legacyStore = KeychainModelCredentialStore(policy: policy, security: malformedLegacy)
    await XCTAssertThrowsErrorAsync(try await legacyStore.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .preVerificationFailed)
    }
    XCTAssertNil(malformedLegacy.protected)
    XCTAssertEqual(malformedLegacy.legacy, Data([0xFF]))
  }

  func testUpdateAndRemoveFailurePreservePriorWorkingCredential() async throws {
    let security = CredentialSecurityFake(protected: Data("working-value".utf8))
    security.protectedUpdateStatus = errSecAuthFailed
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)

    await XCTAssertThrowsErrorAsync(try await store.replace(with: "replacement-value")) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .unavailableIdentity)
    }
    let afterUpdateFailure = try await store.read()
    XCTAssertEqual(afterUpdateFailure, "working-value")
    security.protectedDeleteStatus = errSecAuthFailed
    await XCTAssertThrowsErrorAsync(try await store.remove()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .unavailableIdentity)
    }
    let afterRemoveFailure = try await store.read()
    XCTAssertEqual(afterRemoveFailure, "working-value")
  }

  func testInvalidReplacementNeverMutatesPriorCredential() async throws {
    let security = CredentialSecurityFake(protected: Data("working-value".utf8))
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    for invalid in ["", "contains\nnewline", String(repeating: "x", count: 4097)] {
      await XCTAssertThrowsErrorAsync(try await store.replace(with: invalid)) { _ in }
    }
    XCTAssertEqual(security.operations, [])
    let retained = try await store.read()
    XCTAssertEqual(retained, "working-value")
  }

  func testPreDeleteConflictAndErrorPreserveBothCopies() async throws {
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let conflict = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    conflict.legacyReadDataOverrideAfterProtectedWrite = Data("changed-value".utf8)
    let conflictStore = KeychainModelCredentialStore(policy: policy, security: conflict)
    for _ in 0..<2 {
      await XCTAssertThrowsErrorAsync(try await conflictStore.read()) {
        XCTAssertEqual($0 as? ModelCredentialStoreFailure, .conflict)
      }
    }
    let restarted = KeychainModelCredentialStore(policy: policy, security: conflict)
    await XCTAssertThrowsErrorAsync(try await restarted.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .conflict)
    }
    XCTAssertEqual(conflict.protected, Data("legacy-value".utf8))
    XCTAssertEqual(conflict.legacy, Data("legacy-value".utf8))
    XCTAssertFalse(conflict.operations.contains(.deleteLegacy))
    XCTAssertEqual(conflict.operations.filter { $0 == .updateProtected }.count, 1)

    let readFailure = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    readFailure.legacyReadStatusAfterProtectedWrite = errSecAuthFailed
    let failureStore = KeychainModelCredentialStore(policy: policy, security: readFailure)
    await XCTAssertThrowsErrorAsync(try await failureStore.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .preVerificationFailed)
    }
    let failureOutcome = await failureStore.migrationOutcome()
    XCTAssertEqual(failureOutcome, .preVerificationFailed)
    XCTAssertEqual(readFailure.protected, Data("legacy-value".utf8))
    XCTAssertEqual(readFailure.legacy, Data("legacy-value".utf8))
  }

  func testPostDeleteLegacyReappearanceAndFinalProtectedAbsenceFailClosed() async throws {
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let reappearingLegacy = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    reappearingLegacy.legacyValueAfterDelete = Data("legacy-value".utf8)
    let reappearingStore = KeychainModelCredentialStore(policy: policy, security: reappearingLegacy)
    let reappearingCredential = try await reappearingStore.read()
    let reappearingOutcome = await reappearingStore.migrationOutcome()
    XCTAssertEqual(reappearingCredential, "legacy-value")
    XCTAssertEqual(reappearingOutcome, .cleanupIncomplete)
    XCTAssertEqual(reappearingLegacy.protected, Data("legacy-value".utf8))

    let missingProtected = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    missingProtected.clearProtectedAfterLegacyDelete = true
    let missingStore = KeychainModelCredentialStore(policy: policy, security: missingProtected)
    await XCTAssertThrowsErrorAsync(try await missingStore.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .postCleanupVerificationFailed)
    }
    XCTAssertNil(missingProtected.protected)
    XCTAssertNil(missingProtected.legacy)
  }

  func testDifferentLegacyCredentialReappearingAfterDeleteBlocksUseImmediately() async throws {
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let security = CredentialSecurityFake(legacy: Data("legacy-value".utf8))
    security.legacyValueAfterDelete = Data("changed-value".utf8)
    let store = KeychainModelCredentialStore(policy: policy, security: security)
    await XCTAssertThrowsErrorAsync(try await store.read()) {
      XCTAssertEqual($0 as? ModelCredentialStoreFailure, .conflict)
    }
    XCTAssertEqual(security.protected, Data("legacy-value".utf8))
    XCTAssertEqual(security.legacy, Data("changed-value".utf8))
  }

  func testConcurrentReadReplaceAndRemoveRemainActorSerialized() async throws {
    let security = CredentialSecurityFake(protected: Data("seed-value".utf8))
    let policy = try ModelCredentialPolicy(
      environment: .production, applicationIdentifierPrefix: "TEAM123.")
    let store = KeychainModelCredentialStore(policy: policy, security: security)

    async let first: Void = try await store.replace(with: "first-value")
    async let read: String? = try await store.read()
    async let remove: Void = try await store.remove()
    _ = try await (first, read, remove)

    XCTAssertTrue(security.operations.contains(.updateProtected))
    XCTAssertTrue(security.operations.contains(.deleteProtected))
    XCTAssertLessThanOrEqual(security.operations.filter { $0 == .updateProtected }.count, 1)
    XCTAssertLessThanOrEqual(security.operations.filter { $0 == .deleteProtected }.count, 1)
  }
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected an error", file: file, line: line)
  } catch { errorHandler(error) }
}

private enum CredentialOperation: Equatable {
  case copyProtected, copyLegacy, updateProtected, addProtected, deleteLegacy, deleteProtected
}

private func dictionariesEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
  NSDictionary(dictionary: lhs).isEqual(to: rhs)
}

private final class CredentialIdentityFake: ModelCredentialIdentityProvider, @unchecked Sendable {
  let values: [String: Any]
  init(_ values: [String: Any]) { self.values = values }
  func entitlement(named: String) -> Any? { values[named] }
}

private final class CredentialSecurityFake: ModelCredentialSecurityAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private var protectedValue: Data?
  private var legacyValue: Data?
  private var queryLog: [[String: Any]] = []
  private var operationLog: [CredentialOperation] = []
  private var attributesValue: [String: Any]?
  private var updateAttributesValue: [[String: Any]] = []
  private var failLegacyDeleteValue = false
  private var failProtectedAddValue = false
  private var failProtectedReadAfterLegacyDeleteValue = false
  private var protectedReadDataOverrideValue: Data?
  private var protectedValueAfterLegacyDeleteValue: Data?
  private var protectedReadStatusValue: OSStatus?
  private var legacyReadStatusValue: OSStatus?
  private var legacyReadStatusAfterProtectedWriteValue: OSStatus?
  private var protectedUpdateStatusValue: OSStatus?
  private var protectedDeleteStatusValue: OSStatus?
  private var legacyReadDataOverrideAfterProtectedWriteValue: Data?
  private var legacyValueAfterDeleteValue: Data?
  private var clearProtectedAfterLegacyDeleteValue = false

  init(protected: Data? = nil, legacy: Data? = nil) {
    protectedValue = protected
    legacyValue = legacy
  }
  var protected: Data? { lock.withLock { protectedValue } }
  var legacy: Data? { lock.withLock { legacyValue } }
  var queries: [[String: Any]] { lock.withLock { queryLog } }
  var operations: [CredentialOperation] { lock.withLock { operationLog } }
  var lastAttributes: [String: Any]? { lock.withLock { attributesValue } }
  var updateAttributes: [[String: Any]] { lock.withLock { updateAttributesValue } }
  var failLegacyDelete: Bool {
    get { lock.withLock { failLegacyDeleteValue } }
    set { lock.withLock { failLegacyDeleteValue = newValue } }
  }
  var failProtectedAdd: Bool {
    get { lock.withLock { failProtectedAddValue } }
    set { lock.withLock { failProtectedAddValue = newValue } }
  }
  var protectedReadDataOverride: Data? {
    get { lock.withLock { protectedReadDataOverrideValue } }
    set { lock.withLock { protectedReadDataOverrideValue = newValue } }
  }
  var failProtectedReadAfterLegacyDelete: Bool {
    get { lock.withLock { failProtectedReadAfterLegacyDeleteValue } }
    set { lock.withLock { failProtectedReadAfterLegacyDeleteValue = newValue } }
  }
  var protectedValueAfterLegacyDelete: Data? {
    get { lock.withLock { protectedValueAfterLegacyDeleteValue } }
    set { lock.withLock { protectedValueAfterLegacyDeleteValue = newValue } }
  }
  var protectedReadStatus: OSStatus? {
    get { lock.withLock { protectedReadStatusValue } }
    set { lock.withLock { protectedReadStatusValue = newValue } }
  }
  var legacyReadStatus: OSStatus? {
    get { lock.withLock { legacyReadStatusValue } }
    set { lock.withLock { legacyReadStatusValue = newValue } }
  }
  var legacyReadStatusAfterProtectedWrite: OSStatus? {
    get { lock.withLock { legacyReadStatusAfterProtectedWriteValue } }
    set { lock.withLock { legacyReadStatusAfterProtectedWriteValue = newValue } }
  }
  var protectedUpdateStatus: OSStatus? {
    get { lock.withLock { protectedUpdateStatusValue } }
    set { lock.withLock { protectedUpdateStatusValue = newValue } }
  }
  var protectedDeleteStatus: OSStatus? {
    get { lock.withLock { protectedDeleteStatusValue } }
    set { lock.withLock { protectedDeleteStatusValue = newValue } }
  }
  var legacyReadDataOverrideAfterProtectedWrite: Data? {
    get { lock.withLock { legacyReadDataOverrideAfterProtectedWriteValue } }
    set { lock.withLock { legacyReadDataOverrideAfterProtectedWriteValue = newValue } }
  }
  var legacyValueAfterDelete: Data? {
    get { lock.withLock { legacyValueAfterDeleteValue } }
    set { lock.withLock { legacyValueAfterDeleteValue = newValue } }
  }
  var clearProtectedAfterLegacyDelete: Bool {
    get { lock.withLock { clearProtectedAfterLegacyDeleteValue } }
    set { lock.withLock { clearProtectedAfterLegacyDeleteValue = newValue } }
  }
  func setLegacy(_ value: Data?) { lock.withLock { legacyValue = value } }

  func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
    lock.withLock {
      queryLog.append(query)
      if isLegacy(query) {
        operationLog.append(.copyLegacy)
        if let status = legacyReadStatusValue { return (status, nil) }
        if protectedValue != nil, let status = legacyReadStatusAfterProtectedWriteValue {
          return (status, nil)
        }
        let result =
          legacyValue == nil
          ? nil
          : (protectedValue == nil
            ? legacyValue : (legacyReadDataOverrideAfterProtectedWriteValue ?? legacyValue))
        return result.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
      }
      operationLog.append(.copyProtected)
      if let status = protectedReadStatusValue { return (status, nil) }
      if failProtectedReadAfterLegacyDeleteValue, legacyValue == nil {
        return (errSecAuthFailed, nil)
      }
      let result: Data? =
        protectedValue == nil ? nil : (protectedReadDataOverrideValue ?? protectedValue)
      return result.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
    }
  }
  func add(_ attributes: [String: Any]) -> OSStatus {
    lock.withLock {
      queryLog.append(attributes)
      operationLog.append(.addProtected)
      attributesValue = attributes
      if failProtectedAddValue { return errSecAuthFailed }
      protectedValue = attributes[kSecValueData as String] as? Data
      return errSecSuccess
    }
  }
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    lock.withLock {
      queryLog.append(query)
      operationLog.append(.updateProtected)
      attributesValue = attributes
      updateAttributesValue.append(attributes)
      if let status = protectedUpdateStatusValue { return status }
      guard protectedValue != nil else { return errSecItemNotFound }
      protectedValue = attributes[kSecValueData as String] as? Data
      return errSecSuccess
    }
  }
  func delete(_ query: [String: Any]) -> OSStatus {
    lock.withLock {
      queryLog.append(query)
      if isLegacy(query) {
        operationLog.append(.deleteLegacy)
        if failLegacyDeleteValue { return errSecAuthFailed }
        legacyValue = nil
        if let legacyValueAfterDeleteValue { legacyValue = legacyValueAfterDeleteValue }
        if let protectedValueAfterLegacyDeleteValue {
          protectedValue = protectedValueAfterLegacyDeleteValue
        }
        if clearProtectedAfterLegacyDeleteValue { protectedValue = nil }
      } else {
        operationLog.append(.deleteProtected)
        if let status = protectedDeleteStatusValue { return status }
        protectedValue = nil
      }
      return errSecSuccess
    }
  }
  private func isLegacy(_ query: [String: Any]) -> Bool {
    query[kSecAttrService as String] as? String == "dev.jort.editor.openrouter"
  }
}
