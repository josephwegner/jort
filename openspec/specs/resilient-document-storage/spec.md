# resilient-document-storage Specification

## Purpose
Define durable, asynchronous document persistence that preserves authoritative in-memory edits through storage failures and recovery.

## Requirements

### Requirement: In-memory state remains authoritative while Jort runs
Jort SHALL apply accepted edits to the in-memory document immediately through `DocumentCoordinator` and SHALL NOT await, reject, revert, replace, or discard an edit because persistence is slow or unavailable. Persistence SHALL receive immutable `DocumentSnapshot` values and SHALL NOT mutate live document state.

#### Scenario: Storage is healthy
- **WHEN** the user edits the document
- **THEN** the visible text and paired logical-line metadata update before any storage round trip
- **AND** an immutable snapshot is scheduled for asynchronous persistence

#### Scenario: Storage is unavailable
- **WHEN** SQLite cannot open, begin, commit, sync, write the recovery snapshot, or verify a write
- **THEN** typing, selection, undo/redo, copy/paste, find, wrapping, and scrolling remain available
- **AND** the newest in-memory text and metadata remain authoritative and dirty

#### Scenario: Older write completes after newer edits
- **WHEN** revision N becomes durable while revision N+1 or later exists in memory
- **THEN** Jort records N as an available committed revision without marking the document fully saved
- **AND** never loads revision N over the newer in-memory state

#### Scenario: Stale transaction is submitted
- **WHEN** a transaction's base revision does not match the live revision
- **THEN** the coordinator rejects it
- **AND** the live revision does not advance

### Requirement: One current state persists as a versioned payload in SQLite WAL mode
Jort SHALL persist exactly one current singleton document as a versioned JSON payload blob inside SQLite WAL mode using the system `libsqlite3` API. There SHALL be no third-party persistence library. SQLite schema version and payload format version SHALL be explicit, separately decoded, and migrated as one coordinated operation. The document core and editor host SHALL NOT import SQLite types.

#### Scenario: Snapshot commit succeeds
- **WHEN** SQLite commits a scheduled snapshot and the companion recovery snapshot also writes
- **THEN** the payload represents one complete revision of text, ordered line records, document identity, and live revision
- **AND** Jort reports that revision committed only after the entire save operation succeeds

#### Scenario: Recovery-snapshot write fails after SQLite commit
- **WHEN** the SQLite payload commit succeeds but writing `Recovery.json` fails
- **THEN** the save remains a failed save
- **AND** the document stays dirty

#### Scenario: Transaction is interrupted
- **WHEN** the process exits or crashes before a snapshot transaction commits
- **THEN** relaunch loads either the complete prior revision or the complete new revision
- **AND** never combines text from one revision with metadata from another

#### Scenario: Intentional empty snapshot persists
- **WHEN** the user deletes all document text and that revision commits
- **THEN** the store records the empty document and its one structural line identity
- **AND** relaunch treats the empty document as valid saved state rather than missing data

### Requirement: Persistence envelope is separate from the live model
Jort SHALL encode and decode a persistence envelope distinct from live `DocumentState`. Released payload versions SHALL have explicit decoders and migrate into the current model. Future SQLite or payload versions SHALL be refused without modifying their files. Additive fields such as an empty landmark collection MAY be present in the current envelope so later phases can migrate without rewriting Crawl recovery.

#### Scenario: Version 1 fixture migrates
- **WHEN** Jort opens a committed SQLite/payload v1 fixture
- **THEN** it migrates to the current versions and reopens successfully
- **AND** the original files remain preserved in a pre-migration backup

#### Scenario: Future version is encountered
- **WHEN** Jort opens a store whose SQLite or payload version is newer than this build
- **THEN** it refuses the store without mutation
- **AND** reports a load-blocked-future state

#### Scenario: Unknown version-zero schema is encountered
- **WHEN** Jort finds a database that is not an exact known schema
- **THEN** it does not treat the file as a new empty store
- **AND** it does not rewrite `user_version` in place

### Requirement: Autosave is best-effort and off the keystroke path
Jort SHALL schedule ordinary saves on a fixed approximately half-second cadence rather than a trailing idle debounce, SHALL keep serialization and SQLite IO off the main-thread keystroke path, and SHALL NOT promise users a strict save deadline.

#### Scenario: Typical edit becomes durable
- **WHEN** an edit is accepted while storage is healthy
- **THEN** an immutable snapshot is scheduled on the persistence controller
- **AND** serialization and disk IO do not block the keystroke path

