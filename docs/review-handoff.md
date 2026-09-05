# Jort Architecture and Code Review Handoff

## Purpose

This document is the implementation handoff from the September 2026 review of the Crawl MVP. It describes the changes the code owner should make before building landmarks, history, automation, or external capture.

The current application is a strong prototype. Native editing, Unicode and newline handling, line reconciliation, IME behavior, basic undo/redo, asynchronous persistence, and bounded save retries are all covered by meaningful tests. The Release build also succeeds. The primary concern is not the current typing experience; it is that the current ownership and persistence boundaries will become unsafe as soon as non-editor features can mutate the document.

## Product Decisions

The following decisions are intentional constraints on this handoff:

- Any failure during the save operation is a failed save. Do not downgrade recovery-snapshot failures or present a partially successful save as healthy.
- Continue treating persistence failure as a high-severity condition. Local writes should be dependable, and the existing prominent retry and quit protections are appropriate.
- Preserve the dark-only visual design for now.
- Preserve emoji-first landmark and routing language.
- Preserve line creation and edit timestamps as product data.
- Recovery-copy import and the unsafe-load editing experience will be designed later.
- The current best-effort save cadence is acceptable. Internal tests should measure it, but the product should not promise users a strict half-second deadline.
- Broader status-banner and standard-menu design work is deferred until later UI paradigms are established.

## Recommended Delivery Order

1. Establish one authoritative document owner and transaction API.
2. Add explicit persistence versions and migrations.
3. Make recovery replacement atomic.
4. Enforce one running Jort process per data store.
5. Centralize revision assignment and finalize line identity semantics.
6. Introduce module boundaries and compiler-enforced concurrency isolation.
7. Replace untyped persistence status callbacks with a state model.
8. Strengthen performance, lifecycle, migration, and failure-injection tests.
9. Begin landmarks and command-palette work only after these foundations are in place.

## P0: Complete Before New Document Features

### 1. Create One Authoritative Document Owner

**Current code**

- `EditorViewController` owns mutable `state`: `Jort/UI/EditorViewController.swift:18`.
- Native edits, metadata undo, revision increments, ruler updates, and persistence notifications are coordinated directly in the view controller: `Jort/UI/EditorViewController.swift:135-167`.
- `PersistenceController` owns a second mutable copy: `Jort/Core/PersistenceController.swift:12`, `Jort/Core/PersistenceController.swift:49-50`.

This is workable while `NSTextView` is the only mutation source. It will not safely support history restore, landmark mutations, captures, commands, or delayed automation results. Those features need deterministic ordering, stale-revision checks, unified undo boundaries, and selection/viewport preservation.

**Required direction**

Introduce a document coordinator as the sole owner of live `DocumentState`. All mutations should enter through typed transactions. The coordinator should:

- Assign every live revision.
- Validate line and metadata invariants.
- Accept native text edits, metadata edits, restores, and anchored insertions through explicit APIs.
- Record mutation origin and base revision.
- Produce immutable snapshots for persistence and background work.
- Return the information the AppKit adapter needs to update text, metadata, undo, selection, viewport, and gutter state.
- Reject or resolve stale background mutations without allowing background components to mutate `NSTextView` directly.

`EditorViewController` should own AppKit objects and translate AppKit edit events. `PersistenceController` should schedule and persist immutable snapshots. Neither should own an independently mutable domain state.

Do not move the existing fields into an actor without first defining transaction inputs and outputs. Actor isolation alone will serialize an unclear mutation model rather than fix it.

**Acceptance criteria**

- There is exactly one mutable `DocumentState` during a process lifetime.
- Native edit, undo, redo, metadata mutation, and programmatic insertion tests all use the same transaction path.
- Revision assignment cannot be bypassed by a caller mutating public state.
- A simulated delayed transaction with a stale base revision cannot overwrite newer text.
- Persistence receives immutable snapshots and cannot mutate live state.

### 2. Add Explicit Persistence Migrations

**Current code**

- `DocumentState` relies on synthesized `Codable`: `Jort/Core/DocumentState.swift:11-15`.
- The payload has `schemaVersion`, while SQLite separately uses `PRAGMA user_version`: `Jort/Core/DocumentState.swift:12`, `Jort/Core/SQLiteStore.swift:51-62`.
- Loading directly decodes the current live type: `Jort/Core/SQLiteStore.swift:71-73`.

Adding required fields for landmarks, annotations, durable revisions, or document identity can make existing stores undecodable. The two version numbers also have no defined division of responsibility.

