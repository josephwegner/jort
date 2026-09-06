# logical-line-metadata Specification

## Purpose
Define stable logical-line identity and metadata behavior across editing, persistence, and undo operations.

## Requirements

### Requirement: Logical lines have stable invisible identity
Jort SHALL represent each logical line with one stable opaque `LineID` (UUID) that denotes textual lineage, not an ordinal, character offset, or text-matching heuristic. That identity SHALL remain outside canonical text and all Crawl user-visible copy. A reference SHALL resolve only by UUID. The number of logical lines SHALL equal the number of `NSString` line ranges in the document text, including a final empty structural line when the document is empty or ends with a line terminator.

#### Scenario: Empty document
- **WHEN** the canonical document contains zero characters
- **THEN** the document model contains one structural logical line with a stable identity
- **AND** that line has nil creation and edit timestamps

#### Scenario: Visual wrapping
- **WHEN** one logical line wraps into multiple visual rows
- **THEN** the rows share one logical-line identity
- **AND** wrapping creates no metadata records or canonical newlines

#### Scenario: App relaunch
- **WHEN** a verified persisted document is restored
- **THEN** every surviving logical line has the same identity it had in the durable snapshot
- **AND** character ranges are derived from current text rather than treated as identity

#### Scenario: Document ends with a newline
- **WHEN** canonical text ends with one or more line terminators
- **THEN** each terminator establishes the next logical line, including a final empty structural line
- **AND** every resulting logical line has one ordered identity

### Requirement: Non-whitespace lines have minimal timestamps
Jort SHALL store only `createdAt` and `lastEditedAt` as Crawl provenance for a non-whitespace logical line and SHALL NOT display those timestamps in this change. A line SHALL be whitespace-only when its content is empty after trimming with Foundation `CharacterSet.whitespacesAndNewlines`.

#### Scenario: First non-whitespace content
- **WHEN** a structural or whitespace-only line first receives a non-whitespace character in a committed edit
- **THEN** Jort sets both `createdAt` and `lastEditedAt` to that edit transaction's time
- **AND** retains the line's existing identity

#### Scenario: Existing content changes
- **WHEN** a committed edit changes non-whitespace content within one surviving line
- **THEN** Jort preserves `createdAt`
- **AND** advances `lastEditedAt` to the edit transaction's time

#### Scenario: Line becomes whitespace-only
- **WHEN** a committed edit leaves a logical line containing only whitespace or newline characters
- **THEN** Jort preserves the structural line identity while it exists
- **AND** clears both timestamp values

#### Scenario: Crawl UI is inspected
- **WHEN** the user views, edits, finds, selects, or copies text
- **THEN** no timestamp is rendered, announced, searchable, or copied

### Requirement: Split identity inheritance is deterministic
Jort SHALL keep the original identity on the leading fragment when one logical line is split and SHALL create identities for each resulting trailing fragment.

#### Scenario: Insert one newline
- **WHEN** a committed edit inserts a newline within a logical line
- **THEN** the leading fragment retains the original line identity and creation time when it remains non-whitespace
- **AND** the leading fragment's `lastEditedAt` advances to the transaction time when its visible content changed
- **AND** the trailing fragment receives a new identity with both timestamps set to the transaction time when it is non-whitespace
- **AND** any whitespace-only fragment has nil timestamps

#### Scenario: Insert complete lines at an existing line's start
- **WHEN** a committed edit inserts one or more complete terminated lines immediately before an existing line
- **THEN** each inserted line receives a new identity
- **AND** the original line keeps its identity and moves with its remaining text

#### Scenario: Paste multiple lines
- **WHEN** one paste transaction splits a line into three or more logical lines
- **THEN** the leading result retains the original identity
- **AND** every additional result receives one distinct identity in document order
- **AND** whitespace-only results receive nil timestamps

### Requirement: Join identity inheritance is deterministic
Jort SHALL keep the leading logical line's identity when a committed edit joins lines and SHALL expose removed line IDs on the transaction result so undo can restore them exactly.

