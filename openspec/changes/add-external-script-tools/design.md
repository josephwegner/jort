## Context

Jort currently executes untrusted JavaScript in QuickJS, linked only into a fresh worker behind a private sandboxed XPC broker. `Sources/JortJavaScript/JortJavaScript.c` pumps local promise jobs but treats an unresolved promise with no pending jobs as failure; it has no asynchronous host-call loop. The broker protocol currently admits one request and one terminal response. Model tools are separate and cannot call tools. Native host actions are inert result requests rather than general native callbacks.

The main application is deliberately not App Sandboxed (`Configuration/JortProduction.entitlements`). Its databases, recovery files, tool registry, and diagnostics are same-user filesystem state. Launching Python from the main process, even with empty environment and separate pipes, would not protect that state. Existing JavaScript worker entitlements prohibit networking, files, and processes; expanding them to execute arbitrary runtimes would regress the existing boundary.

This design follows `proposal.md` and the existing `sandboxed-javascript-execution` specification. User acceptance of external script behavior covers supplied input and approved external effects, not implicit access to Jort internals.

## Goals / Non-Goals

**Goals:** Support locally authored Python/shell integrations through `await jort.exec(...)`; require local approval; isolate external code from Jort state; preserve pure JavaScript isolation; bound IPC/resources and own process cleanup; explain irreversible external effects honestly.

**Non-Goals:** A shell command evaluator, unrestricted local automation, model-generated executable calls, arbitrary home-directory/file grants, inherited user environment/SSH agent, Jort provider credentials, community-import enablement, a bundled Python runtime, deterministic whole-process memory limits, or rollback/exactly-once guarantees for remote effects.

## Decisions

### 1. Prototype containment before committing to runtime compatibility

First build a signed release-like prototype of a separate sandboxed supervisor/runner with user-selected Python and shell fixtures. Prove script/runtime readability, Python imports and TLS, denied Jort state access, denied Keychain/Apple Events/debugging/unauthorized IPC, resource setup, and complete cleanup. Test system and Homebrew/venv layouts separately; do not assume macOS includes Python.

Use public supported macOS mechanisms: independently App-Sandboxed XPC supervisors with narrowly scoped user-selected read authority and inherited-sandbox disposable children. Separate network-disabled and network-enabled profiles so network permission is enforced by the OS, not merely a Boolean in a message. Helpers have separate containers, no app groups or Jort Keychain groups. Preserve the existing JavaScript supervisor unchanged in authority. Never use `sandbox-exec`, private Seatbelt APIs, global temporary exceptions, unrestricted helper launch, or a hand-written deny-list as the claimed isolation boundary.

This is a go/no-go gate, not a claim that arbitrary Python installations already work under App Sandbox. If user-selected runtime access or supported child launch cannot satisfy containment, stop and revise the proposal (potentially a stronger VM-based boundary); do not silently weaken isolation. A direct `Process` child and reusing the existing JavaScript worker are rejected because they respectively expose Jort state or destroy current sandbox guarantees.

### 2. Keep a small asynchronous API and explicit local bindings

Proposed use after binding and approval in Settings:

```javascript
export default async function(input) {
  const result = await jort.exec("~/sync-notes-with-slack.py", {
    content: input.content
  });
  return {report: result.stdout || "Sync script completed."};
}
```

`jort.exec(path, payload)` resolves to a frozen `{stdout: string}` only after a successful process exit and complete output collection. Nonzero exit, denied authorization, timeout, invalid encoding, protocol error, or limit breach rejects with a typed sanitized error, never an apparent success. It does not expose stderr, credentials, native objects, or an arbitrary command/argv/env options object. Empty stdout is success, not evidence Slack accepted anything. Scripts can choose their own application-level acknowledgment in stdout.

Payload is plain JSON data: reject cycles, accessors/custom prototypes, undefined/function/symbol/BigInt values, nonfinite numbers, excessive depth, and over-limit serialization; do not call custom `toJSON`. Serialize a single UTF-8 JSON value to stdin and close it; stdin is never shell syntax. Stdout is UTF-8 text, not an automatically interpreted Jort action or model instruction. Raw stderr is drained under a cap and discarded, not persisted or surfaced automatically. Result text becomes document content only if the tool explicitly returns the normal output variant.

