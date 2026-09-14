## Context

The current Swift `ToolRuntime` invokes `jort_js_validate` and `jort_js_run` from a detached task, but `JortJavaScript` and vendored QuickJS remain loaded in Jort's address space. QuickJS already receives a fresh runtime, 16 MiB engine heap limit, 512 KiB engine stack limit, bounded input/output, a maximum 30-second interrupt deadline, cancellation, no module loader or OS bindings, no Date or random source, and disabled dynamic evaluation after host compilation. Those controls constrain scripts but cannot contain a memory-safety failure in the C engine.

The Wave 2 architecture introduces `JortToolContracts`, an executor-neutral `JortToolRuntime`, a pure lifecycle reducer, and a headless coordinator. Settings obtains executor-specific validation through an injected fail-closed protocol; AppKit and Document never call QuickJS. This change replaces only the concrete JavaScript validator/executor behind that seam.

Jort targets macOS 14. Apple documents XPC services as independently sandboxable privilege-separation processes, while directly launched children inherit the launching process's sandbox. The design combines those properties: a minimal XPC broker owns a directly launched, one-run child that inherits the broker's restrictive sandbox. The child is the only binary containing QuickJS; the broker remains a small first-party supervisor able to terminate its own child reliably. POSIX `setrlimit` supplies hard per-process address-space and CPU limits; XPC itself is not treated as a resource limiter.

## Goals / Non-Goals

**Goals:**

- Ensure no process holding Jort documents, settings, credentials, provider transports, or AppKit objects loads QuickJS.
- Give engine code an independently enforced App Sandbox with no network, arbitrary user-file, Keychain credential, Apple Events, hardware, app-group, or PowerBox authority.
- Create a new OS process and fresh engine state for every validation or execution and reap it after exactly one terminal result.
- Enforce hard OS CPU/address-space limits before package source enters the child, while retaining all current engine/API bounds.
- Bound and authenticate every transport step and map every terminal condition into the existing generation reducer without partial canonical mutation.
- Produce structural, negative-authority, and resource-exhaustion evidence suitable for the later signed-release manifest.

**Non-Goals:**

- Developer ID certificate management, release signing automation, notarization, stapling, Gatekeeper assessment, or final package publication.
- Migrating Keychain items/access groups or enabling App Sandbox for the main application.
- Moving model-provider HTTP requests into the worker.
- Adding third-party/community package discovery, download, trust prompts, or automatic updates.
- Treating JavaScript API removal, XPC, or QuickJS's allocator as the sole security boundary.

## Decisions

### Use an XPC broker plus a disposable inherited-sandbox child

Add a private embedded `JortJavaScriptBroker.xpc` service and a minimal C `JortJavaScriptWorker` executable in a code-signing-safe nested-code location. The main-process `JortToolRuntime` JavaScript client opens a private XPC session to the broker. For each validate or execute request, the broker:

1. validates the authenticated caller, exact protocol envelope, capacity, and public limits;
2. launches one worker with only trusted numeric policy arguments and dedicated stdin/stdout pipes;
3. waits for a fixed-size Ready record proving the child successfully installed and read back its resource limits;
4. sends one bounded binary request frame containing source and exact input;
5. reads at most one bounded result frame while owning cancellation and wall-clock watchdogs;
6. reaps the child and returns one correlated XPC terminal reply; and
7. never reuses that process for another package or generation.

The broker supports at most four active children per application. The headless Runtime coordinator queues additional admitted JavaScript generations fairly and keeps them cancellable without opening another XPC request; the broker fails closed if its own capacity is exceeded. This prevents compromised input from creating an unbounded process fan-out.

A direct child from the unsandboxed main app was rejected because it would inherit the main app's authority. An engine-bearing XPC service alone was rejected because launchd may reuse the service and client invalidation is not a reliable per-invocation kill primitive. The hybrid keeps the independently configured XPC sandbox while giving the non-engine broker direct ownership, termination, and `waitpid` confirmation for the disposable child.

