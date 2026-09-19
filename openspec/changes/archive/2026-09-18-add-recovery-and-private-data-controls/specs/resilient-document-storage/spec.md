## ADDED Requirements

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
