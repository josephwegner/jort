## ADDED Requirements

### Requirement: Logical lines have stable invisible identity
Jort SHALL represent each U+000A LF-delimited logical line with one stable opaque identity and SHALL keep that identity outside canonical text and all Crawl UI. The number of logical lines SHALL equal the canonical LF count plus one, including a final structural line after a trailing LF.

#### Scenario: Empty document
- **WHEN** the canonical document contains zero characters
- **THEN** the document model contains one structural logical line with a stable identity
- **AND** that line has nil creation and edit timestamps

#### Scenario: Visual wrapping
- **WHEN** one newline-delimited logical line wraps into multiple visual rows
- **THEN** the rows share one logical-line identity
- **AND** wrapping creates no metadata records or canonical newlines

#### Scenario: App relaunch
- **WHEN** a verified persisted document is restored
- **THEN** every surviving logical line has the same identity it had in the durable snapshot
- **AND** character ranges and visual rows are derived rather than persisted as identity

#### Scenario: Document ends with a newline
- **WHEN** canonical text ends with one or more LF separators
- **THEN** each separator establishes the next logical line, including a final empty structural line
- **AND** every resulting logical line has one ordered identity

### Requirement: Non-whitespace lines have minimal timestamps
Jort SHALL store only `createdAt` and `lastEditedAt` as Crawl provenance for a non-whitespace logical line and SHALL NOT display those timestamps in this change. Whitespace classification SHALL use an embedded scalar/range table pinned to the Unicode 17.0 `White_Space` derived property, independent of the host OS Unicode version. Encoded timestamps SHALL use UTC RFC 3339-compatible ISO 8601 with exactly six fractional-second digits.

#### Scenario: First non-whitespace content
- **WHEN** a structural or whitespace-only line first receives a non-whitespace character in a committed edit
- **THEN** Jort sets both `createdAt` and `lastEditedAt` to that edit transaction's time
- **AND** retains the line's existing identity

#### Scenario: Existing content changes
- **WHEN** a committed edit changes non-whitespace content within one surviving line
- **THEN** Jort preserves `createdAt`
- **AND** advances `lastEditedAt` to the edit transaction's time

#### Scenario: Line becomes whitespace-only
- **WHEN** a committed edit leaves a logical line containing only spaces, tabs, or other Unicode whitespace
- **THEN** Jort preserves the structural line identity while it exists
- **AND** clears both timestamp values

#### Scenario: Host Unicode implementation changes
- **WHEN** Jort runs on supported macOS releases whose system Unicode databases differ
- **THEN** the same scalar sequence receives the same Crawl whitespace classification
- **AND** snapshot validation does not change solely because the host Unicode version changed

#### Scenario: Crawl UI is inspected
- **WHEN** the user views, edits, finds, selects, or copies text
- **THEN** no timestamp is rendered, announced, searchable, or copied

### Requirement: Split identity inheritance is deterministic
Jort SHALL keep the original identity on the leading fragment when one logical line is split and SHALL create identities for each resulting trailing fragment.

#### Scenario: Insert one newline
- **WHEN** a committed edit inserts a newline within a logical line
- **THEN** the leading fragment retains the original line identity and creation time when it remains non-whitespace
- **AND** the leading fragment's `lastEditedAt` advances to the transaction time when it remains non-whitespace
- **AND** the trailing fragment receives a new identity with both `createdAt` and `lastEditedAt` set to the transaction time when it is non-whitespace
- **AND** any whitespace-only fragment has nil timestamps

#### Scenario: Paste multiple lines
- **WHEN** one paste transaction splits a line into three or more logical lines
- **THEN** the leading result retains the original identity
- **AND** every additional result receives one distinct identity in document order
- **AND** whitespace-only results receive nil timestamps

### Requirement: Join identity inheritance is deterministic
Jort SHALL keep the leading logical line's identity when a committed edit joins lines and SHALL preserve removed line records in the paired undo delta.

#### Scenario: Delete a newline
- **WHEN** the user deletes a newline between two logical lines
- **THEN** the joined result retains the leading line's identity and creation time when non-whitespace
- **AND** its `lastEditedAt` becomes the join transaction's time

#### Scenario: Join is undone
- **WHEN** the user undoes a join
- **THEN** the original separate text, line identities, and timestamps are restored exactly
- **AND** redo restores the joined identity result exactly

### Requirement: Replacements apply boundary-aware identity rules
Jort SHALL preserve a line identity for replacement within the same surrounding newline boundaries and SHALL apply split/join inheritance when a replacement changes those boundaries.

#### Scenario: Replace complete line content
- **WHEN** a user replaces all characters between the same preceding and following newline boundaries
- **THEN** the target line keeps its identity
- **AND** its timestamps follow the non-whitespace timestamp rules

#### Scenario: Replacement crosses line boundaries
- **WHEN** a replacement removes or introduces one or more newline boundaries
- **THEN** Jort applies the normative split and join rules to the resulting logical lines
- **AND** does not attach a removed identity to unrelated trailing content

### Requirement: IME metadata changes only at composition boundaries
Jort SHALL treat marked-text updates as provisional and SHALL reconcile logical-line identity, timestamps, undo data, generation, and persistence only when composition commits.

#### Scenario: Marked text changes repeatedly
- **WHEN** an input method updates its marked range or candidate text without committing
- **THEN** the native editor displays the provisional state
- **AND** Jort creates no durable line identities or timestamps for the provisional updates

#### Scenario: Marked text commits
- **WHEN** composition commits
- **THEN** Jort normalizes the complete committed replacement as one metadata transaction
- **AND** applies split, join, replacement, and timestamp rules to that transaction

#### Scenario: Marked text is cancelled
- **WHEN** composition is cancelled
- **THEN** line identities and timestamps remain as they were before composition
- **AND** no autosave generation is created solely for the cancelled text

### Requirement: Text and metadata share undo boundaries
Jort SHALL pair each native undoable text transaction with its logical-line metadata delta and SHALL persist the post-undo or post-redo state as the new current snapshot.

#### Scenario: Complex paste is undone and redone
- **WHEN** a multiline paste that splits and joins logical lines is undone and then redone
- **THEN** every affected identity and timestamp returns to the exact corresponding pre-paste and post-paste value
- **AND** each user action is one native undo-manager operation

#### Scenario: Undo occurs while persistence is pending
- **WHEN** the user invokes Undo before an earlier snapshot is durable
- **THEN** the in-memory text and metadata change immediately to the undo result
- **AND** persistence may coalesce obsolete generations but SHALL NOT later restore the superseded text

### Requirement: Metadata updates are local and performant
Jort SHALL derive the affected logical-line window from the edited UTF-16 range and SHALL avoid rescanning the complete document for ordinary localized edits.

#### Scenario: Local edit in large document
- **WHEN** an insertion or deletion touches one logical line in `CrawlLargeDocument`
- **THEN** Jort normalizes the intersecting lines plus only the bounded neighboring context needed to resolve newline boundaries
- **AND** the operation meets the native-editor typing-latency budget

#### Scenario: Whole-document replacement
- **WHEN** a paste or Service legitimately replaces the complete document
- **THEN** Jort may normalize the full replacement off any avoidable repeated path
- **AND** presents it as one undoable edit without partially published metadata
