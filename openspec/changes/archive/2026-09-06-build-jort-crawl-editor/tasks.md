## 1. Native application foundation

- [x] 1.1 Create a checked-in XcodeGen 2.46.0 manifest for the sandboxed arm64 macOS Swift application plus unit, integration, UI, and performance test targets without coupling them to the existing web prototype; treat the generated `.xcodeproj` as disposable and prohibit hand-maintained project changes.
- [x] 1.2 Set the deployment target to macOS 14 or later and declare the original M1/8 GB hardware class as the normative performance baseline.
- [x] 1.3 Establish narrow modules for the app shell/editor host, in-memory document core, SQLite persistence, recovery, and shared test support.
- [x] 1.4 Add GRDB 7.10.0 as an exact-pinned Swift Package dependency and the sole third-party runtime dependency, confine it to the storage module, and use explicit SQL without exposing GRDB types across module boundaries.
- [x] 1.5 Add dependency-injected clock, UUID generation, storage paths, schedulers, and failure hooks so metadata and storage behavior are deterministic in tests.
- [x] 1.6 Add unified signposts for process start, startup-classification resolution/deadline, state verification, window display, editor focus, edits, normalization, snapshot capture, viewport layout, persistence, WAL checkpointing, retry, checkpointing, and recovery.
- [x] 1.7 Generate the `CrawlLargeDocument` fixture with 1,000,000 UTF-16 code units, 25,000 logical lines, wrapping, mixed Unicode, emoji, combining marks, and whitespace-only lines.
- [x] 1.8 Add CI commands that install or invoke XcodeGen 2.46.0, fail on a version mismatch, regenerate the project, build native release and debug configurations, and run unit/integration suites while retaining test and signpost artifacts.
- [x] 1.9 Add a scope/dependency test proving GRDB is the only third-party runtime dependency and the Crawl target has no network client, provider, plugin, capture, command, AI, search-index, export, or history subsystem initialization.

## 2. In-memory document and snapshot model

- [x] 2.1 Implement typed `DocumentID` and `LineID` values, `LineMeta`, `DocumentState`, immutable `DocumentSnapshot`, and monotonic generation tracking.
- [x] 2.2 Represent the zero-character document as one stable structural line with nil timestamps and add invariant validation for that state.
- [x] 2.3 Implement an embedded Unicode 17.0 `White_Space` scalar/range table plus fixed UTC RFC 3339-compatible timestamps with exactly six fractional-second digits, and implement the rules for setting, preserving, advancing, and clearing line timestamps.
- [x] 2.4 Implement canonical LF normalization and versioned deterministic UTF-8 JSON snapshot encoding with sorted keys, ordered arrays, explicit null timestamps, byte counts, SHA-256 text/envelope hashes, initialized-empty marker, ordered line records, and generation.
- [x] 2.5 Implement shared snapshot validation for document identity, generation, text hash, logical-line count/order, unique IDs, timestamps, and structural agreement with text.
- [x] 2.6 Add model tests covering non-empty, intentional-empty, Unicode, trailing-newline, consecutive-newline, and whitespace-only snapshots.

## 3. Logical-line normalization and undo

- [x] 3.1 Implement UTF-16 edit-window discovery over intersecting logical lines plus the bounded neighboring context required to resolve newline boundaries.
- [x] 3.2 Implement within-line replacement behavior that retains identity and creation time while advancing or clearing edit metadata.
- [x] 3.3 Implement split inheritance so the leading fragment retains identity and creation time while advancing its edit time, and each trailing fragment receives one ordered new identity with transaction-time creation/edit timestamps when non-whitespace.
- [x] 3.4 Implement join inheritance so the leading line survives and removed records are retained in the paired inverse delta.
- [x] 3.5 Implement boundary-crossing replacement and multiline-paste normalization using the same split/join rules.
- [x] 3.6 Define one edit-transaction type that pairs the native text mutation with pre/post line metadata and selection information.
- [x] 3.7 Integrate metadata deltas into the native undo manager's grouping so undo and redo restore exact IDs/timestamps and create a new current generation.
- [x] 3.8 Add randomized property tests for insert, delete, split, join, multiline paste, replacement, whitespace transitions, undo, and redo sequences.
- [x] 3.9 Add a large-document benchmark proving localized edits do not rescan the complete document and remain within the typing budget.

## 4. Native editor host and focus

