## ADDED Requirements

### Requirement: Jort inventories only managed local copies
Jort SHALL identify current-store, history, recovery, diagnostic-backup, replacement, inspection, staging, and maintenance-marker data only through bounded no-follow enumeration of exact Jort naming contracts under the owned data directory, and SHALL distinguish those copies from external backups and user exports.

#### Scenario: Managed-copy inventory is requested
- **WHEN** Jort owns the data directory and inventories data relevant to retention or purge
- **THEN** it classifies only the active Store and direct children or declared bundle files matching exact known names and valid generated suffixes
- **AND** it does not traverse links, unknown names, special files, user-selected recovery copies, or paths outside that data directory

#### Scenario: Unexpected entry resembles managed data
- **WHEN** a symbolic link, special file, malformed suffix, or unexpected nested entry appears under a managed-looking name
- **THEN** Jort leaves the entry and its target untouched and reports a bounded diagnostic when it prevents proof of cleanup
- **AND** never expands the purge target by resolving the entry

### Requirement: User can purge pre-boundary history and recovery copies
Jort SHALL offer one explicitly confirmed operation that captures the current authoritative snapshot as a purge boundary, preserves that snapshot and every later accepted edit, and removes all older Jort-managed history, recovery, diagnostic, replacement, inspection, staging, and SQLite/WAL copies.

#### Scenario: User reviews purge confirmation
- **WHEN** the user activates Clear History and Recovery Data from the File menu for a verified loaded store
- **THEN** Jort explains that all revisions including milestones, recovery checkpoints, and diagnostic backups will be removed while the current document remains
- **AND** explains that exported copies, APFS/filesystem snapshots, Time Machine, and other external backups are outside the operation

#### Scenario: User confirms while current document contains no deleted secret
- **WHEN** Jort captures authoritative snapshot P at confirmation
- **THEN** it pauses old-store persistence/history publication, builds and verifies a new store containing P with no retained history and only minimum new recovery material, and atomically installs it
- **AND** accepts later edits in memory for publication only to the new store

#### Scenario: Purge succeeds
- **WHEN** the current-only store is active and synced and cleanup inventory finds no pre-boundary managed copy
- **THEN** Jort removes the durable purge marker, reports completion, and resumes ordinary saves/history for post-boundary edits
- **AND** relaunch restores the preserved document and cannot browse any pre-boundary history or milestone

#### Scenario: Purge is unavailable
- **WHEN** startup has not resolved, another process owns the store, a future version is refused, or recovery editing has no verified loaded source
- **THEN** Jort disables the destructive purge action
- **AND** continues to permit applicable in-memory editing and recovery-copy export without modifying source files

### Requirement: Purge is crash-consistent and resumable
Jort SHALL durably record a text-free purge operation and phase, SHALL verify both sides of any replacement before deleting old data, and SHALL leave either the original valid store or the validated current-only store recoverable after every injected failure or crash.

#### Scenario: Failure occurs before atomic swap
- **WHEN** replacement creation, current-state write, recovery publication, WAL truncation, close, validation, or marker publication fails
- **THEN** the original store and managed copies remain authoritative and no successful purge is reported
- **AND** queued in-memory edits remain available when the persistence barrier is released

#### Scenario: Relaunch occurs around atomic swap
- **WHEN** a purge marker and exact replacement location remain after interruption
- **THEN** Jort validates document identity, baseline revision/hash, active Store, and replacement before deciding whether to abandon preparation or resume cleanup
- **AND** preserves both candidates and requests recovery attention when their relationship cannot be proven

#### Scenario: Cleanup fails after new store activation
- **WHEN** the validated current-only store is active but a recognized old bundle, backup, recovery, or staging copy cannot be removed or synced
- **THEN** Jort keeps the new store authoritative and reports purge incomplete with Retry Cleanup
- **AND** does not delete the marker or claim that all managed copies were removed

### Requirement: Diagnostic backups have bounded automatic retention
After a healthy canonical store is owned and verified, Jort SHALL retain no more than the two newest verified `PreMigration` backups and two newest verified `Damaged` backups and SHALL retain no backup in either class for more than 30 days.

#### Scenario: Backup class exceeds count
- **WHEN** more than two recognized verified backups exist in one diagnostic class after healthy load
- **THEN** Jort removes and syncs the oldest excess backups without following links
- **AND** evaluates the other class independently

#### Scenario: Backup exceeds age
- **WHEN** a recognized diagnostic backup is older than 30 days after healthy load
- **THEN** Jort removes it even when fewer than two backups exist in that class
- **AND** does not represent the expired copy as available recovery

#### Scenario: Store is not healthy and verified
- **WHEN** load is blocked, recovery is unresolved, ownership is absent, purge is unresolved, or the active store cannot be verified
- **THEN** automatic backup deletion performs no destructive work
- **AND** preserves candidates for explicit recovery handling

#### Scenario: Automatic cleanup fails
- **WHEN** an expired or excess recognized backup cannot be removed or the parent cannot be synced
- **THEN** the verified current store remains usable and Jort exposes a typed maintenance warning
- **AND** a later maintenance pass or explicit purge can retry cleanup

### Requirement: Deletion claims are limited to logical managed copies
Jort SHALL describe purge as deletion of Jort-managed logical history and recovery copies and SHALL NOT claim physical overwrite, forensic erasure, or deletion from filesystem snapshots, system backups, cloud copies, or user-selected exports.

#### Scenario: Purge completes
- **WHEN** Jort reports a successful purge
- **THEN** its managed-copy inventory proves no pre-boundary logical copy remains under the owned data directory
- **AND** user-facing confirmation/documentation continues to distinguish that result from secure physical erasure

#### Scenario: Strong-erasure guarantee is requested
- **WHEN** a product requirement requires reliable destruction beyond managed logical copies
- **THEN** this capability does not claim to satisfy it through overwrite or SQLite cleanup
- **AND** requires a separately specified encrypted-store and crypto-erasure design