#### Scenario: Delete a newline
- **WHEN** the user deletes a newline between two logical lines
- **THEN** the joined result retains the leading line's identity and creation time when non-whitespace
- **AND** its `lastEditedAt` becomes the join transaction's time when content changed
- **AND** the removed trailing identity is detached rather than reassigned to unrelated text

#### Scenario: Delete whole lines including their terminators
- **WHEN** a committed edit deletes one or more complete lines including their terminators
- **THEN** deleted IDs detach
- **AND** an unchanged successor keeps its own identity

#### Scenario: Join is undone
- **WHEN** the user undoes a join
- **THEN** the original separate text, line identities, and timestamps are restored exactly
- **AND** redo restores the joined identity result exactly

### Requirement: Replacements apply boundary-aware identity rules
Jort SHALL preserve a line identity for replacement within the same surrounding line-terminator boundaries and SHALL apply split/join inheritance when a replacement changes those boundaries. Jort SHALL NOT match or reattach identities by text content.

#### Scenario: Replace complete line content
- **WHEN** a user replaces all characters between the same preceding and following line-terminator boundaries
- **THEN** the target line keeps its identity
- **AND** its timestamps follow the non-whitespace timestamp rules

#### Scenario: Replacement crosses line boundaries
- **WHEN** a replacement removes or introduces one or more line-terminator boundaries
- **THEN** Jort applies the normative split and join rules to the resulting logical lines
- **AND** does not attach a removed identity to unrelated trailing content

#### Scenario: Cut then paste elsewhere
- **WHEN** the user cuts text and pastes it at another location
- **THEN** the deletion detaches the removed IDs
- **AND** the paste creates new lineage rather than inferring movement

### Requirement: IME metadata changes only at composition boundaries
Jort SHALL treat marked-text updates as provisional and SHALL reconcile logical-line identity, timestamps, undo data, revision, and persistence only when composition commits.

#### Scenario: Marked text changes repeatedly
- **WHEN** an input method updates its marked range or candidate text without committing
- **THEN** the native editor displays the provisional state
- **AND** Jort creates no durable line identities or timestamps for the provisional updates

#### Scenario: Marked text commits
- **WHEN** composition commits
- **THEN** Jort applies the complete committed replacement as one document transaction
- **AND** applies split, join, replacement, and timestamp rules to that transaction
- **AND** if AppKit does not supply a single stable edit range, Jort MAY reconcile using a common UTF-16 prefix/suffix fallback

#### Scenario: Marked text is cancelled
- **WHEN** composition is cancelled
- **THEN** line identities and timestamps remain as they were before composition
- **AND** no persistence revision is created solely for the cancelled text

### Requirement: Text and metadata share undo boundaries
Jort SHALL pair each accepted text transaction with its logical-line metadata and SHALL persist the post-undo or post-redo state as the new current snapshot. Undo and redo SHALL restore exact text, line IDs, and timestamps through a restore transaction and SHALL advance the live revision once.

#### Scenario: Complex paste is undone and redone
- **WHEN** a multiline paste that splits and joins logical lines is undone and then redone
- **THEN** every affected identity and timestamp returns to the exact corresponding pre-paste and post-paste value
- **AND** each user action is one undo-manager operation

#### Scenario: Undo occurs while persistence is pending
- **WHEN** the user invokes Undo before an earlier snapshot is durable
- **THEN** the in-memory text and metadata change immediately to the undo result
- **AND** persistence may coalesce obsolete revisions but SHALL NOT later restore the superseded text

### Requirement: Metadata updates are local and performant
Jort SHALL derive the affected logical-line window from the edited UTF-16 range plus one neighboring line on each side, then re-split that window, and SHALL avoid rescanning the complete document for ordinary localized edits.

#### Scenario: Local edit in large document
- **WHEN** an insertion or deletion touches one logical line in the committed 10,000-line fixture
- **THEN** Jort normalizes the intersecting lines plus only the bounded neighboring context needed to resolve line-terminator boundaries
- **AND** the operation meets the documented native transaction regression budget

#### Scenario: Whole-document replacement
- **WHEN** a paste or Service legitimately replaces the complete document
- **THEN** Jort may normalize the full replacement
- **AND** presents it as one undoable edit without partially published metadata
