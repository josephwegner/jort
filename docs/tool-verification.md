# Tool implementation verification

Local verification, updated September 28, 2026. JavaScript containment is being implemented by `sandbox-javascript-execution`; release identity and distribution qualification remain in `establish-signed-release-and-app-identity`.

## Implementation and authority audit

Bundled and installed definitions enter `ToolPackageRegistry` as the same `ToolPackage` type and pass the same compile-only broker/worker validator. Execution crosses `JortToolRuntime` → `JortJavaScriptClient` → private `JortJavaScriptBroker.xpc` → a new `JortJavaScriptWorker` process. None of the bundled command names select an in-process native executor. Bundled files are immutable application resources. User edits publish immutable generations through an atomic index, and restore selects the current bundled version while retaining old user files.

Only the disposable worker links QuickJS, without its command-line tools, standard-library module, or OS bindings. The app, Runtime, client framework, and broker contain no engine. The worker installs no module loader, network client, filesystem interface, process/shell runner, provider, native application object, plugin interface, or external-executable interface. Clock and UUID arrive as captured primitive values on the frozen input object. Math.random and Date are unavailable. Compilation occurs before `JS_DisableEval`; eval and function-constructor paths cannot compile new source afterward. Imports are rejected. Each run gets a fresh 16 MiB QuickJS heap and 512 KiB engine stack, bounded protocol/result handling, CPU and wall deadlines, and broker-owned cancellation/termination/reaping.

The broker has its own App Sandbox; the worker inherits that sandbox as nested signed code. The worker receives only a normalized contract, source, captured input metadata, correlation UUIDs, and numeric bounds. It receives no path, bookmark, credential, provider, store, document, or application callback. The API restrictions remain defense in depth; OS process/sandbox separation is the containment boundary. Jort deliberately has no process-memory watchdog or deterministic whole-process memory ceiling. macOS handles native/system memory pressure, while QuickJS retains its engine-heap bound. Public/community package import stays disabled pending the Wave 4 signed release gate.

Local Debug and Release qualification builds are ad-hoc signed. Their peer-verification fallback applies only when both sides lack a Team ID and bear ad-hoc signatures; matching Team-signed builds use the stricter Team requirement. Wave 4 must replace the local signing setup with Developer ID and requalify the production identity path.

Adversarial tests cover ambient authority, constructor/eval variants, imports, frozen input, duplicate promise resolution, hostile exceptions, CPU timeout, memory exhaustion, output bounds, and cancellation races. These checks establish the exposed host contract; they are not an independent security review of the vendored C engine.

The existing Settings → Tools panel now edits the same packages the editor consumes, as explicitly authorized for this change. No new Settings window architecture, marketplace/distribution interface, permission-granting system, agent, model provider, streaming output, or background-agent run was added. Package directory installation is a registry API; it does not introduce a marketplace UI.

## Evidence