A new manifest schema adds bounded `externalScripts` declarations using stable logical script IDs and selectors such as `~/sync-notes-with-slack.py`, plus requested outbound-network capability. No manifest version number is reserved until implementation checks other in-flight changes. The literal path is a selector for an approved local binding, not permission to execute any runtime path. Only an initial `~/` or absolute local selector is accepted; reject `~other`, relative paths, URLs, NUL, glob/environment expansion, and command strings. Exact selector lookup occurs before host resource resolution; no PATH lookup or shell parsing. Validation/compile and module initialization never have executable capability; only the default entry point of an explicitly user-submitted generation does.

Settings maps selectors to selected script and explicit absolute interpreter, read-only runtime resources, and network profile. Fixed launch arguments come from the runner's supported interpreter adapter (`python`/`shell`), not note content or arbitrary tool argv. Executable shebang/PATH resolution is not trusted. Shell scripts use the selected approved interpreter; subprocess creation by the script is out of scope for v1 and is denied. Use `exec` to replace a trusted bootstrap with the approved interpreter in the same constrained process, subject to prototype verification.

### 3. Local consent is independent of package declarations

A tool cannot grant itself executable authority by editing its manifest. Settings displays tool identity, selected script/interpreter, network permission, exact captured-input scope, and a warning about external effects. Approval is local-only, revocable, and bound to the tool generation/source/manifest digest, script digest, interpreter identity/digest, runtime resource set, and profile. Saving/enabling/importing a tool does not execute a script or approve it. Restored documents, provider output, and package metadata cannot create consent.

Take a bounded immutable snapshot of the approved entry script and execute that exact snapshot; reject symlinked script entries and recheck identity at approval/dispatch. Verify interpreter and approved runtime resource identities on launch with a race-resistant mechanism validated by the prototype. If the mechanism cannot ensure the verified executable is the one launched, fail closed. Changes require reapproval. Runtime dependencies are an explicitly approved trust unit, not a promise of supply-chain verification for every Python import; changes to that unit must invalidate consent. Do not grant a broad Homebrew prefix or whole home directory to make imports work. Reject resources overlapping Jort stores, recovery, Settings, app bundle, credentials, or an ancestor granting those areas. Dynamic grants belong only to the external runner, never the QuickJS worker, and expire with the run.

Version one has no arbitrary writable user-file grants. Temporary scratch is per-run and removed best-effort; scripts may use only their isolated container/scratch and approved read resources. Integration secrets must be user-owned script configuration in explicitly approved resources, not Jort's model credentials; plaintext script/config risks are disclosed, never copied into diagnostics. Network permission allows outbound exfiltration of supplied data; v1 does not claim per-domain filtering. It must not let a script impersonate Jort on private IPC or bypass ordinary OS authentication.

### 4. Add a separate capability protocol, not generic native bridging

The flow is: QuickJS promise → bounded worker capability frame → existing broker relay → authenticated Runtime policy router → external supervisor → constrained disposable runner. Return only bounded stdout/error data along the correlated reverse route. QuickJS receives no bookmark, resolved resource path, native handle, or general host callback. The router independently checks manifest, approval, execution phase, generation, call sequence, payload bounds, and revocation; assume a compromised worker can forge any worker message.

Existing tools retain protocol v2 with its contract-1 adapter, contract-2 captured-data bounds and typed action semantics, and one terminal response. Opted-in tools use explicitly negotiated protocol v3 with an allowlisted `execRequest`/`execReply` exchange and exactly one final tool response. Each exec has a unique call sequence under the existing peer/nonce/invocation/generation correlation. Duplicate, stale, unsolicited, unknown-field, wrong-phase, or out-of-order frames fail closed before effects. Main-app authentication uses audited XPC peer identity, not user-supplied bundle IDs. No publicly callable unauthenticated local automation endpoint is added.

Refactor the QuickJS loop to wait for authenticated host completions when local jobs are exhausted, bounded by deadline and cancellation, then enqueue the corresponding promise settlement. A call during top-level module evaluation or `validate` rejects without dispatch. Only one outstanding external call and at most four calls per invocation are allowed initially; cap external runs globally at two with a bounded cancellable FIFO queue. Pure JS admission remains capped at four. No untracked tasks or in-process engine fallback.

### 5. Establish independent external budgets and effect-aware lifecycle

