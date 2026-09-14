## ADDED Requirements

### Requirement: QuickJS executes only in a disposable inherited-sandbox worker
Jort SHALL route each JavaScript validation or execution through a private independently sandboxed XPC broker that launches and reaps one fresh child process, and SHALL link or load QuickJS only in that child executable.

#### Scenario: JavaScript package is validated or executed
- **WHEN** the injected JavaScript validator or executor accepts one request
- **THEN** the broker launches one worker, verifies its resource-ready handshake, sends one bounded frame, receives at most one terminal frame, and reaps it
- **AND** no later package or generation reuses that process or its native runtime state

#### Scenario: Application dependency graph is inspected
- **WHEN** generated and packaged Mach-O dependencies and symbols are recursively audited
- **THEN** QuickJS and the Jort native JavaScript shim occur only in `JortJavaScriptWorker`
- **AND** the app executable, AppKit, Document, Persistence, Settings, Contracts, ordinary Runtime client, model provider, and XPC broker neither link nor load them

#### Scenario: More than four JavaScript runs are ready
- **WHEN** four child workers are active for one application and another generation is admitted
- **THEN** the Runtime coordinator keeps additional permitted work queued and cancellable without spawning another child
- **AND** the broker refuses any request that would exceed its four-child hard admission cap

### Requirement: Worker authority is denied by sandbox and message design
The broker SHALL have App Sandbox and Hardened Runtime with no network, arbitrary user-file, file-selection, app-group, Keychain access-group, Apple Events, device, or temporary-exception entitlement, and the worker SHALL have Hardened Runtime and inherit only that static sandbox while receiving no ambient authority-bearing value.

#### Scenario: Worker attempts prohibited authority
- **WHEN** a signed native containment probe under the worker sandbox attempts representative user-file access, network client/server access, Jort credential lookup, Apple Events, protected device access, or subprocess creation
- **THEN** macOS denies each operation or the worker's process limit prevents it
- **AND** the broker/main process remains usable and records no source, input, output, or credential in diagnostics

#### Scenario: Worker request is constructed
- **WHEN** one immutable JavaScript package is prepared for execution
- **THEN** the request contains only its normalized manifest/contract, source, exact input, captured clock/UUID, generation/correlation identity, and declared bounds
- **AND** contains no document snapshot, settings store, credential, provider, filesystem path, URL, bookmark, native object, or callback capability

#### Scenario: Entitlements are inspected
- **WHEN** the built broker and worker signatures are decoded
- **THEN** the broker has only its approved minimal sandbox/hardening entitlements and the worker's App Sandbox keys are exactly app-sandbox plus inherit
- **AND** their stable code identifiers and expected signer relationship differ from one another and match the checked target manifest

### Requirement: JavaScript IPC is exact-version, allowlisted, correlated, and bounded
Jort SHALL use protocol version 1 with only fixed primitive fields, SHALL reject unknown/missing/wrong-typed fields and unsupported versions, SHALL correlate replies by authenticated peer, 128-bit nonce, invocation ID, and lifecycle generation, and SHALL enforce every independent and summed length before application copying or decoding.

#### Scenario: Maximum valid request is sent
- **WHEN** a request contains at most a 16 KiB contract, 256 KiB source, min(package byte limit, 1 MiB) input, 4 KiB metadata, and 1.5 MiB total payload
- **THEN** both client and broker accept its lengths before copying/decoding and the child accepts its fixed header before allocating payload buffers
- **AND** each layer still validates the decoded semantic bounds

#### Scenario: Maximum valid response is returned
- **WHEN** a worker returns output within min(package byte limit, 1 MiB), min(package line limit, 100,000 lines), and the 1.125 MiB response envelope
- **THEN** the broker and client accept exactly one complete correlated success frame
- **AND** any public error is at most 512 UTF-8 bytes and any private diagnostic is at most 4 KiB without sensitive payload data

#### Scenario: Length or frame is invalid
- **WHEN** any independent length, summed envelope, fixed tag, hash, UTF-8 value, field allowlist, output/error exclusivity, frame count, trailing data, or declared size is invalid
- **THEN** the receiving layer rejects it before allocating or decoding the declared payload and terminates/abandons the generation
- **AND** returns only a bounded typed protocol or limit failure

#### Scenario: Reply is stale or mismatched
- **WHEN** a reply has a valid shape but its peer identity, protocol, nonce, invocation, or generation does not match the outstanding request
- **THEN** Jort rejects it without emitting success or document effects
- **AND** invalidates the affected channel when authenticity or protocol integrity is uncertain

