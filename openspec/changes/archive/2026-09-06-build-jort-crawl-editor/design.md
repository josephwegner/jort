## Context

Jort currently has a disposable web interaction prototype and an archived whole-product roadmap, but Crawl is the first shipped native slice. Implementation already exists as a dark-only AppKit one-document editor with compiler-enforced modules, a single `DocumentCoordinator`, versioned SQLite payload persistence, and a process-lifetime store lock.

The difficult boundary is not drawing a text field. It is preserving AppKit text semantics while coordinating invisible line identity, nonblocking persistence, and recovery without allowing the database to become authoritative over newer in-memory edits. Later phases (landmarks, palette, history, tools, agents) must mutate the document through the same transaction API; they must not grow a second owner of live state.

The committed performance fixture is `canvas-10000.txt`: 10,000 representative lines with ASCII, Japanese, combining-language text, and emoji. Crawl targets macOS 14 or later with Swift 6 complete concurrency. CI regression ceilings on that fixture are generous shared-runner gates, not user-facing latency promises.

## Goals / Non-Goals

**Goals:**

- Present one app-owned plain-text document in a single AppKit window and focus its TextKit 2 editor after persistence load completes.
- Keep `DocumentCoordinator` as the only mutable live `DocumentState`; adapters and persistence consume immutable snapshots and typed transactions.
- Preserve AppKit selection, navigation, undo pairing, clipboard, find, text-input, wrapping, Services, scrolling, and a viewport-bounded line-number gutter.
- Maintain stable textual-lineage identities and minimal timestamps for logical lines without placing metadata in canonical text or visible copy.
- Persist one current-state versioned JSON payload asynchronously to SQLite/WAL with a companion `Recovery.json`, using system `libsqlite3`.
- Keep editing available through write failures, expose typed persistence state without stealing focus, and provide three automatic retries plus manual Retry.
- Recover by preserving the damaged store bundle and atomically publishing a rebuilt sibling directory from a validated recovery snapshot.
- Enforce one running process per data directory.
- Make launch, interaction, persistence, accessibility, and recovery behavior measurable against the committed fixture.

**Non-Goals:**

- Multiple documents, user-selected working files, tabs, folders, rich text, or proprietary block semantics.
- Landmark mutation UI, command palette, visible timestamps, version-history UI, revision browsing, or search indexing.
- AI, agents, tools, providers, scripts, external commands, capture, connectors, accounts, network access, or plugin infrastructure.
- GRDB or any other third-party runtime persistence library.
- A SwiftUI editor shell, `EditorSession` as a second live-state owner, or two rotating independently encoded checkpoint files.
- A strict one-second dirty-age or half-second user-facing save deadline.
- Automatic merging of a newly edited document with older recovered content; recovery-copy import and unsafe-load editing remain later product work.
- Cross-device sync, collaboration, encryption beyond platform file protection, or signed public distribution.

## Decisions

### 1. Use a native AppKit text system in an AppKit window

The native project is generated with XcodeGen 2.46.0 from a checked-in YAML manifest. The tool version, manifest, shared schemes, entitlements, build settings, and versions are the configuration source of truth; generated project files are checked for drift and SHALL NOT receive hand-maintained semantic changes. Crawl is a local sandboxed-style app that reads and writes only its Application Support container or an explicit `JORT_DATA_DIRECTORY`. There is no third-party runtime package; SQLite is the system `libsqlite3`.

The document surface is a TextKit 2 `NSTextView` in an `NSScrollView`, hosted by `EditorViewController` inside an `NSWindow`. A SwiftUI `NSViewRepresentable` shell was tried and removed: it added no product benefit during native layout verification. The text view remains the owner of text-input interpretation, selection, marked text, find UI, accessibility, and scrolling. Jort adds a narrow edit-observation layer and a custom undo manager so text and metadata share one restore transaction.