- [x] 4.1 Build the minimal SwiftUI window shell with the editor as its only persistent content and support for temporary focus-preserving storage notices.
- [x] 4.2 Host a TextKit-backed `NSTextView` in an `NSScrollView` through `NSViewRepresentable` and connect it to the authoritative `EditorSession`.
- [x] 4.3 Configure the text view for plain-text paste/content, accepted-transaction normalization of CRLF, CR, U+0085, U+2028, and U+2029 to LF, visual wrapping, vertical native scrolling, no document-level horizontal scrolling, and no attachment or rich-text import.
- [x] 4.4 Configure native find, undo manager, pasteboard, applicable Services, selection dragging/autoscroll, and standard Edit-menu selectors.
- [x] 4.5 Configure spelling, grammar, automatic correction, substitutions, and text replacement to honor macOS settings and standard menu controls without a Jort checker.
- [x] 4.6 Make the editor first responder on first display and appropriate key-window restoration without overriding focus intentionally held by the native find UI or storage action.
- [x] 4.7 Observe native text mutations, synchronously update `EditorSession`, and enqueue immutable snapshots without awaiting persistence.
- [x] 4.8 Capture and preserve selection and viewport anchors around model synchronization and background storage state changes.
- [ ] 4.9 Add UI tests for immediate focus, key-window restoration, resize reflow, native scrolling inputs, selection autoscroll, rich-to-plain paste, and viewport stability.

## 5. Keyboard, text input, and find conformance

- [x] 5.1 Add UI tests for Command-A/X/C/V/Z/Shift-Z and prove text plus metadata share each native undo boundary.
- [x] 5.2 Add UI tests for Arrow, Option-Arrow, Command-Arrow, Home, End, Page Up, Page Down, and Shift-modified selection behavior.
- [x] 5.3 Add UI tests proving Return, Tab, Delete, Forward Delete, Escape, and configured macOS text bindings remain native editor commands with no Crawl feature interception.
- [ ] 5.4 Add native Command-F/G/Shift-G find tests for next/previous navigation, selection, scrolling, close behavior, and restored editor focus without a search index.
- [ ] 5.5 Detect marked-text lifecycle boundaries so provisional composition remains `NSTextView` display state and neither updates canonical `EditorSession` state nor reconciles metadata, advances generation, enters paired undo data, or schedules persistence before commit.
- [ ] 5.6 Add IME fixtures for repeated candidate updates, replacement ranges, Unicode/combining text, newline commits, cancellation, and undo/redo of the final committed transaction.
- [ ] 5.7 Verify standard spelling indications remain noncanonical and accepted manual or automatic corrections become normal undoable persisted edits.

## 6. SQLite WAL current-state store

- [ ] 6.1 Implement the actor-isolated GRDB-backed SQLite connection and error mapping using explicit SQL, WAL mode, foreign keys, prepared statements, explicit transactions, crash-tested sync settings, and bounded auto-checkpoint configuration.
- [ ] 6.2 Add version-1 migrations for singleton `document`, ordered `line_meta`, and `store_state` tables only.
- [ ] 6.3 Implement atomic snapshot writes that replace the one current text and ordered line-record state for one generation without appending immutable handoff snapshots or a diff chain.
- [ ] 6.4 Verify committed generation, content hash, intentional-empty marker, line count/order, unique IDs, and structural agreement before acknowledging durability.
- [ ] 6.5 Implement verified current-snapshot loading that rejects unsupported schema, incomplete state, hash mismatch, duplicate IDs, and text/line disagreement.
- [ ] 6.6 Implement running/clean session markers and the orderly best-effort flush/clean-marker lifecycle path.
- [ ] 6.7 Add migration and store tests for Unicode, empty documents, large documents, transaction rollback, interrupted commits, unsupported versions, and malformed rows.
- [ ] 6.8 Add off-main-actor size/lifecycle WAL checkpointing and tests proving checkpoints never block editor input or invalidate a verified generation.

## 7. Autosave scheduling and generation safety

- [ ] 7.1 Implement the persistence actor's 150 ms idle debounce and maximum one-second dirty-age deadline using an injectable scheduler.
- [ ] 7.2 Coalesce obsolete pending snapshots while guaranteeing that continuous typing makes all edits older than one second part of a verified generation.
- [ ] 7.3 Track in-memory, queued, writing, and durable generations so completion of an older write cannot clear newer dirty state or overwrite the editor.
- [ ] 7.4 Trigger nonblocking immediate best-effort flush requests on app deactivation and orderly termination.
- [ ] 7.5 Add concurrency tests for rapid edit/undo/redo, out-of-order task completion, cancellation, lifecycle overlap, and edits arriving during commit verification.
- [ ] 7.6 Add a release benchmark with at least 2,000 measured edits proving 95th-percentile idle edit-to-verified durability is at most 250 ms, snapshot capture remains within the typing budget, and continuous dirty age is at most one second under supported load; add a smaller non-gating smoke sample to pull-request CI.

