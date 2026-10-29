## MODIFIED Requirements

### Requirement: QuickJS executes only in a disposable inherited-sandbox worker
Jort SHALL route each JavaScript validation or execution through a private independently sandboxed XPC broker that launches and reaps one fresh child process, and SHALL link or load QuickJS only in that child executable.

#### Scenario: JavaScript package is validated or executed
- **WHEN** the injected JavaScript validator or executor accepts one request
- **THEN** the broker launches one worker, verifies its resource-ready handshake, sends one bounded initial frame, receives at most one terminal frame, and reaps it
- **AND** legacy protocol-version-two requests retain single-request/terminal framing while explicitly negotiated exec-capable execution permits only bounded correlated capability request/reply frames before the terminal frame
- **AND** no later package or generation reuses that process or its native runtime state

#### Scenario: Application dependency graph is inspected
- **WHEN** generated and packaged Mach-O dependencies and symbols are recursively audited
- **THEN** QuickJS and the Jort native JavaScript shim occur only in `JortJavaScriptWorker`
- **AND** the app executable, AppKit, Document, Persistence, Settings, Contracts, ordinary Runtime client, model provider, and XPC broker neither link nor load them

#### Scenario: More than four JavaScript runs are ready
- **WHEN** four child workers are active for one application and another generation is admitted
- **THEN** the Runtime coordinator keeps additional permitted work queued and cancellable without spawning another child
- **AND** the broker refuses any request that would exceed its four-child hard admission cap

### Requirement: JavaScript IPC is exact-version, allowlisted, correlated, and bounded
Jort SHALL retain protocol version 2 for legacy contract 2 data with its contract 1 adapter, and SHALL require explicit negotiation of an exact capability-capable protocol for exec. Protocols SHALL contain only fixed primitive fields and bounded arrays, reject unknown/missing/wrong-typed fields and unsupported versions, correlate replies by authenticated peer, 128-bit nonce, invocation ID, and lifecycle generation, and enforce every independent and summed length before application copying or decoding. Capability exchanges SHALL additionally use a unique call identifier and permit at most one terminal tool response. The numeric version of new framing SHALL be selected against current contracts during implementation rather than assumed by this delta.

#### Scenario: Maximum valid request is sent
- **WHEN** a request contains at most a 16 KiB contract, 256 KiB source, min(package byte limit, 1 MiB) input, at most 1 MiB captured metadata (including at most 16 KiB entropy), and 2.5 MiB total payload
- **THEN** both client and broker accept its lengths before copying/decoding and the child accepts its fixed header before allocating payload buffers
- **AND** each layer still validates the decoded semantic bounds

#### Scenario: Maximum valid response is returned
- **WHEN** a worker returns output within min(package byte limit, 1 MiB), min(package line limit, 100,000 lines), and the 1.125 MiB response envelope
- **THEN** the broker and client accept exactly one complete correlated success frame
- **AND** any public error is at most 512 UTF-8 bytes and any private diagnostic is at most 4 KiB without sensitive payload data

#### Scenario: Length or frame is invalid
- **WHEN** any independent length, summed envelope, fixed tag, hash, UTF-8 value, field allowlist, text/report/action/error exclusivity, protocol-specific frame count, trailing data, or declared size is invalid
- **THEN** the receiving layer rejects it before allocating or decoding the declared payload and terminates/abandons the generation
- **AND** returns only a bounded typed protocol or limit failure

#### Scenario: Reply is stale or mismatched
- **WHEN** a reply has a valid shape but its peer identity, protocol, nonce, invocation, generation, or capability call identifier does not match the outstanding request
- **THEN** Jort rejects it without emitting success or document effects
- **AND** invalidates the affected channel when authenticity or protocol integrity is uncertain

#### Scenario: Protocol versions disagree
- **WHEN** client, broker, or worker versions do not agree on the exact frame schema
- **THEN** the request fails before execution with a bounded compatibility error
- **AND** no participant silently downgrades an action result to text or ignores unknown fields

#### Scenario: A negotiated exec request arrives
- **WHEN** an executing worker emits an exec capability frame
- **THEN** the app-side host independently checks JavaScript executor identity, local per-tool permission, explicit submission, default-entry phase, live generation, call ownership, launch configuration, and payload bounds before launch
- **AND** duplicate, unsolicited, excess, initialization-phase, validation-phase, or stale requests cannot launch a process