The editor is the only persistent content besides a viewport-bounded line-number gutter. Storage-health notices are nonmodal and appear only while attention is required. Successful saves are silent. `File > Save Now` (Command-S) retries the newest snapshot; `File > Save Recovery Copy…` writes a separate JSON file and is not a working-document export. Spell-check substitutions, automatic quotes/dashes/replacements, and link detection are off.

Alternative considered: SwiftUI `TextEditor`. It does not expose enough control over marked-text transactions, viewport instrumentation, or metadata-aware undo. A custom editor engine was rejected because it would sacrifice the native behaviors this MVP exists to prove. GRDB was rejected once the store stayed a single payload blob; a handwritten wrapper around `libsqlite3` is enough for WAL, explicit SQL, and checked return codes.

### 2. Keep one main-actor coordinator authoritative during the process

`DocumentCoordinator` is a `@MainActor` object and the only mutable live `DocumentState`. It owns canonical text, a monotonically increasing live revision, ordered logical-line metadata, optional future landmark records, and the last committed revision. Every accepted mutation enters as a `DocumentTransaction` with a base revision, origin, undo policy, and typed mutation. Stale base revisions are rejected and do not advance the counter.

`EditorViewController` owns AppKit objects and translates native edits, undo/redo, and later programmatic insertions into transactions. `PersistenceController` is `@MainActor` for scheduling and callbacks; it never owns independently mutable domain state. `SQLiteStore` is an actor that owns the connection and filesystem install path. Snapshots crossing those boundaries are immutable and `Sendable`.

Ordinary accepted edits update the text view immediately, then submit one transaction. IME marked-text candidate updates are display state owned by `NSTextView`. They do not advance the coordinator, allocate line identities, enter undo metadata, or schedule persistence. Composition commit submits the complete replacement as one accepted edit; if AppKit does not supply a single stable range, reconciliation MAY use a common UTF-16 prefix/suffix fallback. Cancellation leaves canonical state unchanged.

Alternative considered: making a storage actor the document source of truth. That would put actor hops and storage failure semantics too close to typing and make stale writes capable of rolling back newer text. Moving existing view-controller fields into an actor without a transaction API would only serialize an unclear mutation model.

### 3. Model textual-lineage logical-line identity and timestamps

`LineID` is a UUID denoting textual lineage. References resolve only by UUID. Character offsets and visual rows are derived. `NSString.lineRange` defines logical lines, including a final empty structural line when the document is empty or ends with LF or CR.

The empty document has one structural logical line with a stable ID and nil timestamps. Every line record contains `LineID`, UTF-16 `location`/`length`, optional `createdAt`, and optional `lastEditedAt`. Non-whitespace content receives timestamps. Whitespace classification uses Foundation `CharacterSet.whitespacesAndNewlines`. Whitespace-only lines retain identity while present but both timestamps are nil.

The edit normalizer operates on the pre-edit lines intersecting the edited UTF-16 range plus one neighbor on each side (to catch CR/LF boundary changes), then re-splits that window:

1. An edit within one line keeps its identity and creation time and advances its edit time when visible content changed.
2. On split, the leading fragment keeps the original identity; each trailing fragment receives a new identity. Inserting complete terminated lines at an existing line's start creates new IDs and moves the original line with its remaining text.
3. On join, the leading line keeps its identity. Removed IDs detach and appear on `TransactionResult`; they are not reassigned to unrelated text.
4. A replacement preserving both surrounding terminator boundaries keeps the target identity; replacement across boundaries follows split/join rules. Cut then paste creates new lineage rather than inferring movement.
5. Paste is one edit transaction and applies the same rules.
6. IME marked-text updates are provisional until commit.

Text and metadata share the custom undo manager. Undo and redo restore a complete prior snapshot through a restore transaction and advance the live revision once. This MAY break native TextEdit-style coalescing so pairs stay deterministic. Undo is memory-only and does not survive relaunch.

The current payload may carry an empty landmark collection so Walk can migrate without inventing a second snapshot type. Crawl does not expose landmark UI or treat landmarks as a product feature.