**Required direction**

- Define a persistence envelope that is separate from the live domain model.
- Give each released payload format an explicit decoder and migration into the current model.
- Treat SQLite schema migration and payload migration as one coordinated operation.
- Run migrations transactionally and update version markers only after success.
- Refuse future versions without modifying their files.
- Preserve the pre-migration store until the migrated replacement has been validated.

The current single-state blob is acceptable for the Crawl MVP. Do not introduce a large normalized table schema merely because the archived design suggests one. First establish migration, transaction, and recovery semantics; normalize only where query or atomicity requirements justify it.

**Acceptance criteria**

- Committed fixtures exist for every released SQLite and payload version.
- Every fixture migrates to the current version and reopens successfully.
- A failed migration leaves the original files unchanged and readable by the prior version.
- Future SQLite and payload versions are refused without mutation.
- Additive and renamed fields are tested rather than relying on synthesized decoding behavior.

### 3. Make Recovery Replacement Atomic

**Current code**

`SQLiteStore.recover()` validates `Recovery.json`, removes `Jort.sqlite`, its WAL, and its SHM file, and then attempts to save a replacement: `Jort/Core/SQLiteStore.swift:91-109`.

If the disk fills, permissions change, or another I/O failure occurs after removal, the canonical location no longer contains a working store. The damaged backup is valuable, but Jort has no automated rollback path from it.

**Required direction**

- Acquire exclusive ownership of the store before recovery.
- Build the recovered database in a temporary sibling location on the same volume.
- Close and validate the replacement by reopening and reading it.
- Preserve the original database and WAL companions until replacement validation succeeds.
- Atomically move or swap the validated replacement into the canonical location.
- Roll back automatically if any operation before the final swap fails.
- Keep the damaged backup after successful recovery for manual diagnosis.

Account for SQLite WAL state explicitly. Do not copy or replace an open database while another process may still own it.

**Acceptance criteria**

- Injected failure at every backup, creation, write, validation, and replacement step leaves either the original canonical store or a valid recovered store in place.
- Relaunch after each injected failure has deterministic behavior.
- Recovery cannot run without exclusive store ownership.
- The damaged backup remains intact after successful replacement.

### 4. Enforce One Running Jort Process Per Store

**Current code**

- The app creates one window and one persistence controller per process: `Jort/JortApp.swift:14-25`.
- Saves replace the entire current-state row without checking the generation that was loaded: `Jort/Core/SQLiteStore.swift:76-87`.

Ordinary Launch Services behavior normally reactivates an existing application, but a second process can still be started with development tools, direct executable launch, or `open -n`. Supporting concurrent editing correctly would require cross-process change propagation, diff application, conflict handling, and recovery coordination. That complexity is not justified for the current one-canvas product.

**Required direction**

Enforce single-process ownership instead of implementing multi-instance synchronization.

Use a process-lifetime advisory lock associated with the selected data directory. A robust implementation can open a lock file and hold a nonblocking exclusive `flock` for the life of the process. This is preferable to only querying `NSRunningApplication`, because the filesystem lock is race-safe and scopes ownership to the actual store, including `JORT_DATA_DIRECTORY` development stores.

On lock contention:

- Do not open, recover, or write the store.
- If the existing owner uses the normal bundle identifier, activate it when practical.
- Show a concise message or terminate the duplicate process cleanly.
- Never offer recovery from the second process.

The application already enforces one window inside a process by retaining and reopening the same `NSWindow`. No multi-window document work is needed.

**Acceptance criteria**

- Two processes cannot simultaneously open the same data directory for mutation or recovery.
- A second process exits without changing SQLite, WAL, SHM, recovery, or lock files beyond opening the lock.
- Different explicit `JORT_DATA_DIRECTORY` values can run independently for development and tests.
- A crash releases the OS advisory lock without requiring stale-lock cleanup.
- A race test that launches two processes simultaneously produces exactly one store owner.

## P1: Foundation For History And Automation

### 5. Centralize Revision Semantics

**Current code**

`DocumentState.replaceText` increments `revision`, while undo-related UI paths also increment it manually: `Jort/Core/DocumentState.swift:108-110`, `Jort/UI/EditorViewController.swift:140-166`.

The counter currently means that a selected mutation path happened to increment it. It does not identify mutation origin, base revision, durable revision, affected targets, or a meaningful history boundary.

**Required direction**