#### Scenario: User types continuously
- **WHEN** edits continue without an idle period
- **THEN** Jort still flushes on the fixed cadence so continuous typing cannot postpone saving indefinitely
- **AND** tests measure the achieved cadence without advertising a user-facing half-second guarantee

#### Scenario: Autosave runs during typing and scrolling
- **WHEN** SQLite commit or recovery-snapshot publication overlaps editor interaction
- **THEN** selection and viewport remain unchanged by storage completion
- **AND** typing remains available

#### Scenario: Orderly lifecycle boundary occurs
- **WHEN** the app resigns active, the window closes, or the user quits while dirty
- **THEN** Jort requests an immediate best-effort flush
- **AND** quit waits for that flush and warns if it does not succeed

### Requirement: Write failures trigger bounded nonmodal retry
Jort SHALL classify persistence failures, retain the newest dirty snapshot, and automatically retry one continuous failure episode three times before requiring manual Retry. Manual Retry SHALL reset the budget and always target the newest in-memory revision.

#### Scenario: Transient write failure recovers automatically
- **WHEN** a write fails and a subsequent attempt within the three-attempt budget succeeds
- **THEN** Jort persists the newest coalesced in-memory revision
- **AND** returns storage state to clean without interrupting editing

#### Scenario: Automatic retries are exhausted
- **WHEN** all three automatic attempts in one failure episode fail
- **THEN** Jort stops automatic retrying for that episode and offers Retry
- **AND** later keystrokes update the retained dirty snapshot without starting a new retry storm

#### Scenario: User invokes manual Retry
- **WHEN** the user activates Retry or Command-S after automatic attempts are exhausted
- **THEN** Jort resets the retry budget and attempts to persist the newest in-memory revision
- **AND** editing remains available throughout the attempt

### Requirement: Disk-full and other IO failures never destroy edits
Jort SHALL treat SQLite full-disk, quota, permission, busy, size-limit, and equivalent errors as failed saves and SHALL preserve all subsequently accepted edits in memory until persistence succeeds or the process ends. The maximum serialized payload SHALL be 64 MiB.

#### Scenario: Disk becomes full during commit
- **WHEN** a snapshot commit fails because storage is full
- **THEN** the SQLite transaction does not publish a partial current revision
- **AND** Jort shows a nonmodal notice that offers Retry

#### Scenario: Payload exceeds the size limit
- **WHEN** encoding or binding a snapshot would exceed 64 MiB or `Int32` blob capacity
- **THEN** the save fails without crashing
- **AND** the last committed state remains intact

#### Scenario: Space is made available
- **WHEN** the user frees storage and invokes Retry
- **THEN** Jort writes and verifies the newest in-memory revision
- **AND** clears the unhealthy state only after the complete save operation succeeds

### Requirement: Persistence lifecycle is a typed state machine
Jort SHALL expose a typed `PersistenceState` distinguishing at least loading, clean at a committed revision, dirty, writing, retry scheduled, save failed with remaining retries, save failed with retries exhausted, load blocked by a future version, load failed, and ownership conflict. UI copy SHALL live in the AppKit layer.

#### Scenario: UI reacts to typed state
- **WHEN** persistence reports a state transition
- **THEN** window chrome and Retry/recovery-copy actions switch on the typed state
- **AND** they do not parse status strings

#### Scenario: Successful save is quiet
- **WHEN** a save completes and the newest in-memory revision is committed
- **THEN** no routine saved banner is shown
- **AND** the document is marked clean at that revision

### Requirement: One process owns a data directory
Jort SHALL hold a process-lifetime nonblocking exclusive advisory lock on the selected data directory and SHALL refuse to open, recover, or write that store from a second process. Distinct `JORT_DATA_DIRECTORY` values MAY run independently.

#### Scenario: Second process contends for the same store
- **WHEN** two processes launch against the same data directory
- **THEN** exactly one process becomes the store owner
- **AND** the other exits without changing SQLite, WAL, SHM, recovery, or lock files beyond opening the lock

#### Scenario: Process crashes while holding the lock
- **WHEN** the owning process terminates unexpectedly
- **THEN** the OS releases the advisory lock
- **AND** a later process can open the store without stale-lock cleanup

