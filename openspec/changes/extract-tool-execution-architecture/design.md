## Context

Jort currently has a sound high-level separation between document, persistence, settings, and AppKit code, but tool execution has crossed those boundaries. `JortSettings` imports `JortJavaScript`, validates packages by calling QuickJS directly, owns provider and OpenRouter types, and exposes execution DTOs. `ToolInvocationController` in AppKit owns packages, prompts, warnings, in-flight tasks, lifecycle transitions, execution dispatch, and document mutations. Consequently, most lifecycle tests require AppKit and the application transitively links the native JavaScript engine through Settings.

This change is preparation for process containment, not containment itself. The extracted boundaries must support a later XPC client without requiring the editor, Settings, or persisted document model to know whether execution is in-process. At the same time, the extraction must preserve native editing behavior, the existing package format, persisted invocation decoding, cancellation races, canonical publication, Merge/Dismiss/Undo behavior, and model-provider failures.

The active `make-tool-authoring-transactional-and-bounded` change remains authoritative for package publication, generation retention, and the single-flight Settings save workflow. This change changes type and dependency ownership around that behavior; it does not replace its index-v2 or UI-transaction decisions.

## Goals / Non-Goals

**Goals:**

- Establish an acyclic module graph in which bounded tool values and lifecycle semantics are independent of AppKit, SQLite, Security, networking, and QuickJS.
- Remove QuickJS, model transport, and provider execution ownership from `JortSettings`.
- Make lifecycle decisions testable through a pure reducer and headless coordinator while keeping canonical document mutations in `JortDocument`.
- Make AppKit a native input/presentation adapter rather than the owner of invocation state or execution jobs.
- Compose concrete persistence, credential, provider, and runtime services lazily at the application boundary.
- Preserve serialized document and package formats and all current product behavior.

**Non-Goals:**

- Moving QuickJS into XPC, adding App Sandbox, or changing the current process-security boundary.
- Changing package discovery, the package manifest schema, provider product behavior, or the catalog precedence rules.
- Redesigning invocation visuals, drawing/layout reconciliation, or the editor's general controller decomposition.
- Changing document transaction performance, line storage, or history representation.
- Moving Keychain items to the Data Protection Keychain or changing release signing identity.

## Decisions

### Use two new modules with a one-way dependency graph

Add `JortToolContracts` and `JortToolRuntime` and enforce this dependency shape in `project.yml`:

```text
JortToolContracts (Foundation-only values, protocols, reducer)
  ↑             ↑                ↑
  │             │                └── JortToolRuntime ── JortJavaScript
  │             ├── JortSettings
  ├── JortDocument
  └── JortAppKit

JortPersistence ── JortDocument
Jort application ── composition of Settings, Runtime, Persistence, and AppKit
```

`JortToolContracts` must not import AppKit, SQLite3, Security, a networking implementation, or `JortJavaScript`. It owns package manifests and executor-neutral package values, package identity/provenance, bounded execution request/result/failure values, executor and validator protocols, lifecycle state/actions/effects, and the pure reducer.

`JortToolRuntime` depends on Contracts and, during this intermediate change, `JortJavaScript`. It owns concrete JavaScript validation/execution, model request construction, provider adapters, dispatcher behavior, in-flight execution coordination, and mapping implementation failures into bounded contract failures. It does not own package persistence or native UI behavior.

`JortSettings` depends on Contracts, not Runtime or JavaScript. It owns preferences, the package index and immutable generation storage, catalog snapshots, authoring models, and credential configuration/storage interfaces. Package source validation that requires a native engine is performed through an injected Contracts protocol implemented by Runtime. Structural manifest validation remains in the pure contract type.

`JortAppKit` depends on Contracts plus its existing document, persistence, and settings modules. It receives executor/coordinator interfaces through initialization; it does not import `JortJavaScript`, construct model providers, or select concrete runtimes. The application target imports and embeds the new modules and is the only production composition root.

Allowing Runtime to depend on Settings was rejected because it would make a future helper/XPC client inherit SQLite, Keychain configuration, and package-storage concepts. Allowing Settings to retain JavaScript validation was rejected because the main-process containment change could not then remove QuickJS without redesigning Settings again.

### Keep persisted anchored invocation records in JortDocument

