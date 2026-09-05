## Context

Jort currently has a disposable web interaction prototype and an archived whole-product roadmap, but no native application or active product specifications. This change is the first implementation slice. It must earn trust as a one-document macOS editor before later phases add landmarks, commands, automation, capture, or history.

The difficult boundary is not drawing a text field. It is preserving AppKit text semantics while coordinating invisible line identity, nonblocking persistence, and recovery without allowing the database to become authoritative over newer in-memory edits. The normal keystroke path must remain independent of SQLite latency and failure. Startup must also distinguish a genuinely new or intentionally empty document from missing or corrupt state so that recovery never converts uncertainty into silent data loss.

The supported-load performance fixture, `CrawlLargeDocument`, contains 1,000,000 UTF-16 code units across 25,000 newline-delimited logical lines, includes long lines that wrap, mixed Unicode, emoji, combining marks, and representative whitespace-only lines. Crawl targets arm64 Apple-silicon Macs running macOS 14 or later. Normative performance gates run on the original M1/8 GB hardware class with release builds and no debugger; CI may use a calibrated equivalent and must retain raw signpost results.

## Goals / Non-Goals

**Goals:**

- Present one app-owned plain-text document and make its native editor the first responder as soon as startup has safely resolved the document state.
- Preserve AppKit selection, navigation, undo, clipboard, find, text-input, spelling, accessibility, wrapping, Services, and scrolling behavior.
- Maintain stable identities and minimal timestamps for logical lines without placing metadata in canonical text or visible UI.
- Persist immutable current-state snapshots asynchronously to SQLite/WAL with a one-second maximum dirty-age target under supported load.
- Keep editing available through write failures, expose storage health without stealing focus, and provide bounded automatic plus explicit manual retry.
- Recover cleanly from WAL interruption and preserve corrupt stores before restoring the newest independently verified recovery checkpoint.
- Make launch, interaction, persistence, accessibility, and recovery behavior measurable and testable.

**Non-Goals:**

- Multiple documents, user-selected files, tabs, titles, folders, rich text, or proprietary block semantics.
- A gutter or landmarks, command palette, visible timestamps, version-history UI, revision browsing, or search indexing.
- AI, agents, tools, providers, scripts, external commands, capture, connectors, accounts, network access, or plugin infrastructure.
- Export or non-storage notifications.
- Automatic merging of a newly edited document with an older document recovered later; Crawl prevents automatic startup from creating that divergence, and a later GA change will define an explicit merge workflow.
- Cross-device sync, collaboration, encryption beyond platform file protection, or final distribution-channel decisions.

## Decisions

### 1. Use a native AppKit text system inside a minimal SwiftUI shell

The native project is generated with XcodeGen 2.46.0 from a checked-in YAML manifest. The tool version, manifest, shared schemes, entitlements, build settings, and package pins are the configuration source of truth; the generated `.xcodeproj` is disposable and SHALL NOT receive hand-maintained changes. CI verifies the XcodeGen version and regenerates the project before building. Crawl enables App Sandbox and accesses only its app-owned Application Support container. GRDB 7.10.0, pinned to that exact release through Swift Package Manager, is the sole third-party runtime dependency and is confined to the storage module so no GRDB type crosses into the document core or editor host.

The document surface will be an `NSTextView` backed by TextKit and hosted through `NSViewRepresentable`. The text view remains the owner of text-input interpretation, selection, marked text, find UI, undo manager integration, accessibility, and scrolling. Jort adds only a narrow edit-observation layer and does not replace native key handling. The initial implementation will use TextKit 2 where its APIs are reliable, with the host boundary narrow enough to apply an AppKit workaround without changing the document model.

The scrollable editor is the only persistent content in the ordinary app window. Storage-health transitions may place a temporary, focus-preserving notice over or adjacent to the editor, but no badge, banner, footer, toolbar item, or other ambient storage indicator remains after the notice expires or is dismissed. A `File > Retry Saving` command is enabled only while manual retry is available so recovery remains possible without persistent status chrome. The editor uses ordinary visual line wrapping and no horizontal scrolling. Spell checking, automatic correction, substitutions, and text replacements follow macOS user settings and standard Edit-menu controls; Jort adds no remote or custom checker.

