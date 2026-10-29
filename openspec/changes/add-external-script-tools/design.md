## Context

This feature is trusted local automation, not hostile-code containment. External scripts run with ordinary user permissions and may access files, networks, other programs, and indirect OS automation, including Jort database or app files. Jort supplies no document API, native document objects, editor callbacks, or action-dispatch endpoint to scripts. The JavaScript tool owns input selection and output handling.

The existing JavaScript boundary remains important and unchanged in OS authority. QuickJS runs in a disposable sandboxed worker behind a private sandboxed broker. Current code requires substantive async work: `Sources/JortJavaScript/JortJavaScript.c` fails a pending promise when no local jobs remain; `Sources/JortJavaScriptWorker/main.c` requires EOF and closes its input before evaluation; `Sources/JortJavaScriptBroker/main.c` closes the request pipe and expects one terminal response and EOF. Current contracts identify protocol version 2. Awaited host calls therefore require coordinated engine, pipe protocol, broker, and runtime transport changes, not just a JavaScript wrapper.

## Goals / Non-Goals

**Goals:**
- Support `await jort.exec(path, payload)` with bounded JSON stdin and bounded inert text stdout.
- Require one local per-tool permission plus explicit user submission.
- Make common Python installations work without interpreter setup, using predictable executable discovery.
- Preserve JavaScript isolation, existing result handling, legacy tools, and model behavior.
- Bound process I/O and waiting; own cancellation, direct-child cleanup/reaping, and stale-result rejection.
- Explain nontransactional external effects without rollback or exactly-once claims.

**Non-Goals:**
- Contain scripts from Jort files, credentials available through ordinary user facilities, networking, other programs, or indirect OS automation.
- Add separate sandboxed external supervisors, resource grants, script allowlists, snapshots as authorization, executable/dependency hashing, race-resistant launch identity, or network permission.
- Guarantee arbitrary descendants cannot survive cancellation, app failure, or supervisor failure.
- Evaluate arbitrary shell command strings, bundle/manage Python, reproduce a Terminal tab's activated environment, or provide model tools with exec access.

## Decisions

### 1. Use predictable executable discovery without required interpreter setup

Adopt an Alfred-style default search path:

```text
/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

For Python scripts, resolve `python3` using this ordered path and launch the resolved executable directly. Do not assume macOS supplies a usable Python. If resolution or launch fails, report a bounded actionable error explaining that Python must be installed or an explicit interpreter path supplied. Do not install a runtime automatically.

Support an optional locally configured absolute interpreter path for a specific Python version or venv. It replaces default interpreter discovery, not the per-tool permission. No named profiles, extension-mapping UI, interpreter registration, or required fixed-argument configuration is needed. The override storage/UI shape and non-Python dispatch rules are resolved in Implementation Contracts below; they do not become mandatory setup for ordinary Python use.

Do not run login/interactive shells to discover PATH, source startup files, launch Terminal.app, or invoke an activation shell. A venv can be used through its interpreter's full path without activation. Fixed launch arguments are host-defined or explicit local configuration, never supplied by document content. Do not parse a shell command string or interpolate payload into executable arguments.

Alternatives: automatic shell-environment discovery would improve compatibility with shell-specific managers but introduces startup-file side effects, hangs, and hidden environment dependencies. Global interpreter profiles and extension mappings add unnecessary setup. Both are rejected for the initial feature.

### 2. Keep script resolution and launch context explicit

Accept absolute script paths and initial `~/` expansion to the current user's home. Reject relative paths, other-user tilde syntax, URLs, NUL, and unsupported path forms. Do not perform glob or environment-variable expansion. Treat a path as a filesystem path, not shell syntax; shell metacharacters in filenames or payload are never command interpolation.

Use the script's containing directory as cwd. Give the child the documented default PATH and ordinary home, temporary-directory, and locale context. Do not blindly forward the entire app environment or automatically inject Jort provider credentials, internal connections, or document handles. Scripts configure their own service credentials and can adjust the environment of programs they launch. These are predictable-launch choices, not restrictions on what trusted scripts can access through the OS.

Launch the current file at dispatch. Script edits, symlinks, interpreter updates, and dependency changes do not trigger approval checks or identity enforcement. No immutable snapshot or authorization hash is required. Missing files and unusable interpreters produce ordinary launch failures.

### 3. One local per-tool toggle, independent of invocation

Settings exposes “Allow this tool to execute local scripts.” Store it locally using the tool's stable identity, independently of package declarations and document content. Default to denied when there is no local permission. Importing, saving, enabling, restoring, or replacing package metadata cannot set the toggle. Do not bind consent to source/script/interpreter/dependency hashes or require reapproval on edits.

Explicit user submission is required in addition to permission, including for zero-argument tools. Initialization, validation, preview, completion acceptance, Settings operations, restore, rendering, Merge, and Undo/Redo do not dispatch scripts. Model tools never receive exec capability.

The host checks permission at dispatch, not merely when constructing a worker request. Turning permission off denies new/queued calls and cancels active affected invocations using the same interrupted-outcome semantics as other cancellation. UI must disclose that this permits trusted local code to run with user permissions and that external effects are not undone by document undo.

### 4. Preserve the JSON-in/text-out boundary

```javascript
export default async function(input) {
  const result = await jort.exec("~/scripts/sync-notes.py", {
    content: input.content
  });
  return {report: result.stdout || "Script completed."};
}
```

The promise resolves to frozen `{stdout: string}` only after exit zero, complete valid bounded UTF-8 output, and direct-child reaping. Serialize one bounded JSON value, write it to stdin, and close stdin. Reject unsupported data, cycles, excessive nesting, serialization failures, and size violations; avoid invoking custom serialization/getters when capturing payload. Nonzero exit, launch failure, timeout, invalid output, overflow, or channel failure rejects with a bounded typed error, not partial successful output.

Drain stderr concurrently under a cap; do not automatically return it, persist it, or expose it as document content. Diagnostics record bounded failure categories and correlation information, not payloads, output, script secrets, or raw subprocess diagnostics.

The flow is captured document input → JavaScript tool → JSON stdin → external script → stdout as inert text → JavaScript tool's normal result → existing Jort result handling. Stdout is never automatically parsed as a Jort action, even when it resembles one. A JavaScript author may intentionally interpret output and return a normal supported result; existing app-side result/action validation still applies.

### 5. Extend the existing channel for an awaited host operation

The flow is QuickJS promise → bounded worker request → broker relay → app-side runtime policy/runner → correlated reply through the broker → promise settlement. The sandboxed broker does not launch external scripts or gain their authority. No new external containment helper is required; the app-side runtime owns ordinary user-permission subprocess execution.

Use explicitly negotiated capability-capable framing, preserving legacy protocol-v2 and contract-one adaptation behavior. Select any new protocol/schema version against current code at implementation time. Capability frames contain bounded primitive data with existing peer/nonce/invocation/generation correlation plus a unique call identifier, and allow exactly one terminal tool response. Validate lengths including encoding overhead before allocation/copying. Reject malformed, unknown, duplicate, unsolicited, wrong-phase, or stale messages without launching additional effects.

The host independently checks JavaScript executor identity, permission, explicit submission, execution phase, current generation, configured launch policy, payload limits, and call ownership. Do not trust worker-supplied assertions of permission. Initialization and validation cannot dispatch, including when code attempts an exec before its default entry point.

For opted-in execution, keep pipes/channel usable for bounded request/reply traffic rather than requiring immediate EOF. Wait for a host completion when QuickJS has no runnable jobs but owns an outstanding exec; settle the promise on the engine's owning thread and resume job pumping. An unresolved promise without an outstanding host operation is not permission to wait indefinitely. Cancellation, channel failure, and deadlines terminate waiting. Host waits must not reset JavaScript compute budgets or relax existing heap/stack/CPU restrictions.

QuickJS receives no direct filesystem, network, process, or general native callbacks. Keep existing JavaScript sandbox authority, disposable-worker topology, dependency isolation, legacy bounds, native action semantics, and model execution unchanged.

### 6. Bound work and own the direct child, not arbitrary descendants

Define finite input/output byte and line bounds, nesting limits, a reasonable external timeout within an explicit overall invocation deadline, and bounded global admission. Start with one outstanding exec per invocation; bound total calls and queued work so repeated calls cannot evade the overall budget. Numeric defaults are recorded in Implementation Contracts below and require implementation tests; they are not inherited containment-specific CPU/process restrictions.

Write stdin and drain both output streams concurrently so a script that writes before consuming all input cannot deadlock the runner. On timeout, overflow, cancellation, permission revocation, or channel loss, stop input, request direct-child termination, escalate after a bounded grace period, and reap. Remove queued work without spawning. Guard terminal transitions so only one wins, and reject late completions or further launches for a terminal generation.

A script may legitimately launch other programs. Do not impose a no-subprocess restriction or require proof that descendants die. If a descendant retains a pipe after the direct child exits, bound collection by deadline and close owned endpoints rather than hanging indefinitely. Describe app-crash cleanup limitations honestly; no external supervisor-death containment guarantee is made.

### 7. External effects are nontransactional

Never automatically retry, reconnect-replay, restore-rerun, or recover-rerun an external call. Before launch, cancellation can establish that the queued script was not started. After launch, interruption may leave an unknown external outcome even if the direct child is terminated. Do not present timeout or cancellation as rollback. Document Undo/Redo, Merge, and Dismiss affect Jort state only; they cannot undo a file write, launched program, or remote request. Explicit reruns should warn about possible duplicate effects. Authors may implement their own service-level idempotency in JSON; Jort does not guarantee exactly-once effects.

## Risks / Trade-offs

- [Trusted scripts can read or modify user-accessible Jort state and other resources] → Explicit blanket permission and honest documentation, not containment claims or denial probes.
- [Custom shell-managed Python is absent from the default PATH] → Optional absolute interpreter override and actionable error; no automatic shell discovery.
- [Async framing spans C engine, pipes, XPC, and Swift runtime] → Negotiate explicitly, test phase/correlation/bounds and cancellation races, retain legacy regression coverage.
- [Scripts or descendants retain pipes, ignore termination, or continue external work] → Bounded I/O collection, direct-child escalation/reaping, stale-result rejection, and explicit limitations rather than descendant guarantees.
- [External effects succeed before a timeout or lost reply] → Unknown-outcome messaging, no automatic retries/replay, and explicit duplicate-effect warnings.
- [Minimal launch environment differs from Terminal] → Document cwd/PATH/context; let power users use explicit interpreter paths and script-owned configuration.

## Migration Plan

1. Implement the configuration/API, numeric limits, and compatible protocol decisions recorded below against current main.
2. Add local permission with default-denied behavior; existing packages, imports, and restored documents gain no permission automatically.
3. Implement the bounded host runner and async channel while preserving existing JavaScript isolation and legacy/model behavior.
4. Integrate explicit submission, cancellation, outcome UI, examples, and focused contract/process/protocol/lifecycle regression tests. Use the repository validation workflow during implementation, including its final gate; no external containment prototype or independent security-review release gate is required.
5. Rollback disables new dispatch and cancels owned work; it does not replay calls, change legacy tool behavior, or undo external effects.

## Implementation Contracts (resolved against current code)

These decisions resolve tasks 1.1–1.3. They are implementation targets, not evidence that the feature exists or passes validation.

### Local configuration and dispatch

Use existing `SettingsStore` preferences in the local Settings SQLite database, exposed by `SettingsSnapshot.preferences`. Key records by stable `ToolManifest.id`, not package revision/generation or source hashes. Use `tool.externalExecution.<id>` with only the exact value `true` granting permission (absent, false, or malformed means denied), and `tool.interpreterPath.<id>` for the optional Python interpreter. Package manifests, exports, imports, restore, and package-generation recovery must not populate these keys. Source/package edits retain the user's local choice; permission is not an identity guarantee for imported replacement code with the same tool ID.

In the selected JavaScript tool's Settings detail pane, show the permission toggle, ordinary-user-permission warning, and optional “Python interpreter (absolute path)” text field. Model tools do not expose these controls. Empty interpreter configuration means default discovery. Accept only an absolute path without NUL for an override; no arguments, leading tilde, variable expansion, profiles, or configuration from invocation content. An invalid/unusable configured override fails rather than falling back. No fixed-argument override is supported initially.

A case-insensitive `.py` suffix selects Python: resolved interpreter plus the script path as one separate argument. Other paths must identify executable regular files (following symlinks is allowed); launch their absolute path directly with no extra arguments. Support native binaries as well as scripts whose shebang selects Node, Ruby, a shell, or another installed interpreter. Do not require a shebang for native binaries; let the OS determine executable-format validity. A Node script can use `#!/usr/bin/env node`, which resolves Node through the documented child PATH, or an absolute interpreter shebang. There is no extension-to-shell mapping, automatic `/bin/sh` fallback, or command-string parser. Python scripts need not be executable. All scripts use their containing directory as cwd. Missing/directory/unsupported paths fail before launch. The override affects Python only.

