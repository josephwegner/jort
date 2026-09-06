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