- Assign revisions only in the authoritative document coordinator.
- Distinguish the live document revision from the last durably saved revision and future history checkpoint IDs.
- Include mutation origin, base revision, affected anchors/ranges, and undo policy in transaction input.
- Keep ordinary typing revisions separate from future coalesced history checkpoints.
- Give persistence completion a typed committed revision so dirty-state decisions do not depend on status strings.

Do not turn the document into a full event-sourced system. Transactions can be ephemeral coordination values while current state and selected checkpoints remain the persisted model.

**Acceptance criteria**

- No UI or persistence type increments revisions directly.
- Every accepted transaction advances the live revision exactly once.
- Undo and redo have explicit, tested revision behavior.
- The coordinator can state both current live revision and last committed revision.

### 6. Finalize Line Identity Before Persisting References

**Current code**

Line reconciliation inherits IDs mainly by position, with special handling for the leading edited line: `Jort/Core/DocumentState.swift:62-100`. The archived design adds stronger rules for full-line replacement, joins, tombstones, detached landmarks, and background insertion: `build-jort-v1/design.md:114-139`.

Once landmarks, annotations, runs, or captures persist a `LineID`, identity behavior becomes a product and migration contract rather than an internal implementation detail.

**Required direction**

Define whether `LineID` represents textual lineage, paragraph position, or a persistent user anchor. Then specify identity outcomes for:

- In-line edits and complete line replacement.
- Split and join operations.
- Multiline paste and replace-all.
- Cut, paste, and apparent movement of text.
- Line deletion and detached metadata.
- Undo and redo.
- IME commits.
- Programmatic bulk edits and history restore.

Keep emoji-first landmark interaction. Stable internal IDs should preserve the selected destination when an emoji changes or when duplicate emoji exist; user-visible labels or nearby text may be added later as supporting context without replacing emoji as the primary language.

**Acceptance criteria**

- The identity matrix is documented as normative behavior.
- Property tests cover identity and timestamp invariants for randomized edit, undo, and redo sequences.
- Landmark prototypes demonstrate deterministic behavior for split, join, deletion, duplicate emoji, and emoji replacement.
- Deleted or ambiguous anchors never silently attach to unrelated content.

### 7. Establish Module Boundaries

**Current code**

All production code is compiled into one application target, and tests use `@testable import Jort`: `project.yml:12-38`, `Tests/JortCoreTests.swift:4`.

Protocols inside one application target will not prevent future provider, command, capture, and UI dependencies from flowing into the document model or launch path.

**Required direction**

Create boundaries based on authority rather than on feature count:

- `JortDocument`: state, transactions, line identity, anchors, revisions, and validation.
- `JortPersistence`: versioned persistence, migrations, recovery, and store locking.
- `JortAppKit`: text view, gutter, undo adapter, selection, viewport, and status presentation.
- `Jort`: application composition and lifecycle.

Future automation and capture modules should depend inward on immutable document snapshots and transaction contracts. They must not import AppKit or mutate text storage.

This does not require a large framework hierarchy. Swift packages or framework targets are both acceptable; choose the smallest arrangement that gives the compiler enforceable dependency direction and permits headless document/persistence testing.

**Acceptance criteria**

- Document and persistence tests run without constructing `NSApplication`, `NSWindow`, or `NSTextView`.
- The document module does not import AppKit.
- Optional future modules cannot be dependencies of the launch-to-editor path.
- A clean build regenerates the same project structure from the chosen source of truth.

### 8. Enforce Concurrency Isolation

**Current code**

`PersistenceController` mutates `state`, `timer`, `retryCount`, `writing`, and `savedRevision` without actor annotations or locking: `Jort/Core/PersistenceController.swift:3-13`, `Jort/Core/PersistenceController.swift:49-109`. Correctness currently depends on callers using the main thread.

**Required direction**

- Mark UI-facing persistence scheduling and callbacks `@MainActor`.
- Send immutable, `Sendable` snapshots to the storage executor.
- Isolate SQLite connection ownership to one serial executor or actor.
- Enable strict concurrency checking and address warnings rather than suppressing them.
- Keep serialization and disk work off the main actor.

**Acceptance criteria**

- The project builds with strict concurrency checking enabled at the selected Swift language level.
- No mutable controller state is accessed from both the main actor and storage queue.
- Thread Sanitizer runs cleanly for edit, save, retry, close, and quit tests.

### 9. Replace Stringly Typed Persistence Status

**Current code**

`PersistenceController` reports `(String, Bool)` through `onStatus`: `Jort/Core/PersistenceController.swift:13`. `EditorViewController` infers whether to retry or create a recovery copy from `loadedSafely`: `Jort/UI/EditorViewController.swift:99-104`.

