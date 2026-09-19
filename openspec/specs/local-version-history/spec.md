# Local Version History

## Purpose

Define bounded, local revision retention, browsing, comparison, restoration, and accessibility behavior.

## Requirements

### Requirement: Jort retains coalesced complete-state revisions locally
Jort SHALL retain independently restorable, versioned revisions containing canonical text, ordered logical-line metadata, landmarks, generation information, timestamp, reason, and verification hashes, and SHALL NOT retain one revision per keystroke.

#### Scenario: Ordinary typing becomes idle
- **WHEN** committed edits differ from the latest revision and the configured idle boundary (one minute by default) elapses
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
Jort SHALL expose Version History from the command palette as a transient split workspace and SHALL decode and verify a selected revision before presenting a complete read-only preview.

#### Scenario: Open history
- **WHEN** the user executes Version History
- **THEN** Jort preserves the quiet native title bar and opens a read-only preview beside a Version History rail
- **AND** lazily lists revisions newest first with locale-formatted timestamp and reason
- **AND** shows compact addition/deletion counts computed lazily for visible rows, with muted save reasons at the bottom of each row
- **AND** loads older metadata pages automatically as the rail scrolls near its end
- **AND** omits the former bottom metadata section
- **AND** does not replace the live document or initialize any provider

#### Scenario: History workspace replaces live-editor context
- **WHEN** history becomes active with a valid selected revision
- **THEN** Jort keeps the footer height stable but replaces the live landmark affordance with the selected timestamp, read-only state, and historical landmark count
- **AND** provides an explicit dismissal action without adding a permanent History title-bar control

#### Scenario: Preview a revision
- **WHEN** the user selects a valid revision
- **THEN** Jort shows its complete read-only text and a summary of included metadata
- **AND** displays the selected revision's logical-line ordinals and attached landmark emoji rather than the live document's gutter state
- **AND** clearly distinguishes the preview from the live document

#### Scenario: History is dismissed
- **WHEN** the user dismisses Version History without restoring
- **THEN** Jort restores the live footer, editor selection, applicable viewport anchor, and editor focus
- **AND** does not mutate the live document or create a revision

#### Scenario: Revision is corrupt
- **WHEN** a revision fails decode, schema, checksum, hash, or structural validation
- **THEN** Jort refuses to preview or restore it, marks only that revision unavailable, and leaves current state usable

### Requirement: Users can inspect derived changes without making diffs authoritative
Jort SHALL offer Changes and Snapshot presentation modes, SHALL derive a selected revision's changes from independently verified retained snapshots, and SHALL restore only complete selected snapshots.

#### Scenario: A comparison baseline exists
- **WHEN** the user selects Changes for a revision with an immediately preceding retained verified revision
- **THEN** Jort compares that pair off the main actor and identifies the baseline in the selected-revision summary
- **AND** presents contiguous addition/deletion blocks with explicit text markers and a compact darker gutter containing historical landmarks to the left of old/new ordinals

#### Scenario: Comparison work is superseded
- **WHEN** the user selects another revision before the current comparison finishes
- **THEN** Jort cancels or discards the prior comparison
- **AND** presents results only for the newest selection

#### Scenario: No comparison baseline is available
- **WHEN** the selected revision has no immediately preceding retained verified revision
- **THEN** Jort selects Snapshot, disables Changes, and explains that no comparison is available
- **AND** continues to allow preview and restore of the selected verified snapshot

#### Scenario: Unchanged regions are collapsed
- **WHEN** Changes condenses unchanged context
- **THEN** each collapsed region reports its omitted extent in a visible button operable by mouse and keyboard
- **AND** Snapshot continues to expose the complete canonical text

### Requirement: Revision restore is atomic and recoverable
Jort SHALL restore a verified revision's text, line metadata, and landmarks as one undoable current-state transaction and SHALL preserve the state being replaced as a revision before restore.

#### Scenario: A valid revision is selected
- **WHEN** Jort presents a verified revision in history
- **THEN** an explicit Restore action is available in a separated action area at the bottom of the revision rail alongside Done
- **AND** invoking it identifies the selected revision and requests confirmation before changing the live document

#### Scenario: Restore succeeds
- **WHEN** the user confirms restoring a verified revision
- **THEN** Jort first retains the current complete state, then publishes the selected complete state with a new current generation
- **AND** persistence never exposes mixed text and metadata

#### Scenario: Restore is undone
- **WHEN** the user invokes Undo after a restore
- **THEN** the complete pre-restore text, line metadata, landmarks, selection, and applicable viewport anchor return as one operation

### Requirement: History remains local and accessible
Jort SHALL keep revision content on the Mac and SHALL expose the history rail, Changes and Snapshot modes, preview context, corruption state, restore confirmation, and dismissal through keyboard and accessibility APIs.

#### Scenario: History is inspected for external access
- **WHEN** no later explicitly consented agent capability is installed
- **THEN** no network, command, plugin, or provider receives revision content

#### Scenario: VoiceOver browses history
- **WHEN** a VoiceOver user opens history, selects a revision, previews it, or confirms restore
- **THEN** Jort announces revision identity, timestamp, reason, selected presentation mode, comparison baseline when applicable, preview state, and destructive restore action
- **AND** dismissal returns focus to the live document

### Requirement: Confirmed private-data purge removes every retained revision
Jort SHALL treat Clear History and Recovery Data as an explicit exception to ordinary history retention and SHALL remove all pre-boundary history rows, including minimum-recent revisions, restore milestones, unavailable/corrupt entries, and pending history work, while preserving the purge-boundary current document outside history.

#### Scenario: History contains protected milestones
- **WHEN** the user confirms a private-data purge for a verified loaded document
- **THEN** the fresh replacement contains no retained revision or milestone from before the boundary
- **AND** ordinary pruning continues to protect milestones whenever a purge is not explicitly confirmed

#### Scenario: History retention is pending
- **WHEN** a scheduled idle, semantic, retry, or before-restore revision has not published when the purge boundary is captured
- **THEN** Jort cancels or drains it so it cannot write into the old or replacement store as pre-boundary history
- **AND** post-boundary edits may begin a new ordinary history timeline only after purge cleanup completes

#### Scenario: History opens after purge
- **WHEN** the user opens Version History after successful purge and before any new history boundary
- **THEN** no pre-boundary revision is available to browse, compare, or restore
- **AND** any newly established current baseline contains only the preserved boundary or later document state

#### Scenario: Purge fails before replacement
- **WHEN** a current-only replacement cannot be made authoritative
- **THEN** Jort does not claim history deletion and the original history remains associated with the original valid store
- **AND** the user can retry after resolving the reported failure
