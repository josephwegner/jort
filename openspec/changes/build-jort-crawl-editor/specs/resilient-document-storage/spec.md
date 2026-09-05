## ADDED Requirements

### Requirement: In-memory state remains authoritative while Jort runs
Jort SHALL apply accepted edits to the in-memory document immediately and SHALL NOT await, reject, revert, replace, or discard an edit because persistence is slow or unavailable.

#### Scenario: Storage is healthy
- **WHEN** the user edits the document
- **THEN** the visible text and paired logical-line metadata update before any storage round trip
- **AND** an immutable generation snapshot is scheduled for asynchronous persistence

#### Scenario: Storage is unavailable
- **WHEN** SQLite cannot open, begin, commit, sync, or verify a write
- **THEN** typing, selection, undo/redo, copy/paste, find, wrapping, and scrolling remain available
- **AND** the newest in-memory text and metadata remain authoritative and dirty

#### Scenario: Older write completes after newer edits
- **WHEN** generation N becomes durable while generation N+1 or later exists in memory
- **THEN** Jort records N as an available durable generation without marking the document fully saved
- **AND** never loads generation N over the newer in-memory state

### Requirement: One current state persists atomically in SQLite WAL mode
Jort SHALL persist exactly one current singleton document, ordered logical-line metadata, generation, schema version, initialized-empty marker, and SHA-256 verification hashes in one explicit SQLite transaction using WAL mode. Pinned GRDB APIs and explicit SQL SHALL be encapsulated behind the storage boundary, and no GRDB connection or record type SHALL enter the document core or editor host.

#### Scenario: Snapshot commit succeeds
- **WHEN** SQLite commits a scheduled snapshot
- **THEN** canonical LF text and all ordered line records represent the same generation
- **AND** Jort verifies generation, content hash, line count, line order, and line-identity uniqueness before reporting storage healthy

#### Scenario: Snapshot fields are encoded
- **WHEN** a timestamp or identifier is written to SQLite or recovery material
- **THEN** timestamps use UTC RFC 3339-compatible ISO 8601 with exactly six fractional-second digits and identifiers use lowercase hyphenated UUID text
- **AND** the content hash is SHA-256 over the canonical UTF-8 text bytes

#### Scenario: Immutable handoff snapshots are coalesced
- **WHEN** multiple immutable `DocumentSnapshot` values are produced while persistence is pending
- **THEN** Jort retains only the generations required for an active write and the newest pending state
- **AND** SQLite does not append each handoff snapshot as history or a replay chain

#### Scenario: Transaction is interrupted
- **WHEN** the process exits or crashes before a snapshot transaction commits
- **THEN** relaunch loads either the complete prior generation or the complete new generation
- **AND** never combines text from one generation with metadata from another

#### Scenario: Intentional empty snapshot persists
- **WHEN** the user deletes all document text and that generation commits
- **THEN** the store records a verified intentional-empty marker and one structural line identity
- **AND** relaunch treats the empty document as valid saved state rather than missing data

### Requirement: Current-state storage growth is bounded
Jort SHALL bound primary database, WAL, SHM, and rotating-checkpoint growth relative to the current encoded document state and SHALL NOT allow storage to grow with the lifetime count of same-sized edits.

#### Scenario: WAL reaches its configured threshold
- **WHEN** WAL growth reaches the configured page or byte threshold
- **THEN** Jort schedules an off-main-actor SQLite checkpoint without blocking the keystroke path
- **AND** may request a truncating checkpoint at safe lifecycle or idle boundaries

#### Scenario: Repeated fixed-size edits settle
- **WHEN** `CrawlLargeDocument` receives at least 10,000 edits with no net document growth during nightly or release qualification and all primary/checkpoint work then settles
- **THEN** the database, WAL, SHM, manifest, and two recovery slots contain no retained per-edit snapshot or diff chain
- **AND** their combined settled size is at most four times the verified encoded snapshot size plus 16 MB of fixed SQLite and manifest overhead

#### Scenario: Full-state footprint misses its release bound
- **WHEN** the settled-footprint or write-amplification benchmark fails under normal supported load
- **THEN** Crawl is not release-ready until storage is optimized without weakening atomic verification or recovery
- **AND** any optimization remains bounded current-state storage rather than an unbounded historical diff chain

### Requirement: Autosave meets bounded persistence latency
Jort SHALL debounce ordinary edits for approximately 150 ms, SHALL enforce a maximum one-second dirty-age flush under normal supported load, and SHALL keep all SQLite and checkpoint IO off the main-thread keystroke path.

#### Scenario: Typical edit becomes durable
- **WHEN** an edit is followed by at least 150 ms of idle time while storage is healthy and `CrawlLargeDocument` or a smaller document is open
- **THEN** the edit's generation is committed and verified within 250 ms of the edit at the 95th percentile over at least 2,000 measured edits during nightly or release qualification

#### Scenario: User types continuously
- **WHEN** edits continue without a 150 ms idle period under normal supported load
- **THEN** Jort commits a snapshot containing all edits accepted at least one second before that commit
- **AND** no accepted edit remains absent from every verified durable generation for more than one second