This will not scale to load failures, dirty state, active writes, retry scheduling, future-version refusal, corruption recovery, exhausted retries, or future history degradation.

**Required direction**

Expose a typed persistence state and keep user-facing strings in the UI layer. The state should distinguish at least:

- Loading.
- Clean at a committed revision.
- Dirty.
- Writing.
- Retry scheduled.
- Save failed with retry budget remaining.
- Save failed with automatic retries exhausted.
- Load blocked by a future version.
- Load or recovery failed.

Per the product decision, any failure returned by the save operation remains a failed save. The type is for reliable behavior and presentation, not for weakening failure severity.

**Acceptance criteria**

- UI actions and quit decisions switch on typed state rather than parsing strings or combining unrelated booleans.
- Routine successful saves remain quiet.
- Every failed save remains visibly actionable and keeps the document dirty.
- Status copy is localized independently of persistence logic.

## P2: Scalability And Release Engineering

### 10. Define Performance Budgets And Measure Full Workflows

**Current code**

- Fallback reconciliation copies both complete strings into UTF-16 arrays: `Jort/Core/DocumentState.swift:44-51`.
- Every save serializes the complete document state: `Jort/Core/SQLiteStore.swift:76-89`.
- Metadata undo captures the complete line array: `Jort/UI/EditorViewController.swift:137-166`.
- Every edit shifts all trailing line offsets: `Jort/Core/DocumentState.swift:102-106`.
- The large-document test measures one append and reconciliation operation: `Tests/JortCoreTests.swift:66-74`.

These choices are reasonable for the current scope. They become riskier as annotations, landmarks, history, and undo depth grow.

**Required direction**

- Keep the current data structures until profiling demonstrates a problem.
- Make transaction deltas the coordination interface now, so later optimization does not require redesigning every feature.
- Define budgets for launch-to-editable, typing latency percentiles, scrolling, large paste, undo depth, save serialization, history creation, and memory growth.
- Measure sustained edits while autosave and gutter layout are active, not isolated reconciliation only.
- Measure the best achievable save cadence internally without presenting it as a strict user-facing deadline.

**Acceptance criteria**

- Benchmarks use committed representative fixtures and report distributions rather than a single local timing.
- Performance tests cover sustained random edits, large paste, deep undo, save activity, search, and future metadata growth.
- A regression threshold is enforced in CI on stable measurements.

### 11. Make Build Configuration Deterministic

**Current code**

- Both `project.yml` and the generated Xcode project are committed.
- `project.yml` declares marketing version `0.1.0`: `project.yml:29`.
- `Info.plist` declares short version `1.0`: `Jort/Info.plist:21-24`.
- The project enables generated Info.plist behavior while also supplying an explicit file: `project.yml:9`, `project.yml:16-22`.

**Required direction**

- Choose and document one source of truth for project configuration.
- Regenerate deterministically in CI and fail if committed generated files drift.
- Consolidate version, plist generation, deployment target, architectures, signing, and entitlements.
- Add a clean-environment build and test job.

**Acceptance criteria**

- Marketing and build versions agree in the built artifact.
- Regeneration produces no uncommitted differences.
- CI performs tests, analysis, and a Release build from a clean checkout.

### 12. Package Into A Clean Artifact

**Current code**

`scripts/build.sh` uses `ditto` to copy the new product onto an existing `dist/Jort.app`: `scripts/build.sh:5-8`. Files removed from the build can remain in the distributed bundle. Signing and notarization are intentionally not configured for the current local-only build.

**Required direction**

- Build into a fresh temporary staging directory.
- Validate the staged bundle contents.
- Atomically replace `dist/Jort.app` rather than merging into it.
- Keep local unsigned packaging clearly separate from any future distributable build.
- Before distribution, add Developer ID signing, hardened runtime, notarization, and Gatekeeper verification.

**Acceptance criteria**

- A deliberately added stale file in the previous `dist/Jort.app` does not survive the next build.
- The local build script clearly reports that the result is unsigned and local-only.
- A future distribution job runs `codesign --verify --deep --strict` and `spctl --assess` successfully.

### 13. Harden SQLite API Use

**Current code**

- The result of `sqlite3_bind_blob` is ignored, and payload size is narrowed to `Int32`: `Jort/Core/SQLiteStore.swift:84`.
- Version-zero databases are modified into version 1 without validating an existing table shape: `Jort/Core/SQLiteStore.swift:51-62`.
- Return values from configuration and close operations are not consistently checked.

