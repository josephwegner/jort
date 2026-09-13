## ADDED Requirements

### Requirement: OpenRouter connection is OAuth-only
Jort SHALL connect users to OpenRouter through an OAuth PKCE flow using an S256 challenge and SHALL provide no interface for manually entering, revealing, importing, or exporting an API key.

#### Scenario: Disconnected user connects
- **WHEN** the user activates Connect with OpenRouter in Models Settings
- **THEN** Jort opens an OpenRouter-hosted authorization experience through the system browser or authentication surface
- **AND** begins a bounded PKCE S256 flow without asking the user to enter a credential into Jort

#### Scenario: Authorization returns to Jort
- **WHEN** OpenRouter returns an authorization response to the temporary callback
- **THEN** Jort accepts only the correlated response for the active unexpired attempt and exchanges it with the matching in-memory verifier
- **AND** rejects mismatched, replayed, duplicate, or expired responses

#### Scenario: User cancels authorization
- **WHEN** the user cancels or the OAuth attempt expires before a verified credential is received
- **THEN** Jort discards the verifier, code, and temporary callback state
- **AND** preserves the previously connected credential and status, if any

### Requirement: OpenRouter credentials are verified and stored only in Keychain
Jort SHALL validate an OAuth-issued credential through OpenRouter's current-key endpoint before storing it as an app-scoped nonsynchronizing Keychain secret and SHALL keep raw credential bytes out of all other persistence and diagnostics.

#### Scenario: OAuth exchange succeeds
- **WHEN** Jort receives a credential from a valid authorization exchange and current-key verification succeeds
- **THEN** Jort stores the credential in Keychain and records only bounded nonsecret connection metadata in Settings
- **AND** never displays the complete credential

#### Scenario: OAuth exchange or verification fails
- **WHEN** OpenRouter rejects the authorization code or issued credential, or returns a malformed response
- **THEN** Jort stores no new credential and presents a bounded actionable connection error
- **AND** preserves any previously working Keychain item

#### Scenario: Credential-bearing data is persisted or logged
- **WHEN** Jort saves Settings, documents, history, recovery material, diagnostics, or application logs
- **THEN** none of those stores contains the credential, authorization code, PKCE verifier, or authorization header
- **AND** persisted connection status contains only bounded nonsecret metadata

### Requirement: Models Settings exposes explicit connection status and actions
Jort SHALL register a Models Settings pane that presents cached OpenRouter connection state and accessible Connect, Check Connection, Replace Connection, Disconnect, and account-management actions appropriate to that state.

#### Scenario: User opens Models Settings
- **WHEN** the Models pane appears
- **THEN** it shows Not Connected, Connecting, Connected with last verification, Unable to Verify, or Connection Needs Attention from local and cached state
- **AND** opening the pane performs no network request

#### Scenario: Connected user checks the connection
- **WHEN** the user activates Check Connection
- **THEN** Jort verifies the current Keychain credential through OpenRouter and updates the cached nonsecret label, expiration when supplied, last-verification time, and bounded status
- **AND** leaves the stored credential unchanged

#### Scenario: Connected user replaces the connection
- **WHEN** the user activates Replace Connection and the new OAuth flow verifies successfully
- **THEN** Jort atomically replaces the prior Keychain credential and connection metadata
- **AND** never leaves a partially written connection visible to runtime consumers

#### Scenario: Connected user disconnects
- **WHEN** the user confirms Disconnect
- **THEN** Jort deletes the local Keychain credential and cached connection metadata
- **AND** explains that remote revocation may still be required and provides access to OpenRouter account key management

#### Scenario: Keyboard or VoiceOver user manages the connection
- **WHEN** a keyboard or accessibility user traverses the Models pane
- **THEN** Jort announces the connection state, last verification, relevant errors, and every available action
- **AND** permits the complete connect, check, replace, disconnect, and account-management flow without pointer-only controls

### Requirement: Model providers initialize lazily behind a bounded interface
Jort SHALL initialize the production model provider only for explicit OpenRouter connection management or execution of a configured model-backed tool and SHALL use a fixed HTTPS OpenRouter origin.

#### Scenario: Jort launches without model activity
- **WHEN** the app starts and the user edits, searches, browses history, runs JavaScript tools, opens Settings, or filters the bundled model catalog
- **THEN** no model provider, OAuth attempt, credential check, or provider network request initializes

#### Scenario: Model-backed tool runs
- **WHEN** the user explicitly submits a configured model-backed invocation with a locally available credential
- **THEN** Jort initializes the provider, reads the Keychain credential, and sends one bounded request to OpenRouter
- **AND** exposes no configurable endpoint or undeclared network destination

