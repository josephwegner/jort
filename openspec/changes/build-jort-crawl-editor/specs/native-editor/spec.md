## ADDED Requirements

### Requirement: One app-owned editable document after load
Jort SHALL expose exactly one app-owned plain-text document in a single AppKit window and, after persistence load completes, SHALL make its TextKit 2 `NSTextView` the key window's first responder without requiring a click, file choice, title, setup, account, or network access.

#### Scenario: First launch
- **WHEN** the user launches Jort and no store database exists in the selected data directory
- **THEN** Jort presents an intentionally empty document with an insertion point in the focused editor
- **AND** the user can type while the empty store is created as part of load

#### Scenario: Ordinary relaunch
- **WHEN** Jort loads a verified previously persisted document
- **THEN** it presents that document in the focused editor
- **AND** it does not briefly substitute an empty document for the persisted content after load succeeds

#### Scenario: Load fails
- **WHEN** persistence cannot open or recover the store
- **THEN** Jort still presents an in-memory editor so the user can copy or keep typing
- **AND** it does not overwrite the original store files

#### Scenario: Window regains key status
- **WHEN** the document window becomes key after load and no transient native editor control intentionally owns focus
- **THEN** the editor becomes or remains first responder
- **AND** background persistence does not steal focus

### Requirement: AppKit host owns presentation, not document state
Jort SHALL host the editor in an AppKit `NSWindow` with `EditorViewController` as the adapter and SHALL keep live document state in `DocumentCoordinator`. The adapter SHALL translate AppKit edit events into typed transactions and SHALL NOT own an independently mutable domain model.

#### Scenario: Native edit is accepted
- **WHEN** the text view commits an accepted edit
- **THEN** the adapter submits one `DocumentTransaction` with origin `native`
- **AND** persistence receives an immutable `DocumentSnapshot` from the coordinator

#### Scenario: Programmatic mutation is submitted
- **WHEN** a later command or capture submits a transaction through the adapter
- **THEN** it uses the same coordinator transaction API
- **AND** it never receives `NSTextStorage` or mutates the text view as a second source of truth

### Requirement: Canonical content remains plain text
Jort SHALL store only Unicode text and SHALL keep all logical-line and storage metadata outside that text. Paste SHALL insert the plain-text representation and SHALL NOT retain fonts, colors, attachments, links, or other rich-text attributes as document content.

#### Scenario: Rich clipboard content is pasted
- **WHEN** the user pastes styled text into the editor
- **THEN** Jort inserts its plain-text representation using the native paste path
- **AND** does not retain rich-text attributes as document content

#### Scenario: Content is copied
- **WHEN** the user copies a document selection
- **THEN** the clipboard receives the selected ordinary text with its newline characters
- **AND** no line identity, timestamp, revision, or storage-health data is included

#### Scenario: Crawl command surface is inspected
- **WHEN** the Crawl MVP menus and window controls are presented
- **THEN** no user-selected working-document file workflow is offered
- **AND** the only user-chosen file action is an optional separate recovery-copy export

### Requirement: Native keyboard editing behavior
Jort SHALL use the macOS text system for character input, movement, selection, deletion, indentation, newline insertion, and text transformations, and SHALL NOT intercept standard text key bindings except to invoke the corresponding native or paired undo action.

#### Scenario: Standard editing shortcuts
- **WHEN** the editor is focused
- **THEN** Command-A, Command-X, Command-C, Command-V, Command-Z, and Command-Shift-Z perform select-all, cut, copy, paste, undo, and redo
- **AND** each undo or redo restores text, selection behavior, and paired logical-line metadata as one user-visible undo step

#### Scenario: Keyboard navigation and selection
- **WHEN** the user presses Arrow, Option-Arrow, Command-Arrow, Home, End, Page Up, Page Down, or their Shift-modified selection forms
- **THEN** the insertion point, selection, and viewport move according to standard macOS multiline text behavior
- **AND** Jort does not substitute proprietary line or block navigation

#### Scenario: Native input commands
- **WHEN** the user presses Return, Tab, Delete, Forward Delete, Escape, or a configured macOS text-system key binding
- **THEN** `NSTextView` performs the standard applicable text or composition command
- **AND** no Crawl-only command palette, invocation, or landmark behavior consumes the key

### Requirement: Native undo, clipboard, Services, and drag behavior
Jort SHALL preserve pasteboard interoperability, applicable macOS Services, and native selection drag/autoscroll behavior. Text and metadata undo SHALL share one custom undo manager so each registered group restores a complete prior snapshot rather than a text-only mutation.

#### Scenario: Grouped typing is undone
- **WHEN** the user types an undo group and invokes Undo
- **THEN** the expected text edit is reversed in one operation
- **AND** Redo reapplies that same operation without losing intervening line identities

#### Scenario: Native edit coalescing
- **WHEN** the user types consecutive characters
- **THEN** Jort MAY break native TextEdit-style coalescing to keep text/metadata undo pairs deterministic
- **AND** undo may therefore reverse smaller steps than TextEdit

#### Scenario: Selection crosses the viewport
- **WHEN** the user extends or drags a selection beyond the visible editor bounds
- **THEN** the scroll view autoscrolls using standard macOS behavior
- **AND** the selected canonical text remains accurate

#### Scenario: Plain text service is invoked
- **WHEN** an installed macOS Service applicable to selected plain text is invoked
- **THEN** Jort supplies the ordinary selected text through the standard Services path
- **AND** accepts any returned replacement as a normal undoable plain-text edit

### Requirement: In-document find uses native behavior
Jort SHALL provide the standard macOS in-document find interface and SHALL perform find operations against the current in-memory document without creating a search index.