### Give helpers minimal explicit signing and sandbox identities

The broker has a stable bundle/signing identifier, App Sandbox enabled, Hardened Runtime enabled, and no network client/server, file-selection, Downloads/Documents, app-group, Keychain access-group, Apple Events, device, microphone/camera, USB/Bluetooth, printing, or temporary-exception entitlement. It runs in a new security session and receives no security-scoped bookmark.

The worker is signed with its own stable code identifier, Hardened Runtime without JIT/library-validation exceptions, and exactly `com.apple.security.app-sandbox` plus `com.apple.security.inherit` as its App Sandbox keys. It inherits only the broker's static sandbox, not main-app dynamic access. It receives no filesystem path, credential, provider, document, or settings reference. Standard input/output are its protocol pipes; inherited descriptors are closed; its environment is cleared to a small fixed locale allowlist; it has no writable working-directory dependency.

The main client requires the exact broker identifier and the build's expected signer. The broker validates the caller's audit/code-signing identity and verifies the fixed worker URL and expected nested-code identity before launch. Development and tests use the configured Apple Development identity or a documented local ad-hoc configuration that still signs every nested component and exercises entitlements. Release identity, Developer ID credentials, notarization, and stapling remain Wave 4 work. Production requirements use exact identifier plus same Team ID and fail closed.

### Use low-level allowlisted XPC values and an independent framed child protocol

Do not expose arbitrary `Codable`, `NSSecureCoding`, internal contract graphs, or remote-object methods. XPC protocol version 1 is one low-level dictionary with an exact allowlist of primitive keys. Unknown, duplicate-equivalent, wrong-typed, or missing values are rejected. The application checks field lengths before constructing a request; receivers inspect XPC data lengths before copying or decoding. XPC necessarily transports its own message storage, so the promise is no unchecked application allocation or decoding from it, not zero kernel/framework allocation.

The request contains only:

- exact protocol version, operation (`validate` or `execute`), 128-bit request nonce, invocation ID, and lifecycle generation;
- normalized JavaScript manifest/execution contract;
- immutable UTF-8 source;
- exact UTF-8 input content for execution;
- captured clock string and UUID value;
- requested deadline and engine/output limits within compiled policy maxima.

It never contains a document snapshot, settings/catalog store, credential, model/provider object, URL/path/bookmark, native object, or callback capability. The response echoes version, nonce, invocation, and generation and contains exactly one status plus bounded UTF-8 output or bounded public error category/message.

Independent version-1 maxima are:

| Field | Maximum |
|---|---:|
| Normalized manifest/contract | 16 KiB |
| JavaScript source | 256 KiB |
| Exact input content | min(package byte limit, 1 MiB) |
| Other request metadata | 4 KiB |
| Total XPC or child request payload | 1.5 MiB |
| Successful output | min(package byte limit, 1 MiB) and min(package line limit, 100,000 lines) |
| Public executor error text | 512 UTF-8 bytes |
| Private bounded diagnostic | 4 KiB, never source/input/output/credential data |
| Total XPC or child response payload | 1.125 MiB |

The broker-to-child protocol has a fixed magic, exact version, operation/status tag, nonce/generation, fixed-width lengths, and payload hash. It reads the fixed header first, rejects any independent or summed length before allocation, then reads exactly the declared payload with deadline/cancellation checks. Truncation, trailing bytes, second frames, invalid UTF-8, hash mismatch, nonexclusive output/error, excessive line count, or unexpected exit is failure. There is no permissive version negotiation: unsupported versions fail closed so both binaries must be upgraded together.

### Install hard OS limits before source reaches the child

The broker passes only the already validated deadline and compiled policy version as numeric launch arguments. At the first worker-controlled bootstrap point, before Ready and before reading any source or input, the child lowers both soft and hard limits and verifies them with `getrlimit`:

