## ADDED Requirements

### Requirement: External execution requires one local per-tool permission
Jort SHALL require the local per-tool toggle “Allow this tool to execute local scripts” and explicit user submission before dispatching an external call. Permission SHALL default to denied when no local permission exists and SHALL be independent of package declarations and document content. Importing, saving, enabling, or restoring a package SHALL NOT grant permission. Jort SHALL NOT require per-script approvals, script allowlists, authorization hashes, reapproval on tool/script/interpreter/dependency edits, or separate network permission.

#### Scenario: Invocation does not replace permission
- **WHEN** a user explicitly submits a JavaScript tool whose local toggle is off
- **THEN** exec fails with a bounded authorization error before process launch
- **AND** package metadata and prior import/save/enable/restore operations cannot supply permission

#### Scenario: Scripts change under an enabled toggle
- **WHEN** a permitted tool or its scripts, interpreter, or dependencies change
- **THEN** those edits do not require reapproval or create per-script authorization checks
- **AND** normal package validation and execution-phase checks still apply

#### Scenario: Permission is revoked
- **WHEN** the user turns off a tool's local toggle
- **THEN** Jort denies new calls, removes queued affected calls without spawning, and cancels active affected invocations
- **AND** cancellation after launch does not claim to undo external effects

### Requirement: Exec is bounded JSON-in and inert text-out
During explicitly submitted JavaScript default-entry execution, Jort SHALL provide `jort.exec(path, payload)` returning a promise resolving to frozen `{stdout: string}` only after exit zero, complete valid bounded UTF-8 stdout, and direct-child reaping. Jort SHALL serialize one bounded JSON value to stdin and close stdin. It SHALL reject unsupported values, cycles, excessive nesting, unsafe custom serialization/accessor behavior, and size violations without dispatch. Jort SHALL enforce finite input, stdout byte/line, and stderr limits, drain stderr concurrently, and reject launch, exit, timeout, encoding, limit, and channel failures with bounded typed errors rather than partial successful output. Raw payload/stdout/stderr and secrets SHALL NOT be persisted in diagnostics or automatically surfaced as errors.

#### Scenario: A Python script processes captured input
- **WHEN** a permitted JavaScript tool awaits `jort.exec("~/scripts/sync-notes.py", {content: input.content})`
- **THEN** the script receives one serialized JSON value on stdin and successful complete stdout returns to JavaScript as text
- **AND** the calling tool owns any subsequent parsing and normal result construction

#### Scenario: Stdout resembles a Jort action
- **WHEN** a script prints JSON or text resembling a Jort action request
- **THEN** Jort returns it only as the exec result's stdout string without dispatching an action
- **AND** only an intentional normal JavaScript result enters existing result handling and independent action validation

#### Scenario: Payload or output violates the contract
- **WHEN** payload capture would execute custom serialization/accessors or exceed supported JSON limits, or output is oversized/invalid UTF-8, or the child exits nonzero
- **THEN** Jort rejects the call without partial successful output or automatic retry
- **AND** invalid payload is rejected before launch

### Requirement: Executable discovery is predictable without mandatory setup
Jort SHALL resolve default `python3` for Python scripts through `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` in that order and launch the resolved executable directly with fixed arguments and the script path as a separate argument. It SHALL support an optional locally configured absolute interpreter override for a specific installation or venv without requiring profiles or interpreter registration. It SHALL NOT obtain interpreter configuration from note content, parse arbitrary shell command strings, interpolate payload into arguments, discover PATH through shell startup files, open Terminal.app, or bundle/manage Python. Missing or unusable Python SHALL produce an actionable bounded error rather than automatic installation or shell discovery.

#### Scenario: Default Python is installed in a common location
- **WHEN** a Python script is invoked without an interpreter override and an executable python3 is found in the documented search path
- **THEN** Jort launches the first matching executable without mandatory interpreter setup or a visible terminal

#### Scenario: A particular venv is selected
- **WHEN** a local absolute interpreter override identifies a venv's Python
- **THEN** Jort invokes that interpreter directly without activation or a login shell

#### Scenario: Python cannot be launched
- **WHEN** no usable default Python is found or the configured interpreter cannot launch
- **THEN** Jort reports how to install Python or select an explicit interpreter path
- **AND** it does not install Python or execute shell startup configuration

### Requirement: Script paths and launch context are explicit data
Jort SHALL accept absolute script paths and leading `~/` expansion for the current user, reject relative paths, other-user tilde syntax, URLs and NUL, and perform no glob or environment-variable expansion. It SHALL use the script's containing directory as cwd and provide the documented PATH and ordinary home, temporary-directory, and locale context without blindly forwarding the entire app environment. It SHALL NOT inject Jort provider credentials, document handles, or internal connections. Jort SHALL launch the current script without immutable authorization snapshots or race-resistant interpreter identity guarantees. A case-insensitive `.py` suffix SHALL select the default or locally overridden Python interpreter as a convenience, without requiring executable permission on the script. Other paths SHALL identify executable regular files and SHALL launch directly with no extra arguments, including native binaries and shebang-bearing scripts for Node or other interpreters. Jort SHALL NOT require a shebang on native binaries, infer an interpreter from other extensions, or fall back to a shell for unsupported executable formats. The optional local Python interpreter setting SHALL affect only Python dispatch.