Alternative considered: persisting raw character offsets or recomputing identifiers on every launch. Offsets become stale after edits, and regenerated IDs would prevent later phases from safely anchoring metadata.

### 4. Store one complete current state as a versioned SQLite payload

`PersistenceController` schedules writes on the main actor and sends immutable snapshots to `SQLiteStore`. The store uses WAL mode, `synchronous=FULL`, foreign keys, prepared statements, explicit transactions, and checked SQLite return codes. The schema is intentionally small: a singleton `current_state(id, payload)` table plus `PRAGMA user_version`. The payload is a versioned JSON envelope separate from live `DocumentState`.

Released formats are decoded explicitly:

- SQLite/payload v1: legacy `{schemaVersion, text, revision, lines}` fixtures migrate to v2.
- SQLite/payload v2: `{formatVersion, document: {id, content, liveRevision, lines, landmarks}}`.
- Future versions are refused without mutation. Unknown version-zero schemas are not treated as new empty databases and are not rewritten in place.

Every successful save replaces the singleton payload and then writes `Store/Recovery.json`. The committed revision is acknowledged only after the entire save operation succeeds. A recovery-snapshot failure after the SQLite commit remains a failed save and leaves the document dirty. Maximum serialized payload is 64 MiB.

Scheduling uses a fixed approximately half-second flush rather than a trailing idle debounce, so continuous typing cannot postpone saving indefinitely. This is a best-effort internal cadence, not a user-facing deadline. Deactivation, window close, and quit request an immediate flush; quit waits and warns if it does not succeed.

Alternative considered: normalized `document` / `line_meta` / `store_state` tables behind GRDB, plus a one-second dirty-age deadline. The review handoff kept the single-state blob until query or atomicity requirements justify normalization, and told the product not to promise a strict save deadline. Independently rotating JSON checkpoints were also rejected; `Recovery.json` is part of the same save operation so a “healthy” save cannot silently omit recovery material.

### 5. Preserve the store bundle and publish replacements atomically

The canonical bundle is `Store/` under the data root (`~/Library/Application Support/Jort` or `JORT_DATA_DIRECTORY`), containing `Jort.sqlite`, WAL, SHM, and `Recovery.json`. A process-lifetime nonblocking exclusive `flock` on `Jort.lock` owns that directory. A second process must not open, recover, or write; it should activate the existing owner when practical and exit. Distinct data directories may run independently. A crash releases the OS lock.

Load inspects a private copy so future versions and failed migrations never modify source WAL/SHM. Migration and recovery copy originals to a uniquely named `PreMigration-*` or `Damaged-*` backup, build a sibling `.Replacement-*` directory, close and reopen it for validation, then atomically swap or rename the whole directory into `Store/`. Injected failure before the final swap must leave either the original canonical store or no half-installed replacement.

If `Recovery.json` is missing or invalid, initial-load failure leaves originals untouched. The user may write a separate recovery copy of current in-memory work; this change does not import that file back as the working store.

Alternative considered: deleting `Jort.sqlite` then writing a replacement in place, or gzipping the damaged store. In-place delete can lose the last canonical store if the replacement write fails. Compression needs extra readable bytes and temporary capacity while storage may already be unhealthy.

### 6. Use a typed persistence state machine

`PersistenceState` distinguishes loading, clean at a committed revision, dirty, writing, retry scheduled, save failed (with remaining or exhausted retries), load blocked by a future version, load failed, and ownership conflict. UI copy lives in AppKit.

Automatic retry is three attempts per continuous failure episode. Later keystrokes update the retained dirty snapshot without restarting an exhausted episode. Manual Retry / Command-S resets the budget and always targets the newest in-memory revision. Neither write errors nor notice actions take first responder from the editor. Routine successful saves stay quiet.

