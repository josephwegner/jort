## MODIFIED Requirements

### Requirement: Model execution is composed behind the shared runtime boundary
Jort SHALL construct provider-specific model implementations lazily outside Settings and AppKit, route each captured catalog model to its declared backend, supply credentials through a narrow injected interface only for providers that require them, and map provider behavior into the shared bounded execution and lifecycle contracts.

#### Scenario: Jort launches with configured model tools
- **WHEN** settings and the tool catalog load without a model invocation or explicit connection/download action
- **THEN** no provider HTTP transport, local inference session, or credential lookup initializes
- **AND** configured model tools remain discoverable according to their existing readiness behavior

#### Scenario: Model tool executes
- **WHEN** the shared coordinator dispatches a validated model execution request
- **THEN** Runtime lazily obtains the captured model's declared provider and only the credentials that provider requires, passing only the request's exact bounded content and declared instructions
- **AND** Settings and AppKit receive only typed readiness, connection, result, and failure values rather than transport objects, MLX objects, or credential bytes

#### Scenario: Provider reports a failure
- **WHEN** authentication, connectivity, timeout, cancellation, malformed response, response-limit, local installation, capability, or resource failure occurs
- **THEN** Runtime maps it to an actionable bounded failure before returning it to the lifecycle
- **AND** the provider implementation does not directly mutate invocation UI or canonical document state

### Requirement: Model providers initialize lazily behind a bounded interface
Jort SHALL initialize model execution only for an explicit configured model-backed invocation, SHALL initialize OpenRouter connection management only on explicit connection actions, and SHALL retain a fixed HTTPS OpenRouter origin for cloud requests. Explicit local asset downloads SHALL be separate from inference initialization.

#### Scenario: Jort launches without model activity
- **WHEN** the app starts and the user edits, searches, browses history, runs JavaScript tools, opens Settings, or filters the bundled model catalog
- **THEN** no model provider, local model load, asset download, OAuth attempt, credential check, or provider network request initializes

#### Scenario: Cloud model-backed tool runs
- **WHEN** the user explicitly submits a configured cloud model-backed invocation with a locally available credential
- **THEN** Jort initializes the cloud provider, reads the Keychain credential, and sends one bounded request to OpenRouter
- **AND** exposes no configurable endpoint or undeclared network destination

#### Scenario: Local model-backed tool runs
- **WHEN** the user explicitly submits a configured local model-backed invocation with ready verified assets on supported hardware
- **THEN** Jort initializes a cold local execution session without cloud credentials or network access
- **AND** releases that session's model resources after its terminal state

#### Scenario: Tests exercise model execution
- **WHEN** provider behavior is tested without network authority or model assets
- **THEN** Jort permits dependency injection of deterministic fake providers through the same bounded request and response interface
- **AND** production composition does not require an initialized OpenRouter client or loaded local model

### Requirement: Each model execution is one narrow bounded request
Jort SHALL execute one bounded logical request containing only the captured model identifier, tool instructions, and invocation input and SHALL accept only one complete bounded text response or typed failure. Cloud transport SHALL remain nonstreaming; internal local token iteration SHALL never publish partial output.

#### Scenario: Provider request is constructed
- **WHEN** the model executor receives a submitted tool generation
- **THEN** its provider request excludes document snapshots, line metadata, history, settings, filesystem references, capture, connectors, JavaScript objects, and application state
- **AND** requests no provider tool calls or streaming cloud response

#### Scenario: Provider returns a valid response
- **WHEN** the selected provider returns one well-formed complete response within its deadline and token, byte, line, context, transport, and decoding bounds as applicable
- **THEN** Jort extracts one complete text output for the shared tool publication path
- **AND** performs no document mutation from provider code

#### Scenario: Provider exceeds a limit
- **WHEN** a request times out or input/output exceeds a configured context, token, byte, line, transport, or decoding bound
- **THEN** Jort terminates or invalidates that generation and returns one bounded typed failure
- **AND** publishes no partial output

#### Scenario: Provider attempts unsupported behavior
- **WHEN** a response contains tool calls, multiple unsupported choices, unexpected cloud streaming fragments, or malformed content
- **THEN** Jort rejects it as an invocation-local provider failure
- **AND** grants no additional execution authority

### Requirement: Provider failures remain isolated and actionable
Jort SHALL convert authentication, network, transport, decoding, cancellation, timeout, local capability/installation/resource, and provider failures into bounded invocation-local state without disabling ordinary editor or JavaScript-tool behavior. Provider readiness and failures SHALL remain independent across local and cloud backends.

#### Scenario: No local connection exists for a cloud model
- **WHEN** a cloud model-backed invocation is submitted without a Keychain credential
- **THEN** Jort retains editable input and presents a validation warning directing the user to Models Settings
- **AND** performs no source lock, provider initialization, or canonical mutation

#### Scenario: OpenRouter rejects a stored credential during execution
- **WHEN** a cloud provider request returns an authentication failure
- **THEN** Jort enters the existing readable execution-error state and marks cached OpenRouter status as Connection Needs Attention
- **AND** does not delete or expose the credential automatically or mark an installed local model unavailable

#### Scenario: Network is unavailable during cloud execution
- **WHEN** a cloud model request cannot reach OpenRouter
- **THEN** Jort enters the existing readable execution-error state with bounded diagnostic text
- **AND** keeps local inference, editing, search, history, Settings, and JavaScript tools available

#### Scenario: Local readiness fails before execution
- **WHEN** a local invocation lacks supported capability or verified installed assets
- **THEN** Jort retains editable input and presents a local Models Settings warning without source locking or loading the model
- **AND** neither requests cloud credentials nor falls back to a cloud provider

#### Scenario: Local inference fails after submission
- **WHEN** a local load or generation fails, expires, or encounters corrupt assets or insufficient resources
- **THEN** Jort applies the ordinary bounded execution-error behavior and completes local resource cleanup
- **AND** leaves cloud credential state unchanged and does not retry the input through another provider

#### Scenario: VoiceOver follows model execution
- **WHEN** a VoiceOver user starts, monitors, cancels, dismisses, or merges a model-backed tool
- **THEN** Jort exposes the same named lifecycle states and actions as an equivalent JavaScript tool
- **AND** does not repeatedly announce progress noise or provider internals

### Requirement: Model authority never enters JavaScript containment
Jort SHALL keep credential lookup, cloud HTTP transport, local asset management, MLX loading/generation, model request construction, and provider response handling in the separately composed model Runtime path and SHALL send none of those capabilities or values to the JavaScript broker or worker.

#### Scenario: Model tool executes while JavaScript containment is installed
- **WHEN** the shared lifecycle dispatches a model-backed package
- **THEN** Runtime uses the selected lazy model provider and bounded model request directly without spawning a JavaScript worker
- **AND** returns its result through the same high-level contract and reducer actions

#### Scenario: JavaScript worker is compromised
- **WHEN** native code in the disposable worker attempts to discover model state or credentials
- **THEN** it has no credential value, provider/MLX object, local-model-directory authority, Keychain access group, settings path, or network entitlement
- **AND** local model execution and cached connection/readiness state remain outside the worker process