Alternative considered: SwiftUI `TextEditor`. It does not expose enough control over marked-text transactions, viewport instrumentation, large-document behavior, or metadata-aware undo. A custom editor engine was rejected because it would sacrifice the native behaviors this MVP exists to prove. Hand-maintaining an Xcode project was rejected in favor of a reviewable, reproducible XcodeGen manifest; Tuist was rejected as unnecessary lifecycle machinery for this initial application. A handwritten SQLite C wrapper was rejected because it would duplicate mature transaction, migration, concurrency, and error-handling infrastructure without improving Jort's storage guarantees.

### 2. Keep one main-actor in-memory state authoritative during the process

`EditorSession` is a `@MainActor` object containing canonical text, a monotonically increasing generation, ordered logical-line metadata, selection/viewport integration, and the current dirty/durable generation. Text mutations happen immediately through `NSTextView`; the edit observer synchronously normalizes the affected local line window and advances `EditorSession` before scheduling storage. SQLite never pushes an older snapshot back into a running editor.

Ordinary accepted edits update the text view and `EditorSession` in the same native transaction. IME marked-text candidate updates are display state owned by `NSTextView`, not accepted canonical document state. They do not advance `EditorSession`, allocate line identities, enter undo metadata, or schedule persistence. Composition commit submits the complete replacement to `EditorSession` as one accepted edit; cancellation leaves canonical state unchanged. A crash may lose an active uncommitted composition, while committed text follows the ordinary one-second dirty-age guarantee.

Each `DocumentSnapshot` is an immutable, short-lived value containing the document identifier, generation, canonical text, and ordered line records. The main actor captures only copy-on-write value handoffs and the localized metadata delta required to publish a coherent generation. UTF-8 materialization, full-document hashing, recovery-envelope encoding, and SQLite work occur off the main actor. Immutability prevents a background writer from observing a half-mutated generation; it does not mean snapshots accumulate in memory or SQLite. The scheduler retains only the newest pending value it still needs, and the primary database contains one current state rather than one row per `DocumentSnapshot`. If generation 12 finishes after generation 13 was queued, it may establish durability for 12 but cannot clear the dirty state for 13 or overwrite a newer committed generation. A release benchmark must prove that snapshot capture itself remains inside the native typing budget before full-state persistence is accepted.

Alternative considered: making a storage actor the document source of truth. That would put actor hops and storage failure semantics too close to typing and make stale writes capable of rolling back newer text.

### 3. Model only newline-delimited logical-line identity and timestamps

Canonical text uses U+000A LF as its only line separator. Each accepted paste, Service replacement, automatic correction, or committed IME transaction normalizes CRLF, bare CR, U+0085 NEXT LINE, U+2028 LINE SEPARATOR, and U+2029 PARAGRAPH SEPARATOR to LF before canonical publication, while remaining one native undo transaction. A trailing LF creates a final empty structural line; therefore a document always has one more logical line than canonical LF separators, including one structural line for the zero-character document.

The empty document has one structural logical line with a stable `LineID` and nil timestamps. Every line record contains only `LineID`, optional `createdAt`, and optional `lastEditedAt`; ordinal and character ranges are derived. Non-whitespace content receives timestamps. Whitespace classification uses an embedded scalar/range table pinned to the Unicode 17.0 `White_Space` derived property rather than the host OS's evolving Unicode database. Whitespace-only lines retain identity while present but both timestamps are nil.

Timestamps use a fixed UTC RFC 3339-compatible ISO 8601 representation with exactly six fractional-second digits, such as `2026-08-24T14:32:18.123456Z`. Formatting is Gregorian, locale-independent, and never omits the `Z` or fractional digits. UUIDs use lowercase hyphenated text when encoded.

The edit normalizer operates on the pre-edit lines intersecting the edited UTF-16 range plus one neighbor on each side, then re-splits that window on newline boundaries:

1. An edit within one line keeps its identity and creation time and advances its edit time.
2. On split, the leading fragment keeps the original identity and creation time and advances `lastEditedAt` to the transaction time when it remains non-whitespace. Each trailing fragment receives a new identity and, when non-whitespace, both timestamps at the transaction time. Any whitespace-only result has nil timestamps.
3. On join, the leading line keeps its identity. Removed records are retained in the current undo transaction so the inverse edit restores them exactly.
4. A replacement preserving both surrounding newline boundaries keeps the target identity; replacement across boundaries follows split/join rules.
5. Paste is treated as one edit transaction and applies the same deterministic rules.
6. IME marked-text updates are provisional. They update the native display but do not advance durable generation or reconcile final line identity until composition commits or is cancelled.

Text and metadata deltas share the native undo manager's grouping. Undo and redo use the text system for the text mutation and replay the paired identity delta, producing one new current generation that is eligible for autosave.

Alternative considered: persisting raw character offsets or recomputing identifiers on every launch. Offsets become stale after edits, and regenerated IDs would prevent later phases from safely anchoring metadata.

### 4. Store one complete current state in SQLite/WAL off the keystroke path

`PersistenceScheduler` and `SQLiteStore` are actors outside the main actor. `SQLiteStore` encapsulates pinned GRDB APIs and explicit SQL; GRDB records or connections never cross its boundary. The store uses WAL mode, foreign keys, prepared statements, explicit transactions, a versioned schema, and durability settings validated by crash tests. The initial schema is intentionally small:

- `document`: singleton identifier, canonical text, generation, content hash, initialized-empty marker, and schema version.
- `line_meta`: document identifier, ordinal, stable line identifier, creation time, and last-edit time.
- `store_state`: last complete generation, clean-shutdown/session marker, migration version, and recovery-checkpoint generation.

Every commit replaces the singleton document and its ordered line records in one transaction, then verifies generation, line count, and a SHA-256 hash of the canonical UTF-8 text before reporting success. Committed `DocumentSnapshot` values are not appended as records, and no visible history or user-browsable revisions are retained. SQLite auto-checkpointing and explicit off-main-actor lifecycle/size checkpoints bound WAL growth; checkpointing never runs on the keystroke path.

Scheduling uses a 150 ms idle debounce and a maximum one-second dirty-age deadline. Continuous typing therefore still produces a durable snapshot at least once per second under normal supported load. Deactivation and orderly termination request a best-effort immediate flush, but the main thread never waits indefinitely and hard-crash correctness does not depend on termination callbacks.

Alternative considered: storing a diff from every prior state. A diff chain can reduce write amplification, but it accumulates records, makes startup and corruption recovery depend on replay, and creates new compaction and partial-chain failure modes. Crawl therefore begins with one coalesced current state plus two bounded recovery checkpoints. Release tests measure settled primary/WAL/checkpoint footprint and repeated-edit write amplification. If those measurements fail the specified bound, the preferred next optimization is independently verifiable chunked current-state storage, not an unbounded diff chain.

### 5. Maintain independent, bounded recovery checkpoints rather than history

After successful primary commits, a lower-priority recovery writer coalesces work, publishes no more frequently than once per second, and publishes the newest available snapshot no later than one second after the first unpublished primary generation under normal supported load. It writes a versioned deterministic UTF-8 JSON full-state envelope to one of two rotating checkpoint files. JSON uses sorted object keys, document-order arrays, decimal integers, lowercase hyphenated UUIDs, fixed UTC timestamp strings or explicit `null`, no byte-order mark, and no insignificant whitespace. Each envelope contains the generation, document identifier, text, line records, schema version, byte counts, SHA-256 canonical-text hash, and a SHA-256 checksum over the exact persisted envelope payload excluding the checksum field. Publication is write-temp, fsync, atomic rename, directory sync. Recovery verifies the stored bytes directly and never relies on re-encoding JSON identically. A checkpoint is advertised in a small manifest only after it can be decoded and its checksum, line count, and document hash verify.

These two rotating files are operational recovery material, not revision history: they are not exposed to the user, searched, or retained beyond the two slots. Their independent encoding and publication path permits recovery when the SQLite file or WAL is structurally corrupt, without claiming protection from whole-volume loss.

Alternative considered: keeping recovery rows inside the primary database. They would share its corruption domain. Unbounded snapshot retention was rejected because it would quietly implement history and exceed this change's scope.

### 6. Use an explicit storage-health and retry state machine