Build the child environment explicitly: documented fixed PATH; HOME from the current user's home directory; TMPDIR from the app's ordinary temporary directory; USER and LOGNAME from the current user; and LANG, LC_ALL, LC_CTYPE only when present as valid, bounded locale strings (at most 128 UTF-8 bytes each), otherwise LANG=`en_US.UTF-8`. Do not copy other app variables. These are launch defaults, not access restrictions or a guarantee of the same temporary directory as Terminal.

Runtime consumes settings updates and checks the effective permission again at every dispatch. Turning it off must update runtime policy and cancel affected queued/running generations before the Settings mutation is considered applied; do not rely solely on eventual UI snapshot refresh. Retain `ToolInvocationController.submit(_:)` as the explicit-submission entry point, including zero-argument tools, but carry host-owned submission provenance to Runtime: a UI check alone is not authorization.

### Numeric bounds and clocks

All byte limits count UTF-8 bytes, not Swift/JavaScript characters; all queue/deadline checks use monotonic clocks. Limits apply independently, not just after decoding.

| Resource | Initial bound |
| --- | --- |
| Script path | 4,096 UTF-8 bytes, excluding any terminator |
| Captured payload | 256 KiB serialized JSON; no newline required; stdin closes after exactly that value |
| JSON nesting | 32 container levels; root container is level 1 |
| Payload traversal | 32,768 total visited values/properties, including array slots; reject sparse arrays |
| Stdout | 1 MiB and 100,000 logical lines, using existing protocol line-separator semantics |
| Stderr | 64 KiB drained bytes; overflow fails the call; never returned as successful data |
| Outstanding calls | 1 per invocation, including queued work |
| Total calls | 8 attempts per invocation; invalid/rejected attempts count, with no counter reset after a caught error |
| External admission | 4 active direct children app-wide, at most 16 queued calls; excess fails busy without spawning |
| Exec-capable invocation admission | Existing maximum 4 JavaScript workers; at most 16 queued exec-capable invocations, separate from the external-call queue |
| External call | 30 seconds from request acceptance, including external admission waiting and pipe collection |
| Overall exec-capable invocation | 60 seconds from explicit submission, including worker admission, bootstrap, all calls, and result collection |
| Direct-child termination grace | SIGTERM, then SIGKILL after 500 ms if still owned/running; always reap before successful completion or releasing child admission |
| Pipe collection after direct-child exit | At most 500 ms and never beyond the call/invocation deadline; retained pipe means failure, not partial success |
| Public error / diagnostic | Existing 512-byte public message / 4 KiB private diagnostic limits; fixed categories and correlation only |

