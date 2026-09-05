# Persistence and History Specification

## ADDED Requirements

### Requirement: Asynchronous local persistence
Jort SHALL keep the live document in memory and persist state asynchronously to SQLite in WAL mode without awaiting storage on the keystroke path.

#### Scenario: Edit persistence
- **WHEN** the user edits the document
- **THEN** the in-memory text changes immediately
- **AND** persistence is debounced and flushed at appropriate lifecycle boundaries

#### Scenario: Relaunch
- **WHEN** Jort relaunches after a successful persistence flush
- **THEN** it restores the current text, line metadata, annotations, landmarks, and relevant document state

### Requirement: Full-state revisions
Jort SHALL record meaningful coalesced revisions containing text, line metadata, annotations, landmarks, insertion metadata, and relevant document-level state.

#### Scenario: Revision cadence
- **WHEN** the user types continuously
- **THEN** Jort coalesces changes into useful checkpoints rather than one revision per keystroke

#### Scenario: Automation transaction
- **WHEN** an agent, command, or capture commits text
- **THEN** Jort records the entire atomic transaction as a revision boundary

### Requirement: Local history preview and restore
Jort SHALL expose history from the command palette and SHALL keep history local unless a separately confirmed tool request reads it.

#### Scenario: Preview revision
- **WHEN** the user selects a historical revision
- **THEN** Jort previews its text and metadata changes without mutating the current document

#### Scenario: Restore revision
- **WHEN** the user confirms restore
- **THEN** Jort atomically restores the revision's complete state
- **AND** records the restore as a new recoverable revision

### Requirement: Storage failure isolation
Jort SHALL surface persistence and history errors without blocking or destroying the editable in-memory document.

#### Scenario: SQLite unavailable
- **WHEN** SQLite cannot accept a write
- **THEN** the canvas remains editable
- **AND** Jort retains a retryable dirty state
- **AND** communicates the problem without modal interruption of typing

