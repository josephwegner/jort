# Tool implementation verification

Local verification, updated October 2, 2026. JavaScript containment is being implemented by `sandbox-javascript-execution`; release identity and distribution qualification remain in `establish-signed-release-and-app-identity`.

## Implementation and authority audit

Bundled and installed definitions enter `ToolPackageRegistry` as the same `ToolPackage` type and pass the same compile-only broker/worker validator. Execution crosses `JortToolRuntime` → `JortJavaScriptClient` → private `JortJavaScriptBroker.xpc` → a new `JortJavaScriptWorker` process. None of the bundled command names select an in-process native executor. Bundled files are immutable application resources. User edits publish immutable generations through an atomic index, and restore selects the current bundled version while retaining old user files.

Only the disposable worker links QuickJS, without its command-line tools, standard-library module, or OS bindings. The app, Runtime, client framework, and broker contain no engine. The worker installs no module loader, network client, filesystem interface, process/shell runner, provider, native application object, plugin interface, or external-executable interface. Clock and UUID arrive as captured primitive values on the frozen input object. Math.random and Date are unavailable. Compilation occurs before `JS_DisableEval`; eval and function-constructor paths cannot compile new source afterward. Imports are rejected. Each run gets a fresh 16 MiB QuickJS heap and 512 KiB engine stack, bounded protocol/result handling, CPU and wall deadlines, and broker-owned cancellation/termination/reaping.

The broker has its own App Sandbox; the worker inherits that sandbox as nested signed code. The worker receives only a normalized contract, source, captured input metadata, correlation UUIDs, and numeric bounds. It receives no path, bookmark, credential, provider, store, document, or application callback. The API restrictions remain defense in depth; OS process/sandbox separation is the containment boundary. Jort deliberately has no process-memory watchdog or deterministic whole-process memory ceiling. macOS handles native/system memory pressure, while QuickJS retains its engine-heap bound. Public/community package import stays disabled pending the Wave 4 signed release gate.

Local Debug and packaged Release qualification builds are ad-hoc signed. Peer admission defaults to denying ad-hoc signatures: Debug explicitly opts in, and `scripts/build.sh` passes `JORT_JS_ALLOW_ADHOC=1` to both local Release compilation and resolved-settings capture. Plain Release inherits the strict default. The production pipeline explicitly passes `0` to both commands, and production manifest generation rejects missing, enabled, conflicting, or unresolved compiler definitions for the client and broker. The local fallback still requires both peers to lack a Team ID, bear ad-hoc signatures, and match their sealed identities; matching Team-signed builds use the stricter Team requirement. No helper entitlement changes accompany this fix. Wave 4 must replace local signing with Developer ID and requalify the production identity path.

RegExp and typed arrays are enabled for bounded pure text processing. RegExp execution uses the installed interrupt callback, and typed-array allocations use the same 16 MiB engine heap. Contract 2 captures are recursively frozen; protocol validators capture their intrinsics and freeze the object, array, string, RegExp, and function prototypes before module evaluation. Date, Math.random, dynamic evaluation, and I/O remain disabled. No broker or worker entitlement changes accompany these intrinsics.

Adversarial tests cover ambient authority, constructor/eval variants, imports, frozen input, duplicate promise resolution, hostile exceptions, CPU timeout, memory exhaustion, output bounds, and cancellation races. Protocol 2 adds own-data-property result validation, nested field allowlists, exclusive text/report/action/error variants, exact captured action content, and independent JSON-envelope limits. These checks establish the exposed host contract; they are not an independent security review of the vendored C engine.

The existing Settings → Tools panel now edits the same packages the editor consumes, as explicitly authorized for this change. No new Settings window architecture, marketplace/distribution interface, permission-granting system, agent, model provider, streaming output, or background-agent run was added. Package directory installation is a registry API; it does not introduce a marketplace UI.

## Evidence

