## ADDED Requirements

### Requirement: Tool execution modules have enforced one-way dependencies
Jort SHALL define a Foundation-only tool-contract boundary, SHALL keep package and preference persistence independent of concrete runtimes, and SHALL compose concrete runtime, provider, persistence, and AppKit services only at the application boundary.

#### Scenario: Module dependencies are audited
- **WHEN** the generated project and source imports are checked
- **THEN** `JortToolContracts` imports none of AppKit, SQLite, Security, networking implementations, or QuickJS
- **AND** `JortSettings` imports neither `JortToolRuntime` nor `JortJavaScript`
- **AND** AppKit imports neither QuickJS nor a concrete model transport

#### Scenario: Settings is opened without running a tool
- **WHEN** Jort constructs and displays configuration or package-management UI without submitting an invocation
- **THEN** Settings can load and publish its snapshots without initializing QuickJS or a model-provider transport
- **AND** concrete execution services remain lazy until an operation requires them

#### Scenario: Application composes execution services
- **WHEN** the application creates an editor workspace capable of invoking tools
- **THEN** it injects bounded catalog, validator, executor, credential, and provider interfaces into their consumers
- **AND** no consumer resolves those services through mutable global state or a service locator

### Requirement: Tool contracts are bounded and platform-independent
Jort SHALL represent package identity, manifests, immutable executable packages, execution requests, results, failures, cancellation identity, and lifecycle actions as bounded `Sendable` values that do not expose native views, mutable documents, persistence stores, credentials, filesystem paths, or provider transports.

#### Scenario: Invocation is submitted
- **WHEN** a validated package and exact input are captured for execution
- **THEN** the request contains only the package contract, generation, exact bounded input, captured deterministic facilities, and declared limits required for that run
- **AND** it contains no AppKit object, mutable editor state, settings store, Keychain value, or registry reference

#### Scenario: Runtime completes
- **WHEN** a concrete executor finishes validation or execution
- **THEN** it returns either one complete bounded success value or one typed bounded failure
- **AND** presentation code does not parse implementation-specific native or provider errors to decide lifecycle behavior

#### Scenario: Package changes during execution
- **WHEN** the catalog publishes a different generation or version after a run is submitted
- **THEN** the submitted run retains its immutable captured execution contract
- **AND** the new catalog state applies only to future submission or explicit package reconciliation

### Requirement: Persisted invocation ownership remains document-safe and acyclic
JortDocument SHALL own anchored invocation ranges, validation against document snapshots, range remapping, and canonical invocation transactions while using tool-contract values without creating a dependency from Contracts back to Document.

#### Scenario: Existing document is decoded after extraction
- **WHEN** Jort opens a document containing invocation metadata written by the immediately previous application version
- **THEN** it preserves the encoded fields, raw values, defaults, anchors, hashes, restoration data, and sanitization behavior
- **AND** projects the valid record into the extracted lifecycle contract without changing canonical text

#### Scenario: Lifecycle requests a canonical mutation
- **WHEN** the reducer emits a publish, Merge, Dismiss, or restoration effect
- **THEN** JortDocument validates and applies that effect through one existing typed transaction boundary
- **AND** Runtime and AppKit do not become alternative owners of canonical document state

#### Scenario: Document transaction rejects an effect
- **WHEN** an anchor, hash, revision, generation, or other document invariant is stale
- **THEN** the mutation is rejected without partial canonical change
- **AND** the rejection returns to the lifecycle coordinator as a typed action for deterministic reconciliation

### Requirement: Invocation lifecycle decisions are pure and headless
Jort SHALL define invocation lifecycle state, actions, and effects outside AppKit and SHALL derive each legal transition through a deterministic reducer whose asynchronous generations have exactly one winning terminal outcome.

#### Scenario: Lifecycle transition is reduced
- **WHEN** the reducer receives the same bounded state and action
- **THEN** it produces the same next state and ordered effects without accessing UI, document storage, clocks, network, filesystem, or native runtimes
- **AND** each effect declares the external acknowledgement required before a dependent transition

#### Scenario: Cancellation races with completion
- **WHEN** cancellation, timeout, failure, and success actions arrive for one submitted generation
- **THEN** the first legal terminal action determines the lifecycle outcome
- **AND** the reducer ignores every stale, late, or duplicate action without emitting document mutation

#### Scenario: AppKit translates a native event
- **WHEN** completion acceptance, Submit, Cancel, Merge, Dismiss, focus, or selection input originates in AppKit
- **THEN** AppKit converts it into a bounded lifecycle action or document fact
- **AND** presents the committed reducer/document projection without directly choosing an authoritative phase transition

### Requirement: Executor-specific validation is injected and fail-closed
Settings and package storage SHALL perform structural validation without a concrete runtime dependency and SHALL request executor-specific source validation through an injected bounded validator whose absence or failure cannot make unvalidated code executable.

#### Scenario: Tool draft requires JavaScript validation
- **WHEN** the single-flight tool save reaches executor-specific validation
- **THEN** Settings awaits the injected validator as part of that exact save operation
- **AND** publishes no package generation or catalog revision until validation succeeds

#### Scenario: Runtime validator is unavailable
- **WHEN** an executor-specific validator cannot be constructed or returns an infrastructure failure
- **THEN** authoring reports one bounded actionable diagnostic and keeps the draft intact
- **AND** the candidate package does not become executable

#### Scenario: Tests inject a validator
- **WHEN** package persistence or authoring behavior is tested without loading a native engine
- **THEN** the test can inject a deterministic validator through the same production contract
- **AND** Settings does not require QuickJS linkage or initialization

### Requirement: Domain lifecycle behavior is verified without AppKit
Jort SHALL run contract, reducer, execution dispatch, provider mapping, package reconciliation, and generation-race tests without creating an AppKit application, window, or text view, while retaining native tests for platform integration.

#### Scenario: Headless lifecycle suite runs
- **WHEN** the non-AppKit test target executes lifecycle transition matrices and fake-executor results
- **THEN** it verifies validation, submission, cancellation, failure, publication intent, Merge/Dismiss intent, and stale-generation handling
- **AND** does not initialize `NSApplication`, `NSWindow`, or `NSTextView`

#### Scenario: Native integration suite runs
- **WHEN** AppKit integration tests execute
- **THEN** they verify selection, marked text, focus, accessibility, locked ranges, viewport behavior, presentation, and document transaction integration
- **AND** do not duplicate the complete headless transition matrix
