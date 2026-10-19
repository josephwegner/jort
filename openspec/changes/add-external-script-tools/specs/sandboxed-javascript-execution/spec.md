## MODIFIED Requirements

### Requirement: QuickJS executes only in a disposable inherited-sandbox worker
Jort SHALL route each JavaScript validation or execution through a private independently sandboxed XPC broker that launches and reaps one fresh child process, and SHALL link or load QuickJS only in that child executable.

#### Scenario: JavaScript package is validated or executed
- **WHEN** the injected JavaScript validator or executor accepts one request
- **THEN** the broker launches one worker, verifies its resource-ready handshake, sends one bounded initial frame, receives exactly one terminal frame on success, and reaps it
- **AND** existing protocol-version-two tools retain one-request/one-terminal framing while explicitly negotiated version-three execution permits only bounded correlated capability request/reply frames before that terminal frame
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
Jort SHALL retain protocol version 2 for contract 2 data with its contract 1 adapter and use explicitly negotiated version 3 only for opted-in external-capable tools. Both versions SHALL contain only fixed primitive fields and bounded arrays, reject unknown/missing/wrong-typed fields and unsupported versions, correlate replies by authenticated peer, 128-bit nonce, invocation ID, and lifecycle generation, and enforce every independent and summed length before application copying or decoding. Version 3 SHALL additionally correlate each bounded external capability exchange by unique call sequence and permit exactly one final tool response.

#### Scenario: Maximum valid request is sent
- **WHEN** a request contains at most a 16 KiB contract, 256 KiB source, min(package byte limit, 1 MiB) input, at most 1 MiB captured metadata (including at most 16 KiB entropy), and 2.5 MiB total payload
- **THEN** both client and broker accept its lengths before copying/decoding and the child accepts its fixed header before allocating payload buffers
- **AND** each layer still validates the decoded semantic bounds

#### Scenario: Maximum valid response is returned
- **WHEN** a worker returns output within min(package byte limit, 1 MiB), min(package line limit, 100,000 lines), and the 1.125 MiB response envelope
- **THEN** the broker and client accept exactly one complete correlated success frame
- **AND** any public error is at most 512 UTF-8 bytes and any private diagnostic is at most 4 KiB without sensitive payload data

#### Scenario: Length or frame is invalid
- **WHEN** any independent length, summed envelope, fixed tag, hash, UTF-8 value, field allowlist, text/report/action/error exclusivity, frame count, trailing data, or declared size is invalid
- **THEN** the receiving layer rejects it before allocating or decoding the declared payload and terminates/abandons the generation
- **AND** returns only a bounded typed protocol or limit failure

#### Scenario: Reply is stale or mismatched
- **WHEN** a reply has a valid shape but its peer identity, protocol, nonce, invocation, generation, or external call sequence does not match the outstanding request
- **THEN** Jort rejects it without emitting success or document effects
- **AND** invalidates the affected channel when authenticity or protocol integrity is uncertain

#### Scenario: Version three capability exchange is attempted
- **WHEN** an opted-in executing worker emits an exec request
- **THEN** the host independently checks phase, exact declared selector, current local approval, generation, call count, and payload bounds before dispatching it to a separate external supervisor
- **AND** duplicate, unsolicited, out-of-order, validation-phase, or initialization-phase calls cannot launch a process

#### Scenario: Legacy worker emits a capability frame
- **WHEN** a protocol-version-two worker emits any intermediate capability request
- **THEN** the receiver rejects the protocol violation without dispatching an external effect

#### Scenario: Protocol versions disagree
- **WHEN** client, broker, or worker versions do not agree on the exact frame schema
- **THEN** the request fails before execution with a bounded compatibility error
- **AND** no participant silently downgrades an action result to text or ignores unknown fields

#### Scenario: Existing contract-two tools do not opt into exec
- **WHEN** an existing tool submits maximum valid captured metadata or returns a typed host action under protocol version two
- **THEN** its request and result retain the existing bounds, contract-one adapter compatibility, and inert host-action validation semantics without requiring exec approval

## ADDED Requirements

### Requirement: Async exec does not expand JavaScript worker OS authority
Jort SHALL implement exec as a bounded version-three message exchange and promise settlement, not as a filesystem, network, process, general native bridge, or authority-bearing resource grant to QuickJS. The existing JavaScript broker and worker entitlements, disposable-process topology, QuickJS dependency isolation, CPU/heap/stack limits, and existing protocol-version-two/contract-one-adapter behavior SHALL remain intact. Host resource paths/bookmarks/handles and native application objects SHALL remain outside worker messages; a script selector SHALL be treated only as inert text for host-side approved-binding lookup.

#### Scenario: Promise waits for external completion
- **WHEN** an executing tool awaits an approved exec and the local QuickJS job queue is empty
- **THEN** the worker waits only for a bounded correlated host completion or terminal cancellation/deadline and then settles the promise through the engine job loop
- **AND** it does not refresh its CPU budget, load native OS bindings, or receive the external runner's filesystem/network authority

#### Scenario: A compromised worker forges authority
- **WHEN** a worker emits an undeclared selector, forged approval, excess request, or wrong-generation frame
- **THEN** the independent host policy router rejects it before launch
- **AND** existing signed JavaScript containment probes continue proving denied file/network/process/credential authority