Alternative considered: the earlier Crawl plan's `starting` / `firstLaunch` / `healthyEmpty` / `corruptStore` / `recoveryRequired` matrix with a two-second classification ceiling and ephemeral notices that leave no chrome. The implemented product still refuses to guess an empty store when prior files exist, but first launch is simply “no database present,” load failure keeps an in-memory editor, and failed-save chrome stays visible and actionable rather than expiring.

### 7. Treat keyboard, accessibility, and performance as release evidence

The application provides Jort/File/Edit/Window menus with native selectors and conventional shortcuts, including Find and Save Now. It does not intercept text-system movement or selection commands except to pair undo. The editor exposes a “Jort document” multiline text-area accessibility element. Storage notices remain keyboard reachable and never move editor focus automatically.

Performance uses the committed 10,000-line fixture and reports distributions. Initial CI ceilings (2 s launch, 100 ms debug transaction p95, 250 ms serialization p95, 100 ms sustained-edit p95, 100 ms gutter ceiling) are shared-runner regression gates. They do not replace later hardware qualification and do not promise the older CrawlLargeDocument / 8 ms typing / one-second dirty-age numbers.

Validation is tiered. Headless document/persistence tests run without constructing AppKit. Native adapter tests exercise `NSTextView` inside `xctest`. UI smoke is a separate user-run ad-hoc-signed path. Thread Sanitizer covers foundation suites. Physical IME, complete VoiceOver journeys, and power-loss remain explicit remaining limits.

## Risks / Trade-offs

- **TextKit 2 defects or behavior differences across supported macOS releases** → Keep the editor host narrow, test each supported release, and use localized AppKit fallbacks without replacing native text input.
- **Logical-line identity diverges from native undo or IME composition** → Record restore transactions, add randomized split/join/undo property tests, and exercise marked-text commit plus prefix/suffix fallback.
- **Full current-state writes amplify IO for large documents** → Keep the blob until measurements on the 10k fixture and later fixtures justify chunking; do not introduce an unbounded diff chain.
- **Disk full prevents both primary persistence and a new backup** → Preserve in-memory edits, stop destructive recovery, retain source files in place, and require explicit retry or recovery-copy after capacity is restored.
- **`Recovery.json` can lag or fail after SQLite commit** → Treat that as a failed save; recovery may restore the previous valid snapshot rather than claiming the unconfirmed revision.
- **A second process from an older unsigned 0.1 build cannot be locked out** → Document that users must quit older builds before launching 0.2; the new lock cannot constrain a binary that never took it.
- **Breaking native undo coalescing surprises TextEdit users** → Accept smaller undo steps as the cost of exact metadata restore; keep one user-visible undo operation per registered group.
- **Gutter drawing can force whole-document layout** → Enumerate only already visible TextKit 2 fragments and binary-search logical-line starts.

## Migration Plan

1. Add the XcodeGen-defined native application and `Store/` directory under Jort's Application Support container, or `JORT_DATA_DIRECTORY`, without reading or modifying the web prototype's state.
2. On first 0.2 launch, migrate a legacy root-level v1 `Jort.sqlite` / `Recovery.json` into `Store/` without deleting the originals (`PreMigration-*`). Genuine first launch creates an empty v2 store when no database exists.
3. Gate any future schema or payload migration on preservation of the complete store bundle and a validated sibling replacement. Publish only after close/reopen verification and atomic directory swap.
4. A rollback to an earlier application build must leave newer stores and diagnostic backups untouched. Unsupported schema versions enter load-blocked-future; they are never reinitialized as empty.
5. Recovery-copy import, comparison, and merge of a newer edited document with older recovered content remain deferred.

## Open Questions

No blocking product or architecture questions remain for describing the implemented Crawl slice. Remaining release limits are validation, not design forks: physical IME matrix, complete VoiceOver journey, power-loss durability, memory distributions on representative hardware, and public signing/notarization. The bundle identifier is `dev.jort.editor`. Comparison and merge of a newer edited document with older recovered content stay deferred to a later change.