### Requirement: Store layout uses an atomic directory bundle
Jort SHALL keep `Jort.sqlite`, WAL, SHM, and `Recovery.json` together inside one `Store` directory under the selected data root. Migration and recovery SHALL build a sibling replacement, close and reopen it for validation, then atomically swap or install the whole directory. Originals SHALL be preserved as uniquely named `PreMigration-*` or `Damaged-*` backups before replacement.

#### Scenario: Corruption is detected and a valid recovery snapshot exists
- **WHEN** store integrity or payload verification fails and `Recovery.json` decodes and validates
- **THEN** Jort preserves the damaged bundle and atomically publishes a rebuilt store from that snapshot
- **AND** the damaged backup remains intact after successful replacement

#### Scenario: Injected failure occurs before the final swap
- **WHEN** backup, create, write, validate, or replace fails during install
- **THEN** the canonical location still contains either the original store or no half-installed replacement
- **AND** relaunch behavior remains deterministic

#### Scenario: No valid recovery snapshot is available
- **WHEN** initial load fails and `Recovery.json` is missing or invalid
- **THEN** Jort leaves the original files untouched
- **AND** the user may save a separate recovery copy of current in-memory work

#### Scenario: User saves a recovery copy
- **WHEN** the user chooses Save Recovery Copy
- **THEN** Jort writes a versioned JSON snapshot to the chosen location
- **AND** that file is not imported back as the working store in this change

### Requirement: Hard-crash loss follows the implemented save cadence
Jort SHALL configure WAL with `synchronous=FULL` so a healthy flush can persist the latest snapshot, and SHALL treat crash loss as bounded by the best-effort save cadence rather than a one-second product guarantee.

#### Scenario: Process is killed after a successful flush
- **WHEN** Jort is force-terminated after a completed save
- **THEN** relaunch restores that committed revision
- **AND** the restored text and metadata belong to one verified payload

#### Scenario: Process is killed between SQLite commit and recovery snapshot
- **WHEN** termination occurs after the payload commit and before `Recovery.json` is written
- **THEN** the save is not treated as successful
- **AND** recovery may restore the previous valid snapshot rather than claiming the unconfirmed revision

### Requirement: Persistence rejects document publication until load resolves
Jort's persistence controller SHALL NOT accept a placeholder-derived or startup-draft snapshot as pending, dirty, historical, or writable state before the selected store has loaded successfully.

#### Scenario: Startup edit is accepted while loading
- **WHEN** the editor accepts a native edit before persistence load resolution
- **THEN** persistence retains no pending snapshot from the startup draft and schedules no save or history work for it
- **AND** the edit remains available to the editor for later reconciliation

#### Scenario: Store load succeeds
- **WHEN** persistence verifies and publishes the stored snapshot
- **THEN** that snapshot becomes the committed baseline before any reconciled startup transaction is accepted
- **AND** a subsequent merged snapshot is scheduled as an ordinary newer revision rather than a replacement document identity

#### Scenario: Store load fails
- **WHEN** persistence reports corruption, unsupported version, ownership conflict, or another load failure
- **THEN** it accepts no ordinary autosave or history publication to that source
- **AND** explicit recovery-copy export remains separate from the failed canonical store

### Requirement: Startup merge preserves persistence ordering
After a successful load, Jort SHALL persist a reconciled startup merge through the same immutable snapshot, revision, retry, and committed-revision rules as any other accepted document transaction.

#### Scenario: Merged startup snapshot saves successfully
- **WHEN** the startup-prefix transaction produces a revision newer than the loaded committed baseline
- **THEN** persistence schedules and commits that immutable merged snapshot through the ordinary save path
- **AND** marks the document clean only after the exact merged revision becomes durable

#### Scenario: Save of the merged snapshot fails
- **WHEN** storage fails while saving the reconciled startup revision
- **THEN** the complete merged in-memory document remains authoritative and dirty
- **AND** retry continues to target the newest merged revision without reverting to either the startup draft or loaded baseline

#### Scenario: New edits follow the startup merge
- **WHEN** the user continues typing before the merged revision finishes saving
- **THEN** newer edits remain ordered after the startup-prefix transaction
- **AND** completion of an older save never replaces the newer in-memory state

### Requirement: Recovery files are validated before bounded allocation
Jort SHALL open the recovery manifest, legacy recovery payload, and each manifest-selected recovery slot as a fixed direct child through no-follow file descriptors, SHALL require a singly linked regular file, and SHALL enforce a role-specific maximum while reading before decode.

