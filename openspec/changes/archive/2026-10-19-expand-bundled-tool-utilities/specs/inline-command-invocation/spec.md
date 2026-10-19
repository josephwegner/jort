## ADDED Requirements

### Requirement: Tool arguments are separate from contextual note content
Jort SHALL expose schema-declared arguments in a labeled, keyboard-accessible anchored field for contextual tools and SHALL submit them separately from exact contextual content. Contained generators SHALL parse only their owned input as arguments. Completion acceptance SHALL never execute a command.

#### Scenario: Join receives a separator containing spaces
- **WHEN** a user supplies `" · "` to `/join` and submits captured lines
- **THEN** the script receives a separator containing those spaces and only note text as content
- **AND** arguments are not inserted into or removed from the note block

#### Scenario: Argument is empty or malformed
- **WHEN** `/join` receives `""`, `/split` receives `""`, or an argument has an unmatched quote
- **THEN** empty join is valid, empty split fails validation, and an unmatched quote fails validation
- **AND** a validation failure retains editable arguments and content without running any effect

#### Scenario: Existing contextual tool has no argument schema
- **WHEN** a legacy contextual command is accepted
- **THEN** its current logical-line scope, handles, invocation exclusion, and single-leading-space normalization remain unchanged
- **AND** no extra argument field appears

#### Scenario: Arguments change during a run or are recovered
- **WHEN** execution is submitted
- **THEN** content, arguments, package version, and generation are captured and validated together
- **AND** later UI edits cannot alter that run
- **AND** restored completed actions never re-execute; ephemeral arguments are discarded on dismissal under the existing ephemeral-data policy

### Requirement: Every argument control is keyboard operable
Jort SHALL support keyboard-only entry, traversal, editing, validation, submission, and return to the editor for every tool argument control, with visible focus, accessible labels, and no focus traps.

#### Scenario: User enters and traverses arguments
- **WHEN** a contextual command with arguments is accepted using the keyboard
- **THEN** its first argument field receives focus and Tab/Shift-Tab traverse every argument field and invocation control in a stable order
- **AND** ordinary text editing/navigation keys work within the fields
- **AND** the existing explicit Submit shortcut works from every field without completion acceptance running the tool

#### Scenario: User returns to the editor and re-enters arguments
- **WHEN** Escape is pressed in an argument field
- **THEN** focus returns to the invocation in the editor without executing or discarding entered values
- **AND** the user can reopen the argument controls using the keyboard
- **AND** explicit invocation dismissal still discards ephemeral arguments

#### Scenario: Invalid arguments need correction
- **WHEN** keyboard submission fails argument validation
- **THEN** the first invalid field receives focus with its error available to accessibility clients
- **AND** the user can correct and resubmit without a pointer

#### Scenario: Argument controls are reconstructed
- **WHEN** an invocation scrolls offscreen and its controls are remounted
- **THEN** keyboard navigation retains the same logical order and accessible control labels
- **AND** argument values are preserved for the active invocation without stealing focus from unrelated editing

### Requirement: Reports and action completion remain outside canonical text
Jort SHALL show accessible noncanonical reports and action receipts without entering the text-output Merge path, SHALL preserve contextual content, and SHALL provide Done to remove only the owned invocation token and acceptance separator through an undoable transaction.

#### Scenario: Count completes
- **WHEN** `/count-words` reports a result
- **THEN** the result is visible and announced without being inserted into the document
- **AND** Done and Undo do not replace note text or rerun the command

#### Scenario: Action fails or is cancelled
- **WHEN** an export panel is cancelled or an action returns a failure
- **THEN** source and editable invocation remain available with accurate noncanonical feedback
- **AND** no success receipt or canonical result is fabricated

#### Scenario: Action description is inspected
- **WHEN** a host-action invocation is ready to submit
- **THEN** its description identifies clipboard, file, or notification behavior and relevant configured destination class
- **AND** the same information and argument controls are available through keyboard navigation and accessibility
