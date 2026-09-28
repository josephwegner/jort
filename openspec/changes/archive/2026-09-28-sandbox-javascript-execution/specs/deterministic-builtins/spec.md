## ADDED Requirements

### Requirement: Process containment preserves deterministic JavaScript semantics
Jort SHALL preserve the immutable package contract, exact captured input, clock, UUID, cancellation state, fresh runtime, disabled ambient APIs, module restrictions, dynamic-evaluation restriction, and byte/line results when JavaScript validation/execution moves to the disposable worker.

#### Scenario: Existing valid tool executes through containment
- **WHEN** a package that passed the immediately previous in-process implementation runs with the same source, input, clock, UUID, and limits
- **THEN** the worker produces the same complete deterministic output or corresponding bounded script failure
- **AND** process transport introduces no new clock, random, filesystem, network, module, native export, or host-object API

#### Scenario: Tool attempts dynamic or ambient access
- **WHEN** source attempts Date, randomness, import, module loading, eval/function construction after compilation, filesystem, process, or network behavior
- **THEN** the existing JavaScript-level restriction still rejects or withholds it
- **AND** App Sandbox and process limits remain the security boundary if native engine control is compromised

### Requirement: Authoring validation uses the same disposable boundary
Executor-specific JavaScript validation requested by the transactional Settings save SHALL compile/inspect source in a fresh bounded worker and SHALL fail closed on every broker, sandbox, resource, protocol, or validation failure.

#### Scenario: Valid source is saved
- **WHEN** the injected validator receives a structurally valid JavaScript package during the owned single-flight save
- **THEN** it completes one disposable worker validation before package/index publication
- **AND** the validator process is reaped without executing the package's default operation

#### Scenario: Validation infrastructure fails
- **WHEN** the broker is unavailable or the validation worker crashes, times out, violates limits, or returns malformed data
- **THEN** Settings preserves the draft and reports one bounded actionable validation/infrastructure diagnostic
- **AND** publishes no executable generation and never falls back to in-process validation
