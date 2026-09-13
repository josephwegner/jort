## 1. Executor-discriminated tool packages

- [x] 1.1 Add versioned `javascript` and `model` tool implementations while decoding legacy definitions without an executor as JavaScript.
- [x] 1.2 Update package loading and writing so JavaScript packages require `tool.js` and model packages require bounded instructions and a bundled model identifier.
- [x] 1.3 Extend manifest, registry, catalog, conflict, enablement, override, and compatibility validation for both executor types.
- [x] 1.4 Migrate existing Settings definitions and drafts without changing JavaScript source, enablement, identity, or template ancestry.
- [x] 1.5 Add package, migration, malformed-definition, conflicting-command, unsupported-model, and JavaScript-backward-compatibility tests.

## 2. Bundled model catalog and Tools Settings

- [x] 2.1 Define and bundle a versioned curated OpenRouter model catalog with stable identifiers, friendly names, restrained metadata, and bounded decoding.
- [x] 2.2 Preserve model selections removed by later catalogs as unavailable diagnostics without silently substituting another model.
- [x] 2.3 Add the executor selector and executor-specific draft state to the existing Tools pane.
- [x] 2.4 Add a bounded plain-text instructions editor and compact filterable, keyboard-accessible model picker for model-backed tools.
- [x] 2.5 Confirm destructive executor changes while keeping ordinary Save free of execution, authentication, and connection checks.
- [x] 2.6 Add disconnected authoring, filtering, selection persistence, draft conflict, executor transition, validation, resize, keyboard, and accessibility tests.

## 3. OAuth and credential foundation

- [x] 3.1 Add dependency-injected Keychain credential storage and bounded nonsecret OpenRouter connection-status persistence.
- [x] 3.2 Implement cryptographically random PKCE verifier generation, S256 challenges, bounded attempt correlation, expiration, and loopback callback handling.
- [x] 3.3 Implement redacted OAuth code exchange and current-key verification against fixed OpenRouter HTTPS endpoints.
- [x] 3.4 Implement atomic Connect and Replace behavior that preserves an existing credential until its replacement verifies.
- [x] 3.5 Implement explicit Check Connection and local Disconnect behavior with remote-revocation explanation and OpenRouter account navigation.
- [x] 3.6 Add success, cancellation, timeout, mismatch, replay, malformed response, authentication failure, offline, replacement rollback, Keychain fault, and secret-isolation tests.

## 4. Models Settings pane

- [x] 4.1 Register a Models pane through the existing Settings workspace and preserve normal pane navigation and draft-transition behavior.
- [x] 4.2 Build the OpenRouter connection card for Not Connected, Connecting, Connected, Unable to Verify, and Connection Needs Attention states.
- [x] 4.3 Wire Connect, Check Connection, Replace Connection, Disconnect, and account-management actions without any manual credential field or reveal path.
- [x] 4.4 Add status, no-network-on-open, replacement, disconnection, keyboard-order, window-sizing, and accessibility tests.

## 5. Model provider and executor dispatch

- [x] 5.1 Define immutable bounded model request, response, availability, cancellation, and typed-failure contracts.
- [x] 5.2 Implement a deterministic fake provider for success, delay, cancellation races, timeout, malformed output, authentication failure, and limit violations.
- [x] 5.3 Implement a fixed-origin OpenRouter provider using nonstreaming chat completion with no provider tool calls.
- [x] 5.4 Enforce request timeout, transport, decoding, output-token, byte, and line limits with exactly one terminal result.
- [x] 5.5 Refactor tool execution behind a shared dispatcher while retaining the existing JavaScript runtime unchanged.
- [x] 5.6 Add request-shape, fixed-origin, redaction, lazy initialization, cancellation, malformed-response, output-limit, and JavaScript-regression tests.

## 6. Shared invocation lifecycle integration

- [x] 6.1 Publish valid enabled model-backed tools into ordinary slash completion even while OpenRouter is disconnected.
- [x] 6.2 Validate instructions, bundled model availability, and local connection presence before locking submitted source.
- [x] 6.3 Capture immutable tool identity, executor contract, model, instructions, content, anchors, hashes, input mode, and output operation for each generation.
- [x] 6.4 Dispatch model-backed tools through the existing submitted, processing, cancellation, error, pending-output, Merge, Dismiss, Escape, and Undo paths.
- [x] 6.5 Update Models connection status after provider authentication failures without exposing credentials or disabling JavaScript tools.
- [x] 6.6 Add contained, contextual, ephemeral, disconnected, concurrent editing, cancellation race, output publication, Merge, Dismiss, Undo/Redo, and accessibility tests.

## 7. Bundled model-backed tools and recovery

- [x] 7.1 Add `/ask` as an ordinary bundled model tool using `ephemeralMultiline` and `insert-at-invocation`.
- [x] 7.2 Add `/rewrite` as an ordinary bundled model tool using `contextual` and `replace-context`.
- [x] 7.3 Verify both templates use the ordinary registry, enablement, inspection, duplication, customization, and package-version paths.
- [x] 7.4 Preserve pending canonical output across relaunch and convert in-flight model execution to the existing interrupted error without another request.
- [x] 7.5 Add template, exact-input, output-operation, disconnected discovery, package upgrade, unsupported model, persistence, history, and recovery tests.

## 8. Security, performance, and release gates

- [x] 8.1 Prove model providers receive only captured instructions, model identifier, and `content` and cannot access document, history, filesystem, capture, connectors, processes, shell, JavaScript, or application state.
- [x] 8.2 Prove launch, editing, Settings navigation, model filtering, history, search, and JavaScript tools initialize no OAuth or model-provider network activity.
- [x] 8.3 Benchmark catalog filtering, tool validation, invocation submission, delayed execution, cancellation, and canonical publication against existing editor budgets.
- [ ] 8.4 Re-run foundation, persistence, history, Settings, native invocation, real-app, IME, and accessibility regression suites for both executor types.
- [ ] 8.5 Qualify the OAuth connection and model-tool flows with keyboard and VoiceOver and audit the result for no manual keys, streaming, model tool-calling, JavaScript model API, background execution, broad context, separate run store, conflict UI, or automatic Retry.

## Verification exceptions

The user explicitly requested skipping inaccessible checks. Task 8.4 remains unchecked only for the real-app UI runner, which could not initialize macOS automation; its foundation and native portions passed (122 and 101 tests). Task 8.5 remains unchecked for live OAuth and VoiceOver qualification. No custom accessibility harness is retained. See `VERIFICATION.md` for evidence and limitations.