### Requirement: Hard OS limits precede untrusted source delivery
The worker SHALL lower and verify a 256 MiB `RLIMIT_AS`, a deadline-derived `RLIMIT_CPU` no greater than 31 hard seconds, zero core/file-size/additional-process limits, and a checked minimal file-descriptor limit before announcing Ready or receiving source, and SHALL additionally preserve the 16 MiB QuickJS heap, 512 KiB engine stack, maximum 30-second deadline, cancellation, API, byte, and line limits.

#### Scenario: Worker cannot install a required limit
- **WHEN** any hard or soft limit cannot be lowered to and read back at the approved value
- **THEN** the worker never announces Ready and the broker sends it no source or input
- **AND** the request ends as a bounded sandbox-bootstrap failure

#### Scenario: Native allocation bypasses QuickJS heap accounting
- **WHEN** a test worker attempts native allocation beyond the address-space ceiling without using QuickJS allocation hooks
- **THEN** the OS refuses allocation or terminates that disposable process within the watchdog
- **AND** the main process survives and accepts no partial result

#### Scenario: Native CPU loop bypasses QuickJS interruption
- **WHEN** a test worker burns CPU without calling the QuickJS interrupt handler
- **THEN** `RLIMIT_CPU` signals or kills the disposable process no later than its hard limit
- **AND** the broker reaps it and returns one typed CPU-resource failure

#### Scenario: Script reaches an engine-level limit first
- **WHEN** ordinary JavaScript exceeds its heap, stack, deadline, cancellation, output-byte, or output-line limit before an OS limit
- **THEN** the worker returns or terminates with the corresponding bounded failure
- **AND** the outer OS limits remain installed as defense against native-engine failure

### Requirement: Watchdog, cancellation, and terminal outcomes are process-safe
The broker SHALL own bootstrap and execution wall-clock watchdogs, child cancellation and forced termination, pipe closure, exit-status interpretation, and `waitpid` reaping, and SHALL produce exactly one terminal reply for each admitted request.

#### Scenario: Worker succeeds normally
- **WHEN** one complete valid response, expected EOF, and expected exit occur before the deadline
- **THEN** the broker reaps the child before returning the correlated result
- **AND** closes every request-owned descriptor and timer

#### Scenario: Worker hangs, crashes, or violates protocol
- **WHEN** the child misses bootstrap/execution deadline, exits unexpectedly, stops responding, emits malformed/excess output, or sends more than one frame
- **THEN** the broker closes its channels, terminates and if needed kills the still-owned child, confirms reaping, and returns one typed terminal failure
- **AND** later exit, timer, pipe, or XPC events cannot produce another result

#### Scenario: User cancels execution
- **WHEN** the current lifecycle generation requests cancellation before a terminal result
- **THEN** Runtime and broker cancel the request, terminate/reap any active child, and reduce one cancellation outcome
- **AND** a queued request is removed without spawning and any late reply is ignored

#### Scenario: Broker connection fails
- **WHEN** the broker crashes, restarts, becomes unavailable, or the XPC session is interrupted or invalidated
- **THEN** the main client watchdog makes the generation terminal and abandons the channel
- **AND** the main app remains responsive while any orphaned inherited-sandbox child remains constrained by its hard limits

### Requirement: Containment evidence and QuickJS provenance are release-blocking
Jort SHALL verify dependency isolation, runtime mapping, nested signatures/entitlements, sandbox denials, hard resource limits, watchdog recovery, bounded protocol rejection, and lifecycle nonmutation, and SHALL maintain a reproducible vendored-QuickJS provenance and security-review record.

#### Scenario: Containment verification suite runs
- **WHEN** signed test/package fixtures exercise normal, denial, crash, hang, native CPU/memory, malformed, oversized, cancellation, and late-reply cases
- **THEN** every case proves process cleanup, bounded failure, responsive main application, and absence of unauthorized canonical mutation
- **AND** a missing signature/entitlement, prohibited dependency, or ineffective OS limit fails the release gate

#### Scenario: QuickJS record is audited
- **WHEN** Jort prepares a release or 90 days have elapsed since the last dependency review
- **THEN** the record verifies upstream archive URL/version/SHA-256, imported files, license, reproducible import, exact local patch, vulnerability review, and analyzer baseline/delta
- **AND** no changed diagnostic or dependency version is accepted by silently refreshing a baseline

#### Scenario: Community package support is considered
- **WHEN** public or downloaded tool-package import would be enabled
- **THEN** product gating requires this containment suite and the signed release/notarization change to be implemented and verified
- **AND** neither JavaScript API narrowing nor an unsigned local build satisfies that gate alone
