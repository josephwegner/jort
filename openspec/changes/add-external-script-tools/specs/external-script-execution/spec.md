## ADDED Requirements

### Requirement: External execution requires local capability approval
Jort SHALL expose external execution only to explicitly opted-in JavaScript tools under a new manifest schema and locally approved tool/script/interpreter/resource/profile bindings. Manifest declarations SHALL NOT confer authority. Approvals SHALL be revocable and bound to captured tool configuration, entry-script content, interpreter identity, runtime-resource trust unit, and network profile; changes SHALL require reapproval.

#### Scenario: A tool requests an unapproved script
- **WHEN** a package declares a script or code calls a selector without a matching current local approval
- **THEN** execution fails with an authorization error before process launch
- **AND** enabling, installing, restoring, or saving the package does not grant approval

#### Scenario: An approved configuration changes or is revoked
- **WHEN** source, manifest, script, interpreter, approved runtime resources, or permission profile changes, or the user revokes approval
- **THEN** queued/new calls are denied until reapproval and active affected runs are cancelled
- **AND** a launched run is not described as having had its external effects undone

### Requirement: Exec is a bounded JSON-in text-out API
During the default execution entry point Jort SHALL provide `jort.exec(path, payload)` returning a promise resolving to frozen `{stdout: string}` after exit zero, complete valid UTF-8 stdout, EOF, and reaping. Jort SHALL reject non-JSON data, cycles, custom serialization behavior, nonfinite numbers, nesting beyond 32, and payloads beyond min(tool input cap, 1 MiB). It SHALL write exactly one serialized JSON value to stdin and close stdin without command interpolation. It SHALL reject failed exits and resource/protocol errors with bounded typed errors, drain/discard stderr under a 64 KiB limit, and enforce stdout byte/line bounds no greater than the tool output bounds and 1 MiB.

#### Scenario: A Python sync script reads captured content
- **WHEN** approved code awaits `jort.exec("~/sync-notes-with-slack.py", {content: input.content})`
- **THEN** the approved script receives the exact serialized content on stdin and the promise resolves only after a complete successful exit
- **AND** stdout is inert text until the JavaScript tool explicitly returns a normal result variant

#### Scenario: Hostile payload or process output is supplied
- **WHEN** payload serialization would execute a getter or custom toJSON, exceed limits, or contain unsupported data, or output is oversized/invalid UTF-8 or the process exits nonzero
- **THEN** Jort rejects the call without partial successful output or automatic retry
- **AND** raw payload, stdout, stderr, and secrets are absent from host diagnostics

### Requirement: Script selectors do not become arbitrary shell commands
Jort SHALL resolve only exact approved absolute or initial-tilde local selectors and SHALL reject relative paths, other-user tilde expansion, URLs, NUL, environment/glob expansion, and shell command strings. Jort SHALL use an explicitly selected interpreter with fixed adapter arguments and no PATH lookup. It SHALL execute the verified immutable entry-script snapshot and enforce approved interpreter/resource identity without launch-time replacement races, denying launch when that identity cannot be guaranteed.

#### Scenario: Note content contains shell metacharacters
- **WHEN** payload content includes quotes, newlines, backticks, or command substitutions
- **THEN** it is delivered only as JSON stdin and cannot modify executable selection or arguments

#### Scenario: Approved script is replaced during dispatch
- **WHEN** a script path, symlink, or interpreter is swapped after approval or during launch
- **THEN** the run either uses the exact approved snapshot and executable or fails closed before receiving input

### Requirement: External code is contained separately from JavaScript and Jort state
Jort SHALL run approved external code under a separate authenticated, signed App-Sandboxed supervisor and disposable inherited-sandbox runner, not the unsandboxed main app or existing JavaScript worker. Jort SHALL grant only approved read-only script/runtime resources, per-run isolated scratch, and optional OS-enforced outbound networking. It SHALL NOT grant broad home/user-file access, writable user-file access, Jort storage/recovery/settings/app resources, Jort Keychain groups, app groups, Apple Events, debugging authority, ambient environment/agent descriptors, or Jort native objects. Unsupported launch/containment configurations SHALL fail closed without an unsandboxed fallback.