#### Scenario: Recovery manifest is valid and bounded
- **WHEN** `Recovery-manifest.json` is a singly linked regular direct child no larger than 64 KiB and names only unique slots 0 or 1
- **THEN** Jort reads at most the manifest bound, decodes it, and considers only the fixed declared slot filenames
- **AND** no persisted value becomes an arbitrary path

#### Scenario: Recovery payload reaches its maximum
- **WHEN** the legacy file or a selected slot is a regular direct child whose complete byte count is at most the 64 MiB persistence limit
- **THEN** Jort reads it in bounded chunks and decodes only after the complete bounded payload is available
- **AND** never allocates based on an unchecked external file length

#### Scenario: Candidate is oversized or changes during read
- **WHEN** initial metadata exceeds the role limit or the opened file grows beyond the limit while being read
- **THEN** Jort stops at no more than limit plus one observed byte and rejects the candidate as oversized/changed
- **AND** preserves the source and continues evaluating another explicitly valid candidate when allowed

#### Scenario: Candidate is linked or not regular
- **WHEN** a candidate is a symbolic link, has an unexpected hard-link count, or is a directory, device, socket, FIFO, or other non-regular type
- **THEN** Jort rejects it before decode and never follows or reads its target as recovery data
- **AND** exposes the typed rejection when recovery cannot otherwise succeed

### Requirement: Recovery outcomes are typed and actionable
Jort SHALL expose the recovery source role, disposition, and bounded rejection reason through persistence state and SHALL preserve the original source whenever no verified recovery candidate can be installed.

#### Scenario: Automatic corruption recovery succeeds
- **WHEN** the current store is corrupt and a bounded candidate verifies and is atomically installed
- **THEN** Jort opens the recovered document and reports that automatic recovery occurred and a damaged diagnostic backup was preserved
- **AND** does not require the editor to parse an IO string to choose available actions

#### Scenario: Every candidate is rejected
- **WHEN** recovery candidates are missing, oversized, linked, malformed, checksum-invalid, unsupported, or unreadable
- **THEN** Jort leaves the source files untouched and enters editable non-writing recovery state rather than creating an empty store
- **AND** exposes applicable Retry, Continue in Memory, Save Recovery Copy, or confirmed rejected-file cleanup actions

#### Scenario: Rejected-file cleanup is confirmed
- **WHEN** the user confirms removal of unusable recovery data identified by the current failed attempt
- **THEN** Jort removes only those fixed rejected recovery candidates without following links
- **AND** does not delete or replace the SQLite source, diagnostic backups, or unknown entries

### Requirement: Manual Save and Retry target the newest authoritative snapshot
Jort SHALL expose an explicit manual persistence action whose healthy form requests immediate Save and whose exhausted-failure form requests Retry Save, and both SHALL target the newest authoritative in-memory loaded snapshot through typed completion.

#### Scenario: User invokes Command-S while dirty
- **WHEN** autosave has not committed the newest loaded revision and the user invokes Command-S
- **THEN** Jort immediately requests a flush of that newest revision and reports its actual typed outcome
- **AND** an unrelated later autosave cannot satisfy the command's test expectation

#### Scenario: User invokes Command-S after retries are exhausted
- **WHEN** persistence is in a manual-retry state and the user invokes Command-S
- **THEN** Jort resets the bounded retry episode and attempts the newest in-memory revision
- **AND** keeps editing available while the explicit attempt runs

#### Scenario: Manual Save is unsafe
- **WHEN** persistence is still loading, blocked by a future version, in ownership conflict, or in recovery editing without a verified loaded source
- **THEN** Jort refuses canonical Save/Retry without changing source files
- **AND** exposes recovery-copy export when a coherent in-memory snapshot can be produced

### Requirement: Current-only store rebuild removes prior storage residue
Jort SHALL build a fresh replacement containing the purge-boundary current snapshot, no history revisions, and only newly generated minimum recovery data; SHALL checkpoint/truncate WAL and close handles before validation; and SHALL atomically install it before old-copy cleanup.

#### Scenario: Replacement is validated
- **WHEN** fresh-store construction reaches its validation boundary
- **THEN** a reopened reader proves exact snapshot identity/content/revision, current schema, empty history, valid new recovery material, and absence of unexpected WAL/history residue
- **AND** failure leaves the old canonical store authoritative

#### Scenario: Replacement becomes active
- **WHEN** the validated replacement is atomically swapped into `Store` and the parent directory is synced
- **THEN** Jort reopens and verifies it before classifying the swapped old bundle as removable
- **AND** later accepted edits are scheduled only against the new store