## 8. Storage-health state machine and retry

- [ ] 8.1 Implement the explicit first-launch, healthy-empty, healthy, dirty, retrying, needs-manual-retry, interrupted-shutdown, corrupt-store, recovering, recovered, and recovery-required states.
- [ ] 8.2 Classify disk-full/quota, permission, locked/busy, IO, open, transaction, sync, and verification errors into concise storage-health reasons without exposing raw internals.
- [ ] 8.3 Implement three automatic retries per failure episode at approximately 250 ms, 1 second, and 4 seconds while coalescing to the newest in-memory snapshot.
- [ ] 8.4 Prevent each later keystroke from restarting an exhausted retry episode and implement manual Retry from both the ephemeral notice and conditional File-menu command as a fresh three-attempt budget targeting the newest state.
- [ ] 8.5 Clear unhealthy state only after a commit and verification succeeds, preserving dirty state through all failures.
- [ ] 8.6 Add deterministic tests for transient success, exhausted attempts, manual retry, new edits during failure, disk-full recovery, and repeated manual episodes.

## 9. Bounded recovery checkpoints

- [ ] 9.1 Implement the versioned deterministic UTF-8 JSON recovery-envelope codec with sorted object keys, document-order arrays, fixed UUID/timestamp representations, explicit nulls, document metadata, ordered lines, byte counts, generation, SHA-256 content hash, and envelope SHA-256 checksum.
- [ ] 9.2 Implement two rotating checkpoint slots using temporary writes, file sync, atomic rename, directory sync, and post-publication decode/verification.
- [ ] 9.3 Implement the checkpoint manifest so only fully published and verified slots are advertised and temporary files are never candidates.
- [ ] 9.4 Coalesce checkpoint work to no more than once per second while publishing within one second of the first unpublished primary generation under normal supported load.
- [ ] 9.5 Ensure checkpoint lag, failure, and cancellation never mark the primary store unhealthy or delay editor interaction.
- [ ] 9.6 Add tests for rotation order, interrupted writes at every publication boundary, invalid checksums, truncated envelopes, unsupported versions, duplicate IDs, and strict two-slot retention.

## 10. Startup classification and interrupted-shutdown recovery

- [ ] 10.1 Implement startup classification across primary/WAL/SHM files, checkpoints, manifests, prior-store markers, and quarantine records with an instrumented two-second safety ceiling.
- [ ] 10.2 Initialize and focus an intentional empty in-memory document only after conclusive genuine-first-launch classification, then create its store asynchronously through the normal health path.
- [ ] 10.3 Restore a verified intentional-empty snapshot without treating it as absence, corruption, or a reason to select older non-empty state.
- [ ] 10.4 On a missing clean marker, open SQLite for WAL recovery and verify schema, integrity, generation, hashes, and line structure before loading.
- [ ] 10.5 Route a missing expected store, failed post-WAL verification, or classification unresolved at two seconds into neutral loading/recovery without showing or publishing a substitute editable blank.
- [ ] 10.6 Add startup integration tests for fast first launch, saved empty, saved non-empty, missing expected store, clean shutdown, forced termination, valid/invalid WAL replay, and classification delayed beyond two seconds.

## 11. Corruption preservation and state recovery

- [ ] 11.1 Keep the database, WAL, SHM, and store manifest inside one `active-store` directory; close all handles and atomically rename that complete directory into a uniquely named same-volume quarantine location before replacement, without copying or compressing it.
- [ ] 11.2 Refuse destructive recovery and leave source material untouched when quarantine preservation or atomic relocation cannot be proven successful.
- [ ] 11.3 Implement newest-first candidate discovery across preserved primary material and both recovery checkpoints with complete snapshot verification.
- [ ] 11.4 Rebuild the highest-generation verified candidate in a sibling `active-store.pending` directory, reverify it, and atomically rename the verified directory to the primary `active-store` path.
- [ ] 11.5 Report successful recovery with an ephemeral nonmodal notice containing the recovered generation and preserved damaged-store location while returning focus to the editor.
- [ ] 11.6 Implement recovery-required behavior when no candidate verifies, including Retry and an explicit confirmed start-empty path using a distinct store identity.
- [ ] 11.7 Ensure start-empty and all later successful recovery actions retain quarantine material and never reuse, mutate, or delete the damaged bundle.
- [ ] 11.8 Add corruption tests for damaged database pages, WAL, SHM, manifests, newest/older checkpoints, empty-state candidates, no valid candidate, rebuild failure, publish interruption, and quarantine failure.
- [ ] 11.9 Preserve both states without replacement or automatic merge if older quarantined content becomes recoverable after the explicitly started new document has been edited.

