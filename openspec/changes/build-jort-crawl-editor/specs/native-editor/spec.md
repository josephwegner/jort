## ADDED Requirements

### Requirement: One safely resolved and immediately editable canonical document
Jort SHALL expose exactly one app-owned canonical plain-text document and, after startup has safely resolved that document state, SHALL make its editor the key window's first responder without requiring a click, file choice, title, setup, account, network access, or storage-write success.

#### Scenario: First launch
- **WHEN** the user launches Jort and no prior Jort store, recovery checkpoint, or prior-store marker exists
- **THEN** Jort conclusively classifies genuine first launch before displaying an intentionally empty document with an insertion point in the focused editor
- **AND** the user can type immediately while initial storage creation proceeds asynchronously

#### Scenario: Ordinary relaunch
- **WHEN** Jort loads a verified previously persisted document
- **THEN** it presents that document in the focused editor
- **AND** it never briefly substitutes an empty document for the persisted content

#### Scenario: Startup state remains unresolved
- **WHEN** Jort cannot conclusively resolve prior, empty, first-launch, or recovery state within two seconds of process start
- **THEN** it presents a neutral noneditable loading/recovery state and continues resolving
- **AND** it does not expose a writable blank or later replace user-entered text

#### Scenario: Window regains key status
- **WHEN** the document window becomes key and no transient native editor control intentionally owns focus
- **THEN** the editor becomes or remains first responder
- **AND** background persistence and storage notifications do not steal focus

### Requirement: Canonical content remains normalized plain text
Jort SHALL store only Unicode text with U+000A LF as the canonical line separator and SHALL keep all logical-line and storage metadata outside that text. Each accepted edit SHALL normalize CRLF, bare CR, U+0085 NEXT LINE, U+2028 LINE SEPARATOR, and U+2029 PARAGRAPH SEPARATOR to LF within the same native undo transaction.

#### Scenario: Rich clipboard content is pasted
- **WHEN** the user pastes styled text into the editor
- **THEN** Jort inserts its plain-text representation using the native paste transaction
- **AND** does not retain fonts, colors, attachments, links, or other rich-text attributes as document content
- **AND** canonicalizes every recognized line separator in the accepted plain text to LF

#### Scenario: Service or input method supplies non-LF separators
- **WHEN** a Service replacement or committed input-method transaction contains CRLF, bare CR, U+0085, U+2028, or U+2029
- **THEN** Jort publishes LF in canonical text for each supplied line separator
- **AND** normalization, text insertion, metadata reconciliation, selection behavior, and Undo remain one native transaction

#### Scenario: Content is copied
- **WHEN** the user copies a document selection
- **THEN** the clipboard receives the selected ordinary text with its newline characters
- **AND** no line identity, timestamp, generation, checksum, or storage-health data is included

#### Scenario: Crawl command surface is inspected
- **WHEN** the Crawl MVP menus and window controls are presented
- **THEN** no export command or user-selected document-file workflow is offered

### Requirement: Native keyboard editing behavior
Jort SHALL use the macOS text system for character input, movement, selection, deletion, indentation, newline insertion, and text transformations, and SHALL NOT intercept standard text key bindings except to invoke the corresponding native action.

#### Scenario: Standard editing shortcuts
- **WHEN** the editor is focused
- **THEN** Command-A, Command-X, Command-C, Command-V, Command-Z, and Command-Shift-Z perform native select-all, cut, copy, paste, undo, and redo behavior
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
Jort SHALL preserve the `NSTextView` undo manager, pasteboard interoperability, applicable macOS Services, and native selection drag/autoscroll behavior for the plain-text document.

#### Scenario: Grouped typing is undone
- **WHEN** the user types a native undo group and invokes Undo
- **THEN** the expected text edit is reversed in one operation
- **AND** Redo reapplies that same operation without losing intervening line identities

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

### Requirement: Wrapping and scrolling remain native and viewport-stable
Jort SHALL visually wrap long logical lines to the available editor width, SHALL use a native vertical scroll view without document-level horizontal scrolling, and SHALL preserve the user's viewport during persistence activity.

#### Scenario: Window width changes
- **WHEN** the user resizes the window so a logical line wraps into a different number of visual rows
- **THEN** TextKit reflows the visual rows without inserting or removing canonical newline characters
- **AND** the logical line retains one identity

#### Scenario: User scrolls by supported input method
- **WHEN** the user scrolls with a trackpad, mouse wheel, scrollbar, keyboard command, or accessibility action
- **THEN** the editor uses native momentum, bounds, and selection behavior
- **AND** autosave completion does not jump the viewport or selection

### Requirement: IME and marked-text behavior is preserved
Jort SHALL conform to the macOS text input client protocols and SHALL preserve marked-text composition, candidate selection, replacement ranges, and composition cancellation for supported input methods. Provisional marked text SHALL remain native display state rather than accepted canonical document state until composition commits.

#### Scenario: Composition commits
- **WHEN** an input method presents and then commits marked text containing Unicode, combining marks, or a newline
- **THEN** the candidate UI and marked range behave as in a standard `NSTextView`
- **AND** the committed result becomes one ordinary undoable document edit
- **AND** canonical text, metadata, generation, and persistence advance exactly once at commit

#### Scenario: Composition is cancelled
- **WHEN** the user cancels marked-text composition
- **THEN** the pre-composition canonical text and selection are retained
- **AND** no cancelled provisional text becomes durable document state