- `RLIMIT_AS`: 256 MiB address-space ceiling;
- `RLIMIT_CPU`: soft `max(1, ceil(requestedSeconds))` and hard one second later, with requested time constrained to 0.01 through 30 seconds;
- `RLIMIT_CORE`: zero;
- `RLIMIT_FSIZE`: zero;
- `RLIMIT_NPROC`: zero additional child processes; and
- `RLIMIT_NOFILE`: only the small checked descriptor ceiling required by dyld/bootstrap and the three protocol streams.

The exact `RLIMIT_NOFILE` value is recorded after a signed-target bootstrap test because it is platform-loader dependent; source is never sent if any required limit cannot be lowered and verified. The 256 MiB address-space value is a security policy constant and may change only with measured signed-worker startup/negative-allocation evidence and security review.

After Ready, the child creates a fresh QuickJS runtime with the existing 16 MiB heap and 512 KiB engine stack limits, installs cancellation/deadline interruption, and retains all current disabled-global/module/eval and result restrictions. OS limits cover native-engine defects and allocations outside QuickJS; engine limits give earlier controlled errors. A test-only native burn fixture proves `RLIMIT_CPU` independently of the QuickJS interrupt, and a native allocation fixture proves `RLIMIT_AS` independently of the QuickJS heap.

### Make the broker the watchdog and sole child-lifecycle owner

Worker bootstrap has a separate bounded watchdog. Execution wall time starts immediately before the broker releases the complete request frame and expires at the requested deadline; cancellation starts a short fixed termination grace. On timeout, cancellation, malformed/excess output, protocol violation, or client invalidation, the broker closes pipes, sends termination to the child it still owns, escalates to `SIGKILL` after the grace, and confirms reaping with `waitpid`. It emits exactly one terminal reply and discards all later pipe/XPC events.

Normal success and validation failure also require EOF, expected exit, complete frame verification, and reaping before the broker returns success. Thus the next request can never inherit native runtime state. Broker crash/interruption invalidates the client session; launchd may restart only the engine-free broker, while the inherited-sandbox worker loses its supervisor/pipes and remains bounded by hard CPU/address-space limits. The main client watchdog can invalidate/abandon the XPC request; the reducer makes that generation terminal and refuses every late reply.

### Preserve executor-neutral lifecycle and atomic document publication

The Runtime client maps protocol, unavailable, busy, launch, sandbox/bootstrap, CPU, memory, wall timeout, cancellation, crash, malformed, limit, and internal failures into bounded `ToolExecutionFailure` cases. It sends success/failure/cancel actions with the original lifecycle generation to the pure reducer. The first legal terminal action wins; stale, duplicate, mismatched, or late replies produce no effects.

No worker or broker can mutate canonical text. Only one complete successful output reaches the existing document-owned publication patch after the reducer authorizes it. A failed validation remains fail-closed in the Wave 1 single-flight Settings save. Existing packages, input/output operations, locks, Merge/Dismiss/Undo, persistence, and recovery behavior do not change solely because execution crossed a process boundary.

### Keep model networking and credentials out of containment processes

The model executor remains a separate concrete Runtime path in the main application composition root. It may lazily access the credential interface and fixed OpenRouter HTTPS transport under the existing bounded model contracts. Neither broker nor worker imports the model transport or Security credential implementation, and no provider request is forwarded through JavaScript IPC. Both executors converge only at `ToolExecutionResult` and lifecycle actions.

### Make containment and dependency provenance release-blocking

Generated-project and packaged-fixture checks recursively inspect Mach-O load commands and symbols: QuickJS/JortJavaScript may occur only in `JortJavaScriptWorker`; the app, every framework, and the broker must be free of it. Runtime process tests confirm the main process never maps the engine while a separate ephemeral worker does.

Signature/entitlement tests verify nested locations, unique identifiers, expected signer relationships, broker sandbox, worker inheritance, Hardened Runtime, and absence of prohibited entitlements. Native denial probes running under the inherited worker sandbox attempt representative user-file reads/writes, network client/server access, Keychain lookup, Apple Events, device access, and subprocess creation. Resource probes bypass QuickJS to prove the OS limits and watchdog. All tests assert the editor/main process survives and no canonical patch is emitted.