#### Scenario: An executable Node script is invoked
- **WHEN** a permitted tool invokes an executable script with `#!/usr/bin/env node` or an absolute Node interpreter shebang
- **THEN** Jort launches the script directly and the OS selects its interpreter
- **AND** env-based discovery uses the documented child PATH without shell startup files or automatic version-manager activation

#### Scenario: A native executable is invoked
- **WHEN** a permitted tool invokes a native executable regular file
- **THEN** Jort launches it directly without requiring a shebang or Python
- **AND** the same bounded JSON-stdin, inert-stdout, permission, and lifecycle contracts apply

#### Scenario: A non-Python file is not executable or has an unsupported format
- **WHEN** a non-Python path lacks executable permission or cannot be launched by the OS
- **THEN** Jort returns a bounded launch-policy or launch failure
- **AND** it does not infer Node from `.js`, invoke a shell fallback, or retry

#### Scenario: Payload contains shell syntax
- **WHEN** payload contains quotes, backticks, newlines, or command substitutions
- **THEN** it is delivered as JSON stdin and cannot change executable selection or arguments

#### Scenario: Script files are edited or missing
- **WHEN** a script changes before dispatch or its path no longer exists
- **THEN** Jort uses the current file or reports a bounded launch failure
- **AND** it does not compare approval hashes or require script reapproval

### Requirement: Scripts use ordinary user permissions without a document bridge
Jort SHALL treat external scripts as trusted local automation with ordinary user permissions, not as OS-contained code. It SHALL permit ordinary filesystem/network use, launching other programs, and indirect OS automation subject to platform permissions. Jort SHALL NOT claim scripts cannot access its database or app files. Jort SHALL supply no document API, native document objects, editor callbacks, or action-dispatch endpoint. The existing QuickJS worker/broker sandbox SHALL retain its OS authority restrictions.

#### Scenario: Script performs local automation
- **WHEN** a permitted script accesses user files, contacts a service, or launches another program
- **THEN** those operations use ordinary user permissions without Jort resource grants or separate network permission
- **AND** this is not presented as isolation from Jort state

#### Scenario: Script needs to return a document result
- **WHEN** a script finishes with stdout
- **THEN** it has no supplied document callback or action endpoint and its text returns to the calling JavaScript tool
- **AND** document changes occur only through the tool's normal result handling

### Requirement: External calls have bounded direct-child lifecycle
Jort SHALL bound input/output, outstanding and total calls, global admission/queueing, external timeout, and overall invocation duration. It SHALL allow at most one outstanding exec per invocation initially, write stdin and drain stdout/stderr concurrently, and preserve JavaScript compute limits across host waiting. On timeout, cancellation, overflow, permission revocation, or channel loss, it SHALL stop input, close owned endpoints as appropriate, request direct-child termination, escalate after a bounded grace period, and reap the direct child. Queued cancellation SHALL prevent launch. Jort SHALL accept only one terminal outcome and reject stale completions and additional dispatch for terminal generations. It SHALL NOT require arbitrary descendant cleanup or claim a deterministic whole-process memory ceiling. Numeric bounds SHALL be documented and tested during implementation.

#### Scenario: Script hangs or floods a pipe
- **WHEN** a child exceeds time or output limits, including while writing before consuming stdin
- **THEN** concurrent stream handling prevents pipe deadlock and the bounded failure path terminates/escalates and reaps the direct child
- **AND** no partial successful output is published

#### Scenario: Cancellation races with completion
- **WHEN** a queued or active invocation is cancelled as replies arrive
- **THEN** queued work cannot spawn, active direct children are cleaned up/reaped, and exactly one terminal transition wins
- **AND** stale replies cannot publish results or trigger further calls

#### Scenario: A descendant retains an output pipe
- **WHEN** the direct child exits but a program it launched keeps an output descriptor open
- **THEN** Jort bounds output collection by deadline and closes its owned endpoints rather than waiting indefinitely
- **AND** it does not promise to terminate every descendant or prove cleanup after app failure

### Requirement: External effects require explicit execution and no implicit replay
Jort SHALL NOT launch scripts during validation, module initialization, preview, completion acceptance, Settings operations, document restore, rendering, Merge, Undo/Redo, or automatic recovery/retry/replay. Explicit user submission and current local permission SHALL both be necessary. Model tools SHALL NOT gain exec access. Interruption after launch SHALL be presented as potentially unknown external outcome rather than rollback, and explicit reruns SHALL warn about possible duplicate effects. Document history operations SHALL NOT claim to reverse external effects.

#### Scenario: A remote request precedes timeout
- **WHEN** a script times out after it may have sent a remote request
- **THEN** Jort reports the potentially unknown external outcome and does not retry
- **AND** Undo, Dismiss, or cancellation does not claim to reverse the request

#### Scenario: Non-execution lifecycle paths run
- **WHEN** Jort initializes, validates, previews, saves, restores, renders, merges, or applies Undo/Redo to a tool invocation
- **THEN** no external script is launched by that operation

#### Scenario: Model output or history contains exec text
- **WHEN** a model produces an exec expression or a saved invocation is restored
- **THEN** that content does not launch a script or grant permission
- **AND** model executors remain without exec capability