#### Scenario: Process ends during active composition
- **WHEN** Jort exits or crashes while marked text remains uncommitted
- **THEN** the provisional candidate is not treated as accepted canonical text or a durable generation
- **AND** every earlier committed edit remains subject to the ordinary crash-loss guarantee

### Requirement: Spellcheck policy follows macOS
Jort SHALL use the standard macOS spelling, grammar, automatic correction, substitution, and text-replacement facilities according to system/user settings and standard Edit-menu controls, with no Jort-specific checker or network request.

#### Scenario: Misspelling is detected
- **WHEN** macOS continuous spell checking is enabled and the document contains a misspelling
- **THEN** the native text system presents its standard indication and correction menu
- **AND** the indication does not become canonical content or Jort metadata

#### Scenario: User accepts a correction
- **WHEN** the user or enabled macOS automatic-correction behavior replaces text
- **THEN** Jort treats the replacement as a normal undoable edit
- **AND** schedules the committed replacement for persistence

### Requirement: Editor accessibility is normative
Jort SHALL expose the document editor as one named, enabled, editable multiline accessibility text area and SHALL support VoiceOver reading, navigation, selection, editing, and scrolling without requiring pointer input.

#### Scenario: Accessibility client inspects the editor
- **WHEN** VoiceOver or another accessibility client queries the focused editor
- **THEN** it receives the “Document” label, multiline editable role, current value, selected text and range, insertion point, visible range, and bounds for requested text ranges
- **AND** invisible logical-line and storage metadata are not announced as document text

#### Scenario: VoiceOver edits the document
- **WHEN** a VoiceOver user navigates, selects, dictates, types, cuts, copies, pastes, undoes, redoes, finds, or scrolls within the document
- **THEN** the operation produces the same canonical text result and undo semantics as the equivalent non-VoiceOver operation
- **AND** focus remains in the editor unless the user explicitly moves it

#### Scenario: Display accessibility settings change
- **WHEN** Increase Contrast, Reduce Motion, keyboard Full Keyboard Access, display scaling, or an enlarged editor font is active
- **THEN** text, selection, insertion point, focus indication, scrollbars, and storage-health controls remain perceivable and operable
- **AND** no essential storage state is conveyed by color or animation alone

### Requirement: Storage-health UI is ephemeral, nonmodal, and accessible
Jort SHALL present only ephemeral storage-related Crawl notices, SHALL leave no persistent storage-health chrome in the ordinary document window, and SHALL NOT move keyboard focus or block editing when storage state changes.

#### Scenario: Storage state becomes unhealthy
- **WHEN** persistence enters automatic retry or manual-retry state
- **THEN** Jort presents a nonmodal status near the document window chrome with a concise description
- **AND** VoiceOver receives one polite announcement for the state transition rather than one announcement per failed attempt

#### Scenario: Storage notice expires or is dismissed
- **WHEN** an ephemeral storage notice expires or the user dismisses it
- **THEN** no badge, banner, footer, toolbar item, or other ambient storage status remains in the document window
- **AND** an available manual retry remains reachable through `File > Retry Saving`

#### Scenario: Manual Retry is reached by keyboard
- **WHEN** storage is waiting for manual retry
- **THEN** Retry is reachable from the visible notice and from `File > Retry Saving` using Full Keyboard Access and exposes an accessibility name and current state
- **AND** activating it returns focus to the editor after dispatching the retry

### Requirement: Launch and interaction performance is measurable
Jort SHALL meet the Crawl release budgets in an arm64 release build on the original M1/8 GB performance baseline running a supported macOS release, using the `CrawlLargeDocument` fixture and retained signpost measurements.

#### Scenario: First launch focus performance
- **WHEN** first-launch focus is measured over at least 20 cold process launches with no prior state
- **THEN** the 95th-percentile time from process start to a focused editable insertion point is at most 500 ms

#### Scenario: Startup classification safety ceiling
- **WHEN** storage discovery is artificially delayed beyond two seconds
- **THEN** by two seconds Jort has entered the neutral loading/recovery presentation rather than presenting an editable blank
- **AND** later resolution cannot reset user-entered document text because no provisional blank accepted edits

#### Scenario: Persisted large-document launch performance
- **WHEN** launch is measured over at least 20 runs restoring `CrawlLargeDocument`
- **THEN** the 95th-percentile process-start-to-focused-editor time is at most 700 ms for warm-cache launches and at most 1,500 ms for cold-cache launches
- **AND** the first accepted key event is not delayed by optional or recovery-checkpoint work after focus

#### Scenario: Typing latency under supported load
- **WHEN** at least 5,000 representative insert, delete, paste, undo, and redo events are exercised in `CrawlLargeDocument` while autosave is enabled during nightly or release qualification
- **THEN** key-event-to-visible-layout latency is at most 8 ms at the 95th percentile and 16.7 ms at the 99th percentile
- **AND** no individual event stalls the main thread for more than 50 ms

#### Scenario: Scrolling under supported load
- **WHEN** `CrawlLargeDocument` is continuously scrolled through wrapped and unwrapped regions for at least 30 seconds on a 60 Hz display during nightly or release qualification
- **THEN** the 95th-percentile frame time is at most 16.7 ms and the 99th-percentile frame time is at most 33.4 ms
- **AND** no editor-caused frame stall exceeds 100 ms