- Child-protocol tests cover maximum legal frames, UUID correlation, malformed versions/lengths, invalid UTF-8/NUL, truncation, hash mismatch, trailing bytes, and the Ready handshake. A real broker-path fixture passed 20 capacity, launch, signature, framing, crash, hang, cancellation, watchdog, late-reply, and cleanup tests (`.build-validation/20260926T134438Z-18410`), including rejection of wrong-identifier and tampered signed workers. A separate signed named-XPC test passed an initial real request, then killed only the exact-path disposable broker while its verified worker was active; the production client delivered one `unavailable` terminal outcome with no output, stable request descriptors, and no surviving worker (`.build-validation/20260928T153457Z-22850`).
- Behavioral parity tests launch a nonshipping one-run process fixture; the fixture is never embedded in `Jort.app` and never links QuickJS into XCTest.
- Production Runtime tests use injected transports for admission, cancellation, bounded primitive requests, and typed failures. The focused Runtime suite passed 15 tests, restoring real disposable-worker coverage for eval/constructor and import denial, absent ambient globals, UTF-8 and output boundaries, duplicate resolution, frozen input, concurrent cancellation, and loop/stack failures (`.build-validation/20260926T135145Z-20790`). The coordinator suite passed 7 tests, including terminal nonpublication with a responsive unrelated invocation (`.build-validation/20260926T134558Z-18669`). An app-level matrix covering all 13 terminal broker codes passed, preserving canonical invocation/text, permitting an unrelated edit and a later healthy invocation for each (`.build-validation/20260928T153552Z-23007`). A signed Release UI test completed the actual bundled `/calc` broker workflow and relaunch with one test passed (`.build-validation/20260926T135622Z-22700`).
- A September 26 locally signed Release bundle passed deep signature, exact helper entitlement, Hardened Runtime, nested-path, and recursive QuickJS dependency/symbol and live mapping inspection (`.build-validation/20260926T135754Z-23410`). Signed native probes passed for file read/write, network client/server, subprocess and disposable Keychain-item denial, CPU-limit termination/reaping, and QuickJS heap exhaustion followed by a successful fresh worker through production broker helpers. A signed USB probe opened and immediately closed the connected Yubico service in an unsandboxed control, then observed explicit inherited-sandbox denial against the same service (`.build-validation/20260926T131414Z-13848`). The opt-in Apple Events fixture passed with a separate signed sender receiving `pong` before and after the inherited worker attempt; only the worker received `-600`, while `appleeventsd` logged its receiver lookup as denied due to sandboxing (`.build-validation/20260926T135459Z-22379`). The ordinary Foundation lane skips this consent-requiring test (`.build-validation/20260926T135551Z-22520`). Full app recovery after heap exhaustion remains unverified; that is not claimed by the one-run heap fixture.
- Rendered captures were inspected for wrapped and multiline source, pending source/output seams, per-invocation controls, processing, and canonical line numbers. Controls are accessibility elements and do not enter canonical text.
- The September 27 gate passed format, project generation, Foundation (including the live worker-mapping and reap test), native (132 tests, zero failures), and packaging tests before stopping at an Engineering-scheme coverage audit (`.build-validation/20260927T193142Z-86654`). The missing test-fixture target was added to that scheme; fresh focused format/project, first-party analysis, and QuickJS audit lanes then passed (`.build-validation/20260927T193907Z-89267`, `.build-validation/20260927T193912Z-89481`, `.build-validation/20260927T193925Z-89695`). Release packaging and its signed containment verification passed separately (`.build-validation/20260926T135754Z-23410`). A focused Debug UI attempt timed out enabling macOS automation mode before either selected test began (`.build-validation/20260927T193947Z-89745`); it is a runner failure, not a test result. The signed Release UI workflow above did run and pass. Per the focused-validation approach, the passing Foundation/native lanes were not rerun after the scheme-list-only edit, and no green aggregate gate is claimed.

## Performance observations

Debug build on this machine; these are measurements, not performance acceptance. The editor benchmark uses `CrawlLargeDocument`, with 25,000 logical lines and 1,000,000 UTF-16 units, plus the invocation line. Values below are nearest-rank p95 from local runs.

| Operation | p95 |
| --- | ---: |
| Discover six bundled packages | 2.65 ms |
| Validate calculator package | 0.49 ms |
| Start JavaScript host and calculate | 0.78 ms |
| Refresh visible connected geometry | 3.03 ms |
| Accept invocation in large document | 373.81 ms |
| Move contextual boundary across full document | 217.24 ms |
| Validate, submit, and publish | 536.70 ms |
| Dismiss result transaction | 301.26 ms |

Geometry is bounded by the laid-out viewport. Complete document transitions still incur substantial snapshot, validation, line metadata, and persistence work. Existing foundation measurements also retain the previously documented save/history performance concerns. No claim of performance qualification is made.

## Remaining release checks

Earlier runner infrastructure problems were overcome for the two real-application tool workflows. Direct `xctest` remains useful for foundation and AppKit checks; neither test path replaces a physical IME/VoiceOver journey.

Before release, Wave 4 must consume the recorded broker/client/worker graph, assign the real Team ID and Developer ID identities, notarize/staple, repeat signed entitlement and sandbox-denial probes, and keep QuickJS confined to the worker. Physical IME and VoiceOver checks and the established visual/performance baselines also remain release work.
