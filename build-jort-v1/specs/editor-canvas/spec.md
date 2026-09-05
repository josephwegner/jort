# Editor Canvas Specification

## ADDED Requirements

### Requirement: One canonical document
Jort SHALL expose one app-owned canonical plain-text document and SHALL NOT require the user to choose a file, title, folder, page, or notebook before typing.

#### Scenario: First launch
- **WHEN** the user launches Jort with no prior state
- **THEN** Jort displays an empty focused editor ready for typing
- **AND** no setup, account, provider, network request, or file picker blocks the editor

#### Scenario: Copy and export
- **WHEN** the user copies or exports document content
- **THEN** the output contains ordinary text and newline characters
- **AND** landmarks, annotations, invocation state, provenance, and capture metadata are excluded by default

### Requirement: Native plain-text editing
Jort SHALL implement the primary editor with `NSTextView` and TextKit 2 and SHALL preserve expected macOS behavior for selection, IME composition, accessibility, undo, paste, find, wrapping, and scrolling.

#### Scenario: Optional subsystem failure
- **WHEN** a model provider, plugin, command, capture service, or persistence write fails
- **THEN** typing, selection, copy, paste, and undo remain available
- **AND** the failure is reported without replacing or discarding document text

### Requirement: Logical-line identity and provenance
Jort SHALL assign stable metadata identities to newline-delimited logical lines and store `createdAt` and `lastEditedAt` for each non-whitespace-empty logical line.

#### Scenario: Line becomes empty
- **WHEN** a logical line contains only whitespace after an edit
- **THEN** Jort clears its timestamp metadata

#### Scenario: Visual wrapping
- **WHEN** a logical line wraps into multiple visual rows
- **THEN** it retains one logical-line identity and one gutter entry

#### Scenario: Split or join
- **WHEN** an edit splits or joins logical lines
- **THEN** Jort applies deterministic identity and timestamp inheritance rules
- **AND** undo restores the prior identities and timestamps

### Requirement: Inline invocation recognition
Jort SHALL recognize configured `@agent` and `/command` invocations at the line and character position where they are typed without changing ordinary unmatched punctuation.

#### Scenario: Pending invocation
- **WHEN** a configured invocation is recognized
- **THEN** only its logical line receives a compact inline decoration
- **AND** Return alone does not execute it
- **AND** Escape or abandoning the range returns it to ordinary text

#### Scenario: Visible context
- **WHEN** an invocation requests prompt-only, full-line, or bounded nearby context
- **THEN** Jort visibly decorates the exact submitted ranges before execution
- **AND** the user can inspect and change the context using an on-screen control

#### Scenario: Mid-line full-line context
- **WHEN** a user grants `full-line` to an invocation entered mid-line
- **THEN** the submitted context includes the entire newline-delimited line, including text before and after the invocation

### Requirement: Explicit invocation execution
Jort SHALL require Shift+Enter or an explicit Run control to execute a pending invocation.

#### Scenario: Run snapshots mutable inputs
- **WHEN** an invocation begins
- **THEN** Jort records the invocation range, selected context ranges, document revision, provider/tool identity, and hashes of mutation targets
- **AND** the document remains editable while the run executes

#### Scenario: Completion
- **WHEN** a run completes successfully
- **THEN** Jort inserts the complete output atomically as ordinary text immediately after the invocation line
- **AND** attaches provenance metadata to the inserted range
- **AND** does not stream partial tokens into the document

#### Scenario: Stale mutation target
- **WHEN** the intended mutation target changed after the run began
- **THEN** Jort does not overwrite newer text
- **AND** either inserts at a safe boundary or asks the user to resolve the conflict

### Requirement: Narrow and visible AI authority
Jort SHALL separate configured capabilities from per-run user consent and SHALL never permit permanent authorization for whole-document or history reads.

#### Scenario: Default context
- **WHEN** an agent is invoked without broader context
- **THEN** only the explicit prompt range is submitted

#### Scenario: Whole-document read
- **WHEN** an agent requests the entire current document
- **THEN** Jort presents a fresh confirmation with a content preview for that request

#### Scenario: History read
- **WHEN** an agent requests a revision
- **THEN** Jort identifies and previews the exact revision before requesting fresh consent

### Requirement: Launch and interaction invariants
Jort SHALL focus the editable canvas before initializing optional providers, scripts, commands, capture polling, analytics, update checks, or plugin discovery.

#### Scenario: Background completion
- **WHEN** an optional background operation completes
- **THEN** the current selection and visual viewport remain stable unless the user explicitly navigates to the result

#### Scenario: Large document
- **WHEN** Jort operates on the agreed large-document stress fixture
- **THEN** typing, viewport layout, gutter updates, search, timestamps, and landmark navigation meet defined performance budgets

