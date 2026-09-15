## 1. Protect Existing Contracts

- [x] 1.1 Add golden package and persisted-invocation fixtures covering executor defaults, phases, anchors, restoration data, hashes, and current Codable field/raw-value compatibility.
- [x] 1.2 Add behavior-characterization tests for the existing invocation transition matrix, package reconciliation, exact input capture, canonical publication intents, Merge/Dismiss/Undo, and cancellation/result races before moving ownership.
- [x] 1.3 Record the current target/import graph and add a failing dependency-audit fixture for forbidden Contracts, Settings, AppKit, Runtime, and QuickJS edges.

## 2. Establish Tool Contracts

- [x] 2.1 Add the Foundation-only `JortToolContracts` framework target, its headless test coverage, and project-generation/build configuration.
- [x] 2.2 Move or introduce bounded `Sendable` package identity, manifest, executor kind, input/output mode, output operation, executable-package, request, result, failure, cancellation, validator, executor, credential, and provider contract types.
- [x] 2.3 Implement lifecycle state, typed actions, declarative effects, generation tokens, and the deterministic pure reducer with no UI, document, persistence, clock, network, filesystem, or native-runtime side effects.
- [x] 2.4 Add reducer tests for every legal phase transition, effect acknowledgement, stale action, package reconciliation, interrupted-restoration path, and single-winner cancellation/timeout/failure/success race.

## 3. Keep Canonical Invocation State Document-Owned

- [x] 3.1 Make `JortDocument` depend on Contracts while retaining document anchors, anchored ranges, range remapping, snapshot validation, restoration records, and canonical invocation transactions in the document module.
- [x] 3.2 Add explicit adapters between persisted document invocation records and bounded lifecycle/package contract values without changing encoded fields, raw values, defaults, or sanitization.
- [x] 3.3 Add acknowledged transaction-effect entry points for publish, Merge, Dismiss, restoration, and stale-effect rejection so reducer decisions can be applied atomically without Runtime or AppKit owning canonical state.
- [x] 3.4 Prove pre-extraction fixtures decode identically, unchanged post-extraction values remain backward-readable, and stale anchors/hashes/revisions/generations cause no partial mutation.

## 4. Decouple Settings and Package Storage

- [x] 4.1 Make `JortSettings` depend on Contracts and move package/manifest/execution value ownership out of Settings while preserving source compatibility through temporary aliases or adapters.
- [x] 4.2 Remove the `JortJavaScript` dependency and every direct `ToolRuntime` call from Settings and the package registry.
- [x] 4.3 Layer structural validation with an injected async executor-specific validator that fails closed and participates in the exact Wave 1 single-flight save result.
- [x] 4.4 Reconcile the extracted contract types with index-v2 generation publication, retention, deletion, restoration, and trusted cleanup without changing those active Wave 1 semantics.
- [x] 4.5 Add Settings/package tests using deterministic fake validators and verify slow async package validation does not delay editor readiness or typing, while Settings uses injected validators and provider transports remain lazy.

## 5. Introduce the Runtime Boundary

- [x] 5.1 Add `JortToolRuntime` with dependencies on Contracts and the current `JortJavaScript` framework, and move concrete QuickJS validation/execution behind the injected validator/executor protocols.
- [x] 5.2 Move model request construction, output bounding, provider protocols/adapters, curated provider catalog behavior, HTTP transport, and implementation-failure mapping behind Runtime contracts.
- [x] 5.3 Expose lazy credential and provider factories so credential bytes and transport objects never enter Settings snapshots, lifecycle state, AppKit, or executor-neutral results.
- [x] 5.4 Implement the headless execution coordinator that owns validation/execution tasks, routes reducer effects, correlates acknowledgements by invocation and generation, and ignores late or duplicate outcomes.
- [x] 5.5 Add headless runtime tests for JavaScript/model dispatch, lazy initialization, exact bounded requests, provider and validator failures, cancellation, output limits, and immutable in-flight package capture.

## 6. Reduce AppKit to Integration and Presentation

- [x] 6.1 Replace lifecycle transition logic, package/runtime selection, prompts/warnings authority, and executor-task ownership in `ToolInvocationController` with a narrow adapter over the injected headless coordinator.
- [x] 6.2 Translate completion, Submit, Cancel, Merge, Dismiss, Undo/restoration, selection, focus, viewport, marked-text, and document-change facts into contract actions and apply only reducer-authorized document effects.
- [x] 6.3 Update AppKit presentation to render committed lifecycle/document projections without importing QuickJS, concrete provider transports, or assigning authoritative phases directly.
- [x] 6.4 Preserve native integration coverage for completion, marked text, locked-range editing, selection/focus/viewport restoration, accessibility, geometry, and end-to-end transaction behavior.

## 7. Compose and Enforce the Architecture

- [x] 7.1 Move production construction of Settings, catalog, credential access, runtime validators/executors, provider factories, lifecycle coordinator, persistence, and AppKit adapters into the application composition root.
- [x] 7.2 Update application embeddings, runpaths, schemes, headless/native test targets, and package-manifest expectations for `JortToolContracts` and `JortToolRuntime` without finalizing release signing policy.
- [x] 7.3 Enable the dependency/import audit so CI rejects forbidden imports, Settings-to-Runtime/JavaScript coupling, AppKit-to-QuickJS/provider coupling, and mutable global service lookup.
- [x] 7.4 Split `ToolInvocationTests.swift` into headless reducer/contract/runtime suites and focused native integration suites, then remove obsolete compatibility shims and duplicate implementations.
- [x] 7.5 Run strict OpenSpec validation, project generation/builds, golden persistence/package tests, Settings tests, headless lifecycle/runtime suites, native AppKit suites, and UI smoke tests; document that QuickJS remains in-process until the Wave 3 sandbox change.
