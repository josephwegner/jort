## Purpose

Define metadata-only emoji landmarks, their line-identity anchoring, navigation, persistence, and accessibility.

## Requirements

### Requirement: A logical line can have an emoji landmark outside canonical text
Jort SHALL let the user assign at most one emoji-presenting grapheme cluster to a logical line, SHALL identify the landmark independently from its displayed emoji, and SHALL keep all landmark data outside canonical text.

#### Scenario: Add a landmark
- **WHEN** the user invokes Add Landmark for an unlandmarked logical line and chooses a valid emoji
- **THEN** Jort creates a distinct landmark anchored to that line's stable `LineID`
- **AND** the normal gutter displays the emoji instead of the line number
- **AND** document text, copying, native Find, and accessibility text values do not include the emoji

#### Scenario: Change a landmark emoji
- **WHEN** the user chooses a different valid emoji for an existing landmark
- **THEN** Jort retains the same `LandmarkID` and line attachment
- **AND** updates only the displayed emoji and mutation metadata

#### Scenario: Duplicate emoji are used
- **WHEN** two logical lines are assigned the same emoji
- **THEN** each landmark retains a distinct internal identity and line attachment
- **AND** navigation treats them as separate entries in document order

#### Scenario: Clear a landmark
- **WHEN** the user clears an attached landmark
- **THEN** Jort removes that landmark metadata
- **AND** restores the line number in normal gutter mode without changing text

### Requirement: Landmark anchoring follows deterministic line-identity rules
Jort SHALL anchor landmarks by `LineID`, preserve them through edits where that identity survives, and detach rather than silently reassign a landmark when no unambiguous destination survives.

#### Scenario: Text is inserted above an attached line
- **WHEN** an edit inserts or removes logical lines above a landmark
- **THEN** the landmark remains attached to its original `LineID`
- **AND** appears at that line's new ordinal

#### Scenario: An attached line is split
- **WHEN** a newline splits a landmarked line
- **THEN** the landmark remains on the leading fragment that retains the original `LineID`

#### Scenario: A trailing landmark joins an unlandmarked leading line
- **WHEN** deleting one newline directly joins an unlandmarked leading line with a landmarked trailing line
- **THEN** Jort transfers the trailing landmark to the surviving leading `LineID`
- **AND** records the transfer in the same undo transaction

#### Scenario: Two landmarked lines are joined
- **WHEN** deleting one newline directly joins two landmarked lines
- **THEN** the leading line's landmark remains attached to the surviving `LineID`
- **AND** the trailing line's landmark becomes detached rather than replacing or merging with it

#### Scenario: An attached identity is deleted ambiguously
- **WHEN** an edit removes a landmarked line without a unique surviving identity under the split and join rules
- **THEN** Jort retains the landmark as detached metadata
- **AND** does not display it beside unrelated document text

### Requirement: Landmark mutations share native undo boundaries
Jort SHALL record landmark additions, changes, clears, transfers, and detachments with their associated document transaction so Undo and Redo restore exact landmark state.

#### Scenario: A join that transfers a landmark is undone
- **WHEN** the user undoes and redoes a newline deletion that transferred a landmark
- **THEN** text, line identities, landmark identity, emoji, and attachment return to their exact before and after states
- **AND** each Undo or Redo is one user-visible operation

#### Scenario: A standalone landmark change is undone
- **WHEN** the user adds, changes, moves, or clears a landmark and invokes Undo
- **THEN** Jort restores the prior landmark collection without changing unrelated text or metadata

### Requirement: The gutter provides normal and landmark navigation modes
Jort SHALL render landmarks in the existing fixed-width logical-line gutter and SHALL offer a control that toggles between normal line rows and a compact landmark index without shifting the editor canvas.

#### Scenario: Normal mode displays a visible landmark
- **WHEN** a landmarked logical line is visible in normal mode
- **THEN** its emoji occupies the line-number position aligned to that logical line
- **AND** visual wraps create no additional landmark entries

#### Scenario: Landmark mode opens
- **WHEN** the user activates the landmark-mode control
- **THEN** attached landmark emoji replace line-number rows within the same gutter width
- **AND** appear top-aligned in document order with one accessible row per landmark
- **AND** unlandmarked lines and detached landmarks produce no placeholder rows

#### Scenario: User navigates to a landmark
- **WHEN** the user activates an attached landmark entry
- **THEN** Jort resolves its current `LineID`, scrolls its logical line into view, and returns focus to the editor
- **AND** does not mutate text or landmark order

### Requirement: Landmarks persist and recover atomically with current state
Jort SHALL include attached and detached landmark records in the versioned current-state store and operational recovery checkpoints and SHALL verify their identity and line references before publication.

#### Scenario: App relaunches
- **WHEN** a document with landmarks is saved and Jort relaunches
- **THEN** every landmark restores with the same identity, emoji, attachment state, and document order

#### Scenario: Crawl store is migrated
- **WHEN** Jort first opens a verified Crawl schema that contains no landmark collection
- **THEN** it migrates to an empty landmark collection without changing canonical text, document identity, or line identities

#### Scenario: Crawl contains prototype landmarks
- **WHEN** a Crawl store contains valid prototype landmark records
- **THEN** migration preserves their identities, emoji, and attachments, including detached references
- **AND** malformed metadata causes preservation and refusal rather than silent removal

#### Scenario: The newest recovery checkpoint is damaged
- **WHEN** the primary store cannot be recovered and the newest advertised checkpoint fails verification
- **THEN** Jort attempts the previous advertised checkpoint with complete text, line, and landmark validation
- **AND** preserves the damaged store before installing a verified replacement

#### Scenario: Checkpoint publication fails
- **WHEN** publishing a checkpoint fails after the primary write
- **THEN** the save remains failed and retryable under the shipped save contract
- **AND** the previous verified checkpoint remains available

#### Scenario: Landmark mutation overlaps a write failure
- **WHEN** a landmark changes while storage is unavailable
- **THEN** the in-memory landmark state remains authoritative and usable
- **AND** Retry persists the newest text, line metadata, and landmark collection as one verified generation

### Requirement: Landmark controls are keyboard and accessibility operable
Jort SHALL expose the gutter mode, attached landmark entries, and landmark mutation actions with names, values, roles, focus, and actions usable through Full Keyboard Access and VoiceOver.

#### Scenario: Accessibility client inspects a landmark
- **WHEN** VoiceOver focuses an attached landmark gutter entry
- **THEN** Jort announces the emoji, logical line ordinal, and action to navigate or change it
- **AND** does not announce landmark metadata as document text

#### Scenario: Pointer is unavailable
- **WHEN** the editor caret is on a logical line and the user uses the menu, command palette, or Full Keyboard Access
- **THEN** the user can add, change, or clear that line's landmark and toggle landmark mode without pointer input