Do not promise that SIGKILL/reaping itself completes within a hard wall-clock bound under arbitrary OS failure. A generation can become terminal before cleanup finishes, but the runner retains direct-child ownership and its admission slot until reaped. Close owned pipe endpoints and reject late results; descendants are not owned cleanup targets.

Preserve the existing JavaScript compute allowance (default 5 seconds, caller-selected 10–30,000 ms), 16 MiB heap, 512 KiB stack, and worker CPU soft/hard limits of ceil(computeMilliseconds/1000) seconds and one additional second. In v3, account cumulative active engine wall time across initialization, validation, payload capture, execution, and job pumping. Pause active-time accounting only during an actual owned, correlated host wait; never reset the allowance after a reply. The independent 60-second deadline still runs during waits. An unresolved promise with no outstanding host work fails immediately as today. Legacy v2 timing is unchanged. Cleanup is not extra time for another call or result publication.

### Versioned capability framing and ownership

Current package schemas are 1–3 and entry contracts 1–2. Keep them unchanged: no package declaration grants exec and no manifest extension is necessary. Existing contract-one adaptation and contract-two action/result validation remain in force. A locally permitted, explicitly submitted JavaScript execution selects exact protocol 3; validation and legacy/non-permitted execution retain exact protocol 2. Expose a bounded authorization-rejecting `jort.exec` stub where dispatch is unavailable so explicit invocation without permission fails without launching. Phase denial takes precedence during module initialization and validation. Model tools have no such capability.

