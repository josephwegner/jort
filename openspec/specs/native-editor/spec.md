# native-editor Specification

## Purpose
Define Jort's native macOS plain-text editing experience and its integration with document state and storage health.

## Requirements

### Requirement: Presentation updates preserve native editing continuity
Jort SHALL reconcile editor, ruler, and overlay presentation without interrupting native text input, marked-text composition, selection, first responder, undo grouping, immediate startup editing, or canonical transaction ownership.

#### Scenario: User types while presentation is dirty
- **WHEN** a content, layout, or lifecycle update is scheduled while the editor is accepting native input
- **THEN** committed characters and selection update through the ordinary native transaction path without waiting for presentation reconciliation
- **AND** the later presentation pass does not create another canonical edit or undo group

#### Scenario: Marked text overlaps a pending presentation update
- **WHEN** reconciliation would style, mount, or move presentation associated with the active marked-text range
- **THEN** Jort defers the composition-disturbing portion until marked text commits or is cancelled
- **AND** preserves candidate interaction and the startup-load deferral contract

#### Scenario: Persistence state changes during paint
- **WHEN** storage or startup state changes while AppKit is displaying the editor
- **THEN** its typed projection invalidates presentation outside drawing
- **AND** drawing cannot advance startup state, retry persistence, replace document state, or move focus

### Requirement: Editor presentation decomposition preserves one document owner
Splitting native views and presentation coordinators SHALL NOT create another mutable document model; all accepted canonical edits SHALL continue through `DocumentCoordinator` transactions and all presentation components SHALL consume immutable projections.

#### Scenario: Extracted text view accepts an edit
- **WHEN** the native text view commits a character, paste, service replacement, deletion, or composition
- **THEN** it forwards one typed native transaction through the editor adapter
- **AND** no ruler, styling, overlay, or persistence-projection component mutates canonical text independently

#### Scenario: Programmatic presentation changes
- **WHEN** invocation styles, gutter controls, storage notices, or workspace overlays reconcile
- **THEN** they update presentation-only state through their narrow owners
- **AND** the document revision remains unchanged unless an explicit document transaction effect is separately accepted

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

### Requirement: Startup editing is immediate and lossless
Jort SHALL make its native text view focused, selectable, and editable as soon as the editor shell is ready, SHALL preserve accepted text entered while persistence is loading, and SHALL reconcile that text with the authoritative load result without replacing an existing stored document.

#### Scenario: User types while a stored document is loading
- **WHEN** the editor shell becomes interactive before persistence returns a verified stored snapshot and the user enters text
- **THEN** the accepted startup text appears immediately through the normal native editing path
- **AND** Jort does not treat editability as evidence that persistence loading completed

#### Scenario: Load succeeds after startup text is entered
- **WHEN** persistence returns a verified nonempty stored snapshot after the user has entered accepted startup text
- **THEN** Jort presents the startup text above the complete stored text in one reconciled document
- **AND** preserves the stored document identity, revision lineage, and unaffected metadata rather than saving the placeholder document over it

#### Scenario: Merge needs a text boundary
- **WHEN** startup text and stored text are both nonempty, the startup text does not end in a supported newline, and the stored text does not begin with a supported newline
- **THEN** Jort inserts one LF newline between them
- **AND** otherwise preserves both texts and their existing newline sequences exactly

#### Scenario: Either side already supplies a boundary
- **WHEN** startup text ends in a supported newline or stored text begins with a supported newline
- **THEN** Jort concatenates them without adding another newline
- **AND** does not normalize LF, CRLF, CR, NEL, line-separator, or paragraph-separator content

#### Scenario: Load succeeds without startup content
- **WHEN** persistence returns a verified stored snapshot and the startup draft contains no accepted text
- **THEN** Jort presents the stored snapshot without creating a startup transaction
- **AND** the editor remains first responder unless the user intentionally moved focus