Storage state is independent of editor availability:

| State | Entry and behavior |
|---|---|
| `starting` | Inspect primary/WAL/SHM files, checkpoints, manifests, prior-store markers, and quarantine records before publishing any editable blank. Verified non-empty state may open as soon as it resolves. Startup classification has a two-second safety ceiling. |
| `firstLaunch` | The evidence scan conclusively finds no prior state. Present and focus an intentional empty document as soon as that conclusion is available, then initialize storage asynchronously. |
| `healthyEmpty` | A verified initialized store contains the intentional empty document and its structural line. Empty is valid state, not evidence of missing data. |
| `healthy` | The newest in-memory generation is durable and verified. No storage notification is shown. |
| `dirty` | Newer in-memory state exists; a debounced or deadline flush is scheduled. Editing remains available. |
| `retrying` | A write failed. Preserve the latest in-memory snapshot and retry the episode up to three times after 250 ms, 1 s, and 4 s, coalescing newer edits into the next attempt. |
| `needsManualRetry` | The bounded retries failed. Keep accepting edits, show an ephemeral nonmodal “Changes aren’t saving” notice with Retry and a concise reason such as disk full, and enable `File > Retry Saving`. Do not restart an automatic retry storm for every keystroke. |
| `interruptedShutdown` | The prior session lacks a clean marker. Let SQLite replay WAL, then verify integrity, generation, text hash, and line records before loading. Continue as healthy if verified; otherwise enter corruption recovery. |
| `corruptStore` | Integrity or snapshot verification fails. Close SQLite and preserve the database, WAL, and SHM together before any replacement. Do not initialize an empty document. |
| `recovering` | Inspect preserved primary material and both checkpoints newest-first, accepting only a fully verified state. Rebuild a fresh store from the newest verified state and verify it before publication. |
| `recovered` | Open the verified recovered state, focus the editor, and show an ephemeral nonmodal notice identifying recovery and the preserved damaged-store location. |
| `recoveryRequired` | No candidate verifies or damaged material cannot be preserved. Keep it untouched and require an explicit recovery decision; starting a new empty document is allowed only after confirmation and never deletes the preserved material. |

If classification is still unresolved at the two-second ceiling, Jort shows a neutral noneditable loading/recovery presentation and continues resolving; it does not infer first launch, expose a writable blank, or later replace user-entered text. A blank is presented only after genuine first launch or a verified intentional-empty snapshot is established.

Automatic retry counts are per continuous failure episode. Manual Retry resets the three-attempt budget and always targets the newest in-memory generation. A successful write clears the episode only after verification. Neither write errors nor notification actions take first responder from the editor. Ephemeral notices expire or dismiss without leaving window chrome. Retry remains keyboard and accessibility reachable through the notice while visible and through the conditional File-menu command afterward.

If the user explicitly starts a new empty document from `recoveryRequired` and older content becomes recoverable later, Crawl preserves both states but does not merge them. A later GA change will specify a user-controlled comparison and merge workflow; no automatic recovery path may overwrite the newer in-memory document.

Alternative considered: modal alerts on each failure. They interrupt input, can repeat rapidly, and make storage availability a prerequisite for editing.

### 7. Preserve corrupt material before publishing recovered state

The primary database, WAL, SHM, and store manifest live together inside one `active-store` directory under Jort's Application Support container. Recovery checkpoints live in a sibling `recovery` directory so they do not share the SQLite-format corruption domain, though they intentionally do not claim protection from whole-volume loss.

On corruption, the store connection closes and the complete `active-store` directory is atomically renamed on the same volume into a uniquely named quarantine directory. This constant-space directory rename is the backup; recovery never mutates or compresses it. Gzip or another archive operation is not part of preservation because it would require additional readable source bytes, temporary capacity, and an interruptible full copy while storage may already be unhealthy. If the same-volume atomic rename cannot be completed, Jort leaves the source material in place and enters `recoveryRequired` rather than overwriting it.