Keep v2's 128-byte `JJS1` header, ready handshake, 14-key XPC request, seven-key terminal reply, single-request/EOF behavior, all existing limits, and all exact-version/field checks unchanged. No transparent downgrade or replay is allowed. For v3, require an authenticated per-request XPC connection and a version-3 initial request/reply; readiness must explicitly acknowledge version 3 and the exec capability before sending source. A mismatched broker/worker fails compatibility before evaluating the package. Bind the worker to its broker-owned pipes/process; a nonce or checksum is correlation/integrity data, not peer authentication.

Use a separate 160-byte v3 header rather than reinterpreting unused v2 fields: bytes 0–3 magic `JJS3`; 4–5 version 3; 6–7 kind; 8–11 operation/status; 12–27 nonce; 28–43 invocation UUID; 44–59 generation UUID; 60–75 call UUID; 76–79 remaining overall milliseconds; 80–83 compute milliseconds; 84–87 output bytes; 88–91 output lines; 92–115 six unsigned field lengths; 116–127 reserved zero; 128–159 SHA-256 over concatenated payload fields. Integers are big endian. Kinds are initial request, terminal response, exec request, and exec reply. Initial/terminal call UUIDs are zero; exec call UUIDs are unique nonzero UUIDs within the generation. Only the initial frame sets budgets; later frames have zero budget fields. Neither a request nor a reply can replenish time or limits.

Initial fields retain v2's contract/source/input/clock/UUID/metadata meanings and independent caps; total initial envelope, including the new header, remains at most 2.5 MiB. Terminal fields and the 1.125 MiB terminal envelope retain current success/error exclusivity and semantic result/action limits. Exec-request fields are path and serialized JSON payload, with remaining fields empty and operation=`exec`; full header-plus-fields is capped at 266,400 bytes (160 + 4,096 + 262,144). Exec-reply fields are stdout on success OR a fixed public error message on failure, remaining fields empty, status from the bounded enum below; full header-plus-fields is at most 1,048,736 bytes. Empty stdout is valid. Transport carries raw UTF-8 fields, not base64 or JSON-wrapped stdout: the worker constructs frozen `{stdout}` locally. Encoding a later normal tool result must independently fit its existing result envelope, even if escaping expands stdout beyond that envelope.

Use exact allowlisted v3 XPC dictionaries mirroring these primitive header fields and six bounded data fields (magic/reserved/hash are pipe framing details, not extra authority). The initial XPC request receives exactly one terminal reply via its reply context. Intermediate broker-to-app exec messages and app-to-broker replies use the same authenticated request connection's event channel and the full protocol/nonce/invocation/generation/call tuple; do not create an uncorrelated public service or accept a worker-supplied permission assertion. The C client exposes an intermediate-call callback plus a correlated reply API to the Swift transport, separate from its one-shot completion callback. The broker serially relays validated frames and retains stdin until the terminal frame; v3 must not inherit the legacy immediate-EOF requirement.

