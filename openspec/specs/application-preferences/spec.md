## Purpose

Define application preferences and tool-configuration persistence independently of canonical document state.

## Requirements

### Requirement: Application preferences are independent of canonical document state
Jort SHALL store application preferences and tool definitions outside the canonical document snapshot, document recovery checkpoints, and retained document history.

#### Scenario: Preference changes
- **WHEN** the user commits a settings change
- **THEN** Jort persists the setting without creating a document transaction, document Undo entry, autosave generation, or retained history revision
- **AND** canonical text and document metadata remain byte-for-byte unchanged

#### Scenario: Document state is restored
- **WHEN** the user restores an earlier document revision
- **THEN** current application preferences and tool definitions remain unchanged
- **AND** the restore does not read or rewrite the settings store

### Requirement: Settings persistence is versioned, validated, and atomic
Jort SHALL use an independently versioned local settings schema, SHALL validate bounded values before commit, and SHALL publish every multi-field settings mutation atomically.

#### Scenario: Valid mutation commits
- **WHEN** a typed settings command contains valid values within configured bounds
- **THEN** Jort commits all of its records in one storage transaction and advances the settings revision
- **AND** observers receive one coherent post-commit snapshot rather than partial field updates

#### Scenario: Validation or storage fails
- **WHEN** a settings mutation is invalid or its storage transaction fails
- **THEN** Jort commits none of that mutation and reports an actionable error
- **AND** the previously committed snapshot remains authoritative

#### Scenario: Known older schema opens
- **WHEN** the settings store uses a supported older schema
- **THEN** Jort preserves a pre-migration copy and migrates it transactionally before publishing a snapshot
- **AND** failed migration leaves the original source material intact

### Requirement: Unsupported settings never block document access
Jort SHALL load Settings independently of the document and SHALL preserve corrupt or future-version settings data without silently replacing it.

#### Scenario: Settings store is missing
- **WHEN** Jort launches without an existing settings store
- **THEN** it creates current defaults and makes the editor and Settings available
- **AND** no document migration is triggered

#### Scenario: Settings store is corrupt
- **WHEN** Jort cannot validate or open the settings store
- **THEN** the document editor remains available and Settings presents an unavailable state with retry information
- **AND** Jort leaves the unreadable settings source untouched and does not expose custom tools as executable

#### Scenario: Settings schema is from a future build
- **WHEN** Jort encounters a settings schema version newer than it supports
- **THEN** it opens no writable handle that can downgrade or modify that store
- **AND** the document editor remains available while Settings explains the compatibility problem

### Requirement: Settings snapshots are safe for concurrent consumers
Jort SHALL expose immutable Sendable settings snapshots with monotonically advancing revisions and SHALL make only committed snapshots observable to UI and runtime consumers.

#### Scenario: Draft is being edited
- **WHEN** a settings pane changes an uncommitted local draft
- **THEN** observers continue to read the last committed snapshot
- **AND** no partial name, source, enablement, or validation state enters the executable catalog

#### Scenario: Commit completes off the main actor
- **WHEN** the settings store completes a successful actor-isolated mutation
- **THEN** Jort publishes the resulting snapshot to UI consumers on their required isolation boundary
- **AND** consumers can distinguish it from older snapshots by revision

#### Scenario: Stale writer attempts a commit
- **WHEN** a mutation's expected record revision no longer matches the committed record
- **THEN** Jort rejects the mutation as a conflict without overwriting the newer record
- **AND** returns the current revision so the caller can reload or reconcile explicitly