Extend the vendored record with imported-file inventory, upstream archive URL/version/SHA-256, reproducible verification/import steps, exact local patch diff, license, last review, and analyzer baseline. Review upstream changes, known vulnerability reports, local patches, and analyzer delta at every Jort release and at least every 90 days; an update or diagnostic change requires dedicated review rather than automatic baseline acceptance. Community/public package import remains blocked until this change and Wave 4 are verified.

## Risks / Trade-offs

- **Risk: The hybrid introduces two helper targets and more failure modes.** → Keep the broker engine-free and protocol-small, specify one terminal state machine, inject launch/pipe/XPC failures, and make Wave 4 derive its manifest from the generated target graph.
- **Risk: A cap that is safe on one OS/toolchain prevents worker bootstrap on another.** → Test signed debug/release helper startup on every supported macOS architecture, verify limits before Ready, fail closed, and require measured security review for policy changes.
- **Risk: XPC has already received bytes before application length checks.** → Authenticate the private peer, use low-level primitive dictionaries, enforce a total send bound in the client, inspect lengths before copying/decoding in the broker, and independently frame/bound the child pipe.
- **Risk: Killing by stale PID could target another process.** → The broker retains the launched child object, serializes termination with exit handling, acts only while ownership is live, and confirms reaping; the main app never sends signals by a remotely observed PID.
- **Risk: Worker compromise attacks the broker through output.** → Broker parsing accepts one fixed header and bounded byte fields, treats output as UTF-8 data only, never deserializes object graphs, and kills on any framing violation.
- **Risk: Four workers can still consume substantial aggregate resources.** → Runtime admission caps active children, each has hard independent address-space/CPU limits, and tests measure aggregate peak use; the broker refuses excess capacity.
- **Trade-off: Process startup makes validation/execution slower.** → Authoring validation is explicit and awaited; execution already exposes asynchronous processing. Security isolation takes precedence, and timings are tracked without weakening limits or reusing engine processes.
- **Trade-off: Main-process model execution remains network-capable.** → It does not execute native QuickJS code, retains its narrow provider contract, and never shares credentials/network objects with containment processes.

## Migration Plan

1. Add protocol constants/types, failure mapping, deterministic codec tests, and fake broker/client implementations behind the extracted validator/executor protocols.
2. Add signed XPC broker and disposable C worker targets, stable identifiers, restrictive entitlements, Hardened Runtime settings, standard nested-code placement, and generated-project dependency tests.
3. Implement worker bootstrap limits/Ready handshake, one-frame QuickJS validation/execution, inherited-descriptor closure, and bounded result framing.
4. Implement broker peer checks, worker signature/path checks, four-child admission, launch/pipes, independent field bounds, watchdog/cancel/kill/reap, and single-terminal reply state.
5. Switch Settings validation and Runtime JavaScript execution to the XPC client while keeping a test-only in-process comparison oracle outside production target dependencies.
6. Run behavioral parity, generation-race, crash/hang/malformed/oversize, native CPU/memory exhaustion, sandbox-denial, signature/entitlement, load-command/symbol, and runtime-mapping tests.
7. Remove production main-process/broker linkage to `JortJavaScript`, delete the in-process executor adapter, and update dependency/provenance/security verification documentation.
8. Keep community import disabled and hand the resulting nested target manifest, identifiers, entitlements, and verification commands to Wave 4.

During steps 1–5, a build flag may select the old executor only in dedicated local comparison tests. It must not exist in shipping configurations. The package and persisted document schemas do not change, so source rollback is possible; public distribution remains blocked if rollback restores in-process QuickJS.

## Open Questions

None at proposal time. The platform design is the XPC-broker/disposable-child hybrid; OS enforcement is `setrlimit` plus broker watchdog/owned-child termination; protocol v1 and its independent bounds are fixed above. The loader-dependent `RLIMIT_NOFILE` numeric constant is the only implementation-calibrated value and must be recorded by the signed bootstrap test before source delivery can be enabled.