#### Scenario: Open and navigate find results
- **WHEN** the user presses Command-F, Command-G, or Command-Shift-G
- **THEN** the native find interface opens or moves to the next or previous match
- **AND** the editor scrolls and selects the matching range using standard macOS behavior

#### Scenario: Close find
- **WHEN** the user dismisses the native find interface
- **THEN** focus returns to the document editor
- **AND** the document selection remains valid

### Requirement: Wrapping, scrolling, and a viewport-bounded line-number gutter
Jort SHALL visually wrap long logical lines to the available editor width, SHALL use a native vertical scroll view without document-level horizontal scrolling, and SHALL draw a line-number gutter from already visible TextKit 2 fragments. Scrolling SHALL NOT force whole-document layout.

#### Scenario: Window width changes
- **WHEN** the user resizes the window so a logical line wraps into a different number of visual rows
- **THEN** TextKit reflows the visual rows without inserting or removing canonical newline characters
- **AND** the logical line retains one identity

#### Scenario: User scrolls by supported input method
- **WHEN** the user scrolls with a trackpad, mouse wheel, scrollbar, keyboard command, or accessibility action
- **THEN** the editor uses native momentum, bounds, and selection behavior
- **AND** autosave completion does not jump the viewport or selection

#### Scenario: Gutter shows visible line numbers
- **WHEN** the document is displayed
- **THEN** the gutter shows decimal line numbers for visible logical lines, including the extra empty end-of-document row
- **AND** it does not display timestamps, landmark emoji, or storage status

### Requirement: IME and marked-text behavior is preserved
Jort SHALL conform to the macOS text input client protocols and SHALL preserve marked-text composition, candidate selection, replacement ranges, and composition cancellation. Provisional marked text SHALL remain native display state rather than accepted canonical document state until composition commits.

#### Scenario: Composition commits
- **WHEN** an input method presents and then commits marked text containing Unicode, combining marks, or a newline
- **THEN** the candidate UI and marked range behave as in a standard `NSTextView`
- **AND** the committed result becomes one ordinary undoable document transaction
- **AND** canonical text, metadata, revision, and persistence advance exactly once at commit

#### Scenario: Composition is cancelled
- **WHEN** the user cancels marked-text composition
- **THEN** the pre-composition canonical text and selection are retained
- **AND** no cancelled provisional text becomes durable document state

#### Scenario: Process ends during active composition
- **WHEN** Jort exits or crashes while marked text remains uncommitted
- **THEN** the provisional candidate is not treated as accepted canonical text
- **AND** earlier committed edits remain subject to the ordinary save-cadence durability of this change

### Requirement: Automatic substitutions remain off
Jort SHALL disable automatic quote, dash, text-replacement, and link-detection substitutions and SHALL leave continuous spell checking off. Jort SHALL add no remote or custom checker.

#### Scenario: User types punctuation that macOS would otherwise rewrite
- **WHEN** the user types quotes, dashes, or other substitution triggers
- **THEN** the typed characters remain as entered
- **AND** no automatic substitution becomes document content

### Requirement: Editor accessibility is normative
Jort SHALL expose the document editor as one named, enabled, editable multiline accessibility text area and SHALL support VoiceOver reading, navigation, selection, editing, and scrolling without requiring pointer input.

#### Scenario: Accessibility client inspects the editor
- **WHEN** VoiceOver or another accessibility client queries the focused editor
- **THEN** it receives the “Jort document” label, multiline editable role, current value, selected text and range, insertion point, visible range, and bounds for requested text ranges
- **AND** invisible logical-line and storage metadata are not announced as document text

#### Scenario: VoiceOver edits the document
- **WHEN** a VoiceOver user navigates, selects, dictates, types, cuts, copies, pastes, undoes, redoes, finds, or scrolls within the document
- **THEN** the operation produces the same canonical text result and undo semantics as the equivalent non-VoiceOver operation
- **AND** focus remains in the editor unless the user explicitly moves it

### Requirement: Storage-health UI is actionable and non-blocking
Jort SHALL keep editing available when storage is unhealthy, SHALL present a concise nonmodal notice with Retry or Save Recovery Copy as appropriate, and SHALL NOT move keyboard focus when storage state changes. Routine successful saves SHALL remain silent. Failed saves SHALL remain visibly actionable.

#### Scenario: Storage state becomes unhealthy
- **WHEN** persistence reports a failed save, retry-scheduled save, load failure, or future-version refusal
- **THEN** Jort presents a nonmodal notice near the document window with a concise description
- **AND** Command-S retries the newest in-memory snapshot when retry is permitted

#### Scenario: Ownership conflict
- **WHEN** another Jort process already owns the selected data directory
- **THEN** the duplicate process does not offer recovery or write the store
- **AND** it activates the existing owner when practical and exits

#### Scenario: User quits while dirty
- **WHEN** the user quits and the latest flush does not succeed
- **THEN** Jort warns that unsaved changes may be lost
- **AND** offers to keep the app open or quit without saving

### Requirement: Launch and interaction performance is measurable
Jort SHALL report launch, transaction, serialization, paste, gutter, sustained-edit, undo, and search measurements against the committed 10,000-line fixture. CI MAY enforce the documented generous regression ceilings; those ceilings are not user-facing latency promises.

#### Scenario: Healthy fixture launch
- **WHEN** launch is measured against a healthy fixture store
- **THEN** time to an editable editor is reported
- **AND** the initial CI regression ceiling is 2 seconds

#### Scenario: Localized transaction under the fixture
- **WHEN** a 10,000-line transaction is measured
- **THEN** CI may fail a debug p95 above 100 ms
- **AND** the optimized target remains under 16 ms

#### Scenario: Sustained native edits with saves
- **WHEN** native edits run with autosave and gutter updates active
- **THEN** the reported p95 remains below the 100 ms regression ceiling
- **AND** no user-facing half-second save deadline is promised