#### Scenario: Autosave runs during typing and scrolling
- **WHEN** SQLite commit, WAL sync, or recovery-checkpoint publication overlaps editor interaction
- **THEN** the native-editor typing and scrolling performance budgets continue to pass
- **AND** selection and viewport remain unchanged by storage completion

### Requirement: Hard-crash loss is bounded under normal supported load
Jort SHALL configure and verify its WAL durability so that, under the supported storage fixture, a forced process termination can lose at most the final one second of accepted edits and cannot invalidate an earlier verified generation.

#### Scenario: Process is killed at a randomized edit boundary
- **WHEN** a crash harness force-terminates Jort at randomized times during continuous edits and immediately relaunches it for at least 100 trials during nightly or release qualification
- **THEN** the restored snapshot contains every edit accepted more than one second before termination
- **AND** the restored text and metadata belong to one verified generation

#### Scenario: Orderly lifecycle boundary occurs
- **WHEN** the app resigns active or receives an orderly termination opportunity while dirty
- **THEN** Jort requests an immediate best-effort flush
- **AND** correctness does not depend on the callback completing before termination

### Requirement: Write failures trigger bounded nonmodal retry
Jort SHALL classify persistence failures, retain the newest dirty snapshot, and automatically retry one continuous failure episode no more than three times after approximately 250 ms, 1 second, and 4 seconds before requiring manual Retry.

#### Scenario: Transient write failure recovers automatically
- **WHEN** a write fails and a subsequent attempt within the three-attempt budget succeeds and verifies
- **THEN** Jort persists the newest coalesced in-memory generation
- **AND** returns storage state to healthy without interrupting editing

#### Scenario: Automatic retries are exhausted
- **WHEN** all three automatic attempts in one failure episode fail
- **THEN** Jort stops automatic retrying for that episode, offers Retry in an ephemeral nonmodal notice, and enables `File > Retry Saving`
- **AND** later keystrokes update the retained dirty snapshot without starting a new retry storm

#### Scenario: User invokes manual Retry
- **WHEN** the user activates Retry after automatic attempts are exhausted
- **THEN** Jort resets one three-attempt budget and attempts to persist the newest in-memory generation rather than the generation that first failed
- **AND** editing remains available throughout the attempt

### Requirement: Disk-full state never destroys edits
Jort SHALL treat SQLite full-disk, quota, and equivalent no-space errors as a storage-health failure and SHALL preserve all subsequently accepted edits in memory until persistence succeeds or the process ends.

#### Scenario: Disk becomes full during commit
- **WHEN** a snapshot commit fails because storage is full
- **THEN** the SQLite transaction does not publish a partial current generation
- **AND** Jort shows an ephemeral nonmodal “Changes aren’t saving” notice that identifies insufficient storage and offers Retry after the bounded attempts

#### Scenario: Space is made available
- **WHEN** the user frees storage and invokes Retry
- **THEN** Jort writes and verifies the newest in-memory generation
- **AND** clears the unhealthy state only after the verification succeeds

### Requirement: First-launch and empty-document states are distinguishable from loss
Jort SHALL create a new empty document automatically only after a conclusive storage-evidence scan establishes that no store bundle, recovery checkpoint, manifest, quarantine material, or prior-store marker indicates earlier Jort state, and SHALL use two seconds as the startup-classification safety ceiling rather than as permission to guess empty.

#### Scenario: Genuine first launch
- **WHEN** no evidence of prior Jort storage exists
- **THEN** Jort conclusively classifies first launch, creates one intentional empty in-memory document, and focuses it
- **AND** failed asynchronous store creation follows the normal write-failure state without blocking edits

#### Scenario: Verified empty document relaunches
- **WHEN** the newest verified snapshot has an intentional-empty marker, empty text, and valid structural-line metadata
- **THEN** Jort restores that empty document as the saved current state
- **AND** does not report corruption or attempt to recover older non-empty state

#### Scenario: Expected store is missing
- **WHEN** a prior-store marker, recovery file, or quarantine record exists but the primary store is absent
- **THEN** Jort enters recovery evaluation
- **AND** does not silently initialize a replacement empty store

#### Scenario: Classification is unresolved at two seconds
- **WHEN** filesystem or verification work has not conclusively classified startup state within two seconds of process start
- **THEN** Jort enters or remains in a neutral noneditable loading/recovery presentation
- **AND** does not publish an editable blank solely because the deadline elapsed

### Requirement: Interrupted shutdown uses verified WAL recovery
Jort SHALL record session cleanliness, treat a missing clean-shutdown marker as an interrupted shutdown, and verify the recovered SQLite state before presenting it as the current document.

#### Scenario: WAL replay produces valid state
- **WHEN** relaunch detects an interrupted shutdown and SQLite WAL replay yields a valid schema, integrity result, generation, content hash, and line structure
- **THEN** Jort restores the newest complete verified generation
- **AND** opens the focused editor without requiring user intervention

#### Scenario: WAL replay does not verify
- **WHEN** the replayed store fails integrity, hash, generation, or line-structure verification
- **THEN** Jort closes the store and enters corrupted-store recovery
- **AND** never exposes the unverifiable state as an empty or healthy document

