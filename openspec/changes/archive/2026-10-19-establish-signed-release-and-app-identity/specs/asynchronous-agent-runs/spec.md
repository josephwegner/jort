## ADDED Requirements

### Requirement: Model credentials use the Data Protection Keychain
Jort SHALL perform every production and development model-credential add, read, update, delete, migration-verification, and cleanup operation against its selected Data Protection Keychain policy and SHALL preserve nonsynchronizing `WhenUnlockedThisDeviceOnly` accessibility.

#### Scenario: Credential query is constructed
- **WHEN** the credential store performs any operation on a protected model credential
- **THEN** the complete query includes `kSecUseDataProtectionKeychain: true`, `kSecAttrSynchronizable: false`, the exact service/account, and the selected access group
- **AND** every created or replaced item includes `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

#### Scenario: Protected Keychain policy cannot be applied
- **WHEN** Security rejects the data-protection selector, access group, accessibility class, or current code identity
- **THEN** Jort returns a typed actionable credential-store failure and performs no provider request with an unverified fallback item
- **AND** does not retry through the legacy Keychain policy or a broader access group

### Requirement: Production and development credentials have disjoint identities
Jort SHALL use service `dev.jort.editor.openrouter.v2`, account `openrouter`, and production access-group suffix `dev.jort.editor.credentials` only from the signed production app, and SHALL use distinct development service, account, and access-group policy that never queries the production namespace.

#### Scenario: Production app requests a model credential
- **WHEN** the production model Runtime lazily asks the credential interface for OpenRouter authorization
- **THEN** the store queries only the production Data Protection item whose application-identifier prefix matches the verified release Team ID
- **AND** returns credential bytes only through the existing bounded runtime interface

#### Scenario: Development app requests a model credential
- **WHEN** an ad-hoc or Apple Development build connects or executes a model tool
- **THEN** it uses `dev.jort.editor.development.openrouter.v2`, account `openrouter-development`, and the development access-group policy
- **AND** never reads, updates, deletes, migrates, or falls back to the production item

#### Scenario: JavaScript helper identities are inspected
- **WHEN** the packaged broker or worker entitlements are evaluated
- **THEN** neither helper contains the production or development Keychain access group
- **AND** JavaScript validation/execution receives no credential value or Security capability through IPC

### Requirement: Legacy credentials migrate only after verified protected copy
Jort SHALL serialize legacy credential migration with connection mutations, write a protected production replacement, verify its exact bytes through the complete protected query, and delete the exact legacy item only after that verification succeeds.

#### Scenario: Only a valid legacy item exists
- **WHEN** the signed production app finds no protected item and reads a valid bounded legacy OpenRouter credential
- **THEN** it writes the new production item, reads it back through the full Data Protection/access-group query, compares exact bytes, and only then deletes the legacy item
- **AND** confirms the protected item remains readable and the legacy query is absent before reporting migration complete

#### Scenario: Migration fails before replacement verification
- **WHEN** legacy read, protected write, or protected read-back verification fails
- **THEN** Jort preserves the legacy item and reports a bounded actionable migration state
- **AND** neither deletes the source nor sends an unverified replacement to OpenRouter

#### Scenario: Legacy cleanup fails after replacement verification
- **WHEN** the protected replacement matches but deleting or confirming removal of the legacy item fails
- **THEN** Jort retains and uses the verified protected item, reports cleanup incomplete, and retries only the exact legacy cleanup
- **AND** never recreates legacy storage or exposes either value

#### Scenario: Protected and legacy values conflict
- **WHEN** both items exist with different credential bytes
- **THEN** Jort deletes neither, performs no automatic overwrite, and presents an actionable reconnect or cleanup state
- **AND** does not guess which credential should authorize billable use

### Requirement: Unauthorized code identities cannot read model credentials
Jort SHALL verify with signed disposable canaries that only the authorized main-app identity can access its selected credential group and SHALL make production release validation prove every nested helper omits that authority.

#### Scenario: Authorized signed host reads a canary
- **WHEN** a correctly signed main-app integration host creates a random canary under the test policy matching production group structure
- **THEN** it can read, update, and delete the canary through the complete Data Protection query
- **AND** the fixture removes the canary without logging its bytes

#### Scenario: Differently signed helper reads a canary
- **WHEN** a helper with a different identifier and no authorized access-group entitlement queries the canary
- **THEN** Security denies access or returns no item
- **AND** the helper cannot distinguish or recover any credential bytes from diagnostics

#### Scenario: Broker or worker probes Keychain
- **WHEN** the Wave 3 containment denial fixtures attempt the corresponding credential-group lookup
- **THEN** the broker and worker have no entitlement or IPC value that grants access and the probe fails
- **AND** ordinary JavaScript failure handling remains bounded and cannot mutate the document

### Requirement: Credential migration and diagnostics never disclose secrets
Jort SHALL keep protected, legacy, development, and canary credential bytes out of settings, documents, history, recovery data, package data, release evidence, test output, and application logs throughout normal access and every migration failure path.

#### Scenario: Migration or identity test fails
- **WHEN** Security returns an error at any credential migration or signed-denial boundary
- **THEN** Jort records only a bounded nonsecret operation category, status classification, and actionable state
- **AND** omits query-return data, credential bytes, authorization headers, and canary contents

#### Scenario: Application rolls back after successful migration
- **WHEN** an older build that knows only the legacy service runs after the new app deleted a verified legacy item
- **THEN** no component copies the protected credential back into legacy storage automatically
- **AND** documentation explains that the older build may require a new connection while the protected item remains intact