#### Scenario: A legacy worker emits a capability frame
- **WHEN** a protocol-version-two worker emits an intermediate capability request
- **THEN** Jort rejects the protocol violation without external dispatch

#### Scenario: Existing tools do not use exec
- **WHEN** a legacy tool submits maximum valid captured metadata or returns a typed host action under protocol version two
- **THEN** existing bounds, contract-one adaptation, and inert host-action validation remain unchanged without requiring exec permission

### Requirement: Watchdog, cancellation, and terminal outcomes are process-safe
The broker SHALL own bootstrap and execution wall-clock watchdogs, JavaScript child cancellation and forced termination, pipe closure, exit-status interpretation, and `waitpid` reaping, and SHALL produce exactly one terminal reply for each admitted request. For negotiated exec traffic it SHALL relay only valid bounded correlated capability frames; app-side Runtime SHALL own external subprocess lifecycle as specified by external-script-execution. Broker or worker loss SHALL cancel owned external work without replay.

#### Scenario: Worker succeeds normally
- **WHEN** one complete valid terminal response, expected EOF, and expected exit occur before the deadline, with only permitted capability exchanges preceding that response
- **THEN** the broker reaps the JavaScript child before returning the correlated result
- **AND** closes every request-owned descriptor and timer

#### Scenario: Worker hangs, crashes, or violates protocol
- **WHEN** the child misses bootstrap/execution deadline, exits unexpectedly, stops responding, emits malformed/excess output, sends multiple terminal frames, or emits frames not permitted by the negotiated protocol
- **THEN** the broker closes its channels, terminates and if needed kills the still-owned JavaScript child, confirms reaping, and returns one typed terminal failure
- **AND** later exit, timer, pipe, or XPC events cannot produce another result

#### Scenario: User cancels execution
- **WHEN** the current lifecycle generation requests cancellation before a terminal result
- **THEN** Runtime and broker cancel the request, terminate/reap any active JavaScript child, and reduce one cancellation outcome
- **AND** queued requests are removed without spawning, late replies are ignored, and Runtime cancels owned external calls using direct-child cleanup semantics

#### Scenario: Broker connection fails
- **WHEN** the broker crashes, restarts, becomes unavailable, or the XPC session is interrupted or invalidated
- **THEN** the main client watchdog makes the generation terminal and abandons the channel without retry or replay, and Runtime cancels owned external work
- **AND** any orphaned inherited-sandbox JavaScript child remains constrained by its sandbox and CPU limit while macOS manages memory pressure
- **AND** this JavaScript containment property is not a claim of external-script descendant cleanup or rollback

## ADDED Requirements

### Requirement: Awaited exec does not expand JavaScript worker OS authority
Jort SHALL implement exec through bounded capability messages and promise settlement rather than direct filesystem, network, process, or general native bindings in QuickJS. Existing broker/worker entitlements, disposable-process topology, dependency isolation, CPU/heap/stack limits, and JavaScript denial evidence SHALL remain intact. Script path selectors SHALL be inert message data, not OS authority grants. Native document objects, callbacks, credentials, and handles SHALL remain outside messages. External scripts SHALL run with ordinary user permissions under app-side Runtime ownership, not inside the JavaScript sandbox.

#### Scenario: Promise waits for external completion
- **WHEN** a default-entry promise awaits exec and the QuickJS job queue is empty with a host call outstanding
- **THEN** the worker waits for a bounded correlated completion or cancellation/deadline and settles the promise on its engine-owning thread before resuming jobs
- **AND** host waiting does not reset compute budgets or introduce OS bindings

#### Scenario: A pending promise has no outstanding host operation
- **WHEN** the QuickJS job queue is empty and no host operation can settle the pending promise
- **THEN** the worker does not wait indefinitely or extend its deadline

#### Scenario: Initialization or validation attempts exec
- **WHEN** module evaluation or validation calls exec or forges a capability frame
- **THEN** phase checks reject it without external launch

#### Scenario: External output resembles an action
- **WHEN** an exec reply carries action-looking stdout
- **THEN** the worker settles exec with inert text and no broker or host action dispatch follows automatically
- **AND** only the JavaScript tool's normal returned result enters existing result validation

#### Scenario: Existing JavaScript containment is checked
- **WHEN** existing signed JavaScript denial probes and dependency/entitlement checks run
- **THEN** the JavaScript worker still lacks direct file/network/process/credential authority
- **AND** these checks do not impose a new external-script containment architecture or release gate