### Requirement: Recovery checkpoints are bounded and independently verifiable
Jort SHALL maintain exactly two rotating, non-user-visible full-state recovery checkpoints outside the primary `active-store` directory and in an encoding domain independent of SQLite-format corruption, and SHALL publish a checkpoint only after complete verification. Jort does not claim that same-volume checkpoints survive whole-volume loss.

#### Scenario: Primary commit advances recovery material
- **WHEN** one or more primary generations commit successfully
- **THEN** the recovery writer publishes no more frequently than once per second and publishes the newest available snapshot no later than one second after the first unpublished generation under normal supported load
- **AND** retains no more than the two newest verified checkpoint slots

#### Scenario: Checkpoint publication is interrupted
- **WHEN** the process or filesystem interrupts a checkpoint write before atomic publication
- **THEN** the previously published checkpoint remains valid
- **AND** the incomplete temporary file is never selected as recoverable state

#### Scenario: Checkpoint is inspected
- **WHEN** recovery evaluates a checkpoint
- **THEN** it accepts the checkpoint only if schema version, complete decode, document identity, generation, byte count, checksum, text hash, line count/order, and unique line identities all verify

#### Scenario: Checkpoint envelope is encoded
- **WHEN** Jort prepares a recovery checkpoint
- **THEN** it produces versioned UTF-8 JSON with sorted object keys, document-order arrays, decimal integers, lowercase hyphenated UUIDs, fixed UTC timestamp strings or explicit `null`, no byte-order mark, and no insignificant whitespace
- **AND** records a SHA-256 checksum over the exact persisted envelope payload excluding the checksum field
- **AND** recovery verifies those stored bytes directly without depending on a later encoder to reproduce identical bytes

### Requirement: Corrupt stores are preserved before replacement
Jort SHALL keep the SQLite database, WAL, SHM, and store manifest together inside one `active-store` directory and SHALL preserve that complete directory in a uniquely identified same-volume quarantine location before publishing a rebuilt primary store.

#### Scenario: Corruption is detected and preservation succeeds
- **WHEN** store integrity or snapshot verification fails
- **THEN** Jort closes SQLite and atomically renames the complete `active-store` directory into quarantine without modifying, copying, or compressing its contents
- **AND** recovery operates on separate material

#### Scenario: Damaged material cannot be preserved
- **WHEN** permissions, storage exhaustion, or filesystem failure prevents safe preservation or atomic relocation of the damaged bundle
- **THEN** Jort leaves the source material untouched and enters a recovery-required state
- **AND** does not overwrite, truncate, migrate, or replace it

### Requirement: Recovery selects the newest verified recoverable state
Jort SHALL evaluate preserved primary material and recovery checkpoints in descending generation order and SHALL rebuild from the highest-generation candidate that completely verifies.

#### Scenario: Newest checkpoint is valid
- **WHEN** the primary store is corrupt and the newest recovery checkpoint verifies
- **THEN** Jort rebuilds a temporary SQLite store from that checkpoint, verifies the rebuilt store, and atomically publishes it
- **AND** presents the recovered document with an ephemeral nonmodal storage notice that identifies the preserved damaged-store location

#### Scenario: Newest checkpoint is invalid but an older candidate is valid
- **WHEN** the highest-generation candidate fails verification and a lower-generation candidate verifies
- **THEN** Jort restores the highest-generation verified candidate
- **AND** reports that recovery used an older state without claiming unsaved later edits were recovered

#### Scenario: No candidate verifies
- **WHEN** neither preserved primary material nor either recovery checkpoint can be verified
- **THEN** Jort preserves all available material and requires an explicit user recovery decision
- **AND** does not silently show, save, or publish an empty document in its place

#### Scenario: User explicitly starts empty after unrecoverable corruption
- **WHEN** no candidate verifies and the user confirms starting a new empty document after being told the damaged material will remain preserved
- **THEN** Jort creates a new store with a distinct identity and intentional-empty marker
- **AND** does not delete or reuse the quarantined damaged bundle

#### Scenario: Older content becomes recoverable after confirmed start-empty
- **WHEN** the user has edited the explicitly created new document and older quarantined content later becomes recoverable
- **THEN** Crawl preserves both states and does not automatically replace or merge the newer document
- **AND** comparison and merge remain deferred to a later user-controlled GA workflow

### Requirement: Recovery publication is atomic
Jort SHALL rebuild recovered state in a sibling `active-store.pending` directory and SHALL atomically rename it to the primary `active-store` path only after the pending store passes the same integrity and snapshot verification as a normal store.

#### Scenario: Rebuild fails
- **WHEN** a candidate verifies but rebuilding or verifying the new SQLite store fails
- **THEN** Jort retains the candidate and damaged-store backup unchanged
- **AND** remains in recovery-required state with Retry available

#### Scenario: Rebuild succeeds
- **WHEN** the temporary recovered store verifies and is atomically published
- **THEN** relaunch and current-session loading use that complete generation
- **AND** the editor becomes focused with the recovered text and metadata