#### Scenario: Tests exercise model execution
- **WHEN** provider behavior is tested without network authority
- **THEN** Jort permits dependency injection of a deterministic fake provider through the same bounded request and response interface
- **AND** production code does not require an initialized OpenRouter client

### Requirement: Each model execution is one narrow bounded request
Jort SHALL send one nonstreaming request containing only the captured model identifier, tool instructions, and invocation `content` and SHALL accept only one complete bounded text response or typed failure.

#### Scenario: Provider request is constructed
- **WHEN** the model executor receives a submitted tool generation
- **THEN** its provider request excludes document snapshots, line metadata, history, settings, filesystem references, capture, connectors, JavaScript objects, and application state
- **AND** requests no provider tool calls or streaming response

#### Scenario: Provider returns a valid response
- **WHEN** OpenRouter returns one well-formed response within timeout, transport, token, byte, and line limits
- **THEN** Jort extracts one complete text output for the shared tool publication path
- **AND** performs no document mutation from provider code

#### Scenario: Provider exceeds a limit
- **WHEN** a request times out or a response exceeds a configured transport, token, byte, line, or decoding bound
- **THEN** Jort terminates or invalidates that generation and returns one bounded typed failure
- **AND** publishes no partial output

#### Scenario: Provider attempts unsupported behavior
- **WHEN** a response contains tool calls, multiple unsupported choices, streaming fragments, or malformed content
- **THEN** Jort rejects it as an invocation-local provider failure
- **AND** grants no additional execution authority

### Requirement: Model execution reuses the shared tool lifecycle
Jort SHALL run model-backed tools through the existing tool submission, source-locking, delayed processing, cancellation, error, canonical pending-output, Merge, Dismiss, Undo, persistence, and recovery behavior without a separate agent-run state machine.

#### Scenario: Model request is submitted
- **WHEN** preflight validation succeeds and the shared tool invocation begins model execution
- **THEN** Jort locks exactly the source required by the author-selected input mode and captures one execution generation
- **AND** leaves unrelated document editing, search, history, and JavaScript tools available

#### Scenario: User cancels model execution
- **WHEN** the user activates the existing Cancel action before model completion
- **THEN** Jort cancels or invalidates the provider request and applies the ordinary tool Cancel behavior
- **AND** ignores every late or duplicate provider result

#### Scenario: Model execution succeeds
- **WHEN** a complete bounded response returns for the active generation
- **THEN** Jort publishes it through the existing atomic canonical pending-output transaction
- **AND** exposes the ordinary Merge and Dismiss actions required by the captured output operation

#### Scenario: Ask output is merged
- **WHEN** `/ask` output using `insert-at-invocation` is merged
- **THEN** Jort removes the invocation and retains its complete canonical output according to existing tool semantics

#### Scenario: Rewrite output is merged
- **WHEN** `/rewrite` output using `replace-context` is merged
- **THEN** Jort replaces the exact locked contextual source and invocation with its complete canonical output according to existing tool semantics

#### Scenario: App relaunches during model execution
- **WHEN** Jort restores invocation metadata whose model execution was submitted or processing
- **THEN** it enters the existing interrupted execution error state without making another provider request
- **AND** already published canonical output is never re-requested

### Requirement: Provider failures remain isolated and actionable
Jort SHALL convert authentication, network, transport, decoding, cancellation, timeout, and provider failures into bounded invocation-local state without disabling ordinary editor or JavaScript-tool behavior.

#### Scenario: No local connection exists
- **WHEN** a model-backed invocation is submitted without a Keychain credential
- **THEN** Jort retains editable input and presents a validation warning directing the user to Models Settings
- **AND** performs no source lock, provider initialization, or canonical mutation

#### Scenario: OpenRouter rejects a stored credential during execution
- **WHEN** a provider request returns an authentication failure
- **THEN** Jort enters the existing readable execution-error state and marks cached Models status as Connection Needs Attention
- **AND** does not delete or expose the credential automatically

#### Scenario: Network is unavailable during execution
- **WHEN** a model request cannot reach OpenRouter
- **THEN** Jort enters the existing readable execution-error state with bounded diagnostic text
- **AND** keeps editing, search, history, Settings, and JavaScript tools available

#### Scenario: VoiceOver follows model execution
- **WHEN** a VoiceOver user starts, monitors, cancels, dismisses, or merges a model-backed tool
- **THEN** Jort exposes the same named lifecycle states and actions as an equivalent JavaScript tool
- **AND** does not repeatedly announce progress noise or provider internals