- Child-protocol tests cover maximum legal frames, UUID correlation, malformed versions/lengths, invalid UTF-8/NUL, truncation, hash mismatch, trailing bytes, and the Ready handshake. A real broker-path fixture passed 20 capacity, launch, signature, framing, crash, hang, cancellation, watchdog, late-reply, and cleanup tests (`.build-validation/20260926T134438Z-18410`), including rejection of wrong-identifier and tampered signed workers. A separate signed named-XPC test passed an initial real request, then killed only the exact-path disposable broker while its verified worker was active; the production client delivered one `unavailable` terminal outcome with no output, stable request descriptors, and no surviving worker (`.build-validation/20260928T153457Z-22850`).
- Behavioral parity tests launch a nonshipping one-run process fixture; the fixture is never embedded in `Jort.app` and never links QuickJS into XCTest.
- Production Runtime tests use injected transports for admission, cancellation, bounded primitive requests, and typed failures. The focused Runtime suite passed 15 tests, restoring real disposable-worker coverage for eval/constructor and import denial, absent ambient globals, UTF-8 and output boundaries, duplicate resolution, frozen input, concurrent cancellation, and loop/stack failures (`.build-validation/20260926T135145Z-20790`). The coordinator suite passed 7 tests, including terminal nonpublication with a responsive unrelated invocation (`.build-validation/20260926T134558Z-18669`). An app-level matrix covering all 13 terminal broker codes passed, preserving canonical invocation/text, permitting an unrelated edit and a later healthy invocation for each (`.build-validation/20260928T153552Z-23007`). A signed Release UI test completed the actual bundled `/calc` broker workflow and relaunch with one test passed (`.build-validation/20260926T135622Z-22700`).
- A September 26 locally signed Release bundle passed deep signature, exact helper entitlement, Hardened Runtime, nested-path, and recursive QuickJS dependency/symbol and live mapping inspection (`.build-validation/20260926T135754Z-23410`). Signed native probes passed for file read/write, network client/server, subprocess and disposable Keychain-item denial, CPU-limit termination/reaping, and QuickJS heap exhaustion followed by a successful fresh worker through production broker helpers. A signed USB probe opened and immediately closed the connected Yubico service in an unsandboxed control, then observed explicit inherited-sandbox denial against the same service (`.build-validation/20260926T131414Z-13848`). The opt-in Apple Events fixture passed with a separate signed sender receiving `pong` before and after the inherited worker attempt; only the worker received `-600`, while `appleeventsd` logged its receiver lookup as denied due to sandboxing (`.build-validation/20260926T135459Z-22379`). The ordinary Foundation lane skips this consent-requiring test (`.build-validation/20260926T135551Z-22520`). Full app recovery after heap exhaustion remains unverified; that is not claimed by the one-run heap fixture.
- Rendered captures were inspected for wrapped and multiline source, pending source/output seams, per-invocation controls, processing, and canonical line numbers. Controls are accessibility elements and do not enter canonical text.
- The September 27 gate passed format, project generation, Foundation (including the live worker-mapping and reap test), native (132 tests, zero failures), and packaging tests before stopping at an Engineering-scheme coverage audit (`.build-validation/20260927T193142Z-86654`). The missing test-fixture target was added to that scheme; fresh focused format/project, first-party analysis, and QuickJS audit lanes then passed (`.build-validation/20260927T193907Z-89267`, `.build-validation/20260927T193912Z-89481`, `.build-validation/20260927T193925Z-89695`). Release packaging and its signed containment verification passed separately (`.build-validation/20260926T135754Z-23410`). A focused Debug UI attempt timed out enabling macOS automation mode before either selected test began (`.build-validation/20260927T193947Z-89745`); it is a runner failure, not a test result. The signed Release UI workflow above did run and pass. Per the focused-validation approach, the passing Foundation/native lanes were not rerun after the scheme-list-only edit, and no green aggregate gate is claimed.

## Local Release tool discovery regression (October 2, 2026)

The packaged Release app previously compiled without local ad-hoc peer support.
JavaScript startup validation therefore excluded its packages from slash
completion, while model packages bypassed that validator and Settings continued
to list the bundled templates. Debug-only UI tests did not cover this mismatch.

The fresh package build, packaging fixtures, and binary containment inspection
passed in `.build-validation/20261002T171155Z-93880`. Its initial packaged UI
attempt could not launch after attempting to terminate an existing Jort process;
that attempt is not runtime verification. After the user closed running copies,
the packaged UI rerun passed in `.build-validation/20261002T172229Z-98278`.
It explicitly launched `dist/Jort.app` with an isolated data directory, discovered
`/now`, `/today`, `/copy-rich`, and `/lorem` in editor completion, executed and
merged `/lorem`, then verified saved content and JavaScript discovery on relaunch.
The Debug build supplied the test runner, not the app under test.

The `package`, `ci-test`, and `all` lanes now include this packaged-app check.
Changed-file routing rebuilds Release before running it; ordinary Debug UI tests
exclude its separate class. Twelve dispatcher self-tests passed, including both
packaged source/script routing cases. Independent review confirmed the signing
guards and resolved a missing changed-file routing case. The final full gate
passed all nine checks in `.build-validation/20261002T172354Z-98710`.
Actual Developer ID distribution remains a separate credentialed qualification;
these local tests do not claim it, notification delivery, or VoiceOver feedback.

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

## Expanded utility catalog qualification (October 2, 2026)

The change `expand-bundled-tool-utilities` implements 40 catalog commands:
35 JavaScript packages and five model packages. Model fixtures use the existing
executor with injected provider responses, not paid requests. Scripts expose
readable customization constants and are self-contained teaching examples.
`/gist` is not included.