**Required direction**

- Check every SQLite return code that affects correctness.
- Validate payload size before conversion and define a maximum supported stored-document size.
- Use exact-version transactional migrations rather than treating every version less than or equal to the current version as compatible.
- Validate expected table columns and constraints before changing `user_version`.
- Preserve the most useful primary error if rollback or close also fails, while retaining secondary diagnostics.

**Acceptance criteria**

- Bind, size-limit, busy, malformed-schema, and close failures have deterministic tests.
- Opening an unknown version-zero schema does not modify it.
- Payloads over the documented limit fail without crashing or losing the last committed state.

## Test Gaps

Add these tests as their corresponding changes are implemented:

- Two processes racing to own one store, including recovery attempts.
- Different data directories running concurrently.
- Failure injection at every atomic recovery stage.
- Real migration fixtures for every released schema and payload version.
- Future payload version refusal in addition to future SQLite version refusal.
- Valid JSON with invalid line ranges, duplicate IDs, and inconsistent metadata.
- Crash or forced termination with SQLite WAL present.
- Disk-full, read-only directory, permissions, busy database, and payload-size failures.
- Multiple rapid flush callers while a write is active.
- Close and quit during active or failed writes.
- Randomized native AppKit undo and redo, not only direct `DocumentState` mutation.
- Find/Replace, replace-all, paste, Services, drag-and-drop, and programmatic changes against metadata reconciliation.
- Physical IME/input-source checks in addition to synthetic marked-text tests.
- Sustained editing with autosave, scrolling, wrapping, and gutter updates active.
- Clean packaging with stale-file detection.
- Strict-concurrency and Thread Sanitizer runs.

## Existing Strengths To Preserve

- Storage serialization and I/O remain off the keystroke path: `Jort/Core/PersistenceController.swift:24-47`, `Jort/Core/PersistenceController.swift:77-109`.
- Failed initial load does not overwrite the existing canonical store: `Jort/Core/PersistenceController.swift:28-45`, `Jort/Core/PersistenceController.swift:49-52`.
- Save retries are bounded, manual retry saves the newest state, and editing remains available after failure: `Jort/Core/PersistenceController.swift:49-66`, `Tests/JortCoreTests.swift:236-267`.
- Quit waits for persistence and warns before discarding unsaved changes: `Jort/JortApp.swift:57-73`.
- Unicode, emoji, combining characters, Japanese, LF, CRLF, and CR receive explicit coverage: `Tests/JortCoreTests.swift:24-29`.
- IME marked text remains provisional until commit: `Jort/UI/EditorViewController.swift:121-145`, `Tests/JortCoreTests.swift:183-207`.
- Loaded states validate logical ranges and unique line IDs: `Jort/Core/DocumentState.swift:113-120`.
- Gutter rendering is viewport-bounded rather than forcing whole-document layout: `Jort/UI/EditorViewController.swift:195-233`.
- Current corruption recovery validates the separate snapshot before replacing damaged data and preserves damaged companions for diagnosis: `Jort/Core/SQLiteStore.swift:91-109`.
- The existing test suite exercises meaningful native and persistence integration rather than only isolated unit helpers.

## Verification Baseline

At review time:

- `./scripts/test.sh` passed all 13 tests.
- Debug static analysis succeeded.
- The Release build succeeded.
- The large-document reconciliation test reported approximately 9 ms on the review machine; this is not an end-to-end typing latency result.
- `codesign --verify --deep --strict dist/Jort.app` failed because the local artifact is unsigned.
- `spctl --assess` rejected the artifact with `no usable signature`, consistent with the documented local-only build.
- The project directory was not a Git repository, so commit history, diff ownership, and CI configuration could not be assessed.

## Completion Gate For The Next Product Phase

Landmark and command-palette implementation can begin when:

- One document owner coordinates native and programmatic transactions.
- Existing stores have a tested migration path.
- Recovery replacement cannot remove the last canonical store before a replacement is valid.
- Only one process can own a given store.
- Line identity behavior is normative and covered by edit plus undo property tests.
- Document, persistence, and AppKit dependencies are compiler-enforced.
- Persistence lifecycle is represented by typed state.
- Clean CI executes tests, analysis, Release build, migration fixtures, and the initial performance suite.

Automation and external capture should remain later phases. Before either can mutate text, they additionally need immutable input snapshots, anchored transactions, stale-target handling, explicit capability enforcement, and durable idempotency semantics.
