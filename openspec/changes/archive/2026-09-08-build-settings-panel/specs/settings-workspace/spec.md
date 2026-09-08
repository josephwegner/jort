## ADDED Requirements

### Requirement: Jort provides one native Settings window
Jort SHALL provide one modeless native Settings window for the application and SHALL route the Jort menu Settings command and Command-comma shortcut to that same window instance.

#### Scenario: Settings opens from the application menu
- **WHEN** the user chooses Settings or presses Command-comma
- **THEN** Jort presents the Settings window in front with its current pane focused
- **AND** does not create a second Settings window or mutate document content

#### Scenario: Settings is already visible
- **WHEN** the user invokes Settings while its window is already open
- **THEN** Jort activates the existing window and preserves its selected pane and draft state
- **AND** does not reset the editor window's selection or viewport

#### Scenario: Editor window is closed
- **WHEN** the user closes the editor window while Settings is visible
- **THEN** Settings remains usable as application chrome
- **AND** reopening the editor does not create another Settings window

### Requirement: Settings navigation scales through registered panes
Jort SHALL render registered settings panes in a source-list sidebar using stable pane identifiers and SHALL present exactly one selected pane in the detail region.

#### Scenario: User changes pane
- **WHEN** the user selects a registered pane in the sidebar
- **THEN** its detail view replaces the prior detail view and receives an appropriate initial focus target
- **AND** the selected stable pane identifier is remembered independently of its current row index

#### Scenario: Remembered pane no longer exists
- **WHEN** Settings opens with a remembered pane identifier that is not registered in this build
- **THEN** Jort selects the first available pane deterministically
- **AND** does not show a blank or broken detail region

#### Scenario: Future pane is registered
- **WHEN** application composition adds another valid pane descriptor
- **THEN** the sidebar can present it without changing the Settings window controller's pane-specific behavior
- **AND** the new pane owns its own view state, validation, and actions

### Requirement: Settings preserves destructive drafts before transitions
Jort SHALL ask the active pane to resolve an unsaved destructive draft before changing panes, closing Settings, or replacing that draft, and SHALL support Save, Discard, and Cancel outcomes.

#### Scenario: User saves before leaving
- **WHEN** the user chooses Save in response to a dirty-draft transition
- **THEN** Jort attempts the pane's normal validated save and continues the transition only after success
- **AND** a failed save leaves the draft, selection, caret, and local undo state available

#### Scenario: User cancels leaving
- **WHEN** the user chooses Cancel in response to a dirty-draft transition
- **THEN** the requested pane or window transition does not occur
- **AND** the current draft remains unchanged and focused

#### Scenario: User discards changes
- **WHEN** the user chooses Discard in response to a dirty-draft transition
- **THEN** Jort abandons only the uncommitted draft and completes the requested transition
- **AND** committed settings and document state remain unchanged

### Requirement: The Settings workspace remains usable and accessible at supported sizes
Jort SHALL expose the Settings window, sidebar, selected pane, validation status, and actions through keyboard and accessibility APIs and SHALL enforce usable minimum dimensions for its navigation and detail regions.

#### Scenario: Keyboard user navigates Settings
- **WHEN** a Full Keyboard Access user moves between the sidebar, fields, source editor, diagnostics, and actions
- **THEN** focus follows a stable logical order and every operation is available without pointer input
- **AND** focus never moves into the document editor unless Settings is dismissed

#### Scenario: VoiceOver inspects Settings
- **WHEN** VoiceOver traverses the window
- **THEN** it identifies the window as Jort Settings, announces the selected pane and current validation or dirty state, and exposes named actions
- **AND** source text is exposed only as the value of its editor

#### Scenario: Window is resized to its minimum
- **WHEN** the user resizes Settings to its supported minimum dimensions
- **THEN** the sidebar, detail content, primary actions, and error state remain reachable without overlap
- **AND** larger content scrolls within its pane rather than resizing the editor window