#### Scenario: Startup selection survives reconciliation
- **WHEN** load succeeds while the user has a selection or insertion point within accepted startup text
- **THEN** the reconciled document preserves that UTF-16 selection within the startup prefix when valid
- **AND** loading does not move focus into the stored content

#### Scenario: User undoes after successful reconciliation
- **WHEN** the user invokes Undo after startup text has been merged with the loaded document
- **THEN** one undo group removes the startup text and any generated boundary while leaving the loaded document intact
- **AND** Redo restores the same merged result without restoring a placeholder document identity

#### Scenario: Load resolves during marked-text composition
- **WHEN** persistence succeeds while the native text view has uncommitted marked text
- **THEN** Jort leaves the composition and candidate interaction intact until it commits or is cancelled
- **AND** includes only committed composition text in the startup merge

#### Scenario: Load fails after startup editing
- **WHEN** persistence cannot open or recover the source store after the user has entered startup text
- **THEN** Jort keeps the current in-memory text editable with its native selection and undo behavior
- **AND** exposes a recovery-editing state without overwriting or replacing the failed source files

### Requirement: Editor load completion is explicitly observable
Jort SHALL expose a typed editor startup phase that distinguishes loading, loaded-and-ready, and editable recovery after failure, and tests and UI coordination SHALL use that phase rather than native control properties as a proxy for persistence state.

#### Scenario: Test waits for ordinary load
- **WHEN** a native editor test requires a loaded document before acting
- **THEN** it waits until the editor startup phase reports ready
- **AND** cannot pass its load precondition merely because `NSTextView.isEditable` is true

#### Scenario: Test exercises the startup window
- **WHEN** a controlled persistence fixture delays load completion
- **THEN** the test can observe the loading phase while the editor remains editable
- **AND** can deterministically resolve the load as success, failure, or future-version refusal

### Requirement: Recovery and private-data actions remain quiet and accessible
Jort SHALL place Save/Retry Save, Save Recovery Copy, Clear History and Recovery Data, and applicable Retry Cleanup actions in the File menu or contextual storage-health UI, SHALL keep them out of Pocket, and SHALL expose their state and confirmation to keyboard and accessibility clients without stealing editor focus for routine status changes.

#### Scenario: File menu opens for a dirty healthy document
- **WHEN** the active editor has a verified loaded store and an unsaved authoritative revision
- **THEN** File presents enabled Save with Command-S and Save Recovery Copy
- **AND** Pocket contains neither recovery nor purge actions

#### Scenario: File menu opens after automatic retries are exhausted
- **WHEN** the active editor requires manual persistence retry
- **THEN** the Command-S item is titled Retry Save and describes the newest pending revision through accessible state
- **AND** activating it invokes the explicit retry path rather than waiting for autosave

#### Scenario: Recovery needs attention at launch
- **WHEN** recovery succeeds from a damaged store or all bounded candidates are rejected
- **THEN** Jort presents concise localized nonmodal or launch-context UI explaining what was preserved and which actions remain available
- **AND** keeps recovery editing, copy, selection, and recovery export usable without silently replacing the source

#### Scenario: User saves a recovery copy while source is unhealthy
- **WHEN** the user chooses Save Recovery Copy and completes the native save panel
- **THEN** Jort exports the newest coherent in-memory snapshot to the chosen versioned JSON file and reports the actual result
- **AND** does not overwrite, import, or mark the canonical source healthy

#### Scenario: User confirms destructive purge
- **WHEN** Clear History and Recovery Data is available and activated
- **THEN** a keyboard- and VoiceOver-operable confirmation names history, milestones, recovery data, diagnostic backups, current-document preservation, and deletion limits
- **AND** cancellation changes no persistence, history, or recovery data

#### Scenario: Purge cleanup is incomplete
- **WHEN** the current-only store is active but recognized old managed copies remain
- **THEN** Jort reports that cleanup is incomplete and offers Retry Cleanup without claiming deletion succeeded
- **AND** the editor remains usable with its current text, selection, and focus