#### Scenario: Script attempts to access Jort internals
- **WHEN** signed native probes under each supported runner profile attempt Jort database/WAL/recovery/settings reads or writes, credential retrieval, app IPC impersonation, Apple Events, or process attachment
- **THEN** the OS or authenticated endpoint denies each attempt and the main app remains usable without canonical mutation

#### Scenario: Runtime support cannot be safely established
- **WHEN** a Python/venv/shell layout needs an overbroad grant or the runner cannot install and verify required containment
- **THEN** Jort reports unsupported runtime or containment failure before delivering note input
- **AND** it does not relax the existing JavaScript sandbox or launch an unrestricted child

#### Scenario: Network permission differs
- **WHEN** an approved runner without network permission attempts an outbound connection
- **THEN** the OS denies it
- **AND** a separately approved network-enabled profile can contact external services without gaining Jort data or credential authority

### Requirement: External calls have bounded owned lifecycle
Jort SHALL allow at most one outstanding exec and four total exec calls per invocation, at most two active external runners globally with a bounded cancellable FIFO queue, a shared 25-second external wall budget including queue time, and an overall external-tool deadline no greater than 30 seconds. Each runner SHALL install and verify a maximum 20-second CPU budget, zero core dumps, checked descriptor/process restrictions, and minimal environment/cwd before input delivery. The supervisor SHALL drain pipes concurrently, terminate/escalate/reap on timeout, cancellation, overflow, crash, or revocation, prevent surviving descendants, and produce one terminal outcome. Jort SHALL NOT claim a deterministic whole-process memory ceiling.

#### Scenario: Script hangs or floods either output stream
- **WHEN** a runner exceeds its deadline, CPU budget, stdout/stderr bounds, or attempts a surviving descendant
- **THEN** the run fails, its owned process resources are terminated/reaped, and no partial output is published

#### Scenario: User cancels queued or running work
- **WHEN** an invocation generation is cancelled
- **THEN** queued work is removed without spawning and active work is terminated/reaped
- **AND** late or mismatched replies cannot publish results or cause additional external launches

#### Scenario: Supervisor fails
- **WHEN** the supervising service crashes or its connection is lost
- **THEN** the invocation becomes terminal without retry and the release-tested containment/cleanup mechanism prevents surviving unconstrained work

### Requirement: External effects require explicit execution and are never replayed implicitly
Jort SHALL require explicit user submission for external-capable tools, including zero-argument tools. It SHALL NOT execute scripts during validation, module initialization, preview, completion acceptance, Settings save, document restore, rendering, Merge, Undo/Redo, or automatic retries. After launch, interruption SHALL expose an unknown external outcome rather than promise rollback; explicit reruns SHALL warn about duplicate effects. Model tools SHALL NOT gain exec access.

#### Scenario: A sync times out after sending a Slack request
- **WHEN** a launched script times out before Jort receives a success
- **THEN** Jort reports that external completion is unknown and does not retry automatically
- **AND** Undo or Dismiss does not claim to reverse the Slack request

#### Scenario: A saved invocation or model output is restored
- **WHEN** a document reopens, history restores an invocation, or model output contains an exec expression
- **THEN** no script is launched without a fresh explicit user submission and valid approval

### Requirement: Signed containment evidence blocks release
Jort SHALL keep external execution disabled until release-like signed probes prove supported interpreter compatibility, scoped resource access, prohibited Jort authority, race-resistant launch identity, authenticated/bounded IPC, no surviving descendants, and cleanup under cancellation, overflow, and supervisor failure. It SHALL document supported runtimes and failed/unsupported layouts without substituting development-only signatures for release evidence.

#### Scenario: Containment prototype or release probe fails
- **WHEN** any required denial, identity check, process restriction, or cleanup assertion fails
- **THEN** external execution remains disabled and release validation fails rather than accepting a weaker fallback
