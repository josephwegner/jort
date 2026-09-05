# Tasks: Build Jort V1

## 1. Native project and performance harness

- [ ] 1.1 Create the macOS Swift application target, module boundaries, test targets, and CI build.
- [ ] 1.2 Add signposted launch-to-window, launch-to-focus, and first-keystroke measurements.
- [ ] 1.3 Define large-document fixtures and initial budgets for launch, typing, scrolling, gutter rendering, search, and revision creation.
- [ ] 1.4 Add a dependency/lazy-initialization test proving optional subsystems do not initialize before invocation.
- [ ] 1.5 Implement the minimal SwiftUI window shell with dark appearance, centered Jort title, notification control, and top-right command palette control.

## 2. Native editor foundation

- [ ] 2.1 Host an `NSTextView`/TextKit 2 editor inside SwiftUI with immediate first-responder focus.
- [ ] 2.2 Configure the editor as aggressively plain text while preserving native selection, copy/paste, find, spellcheck policy, undo, accessibility, and Services.
- [ ] 2.3 Implement selection and viewport anchor capture/restore utilities for background transactions.
- [ ] 2.4 Add integration tests for visual wrapping, resizing, scrolling, large paste, undo/redo, and accessibility navigation.
- [ ] 2.5 Add IME/marked-text fixtures and ensure provisional composition does not emit durable metadata transactions.
- [ ] 2.6 Verify the editor remains usable when every optional coordinator is stubbed as unavailable.

## 3. Document state and logical-line identity

- [ ] 3.1 Implement `DocumentState`, typed identifiers, anchored ranges, annotations, and revision counters.
- [ ] 3.2 Implement local-window newline parsing around TextKit edit ranges.
- [ ] 3.3 Implement deterministic within-line edit and timestamp update behavior.
- [ ] 3.4 Implement split inheritance: leading fragment keeps identity and trailing fragments receive new identities.
- [ ] 3.5 Implement join inheritance and tombstones needed for undo restoration.
- [ ] 3.6 Implement whitespace-empty timestamp clearing without losing structural line identity.
- [ ] 3.7 Integrate text and identity deltas into unified undo/redo groups.
- [ ] 3.8 Add property tests covering randomized split, join, paste, replace, delete, undo, and redo sequences.

## 4. Gutter and landmarks

- [ ] 4.1 Implement a viewport-bounded TextKit 2 gutter aligned to newline-delimited logical lines rather than visual wraps.
- [ ] 4.2 Render line numbers in the fixed-width gutter and verify baseline alignment under font, scale, wrap, and scroll changes.
- [ ] 4.3 Add native emoji picking from a gutter line and create a `Landmark` anchored by `LineID`.
- [ ] 4.4 Replace an assigned line number with its emoji and restore the number when cleared.
- [ ] 4.5 Implement landmark survival across edits above, within, split, join, paste, undo, redo, and IME commit.
- [ ] 4.6 Add the fixed bullet-list toggle above the gutter content.
- [ ] 4.7 Implement landmark navigation mode inside the existing gutter width with top-aligned emoji in document order and one editor-line row per entry.
- [ ] 4.8 Scroll and focus the editor when a landmark index entry is activated without changing text or horizontal layout.
- [ ] 4.9 Implement stable landmark identity independent of emoji and cover duplicate/change-emoji routing cases in tests.
- [ ] 4.10 Stress-test gutter and landmark navigation on the large-document fixture.

## 5. SQLite persistence and current-state recovery

- [ ] 5.1 Add an actor-isolated SQLite layer configured for WAL, migrations, foreign keys, prepared statements, and explicit transactions.
- [ ] 5.2 Create current-state schemas for document, line metadata, annotations, landmarks, runs, inbox, connections, commands, scripts, providers, and settings.
- [ ] 5.3 Implement asynchronous transaction persistence from `DocumentActor` without synchronous keystroke writes.
- [ ] 5.4 Add debounced idle flush plus best-effort app deactivation and termination flushes.
- [ ] 5.5 Restore current text and metadata before optional subsystem startup while keeping launch-to-focus within budget.
- [ ] 5.6 Implement dirty-state retry and quiet error reporting when SQLite writes fail.
- [ ] 5.7 Add crash/relaunch and migration integration tests.