The recovery coordinator validates candidates by schema version, complete decode, SQLite integrity where applicable, document identifier, monotonic generation, SHA-256 text hash, line count/order, unique line IDs, and line-to-text structural agreement. It picks the highest verified generation, rebuilds into a sibling `active-store.pending` directory, validates that store, and atomically renames the verified directory to `active-store`. An intentional empty document is accepted only when the candidate includes the initialized-empty marker and valid empty-state metadata.

### 8. Treat keyboard, accessibility, and performance as release gates

The application provides standard File/Edit/View/Window/Help menus as appropriate for a one-document app, with native selectors and conventional shortcuts. It does not intercept text-system movement or selection commands. The editor exposes a named multiline text-area accessibility element with value, selection, insertion point, visible range, and range bounds. Storage notices use status semantics, announce only state transitions, remain keyboard reachable, and never move editor focus automatically.

Signposts cover process start, startup-classification resolution/deadline, state verification, window display, first-responder focus, first edit, edit normalization, snapshot capture, viewport layout, persistence enqueue/commit/verification, WAL checkpointing, retry, and recovery. Release tests enforce the exact budgets in the capability specifications using `CrawlLargeDocument`, including repeated warm/cold launches, key-event latency percentiles, scroll frame times, settled storage footprint, and edit-to-durable-generation latency.

Validation is tiered. Pull-request CI runs complete deterministic unit and state-machine suites plus small performance and failure smoke samples. Nightly or release qualification on calibrated hardware runs 20 launch samples per condition, 5,000 representative typing events, 2,000 autosave-latency samples, 30 seconds of continuous scrolling, 100 randomized crash/relaunch trials, and 10,000 fixed-size storage edits. Manual VoiceOver and real-IME coverage is required on the minimum and latest supported macOS releases, with automated smoke coverage on intermediate supported releases. Raw measurements are retained; the reduced counts do not relax the latency, atomicity, or crash-loss thresholds.

## Risks / Trade-offs

- **TextKit 2 defects or behavior differences across supported macOS releases** → Keep the editor host narrow, test each supported release, and use localized AppKit fallbacks without replacing native text input.
- **Logical-line identity diverges from native undo or IME composition** → Record paired text/metadata transactions, add randomized split/join/undo property tests, and exercise real marked-text clients in UI tests.
- **Full current-state writes amplify IO for large documents** → Coalesce writes, bound WAL/checkpoint growth, enforce the settled-footprint benchmark, and prefer verifiable chunked current-state storage over diff chains if measurement requires optimization.
- **Disk full prevents both primary persistence and a new corruption backup** → Preserve in-memory edits, stop destructive recovery, retain source files in place, and require explicit user action after capacity is restored.
- **The newest recovery checkpoint can lag the primary store** → Primary SQLite/WAL recovery remains first choice; checkpoints run at most one second behind under normal load and are used only when newer state does not verify.
- **Launch verification competes with immediate focus** → Resolve verified state as quickly as possible, enforce the two-second classification ceiling, show a neutral recovery/loading presentation if unresolved, and never flash an unverified editable blank in place of prior state.
- **Ephemeral storage UI can be missed** → Announce each health transition once, keep notices visible for an accessible interval, and retain `File > Retry Saving` while manual retry is available without showing ambient window status.

## Migration Plan

1. Add the XcodeGen-defined, sandboxed native application and version-1 `active-store` directory under Jort's Application Support container without reading or modifying the web prototype's state.
2. On launch, complete the storage-evidence classification before publishing an editable blank. Genuine first launch creates an intentional-empty snapshot and initializes the version-1 store asynchronously; unresolved classification at two seconds remains in neutral recovery/loading state, and creation failure enters the normal write-failure path.
3. Gate any future schema migration on preservation of the complete store bundle and a verified recovery checkpoint. Run migrations in a temporary store and publish only after verification.
4. A rollback to an earlier application build must leave newer stores and quarantine directories untouched. Unsupported schema versions enter `recoveryRequired`; they are never reinitialized as empty.

## Open Questions

No blocking product or architecture questions remain for implementation. Crawl targets arm64 macOS 14 or later and uses the original M1/8 GB class as its normative performance baseline. The initial bundle identifier may use `com.josephwegner.Jort` unless signing or an owned distribution namespace requires a different permanent identifier before release. Comparison and merge of a newer edited document with older content recovered later is intentionally deferred to a GA change.
