## Purpose

Define Jort's extensible, modeless native Settings workspace.

## Requirements

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

### Requirement: Settings transitions await the owned save result
When a pending pane, draft, window, or application transition chooses Save, Settings SHALL await the active pane's exact owned save operation and SHALL continue the transition only after that operation reports success.

#### Scenario: User saves before changing panes
- **WHEN** the user chooses Save while navigating away from a dirty Tools draft
- **THEN** the requested pane remains pending until the owned save operation completes successfully
- **AND** no timer, polling loop, or observation of draft dirtiness is used as a completion signal

#### Scenario: User saves before replacing the draft
- **WHEN** creating, duplicating, or selecting another tool would replace a dirty draft and the user chooses Save
- **THEN** Jort awaits the same owned save result before constructing or selecting the requested draft
- **AND** unsuccessful save leaves the original draft and requested transition uncommitted

#### Scenario: User saves before closing or terminating
- **WHEN** the user chooses Save while closing Settings or terminating Jort with a dirty Tools draft
- **THEN** close or termination waits for the exact save operation and proceeds only on success
- **AND** validation, conflict, cancellation, or storage failure keeps Jort open with the draft available

#### Scenario: Transition is requested during an existing save
- **WHEN** a pane, close, draft, or termination transition arrives while the active draft is already saving
- **THEN** it awaits the existing operation rather than starting another save
- **AND** its completion callback is invoked exactly once on the main actor

### Requirement: Save resolution remains responsive and accessible
Settings SHALL expose the in-flight save state to assistive technologies, SHALL keep non-conflicting window behavior responsive, and SHALL restore a useful focus target after success or failure.

#### Scenario: Assistive technology inspects an in-flight save
- **WHEN** validation or storage is still running
- **THEN** Settings communicates that the tool is saving and exposes conflicting controls as disabled
- **AND** does not announce success or permit the pending transition before the result exists

#### Scenario: Save fails during a pending transition
- **WHEN** an awaited save returns diagnostics, conflict, or storage failure
- **THEN** focus returns to the relevant draft field, diagnostic, or Save workflow
- **AND** the pending destination does not replace the draft or steal focus

#### Scenario: Publication durability is uncertain
- **WHEN** replacement is visible but durable publication cannot be confirmed
- **THEN** Settings keeps the draft and pending transition open, reports uncertainty, and offers Show Recovery Files for the preserved indexes and package sources