## 6. Full-state version history

- [ ] 6.1 Define and version the complete serialized revision schema.
- [ ] 6.2 Implement time-, idle-, lifecycle-, and event-based revision coalescing behind configurable thresholds.
- [ ] 6.3 Force revision boundaries for automation, captures, landmark changes, restores, and bulk commands.
- [ ] 6.4 Add Version History to the title-bar command palette rather than permanent chrome.
- [ ] 6.5 Build lazy history browsing and complete-state preview UI.
- [ ] 6.6 Implement atomic full-state restore, preserving the replaced state as a new recoverable revision.
- [ ] 6.7 Add tests for metadata-inclusive restore, storage growth, coalescing quality, undo behavior, and corrupted revision handling.

## 7. Command palette and deterministic commands

- [ ] 7.1 Implement the transient title-bar command palette with search and keyboard navigation.
- [ ] 7.2 Define registries and completion models for `/command` and `@agent` names.
- [ ] 7.3 Implement local `/date`, `/time`, `/uuid`, and `/calc` built-ins.
- [ ] 7.4 Implement range-based `/sort` and `/dedupe` with previewable input scope.
- [ ] 7.5 Commit built-in results as atomic undoable text transactions immediately after the invocation line or against an explicit selection.
- [ ] 7.6 Add completion, punctuation, Escape, Return, and Shift+Enter interaction tests.

## 8. JavaScriptCore scripting

- [ ] 8.1 Define the JavaScriptCore bridge surface for explicit text input, returned text, landmark mutation, and narrow Jort tool requests.
- [ ] 8.2 Create isolated execution contexts with time, cancellation, memory/behavioral, and output limits.
- [ ] 8.3 Prove Node globals, process execution, ambient filesystem, dynamic native modules, and unrestricted network are absent.
- [ ] 8.4 Implement script registration/configuration in lazily loaded settings.
- [ ] 8.5 Commit successful script results atomically and surface failures as quiet inline operational errors.
- [ ] 8.6 Add adversarial sandbox and authority tests.

## 9. Inline invocation and context UX

- [ ] 9.1 Recognize registered `@` and `/` invocations at their actual character and logical-line positions.
- [ ] 9.2 Render a one-line pending decoration anchored to the invocation layout fragment without changing canonical text.
- [ ] 9.3 Add explicit Run and Shift+Enter behavior; ensure Return alone remains text editing.
- [ ] 9.4 Implement prompt-only and full-logical-line context manifests, including mid-line invocation text before and after the prompt.
- [ ] 9.5 Implement bounded before/after context manifests declared by an agent.
- [ ] 9.6 Decorate the exact submitted ranges and update both decoration and manifest when the user changes context.
- [ ] 9.7 Show provider locality/network identity before Run.
- [ ] 9.8 Add Escape/abandon behavior that returns the invocation to ordinary text.
- [ ] 9.9 Usability-test decoration padding, line overlap, context discoverability, and keyboard behavior against the interaction prototype.

## 10. Run coordinator and atomic insertion

- [ ] 10.1 Define `AgentRun`, `ContextManifest`, capability, target hash, status, cancellation, and audit records.
- [ ] 10.2 Implement a fake delayed provider to exercise progress, cancellation, editing-during-run, and failure states.
- [ ] 10.3 Snapshot invocation, context ranges, revision, target hashes, and viewport/selection on Run.
- [ ] 10.4 Implement optional fixed-height progress attachment without token streaming.
- [ ] 10.5 Validate/rebase `LineID` insertion anchors when unrelated edits occur during a run.
- [ ] 10.6 Detect material target changes and present safe insertion/conflict resolution without overwriting newer text.
- [ ] 10.7 Insert completed output as one transaction immediately after the invocation line with provenance metadata.
- [ ] 10.8 Implement Merge as metadata removal, Delete as explicit text removal, and Retry as a new independent run.
- [ ] 10.9 Verify automation commits preserve viewport and selection unless the user navigates to the result.
- [ ] 10.10 Add concurrency, cancellation, stale-target, undo, and revision-boundary tests.