Before allocation/copying, every layer checks field types, exact key sets, fixed header, individual lengths and overflow-safe summed lengths; after receipt check UTF-8, checksum, and JSON semantics. Fixed status categories are authorization, phase, invalidPayload, invalidPath, missingRuntime, launch, nonzeroExit, invalidEncoding, outputLimit, busy, callLimit, timeout, cancelled, and channel/protocol failure. Messages are fixed, bounded, and omit path, payload, stdout, stderr, and arbitrary child diagnostics; missingRuntime explains installing Python or selecting an absolute interpreter. Malformed framing makes the generation terminal rather than becoming a catchable opportunity to send another effect.

Runtime owns the canonical tool ID, JavaScript executor identity, explicit-submission provenance, live invocation/generation, settings, launch policy, deadline, and call state. It compares the incoming tuple against that owned state and rechecks permission before launch. Host entry phase is bound to an execute-only channel; the worker also keeps a native phase latch closed throughout module evaluation/validation and opens it only around the default entry point and its jobs. A worker-supplied phase/permission flag is never sufficient. As with the existing architecture, the sandboxed native worker is a trusted protocol implementation, not a source of package-authored host authority. The host tracks each call through queued/running/terminal; duplicates, unsolicited replies, wrong peers, stale generations, excess calls, and any post-terminal traffic cannot start effects. Worker/broker/connection loss cancels owned external work without reconnect or replay.

### Payload capture without author callbacks

Capture in native QuickJS code, not `JSON.stringify(payload)` or a JavaScript recursive helper. Use `JS_GetClassID` to accept only ordinary objects and arrays before prototype/property inspection; compare against classes of pristine native-created object/array values rather than hard-coded private class numbers. Reject proxy/exotic/function/boxed/typed-array objects before any operation that could invoke their hooks. Do not enable Proxy intrinsics (the current raw context does not add them). Accept null, booleans, strings, finite numbers, dense arrays, and plain objects with the pristine Object prototype or null prototype. Reject undefined, symbols, BigInt, nonfinite numbers, cycles, custom prototypes, symbol properties, accessor descriptors, and custom `toJSON` properties, without invoking them. Inspect own descriptors using native APIs, never a property value getter; arrays may have only length and dense indexed data properties. Reject unsupported own properties rather than silently dropping them. Shared acyclic references may serialize more than once but count against traversal/byte limits. Encode JSON directly into a capped native buffer, including escape/UTF-8 expansion in the byte limit, before emitting any frame. Tests must cover getters, toJSON, changed prototypes, sparse arrays, cycles, and proxies if introduced by future runtime changes.

## Remaining implementation checks

The contracts above require focused permission, serialization, protocol, process, and lifecycle tests before completion. In particular, verify exact v2 compatibility; settings-revocation ordering; active compute accounting across multiple host waits; encoding-expansion boundaries; stdin/output flood behavior; and cleanup ownership when descendants retain pipes. If implementation cannot satisfy these decisions without changing the trust model or public behavior, pause and revise the artifacts rather than silently weakening the contract.

## Research References

- Alfred's documented scripting environment uses `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` and avoids loading shell startup configuration by default: https://www.alfredapp.com/help/workflows/advanced/understanding-scripting-environment/
- Python documents that virtual-environment activation is not required to use the environment: https://docs.python.org/3/library/venv.html
- Foundation exposes explicit process environment and termination; termination requests alone do not establish that an ignoring process has stopped: https://developer.apple.com/documentation/foundation/process/environment and https://developer.apple.com/documentation/foundation/process/terminate%28%29
- These are documentation findings plus inspection of the current worker/job loop, not evidence of an implemented or tested Jort runner.
