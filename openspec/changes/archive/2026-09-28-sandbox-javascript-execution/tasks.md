## 1. Protocol and failure contracts

- [x] 1.1 Define protocol-v1 primitive field keys, operation/status tags, correlation values, compiled policy constants, and independent/total request and response limits without exposing internal contract `Codable` graphs.
- [x] 1.2 Implement client-side normalized-manifest, source, input, metadata, deadline, and total-envelope validation before constructing low-level XPC values.
- [x] 1.3 Implement broker-side exact-key/type/version validation and inspect every XPC data length and sum before application copying or semantic decoding.
- [x] 1.4 Define the fixed broker-child header, integer-overflow-safe length validation, payload hash, exact-one-frame semantics, and bounded streaming read/write helpers.
- [x] 1.5 Add bounded public JavaScript failure cases for unavailable/busy, peer identity, launch, sandbox bootstrap, timeout/cancel, CPU/engine limits, crash, protocol, output, and internal errors.
- [x] 1.6 Add deterministic codec tests for maximum legal values and unknown, missing, wrong-typed, overflowed, truncated, trailing, duplicated, invalid-UTF-8, hash-mismatched, version-mismatched, and oversized messages on both protocol layers.

## 2. Signed containment target graph

- [x] 2.1 Add stable `JortJavaScriptBroker` XPC-service and minimal C `JortJavaScriptWorker` executable targets in `project.yml` with standard nested-code placement and no main-target QuickJS dependency.
- [x] 2.2 Add the broker entitlements with App Sandbox and Hardened Runtime and verify no network, file-selection/user-directory, app-group, Keychain-group, Apple Events, device, or temporary-exception capability.
- [x] 2.3 Add worker signing/hardening configuration whose App Sandbox keys are exactly app-sandbox plus inherit and which has no JIT, unsigned-executable-memory, or library-validation exception.
- [x] 2.4 Configure development/test signing for the app and both helpers so entitlements are exercised locally while leaving Developer ID credentials, notarization, and release publication to Wave 4.
- [x] 2.5 Add checked target identifiers, expected signer relationships, fixed worker bundle URL, and peer code-requirement construction for development and production configurations.
- [x] 2.6 Add generated-project/package-structure tests proving the broker is private to the containing app and every nested executable occupies a code-signing-safe declared location.

## 3. One-run worker bootstrap and engine host

- [x] 3.1 Implement the worker's earliest bootstrap path to clear environment/state, close all undeclared inherited descriptors, parse only trusted numeric policy arguments, and avoid writable-current-directory dependence.
- [x] 3.2 Install and read back deadline-derived `RLIMIT_CPU`, zero `RLIMIT_CORE`/`RLIMIT_FSIZE`/additional-process allowance, and the minimal signed-bootstrap-tested `RLIMIT_NOFILE` before Ready; intentionally add no whole-process memory watchdog or deterministic memory ceiling.
- [x] 3.3 Add the fixed Ready/failure handshake and ensure the worker reads no source or input when any required limit cannot be installed and verified.
- [x] 3.4 Move the QuickJS shim and vendored engine linkage into only the C worker and preserve a fresh 16 MiB heap, 512 KiB engine stack, interrupt/cancel, disabled globals, module restrictions, and post-compilation eval disablement.
- [x] 3.5 Decode one bounded request frame, compile/inspect without default execution for validation, or execute exact captured input for execution, then create one bounded exclusive output/error frame.
- [x] 3.6 Enforce package output bytes and line count while building/reading results, reject invalid UTF-8/NUL/nonexclusive values, erase transient buffers where practical, and emit no payload-bearing logs.
- [x] 3.7 Exit after exactly one terminal frame or bootstrap/protocol failure and add standalone worker parity tests for existing valid/adversarial JavaScript fixtures.

## 4. XPC broker supervision