## 12. Ephemeral storage-health UI and accessibility

- [ ] 12.1 Build ephemeral nonmodal storage notices for retrying, manual-retry, and recovered transitions with no persistent badge, banner, footer, toolbar item, or other ordinary-window status.
- [ ] 12.2 Present concise disk-full and write-failure explanations plus Retry without modal interruption or automatic focus movement, and enable `File > Retry Saving` only while manual retry is available.
- [ ] 12.3 Expose storage status and Retry through accessibility names, values, actions, Full Keyboard Access, non-color-only state, and one polite announcement per state transition.
- [ ] 12.4 Implement the explicit unrecoverable-corruption decision UI so empty initialization requires informed confirmation and preserved-material location remains available.
- [ ] 12.5 Add UI tests proving storage transitions do not interrupt typing, selection, IME, find, scrolling, or undo; notices leave no chrome after dismissal/expiry; and notice/menu Retry returns focus to the editor.

## 13. Editor accessibility verification

- [ ] 13.1 Set and verify the editor's “Document” accessibility label, editable multiline role, enabled/focused state, value, selected text/range, insertion point, visible range, and range bounds.
- [ ] 13.2 Add accessibility tests for VoiceOver-style navigation, selection, editing, dictation insertion, clipboard, undo/redo, find, and scrolling parity.
- [ ] 13.3 Verify logical-line identity, timestamps, generations, checksums, and storage internals are never exposed as document text to accessibility clients.
- [ ] 13.4 Test editor and storage-health operation with Increase Contrast, Reduce Motion, Full Keyboard Access, display scaling, and enlarged editor fonts.
- [ ] 13.5 Complete and retain a manual VoiceOver and real-IME test matrix on the minimum and latest supported macOS releases, with automated smoke coverage on intermediate supported releases.

## 14. Crash, failure, and performance release gates

- [ ] 14.1 Build a force-termination harness and run at least 100 randomized continuous-edit crash/relaunch trials in nightly or release qualification, plus at least 10 smoke trials in pull-request CI, proving at most one second of accepted edits is lost and every restored snapshot is atomic.
- [ ] 14.2 Inject disk-full, quota, permission, busy/locked, IO, transaction, sync, and verification failures while continuously editing and verify in-memory state is never discarded.
- [ ] 14.3 Measure at least 20 first-launch cold runs and meet the 500 ms 95th-percentile process-start-to-focused-editor budget.
- [ ] 14.4 Measure at least 20 warm-cache and cold-cache `CrawlLargeDocument` restores and meet the 700 ms and 1,500 ms 95th-percentile launch-to-focus budgets.
- [ ] 14.5 Exercise at least 5,000 representative edits with autosave enabled during nightly or release qualification and meet the 8 ms p95, 16.7 ms p99, and 50 ms maximum main-thread-stall typing budgets; run at least 500 non-gating smoke events in pull-request CI.
- [ ] 14.6 Scroll `CrawlLargeDocument` for at least 30 seconds during nightly or release qualification and meet the 16.7 ms p95, 33.4 ms p99, and 100 ms maximum editor-caused frame-stall budgets.
- [ ] 14.7 Verify concurrent SQLite commits, WAL syncs, checkpoint publication, retry, and recovery do not violate typing, scrolling, selection, or viewport budgets.
- [ ] 14.8 Apply at least 10,000 fixed-size edits during nightly or release qualification, plus at least 1,000 smoke edits in pull-request CI, settle all IO, and prove combined database/WAL/SHM/manifest/two-checkpoint size is at most four times the encoded verified snapshot plus 16 MB and does not grow with edit count.
- [ ] 14.9 Audit the finished Crawl application to confirm it exposes no landmarks, gutter, command palette, visible timestamps, history, search indexing, AI, tools, providers, capture, connectors, persistent storage-health chrome, unrelated notifications, export, or recovered-version merge UI.
- [ ] 14.10 Define pull-request and nightly/release test tiers, run all unit, property, migration, integration, UI, accessibility, IME, crash, corruption, storage-growth, and performance release suites at their specified tier, and retain passing release evidence before implementation is declared complete.