The final protocol review found inherited optional result fields could run
untrusted getters. Root results, nested actions, and landmarks now copy only
validated own data-property values into null-prototype records before reading
fields. Disposable-worker regressions verify that inherited optional getters
never execute and inherited required fields cannot provide action authority.
All 23 runtime tests passed in `.build-validation/20261002T022836Z-8779`.

Independent review also required disclosure of native effects before submission,
even when a custom package supplies an innocuous description. Inputting action
invocations now show wrapping, accessible clipboard/file/notification destination
descriptions derived from the manifest used by Submit. The disclosure regression
and three legacy Undo restoration cases passed together (four tests) in
`.build-validation/20261002T145133Z-39120`. Contract 1 retains absent argument
metadata rather than adding an empty dictionary to its pre-submit restoration.
The reviewer confirmed both fixes and found no further material regressions.

The signed production-worker heap probe now sends a valid contract-1 request and
checks protocol-2 JSON output. Its explicit typed-array allocation exceeds the
unchanged 16 MiB heap, followed by a successful fresh 1 MiB worker and reaping;
the probe passed in `.build-validation/20261002T145210Z-39319`. Packaging fixtures
passed in `.build-validation/20261002T145705Z-39817` with the Xcode developer
directory explicitly selected.

Four signed-app UI flows passed in `.build-validation/20261002T154905Z-47325`:
bundled generation/Merge/save/relaunch; contextual keyboard accept/edit/Escape/
re-entry/Submit; model discovery; and a custom-tool draft/save/invocation. Tests
wait for catalog completion or enabled Settings controls instead of treating an
editable document window as proof that package validation has finished. The
contextual pending-output expectation respects insertion immediately after the
token and before its owned acceptance separator. Initial editor/Settings focus
uses a pointer; the argument interaction itself is keyboard-only.

Final full-gate evidence is in `.build-validation/20261002T155244Z-49266`.
Format, project consistency, foundation, native, packaging, first-party analysis,
QuickJS audit, and signed-app containment all passed. The aggregate gate failed
in the UI lane: the custom-tool test advanced before asynchronous saves finished,
and later tests lost macOS automation access during the interrupted session.
Only test synchronization changed afterward: each custom-tool save now waits
for its completion feedback before toggling enablement or closing Settings.
The fresh full UI lane passed all eight tests and signed-app containment in
`.build-validation/20261002T161641Z-66311`. Unchanged passing gate lanes were
not repeated; this is combined final evidence, not a claim that the earlier
aggregate gate returned success. Strict OpenSpec validation and diff whitespace
checks also passed.

Native fixtures use isolated pasteboards/export destinations and an injected
notification boundary. They cover rich RTF/HTML/plain representations, exact
UTF-8 export, cancellation/errors, durable reminder receipts, unknown acceptance,
full captured details, retention, cancellation, and no automatic replay.
Keyboard integration covers initial focus, traversal, invalid-field correction,
Escape/re-entry, and offscreen remount without lost arguments. This is not proof
of physical notification delivery or a VoiceOver usability session.

### Physical qualification (user-confirmed)

The user confirmed completing all outstanding signed-app manual checks with
"I've tested all of those. Good to go." This is user-reported qualification,
not an agent-observed session or additional automated evidence. The confirmed
checklist was:

- Paste `/copy-rich` output into rich-text and plain-text targets.
- Export to a disposable existing file, cancel overwrite once, then confirm;
  verify exact bytes and accurate feedback.
- Schedule `/remind 1`, allow notifications if desired, edit the source, exit
  Jort, and verify OS delivery and full captured text on activation. Repeat with
  denied permission and pending cancellation. Delivery follows Focus/settings.
- Try argument fields with keyboard-only editing and VoiceOver, including an
  invalid delay and scrolling away/back. Gather feedback on this experimental UI.
- Exercise argument/report controls, Tab/Shift-Tab, Escape/re-entry, error
  correction, and offscreen/remounted controls without a pointer.
- Verify `/daily` landmark navigation and atomic text/landmark Undo/Redo.

The user's overall usability feedback was "Good to go"; no blocking issues or
environmental limits were reported. Build identity, OS version, paste-target
names, screenshots, and per-step observations were not supplied. Task 8.2 is
closed on the user's confirmation, without inferring those details. Automated
fixtures still do not establish physical notification delivery or accessibility
usability; notification delivery remains subject to Focus and system settings.

### Safe rollback

Disable new action packages in Settings without deleting overrides, receipts,
or note text. Resolve active invocations with Merge, Done, or Dismiss as
appropriate; preserve a recovery copy and the private data directory before
downgrading. An older build cannot be assumed to decode contract-2 or completed
action annotations. Never retry an unknown action automatically. Downgrading
does not cancel an OS reminder or undo clipboard/file changes; cancel pending
reminders from this build first when desired. Preserve legacy enablement and
user source files.