`ToolInvocation`, `ToolAnchor`, `ToolAnchoredRange`, restoration data, range remapping, validation against `DocumentSnapshot`, and the transaction operations that publish, merge, dismiss, or restore canonical text remain owned by `JortDocument`. These types encode document coordinates and invariants and would force Contracts to depend on the complete document model if moved wholesale.

Contracts instead owns executor-neutral value types such as executor kind, input mode, output operation, package reference, lifecycle phase, captured execution descriptor, generation token, and typed failure. `JortDocument` depends on Contracts and adapts its anchored persisted representation to and from those values. During migration, compatibility type aliases or narrow conversion initializers may preserve source compatibility.

Existing encoded field names, enum raw values, defaults, and recovery sanitization remain unchanged. A fixture encoded by the pre-extraction build must decode identically after extraction, and a post-extraction fixture containing no new behavior must remain readable by the immediately previous build. A document-schema migration was rejected because module ownership alone does not justify changing user data.

### Separate pure lifecycle decisions from side effects

Define a pure reducer in Contracts whose input is a bounded `InvocationLifecycleState` plus a typed action and whose output is the next state plus declarative effects. Actions cover completion acceptance, validation outcome, submit, execution started, result, cancellation, timeout/failure, package reconciliation, Merge, Dismiss, Undo restoration, and document-anchor invalidation. Effects cover validation/execution requests, cancellation, canonical document operations, presentation/focus requests, and persistence/history boundaries.

Every asynchronous action carries both invocation identity and generation. Terminal reduction is single-winner: results for an old generation or a lifecycle that has already transitioned are ignored deterministically. The reducer never calls AppKit, reads a document, starts a task, or performs network/native runtime work.

A headless coordinator in `JortToolRuntime` owns executor tasks and routes reducer-requested validation/execution through an injected `ToolExecutor`. It exposes state changes and effects through bounded Contracts interfaces. The document integration applies only reducer-authorized mutation effects through `JortDocument` transactions, then feeds success or rejection back as typed actions. AppKit captures native events and selection/viewport facts, forwards them, and presents the committed projection; it does not decide legal lifecycle transitions or own execution tasks.

Putting document mutation closures directly inside the reducer was rejected because it would make transitions impure and hard to exhaustively test. Moving canonical text ownership into Runtime was rejected because it would create a second document owner and weaken transaction invariants.

### Snapshot the execution contract at submission

The submitted lifecycle state captures only the validated bounded values required to finish one run: package ID/version and executor kind, entry contract, input/output mode, generation, exact input bytes and hash, output limits, and runtime/provider selection required by the manifest. It does not hold an AppKit view, mutable document, settings store, credential, or package registry.

The coordinator receives an immutable executable package resolved by the catalog at submission. Package/catalog updates affect future submissions and reconciliation according to existing migration rules; they do not silently replace code or provider parameters for a run already in flight. Runtime results contain either one complete bounded output or one typed failure and never contain presentation objects.

### Inject provider and credential access and initialize lazily

The application composition root constructs Settings/package storage, the credential source, provider-specific transport factories, runtime validators/executors, and the editor integration. Runtime accepts narrow closures/protocols for credential access and provider construction. It obtains a credential only when an authenticated model run or connection workflow requires one and does not persist it.

Provider catalogs and request descriptors use Contracts values. Provider-specific HTTP/OAuth behavior and response decoding move to Runtime; UI-facing connection actions are exposed as injected services. Keychain storage can remain implemented in Settings for this change, but Runtime accesses it only through a bounded credential-provider interface. This preserves the later release-identity migration without making Runtime depend on the settings database.

Eager singleton initialization was rejected because launching Settings or the editor should not initialize QuickJS or a network provider. A general service locator was rejected because it would hide dependency direction and make tests depend on global state.

### Preserve authoring validation through layered validators

Manifest, package path, size, and executor-shape validation lives in Contracts and Settings as appropriate. Executor-specific validation is represented by an injected async validator interface. Runtime supplies QuickJS and model/provider-aware implementations; Settings combines their diagnostics with structural authoring diagnostics inside the single-flight save operation specified by `make-tool-authoring-transactional-and-bounded`.