## 11. Permission and consent enforcement

- [ ] 11.1 Implement capability declarations separately from run-scoped consent grants.
- [ ] 11.2 Enforce prompt-only default and manifest-bounded reads at the coordinator boundary.
- [ ] 11.3 Build whole-document preview and fresh confirmation for every requested read.
- [ ] 11.4 Build exact-revision preview and fresh confirmation for every history read.
- [ ] 11.5 Enforce declared network identity and narrow hash-checked mutation targets.
- [ ] 11.6 Reject agent-requested external commands in V1.
- [ ] 11.7 Add tests proving no configuration or cached consent bypasses whole-document/history confirmation.

## 12. Model providers

- [ ] 12.1 Define the lowest-common-denominator `ModelProvider` message/tool protocol and availability model.
- [ ] 12.2 Implement lazy provider registry initialization after explicit invocation.
- [ ] 12.3 Implement the Apple on-device provider behind availability checks and the common protocol.
- [ ] 12.4 Implement one OpenAI-compatible URLSession provider with secure credential storage and cancellation.
- [ ] 12.5 Add advanced configuration for compatible custom endpoints without placing it in first-run flow.
- [ ] 12.6 Add offline, missing-credential, timeout, malformed-response, tool-request, and cancellation tests.

## 13. Registered external commands

- [ ] 13.1 Define `RegisteredCommand` with exact executable identity/bookmark, structured arguments, input source, output disposition, timeout, environment allowlist, and byte cap.
- [ ] 13.2 Implement a runner that launches the executable directly without a shell.
- [ ] 13.3 Add explicit user-only registration and invocation UI under advanced settings.
- [ ] 13.4 Insert or transform output through atomic document transactions and report failures inline.
- [ ] 13.5 Prototype App Sandbox/Shortcuts constraints and document the direct-distribution versus App Store decision.
- [ ] 13.6 Add tests for argument injection, environment leakage, timeout, cancellation, output caps, invalid bookmarks, and process failure.

## 14. Notifications and external capture

- [ ] 14.1 Specify relay privacy requirements: authentication, encryption, retention, deletion, abuse prevention, and acknowledgement semantics.
- [ ] 14.2 Implement the minimal relay inbox API and authenticated pull/ack client contract.
- [ ] 14.3 Start capture synchronization lazily after the focused canvas is available.
- [ ] 14.4 Implement capture connections targeting stable landmark identity while displaying emoji-facing language.
- [ ] 14.5 Implement deterministic append-to-section when a boundary is unambiguous.
- [ ] 14.6 Implement immediate-below-anchor fallback when a boundary is fuzzy.
- [ ] 14.7 Queue captures outside the document when the destination is missing, detached, or unresolved.
- [ ] 14.8 Add the title-adjacent notification indicator and transient notification drawer for runs and captures.
- [ ] 14.9 Implement destination repair/reroute and ordered batch commit as one undoable transaction.
- [ ] 14.10 Acknowledge relay items only after local durable commit or explicit rejection.
- [ ] 14.11 Add offline, retry, duplicate emoji, moved/deleted destination, order, expiry, acknowledgement, and plugin-failure tests.

## 15. Final integration and release gates

- [ ] 15.1 Run all unit, property, integration, UI, accessibility, migration, sandbox, permission, and capture state-machine tests.
- [ ] 15.2 Benchmark cold/warm launch, first focus, typing latency, scrolling, gutter rendering, search, snapshots, and automation commit against budgets.
- [ ] 15.3 Audit that no network, provider, JSC, command, relay, plugin, or update work occurs on launch or the keystroke path.
- [ ] 15.4 Audit plain-text copy/export and confirm all semantics remain metadata.
- [ ] 15.5 Run failure-injection tests proving every optional subsystem can fail while editing continues.
- [ ] 15.6 Complete keyboard-only, VoiceOver, reduced-motion, high-contrast, scaling, IME, and localization checks.
- [ ] 15.7 Resolve or explicitly defer each prototype gate and open decision in `design.md` before declaring V1 release-ready.