Initial host hard caps: 1 MiB JSON payload (also no greater than tool input cap), nesting depth 32, stdout min(tool output cap, 1 MiB) and tool line cap, stderr 64 KiB, 25-second external wall budget including queue time shared by all calls, and 20 CPU seconds per runner. Install/read back core=0, checked descriptor limits, and process creation restrictions before input. Confirm interpreter replacement works with those limits. No whole-process memory ceiling is claimed. External tools have an explicitly selected overall deadline of at most 30 seconds (instead of the ordinary five-second default); waiting does not extend the existing CPU budget or relax QuickJS heap/stack limits. Tests must prevent a malicious tool from using host waiting to refresh JS compute limits.

Spawn with fixed cwd, empty/minimal allowlisted environment, no inherited document/network/agent descriptors, and private stdin/stdout/stderr channels. Remove bootstrap/native authority not needed by the interpreter. The supervisor drains streams concurrently, terminates on overflow or cancellation, escalates termination, and reaps before acknowledging terminal completion. Bound all new frames including JSON escaping overhead before allocation. Reject descendants or prove they cannot survive; process groups alone are not a defense against a script that daemonizes. This cleanup property is a release gate, including broker death.

Consent is necessary but not sufficient to trigger execution: require explicit user submission even for no-argument generators. Completion acceptance, preview, rendering, package validation, restored invocations, Undo/Redo, Merge, or opening Settings never launch scripts. Keep model executors without this capability.

Cancellation is not rollback. Once a process launches, remote effects may already have happened; timeout, crash, lost connection, cancellation, or revocation reports an interrupted/unknown external outcome rather than claiming nothing happened. No automatic retry, reconnect replay, or recovery rerun. A user-requested rerun warns about possible duplication. Merge and Undo affect Jort text only. An invocation/call identifier can be supplied by the author in JSON for remote idempotency, but Jort does not guarantee exactly-once effects. Logs contain only bounded failure classes, IDs, and timing—not paths, payload, stdout, stderr, or script secrets.

## Risks / Trade-offs

- [Arbitrary Python installs may need broad runtime access or launch facilities] → Ship a narrow tested compatibility matrix only; stop at the prototype gate rather than launch unsandboxed.
- [Same-user filesystem access is not isolation] → Separate App Sandbox, no Jort resource grants, signed native denial probes against real storage/recovery locations and IPC; no reliance on user trust as an internal boundary.
- [Sandboxed scripts still contact hostile services and can leak supplied content] → Explicit network consent and clear input preview; remote behavior is user-owned, host integrity remains Jort-owned.
- [Mutable runtimes/dependencies and launch races] → Exact entry snapshot, resource trust-unit invalidation, race tests; block configurations whose launch identity cannot be enforced.
- [Network may expose unrelated local unauthenticated services] → Document that outbound permission is broad; Jort's own services require authenticated peers. Per-domain/loopback firewalling is not claimed.
- [Custom helpers and duplex async IPC expand attack surface] → Separate targets/profiles, minimal allowlists, bounded queues, adversarial frames, signed release audit and independent security review.
- [Failed runs may have real external effects] → Unknown-outcome UI, explicit reruns, no retry or transactional/rollback claims.
- [Dependency changes in active tool/model proposals] → Choose schema/protocol versions and integration seams against current main at implementation time; preserve existing models and native actions.

## Migration Plan

1. Complete signed prototype and record evidence/compatibility matrix before exposing any exec UI or shipping new authority.
2. Add opt-in contracts and local approval storage; absent approvals mean denied. Never migrate an existing tool to executable authority automatically.
3. Land separate supervisors/runner and protocol v3 behind a disabled feature flag, retaining existing protocol-v2/contract-1-adapter tests, captured-data limits, action semantics, and entitlements.
4. Integrate Settings, explicit submission, effect status, examples, and signed release-blocking probes. Enable only after independent review and current validation gate pass.
5. Rollback disables new dispatch, cancels/reaps live runs, and leaves existing pure JS/model tools and pending canonical text intact. Approval metadata can remain inert; no rollback can undo a Slack post.

## Open Questions

- Which system/Homebrew/venv interpreter layouts can the signed prototype safely support, and what race-resistant executable/resource identity mechanism works with public APIs? These are blocking research tasks, not assumptions.
- Can both selected-resource authority and no-descendant cleanup be proved with the proposed inherited sandbox and process limits for supported runtimes? If not, revise the architecture before continuing.
- How should Settings present runtime-resource trust units without encouraging overbroad grants? Prefer restricted adapters and actionable unsupported-runtime errors.
