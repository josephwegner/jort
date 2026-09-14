## ADDED Requirements

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