- [x] 4.1 Implement the private low-level XPC listener with exact caller audit/code-signing checks, connection lifecycle handling, and no engine/model/credential dependency.
- [x] 4.2 Verify the fixed worker path, static code signature, identifier, and signer relationship before every launch and fail closed if bundle sealing or identity is invalid.
- [x] 4.3 Implement a four-child admission controller with one owned state record per nonce/generation and no unbounded broker queue.
- [x] 4.4 Launch each child with dedicated pipes and numeric policy only, require its bounded Ready handshake, and send source/input only after verified resource setup.
- [x] 4.5 Implement bounded child-response framing, expected EOF/exit verification, exit/signal classification, and reap-before-success behavior.
- [x] 4.6 Implement separate bootstrap and execution wall watchdogs plus cancellation/client-invalidation handling that closes pipes, terminates the owned child, escalates to `SIGKILL`, and confirms `waitpid` reaping.
- [x] 4.7 Serialize reply, pipe, timer, cancellation, and exit events through one terminal-state gate so exactly one bounded correlated XPC reply can win.
- [x] 4.8 Add broker unit/integration fixtures for capacity, launch/signature failure, partial writes, backpressure, second frames, child crash/hang, watchdog race, cancellation race, and descriptor/process leak detection.

## 5. Runtime, Settings, and lifecycle integration

- [x] 5.1 Implement the lazy `JortToolRuntime` JavaScript broker client with exact broker peer requirement, request correlation, client watchdog, session invalidation, and typed failure mapping.
- [x] 5.2 Add fair maximum-four JavaScript admission in the headless Runtime coordinator, cancellable queued generations, and fail-closed handling if broker capacity disagrees.
- [x] 5.3 Route the Wave 1 transactional Settings save's injected JavaScript validation through one disposable worker and remove every production in-process validation fallback.
- [x] 5.4 Route JavaScript execution results through generation-tagged reducer actions and the document-owned atomic patch path, preserving first-terminal-wins, no partial output, Merge/Dismiss/Undo, persistence, and recovery behavior.
- [x] 5.5 Keep model execution on the separately injected main-process provider/credential/HTTP path and add dependency tests proving it never contacts or links the JavaScript containment targets.
- [x] 5.6 Retain the old executor only as a nonshipping comparison oracle until parity tests pass, then remove its build flag, production adapter, and main-process `JortJavaScript` linkage.

## 6. Security and containment verification

- [x] 6.1 Add recursive `otool`/symbol and runtime-mapping checks proving QuickJS is absent from the app, all frameworks, Runtime client, and broker and present only in ephemeral worker processes.
- [x] 6.2 Add signature/entitlement tests for unique identifiers, expected signers, nested locations, broker sandbox/hardening, worker inheritance/hardening, and absence of every prohibited entitlement.
- [x] 6.3 Build signed native inherited-sandbox probes for representative arbitrary user-file read/write, network client/server, Jort Keychain credential, Apple Events, protected device, and subprocess attempts and require every authority denial.
- [x] 6.4 Add an engine-allocation fixture proving the 16 MiB QuickJS heap limit fails safely without destabilizing the broker or app, while making no whole-process memory-ceiling claim.
- [x] 6.5 Build a native CPU-burn probe that bypasses the QuickJS interrupt and proves the kernel CPU limit terminates it by the hard deadline and the broker reaps it.
- [x] 6.6 Exercise infinite loop, stack exhaustion, deliberate crash, deadlock/hang, cancellation, broker interruption, malformed/oversized output, and late reply fixtures with exact typed terminal outcomes.
- [x] 6.7 Assert every negative case leaves canonical text/invocation state unchanged, unrelated edits and invocations responsive, no sensitive diagnostics, no open request descriptors, and no unreaped child.

## 7. Provenance, gates, and release handoff

- [x] 7.1 Expand the QuickJS vendoring record with archive URL/version/SHA-256, imported-file inventory, license, reproducible verification/import commands, exact local patch, last security review, and analyzer baseline/delta procedure.
- [x] 7.2 Add a release-and-90-day review checklist for upstream changes, vulnerability reports, local patches, compiler/analyzer changes, and explicit approval of any dependency or diagnostic-baseline update.
- [x] 7.3 Update tool security/package documentation to distinguish JavaScript API defense in depth from OS containment and keep public/community import explicitly disabled pending Wave 4 verification.
- [x] 7.4 Run formatter, project generation, first-party and vendored analyzer lanes, headless/Foundation/native suites, focused signed UI workflows, signed containment probes, packaged-target verification, and strict OpenSpec validation; record runner-only failures without counting them as test results.
- [x] 7.5 Record the final broker/worker identifiers, entitlements, nested-code paths, dependency graph, local-signing requirements, and verification commands as mandatory inputs to `establish-signed-release-and-app-identity`.
