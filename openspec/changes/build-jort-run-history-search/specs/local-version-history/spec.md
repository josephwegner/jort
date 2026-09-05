## ADDED Requirements

### Requirement: Jort retains coalesced complete-state revisions locally
Jort SHALL retain independently restorable, versioned revisions containing canonical text, ordered logical-line metadata, landmarks, generation information, timestamp, reason, and verification hashes, and SHALL NOT retain one revision per keystroke.

#### Scenario: Ordinary typing becomes idle
- **WHEN** committed edits differ from the latest revision and the configured idle boundary elapses
- **THEN** Jort writes one verified revision for the newest eligible state off the main actor
- **AND** intermediate handoff snapshots do not each become revisions

#### Scenario: Semantic mutation occurs
- **WHEN** a landmark change, full-state restore, or registered semantic bulk transaction commits
- **THEN** Jort requests a meaningful revision boundary

#### Scenario: State is unchanged
- **WHEN** a proposed revision has the same complete-state hash as the latest revision
- **THEN** Jort does not retain a duplicate revision

### Requirement: History is bounded separately from recovery
Jort SHALL enforce a configurable local history byte budget while preserving a minimum recent revision window, and SHALL never prune current state or operational recovery checkpoints as history.

#### Scenario: History exceeds its budget
- **WHEN** verified revisions exceed the configured budget
- **THEN** Jort transactionally removes the oldest eligible non-milestone revisions in the background
- **AND** leaves current-state and recovery material untouched

#### Scenario: Revision cannot fit because storage is full
- **WHEN** revision creation fails for insufficient storage
- **THEN** current-state autosave follows its existing health behavior and remains independently retryable
- **AND** Jort reports history retention degradation without discarding live edits

### Requirement: Users can browse and preview verified revisions
Jort SHALL expose Version History from the command palette and SHALL decode and verify a selected revision before presenting a complete read-only preview.

#### Scenario: Open history
- **WHEN** the user executes Version History
- **THEN** Jort lazily lists revisions newest first with timestamp and reason
- **AND** does not replace the live document or initialize any provider

#### Scenario: Preview a revision
- **WHEN** the user selects a valid revision
- **THEN** Jort shows its complete read-only text and a summary of included metadata
- **AND** clearly distinguishes the preview from the live document

#### Scenario: Revision is corrupt
- **WHEN** a revision fails decode, schema, checksum, hash, or structural validation
- **THEN** Jort refuses to preview or restore it, marks only that revision unavailable, and leaves current state usable

### Requirement: Revision restore is atomic and recoverable
Jort SHALL restore a verified revision's text, line metadata, and landmarks as one undoable current-state transaction and SHALL preserve the state being replaced as a revision before restore.

#### Scenario: Restore succeeds
- **WHEN** the user confirms restoring a verified revision
- **THEN** Jort first retains the current complete state, then publishes the selected complete state with a new current generation
- **AND** persistence never exposes mixed text and metadata

#### Scenario: Restore is undone
- **WHEN** the user invokes Undo after a restore
- **THEN** the complete pre-restore text, line metadata, landmarks, selection, and applicable viewport anchor return as one operation

### Requirement: History remains local and accessible
Jort SHALL keep revision content on the Mac and SHALL expose history list, preview, corruption state, restore confirmation, and dismissal through keyboard and accessibility APIs.

#### Scenario: History is inspected for external access
- **WHEN** no later explicitly consented agent capability is installed
- **THEN** no network, command, plugin, or provider receives revision content

#### Scenario: VoiceOver browses history
- **WHEN** a VoiceOver user opens history, selects a revision, previews it, or confirms restore
- **THEN** Jort announces revision identity, timestamp, reason, preview state, and destructive restore action
- **AND** dismissal returns focus to the live document