The package registry never imports Runtime. The application supplies the validator when constructing the registry/store workflow, and tests inject deterministic fakes. A missing runtime validator fails closed for package execution and produces a bounded authoring diagnostic rather than treating unvalidated source as executable.

### Split tests by authority rather than only by source file

Create headless contract/reducer and runtime test groups that do not initialize `NSApplication`, `NSWindow`, or `NSTextView`. Move lifecycle transition matrices, generation/cancellation races, package reconciliation, exact captured input, executor dispatch, and provider failure mapping out of `ToolInvocationTests.swift`. Keep native tests for command completion integration, selection and marked text, locked-range editing, viewport/focus restoration, accessibility, drawing geometry, and end-to-end document transaction integration.

Add a dependency audit that fails when Contracts imports a forbidden framework, Settings imports Runtime/JavaScript, AppKit imports JavaScript or concrete provider transport, or the application bypasses the composition entry points. Generated-project build tests must build every new target and the relevant headless/native suites.

## Risks / Trade-offs

- **Risk: A behavior-preserving extraction subtly changes serialized invocation data.** → Keep anchored persistence in Document, retain field names/raw values/defaults, and add bidirectional golden-fixture tests before moving logic.
- **Risk: Reducer state and canonical document state diverge.** → Treat successful document transactions as acknowledged effects, feed their result back into the reducer, reject stale generations, and rebuild transient coordinator state from sanitized document projections on load.
- **Risk: The new protocols become a wide abstraction of the current controller.** → Pass bounded immutable values and typed effects, avoid exposing views/stores/coordinators, and enforce import boundaries with tests.
- **Risk: Injected validation weakens package-save guarantees.** → Fail closed when executor validation is unavailable and keep validation inside the exact owned save result established by Wave 1.
- **Risk: Moving provider/authentication code overlaps later Keychain identity work.** → Preserve the credential store behavior and query format; move only ownership and inject access so the release change has one well-defined interface to migrate.
- **Trade-off: Runtime still links QuickJS in the main process after this change.** → This is an intentional intermediate boundary; third-party/community package support remains blocked until `sandbox-javascript-execution` replaces the concrete executor.
- **Trade-off: More framework targets increase packaging work.** → Make the project manifest authoritative and require later signed-distribution validation to derive the final embedded target set from the post-extraction graph.

## Migration Plan

1. Add `JortToolContracts` with executor-neutral types, protocols, reducer state/actions/effects, and forbidden-import tests; add golden fixtures for current package and invocation encoding.
2. Make `JortDocument` depend on Contracts, retain its anchored persisted representation, and add explicit projection/conversion helpers plus document-transaction integration tests.
3. Make `JortSettings` depend on Contracts, move manifest/package/execution contract values to Contracts, and replace direct `ToolRuntime` validation with an injected fail-closed validator while preserving the active index-v2 design.
4. Add `JortToolRuntime`, move QuickJS execution, dispatcher/model request/provider/transport behavior behind Contracts protocols, and add headless fake-executor/provider tests.
5. Implement the pure reducer and headless coordinator; move lifecycle, reconciliation, race, failure, and exact-input tests out of the AppKit suite.
6. Replace AppKit lifecycle decisions and job ownership with a narrow adapter that translates native events and applies reducer effects through existing document transactions.
7. Move concrete construction to the application root, prove runtime/provider initialization is lazy, and add module dependency/import audits.
8. Run golden persistence/package tests, settings authoring tests, headless lifecycle/runtime tests, native text-system tests, and UI smoke tests before deleting compatibility shims.

The work should land in compilation-preserving stages. If rollback is required before compatibility shims are removed, the old implementation remains behind the same contract interfaces. Once files have moved, rollback is a source rollback only; no user-data reversal is required because persisted schemas do not change.

## Open Questions

- Select final concrete type and target names during implementation while preserving the required ownership graph; avoid renaming public product concepts merely to mirror framework names.
- Determine whether the provider connection workflow belongs entirely in Runtime or is split into a Runtime transport plus a Settings-owned credential/configuration facade. Either choice must keep provider HTTP types out of Settings persistence and credential bytes out of lifecycle state.
- Decide whether the dependency audit is best implemented as a small repository script, a project-generation assertion, or both; it must run in the normal first-party quality lane.
