## Purpose

Define the transient, searchable, and accessible Walk command palette.

## Requirements

### Requirement: The command palette is transient and searchable
Jort SHALL provide one transient command palette opened from a title-bar control or Command-K and SHALL filter currently registered actions by title and keywords without adding persistent document-window chrome beyond the title-bar control.

#### Scenario: Open from the keyboard
- **WHEN** the editor is focused and no marked-text composition is active and the user presses Command-K
- **THEN** Jort opens the palette with its search field focused
- **AND** preserves the document selection and viewport

#### Scenario: Filter actions
- **WHEN** the user enters a query in the palette
- **THEN** Jort filters enabled and disabled registered actions case- and diacritic-insensitively by title and keywords
- **AND** updates the visible result set without mutating document text

#### Scenario: No action matches
- **WHEN** the query matches no registered action
- **THEN** the palette displays an accessible empty-result state
- **AND** Return performs no document mutation

### Requirement: Palette operation is keyboard complete
Jort SHALL support Arrow-key result navigation, Return execution, and Escape dismissal while preserving standard text editing within the palette query field.

#### Scenario: Execute selected action
- **WHEN** the user selects an enabled result and presses Return
- **THEN** Jort executes that action exactly once and dismisses the palette
- **AND** returns focus to the editor unless the action explicitly transfers focus to another presented control

#### Scenario: Dismiss without action
- **WHEN** the user presses Escape or dismisses the palette without executing a result
- **THEN** Jort restores the prior editor selection, viewport, and focus
- **AND** makes no document or metadata change

#### Scenario: Selected action becomes disabled
- **WHEN** document state changes while an action result is selected and that action becomes disabled
- **THEN** Return does not execute it
- **AND** the palette exposes its disabled state without relying on color alone

### Requirement: Walk palette scope remains bounded
Jort SHALL register application and landmark-navigation actions in Walk and SHALL NOT expose text-generating commands, agents, revision history, or indexed search as implemented actions in this change.

#### Scenario: Walk palette is inspected
- **WHEN** the user opens the completed Walk palette
- **THEN** it can discover applicable landmark and application actions
- **AND** no unavailable command, agent, history, or search subsystem initializes or appears as a functioning result

### Requirement: The palette is accessible
Jort SHALL expose the palette as a named dialog with an accessible search field, result count, selectable action rows, enabled state, and keyboard actions.

#### Scenario: VoiceOver operates the palette
- **WHEN** a VoiceOver user opens, filters, navigates, executes, or dismisses the palette
- **THEN** focus order and announcements identify the query, result count, selected action, and disabled state
- **AND** dismissal restores focus to the document

### Requirement: Pocket can open Settings
Jort SHALL register an Open Settings action in Pocket and SHALL route it to the same single-instance Settings presenter used by the application menu and Command-comma.

#### Scenario: Settings opens from Pocket
- **WHEN** the user selects Open Settings in Pocket
- **THEN** Pocket dismisses and the existing or newly presented Settings window becomes key
- **AND** the document selection and viewport remain unchanged

#### Scenario: Settings is already open from Pocket
- **WHEN** the user chooses Open Settings while the Settings window already exists
- **THEN** Jort activates that window without creating a duplicate or resetting its selected pane or draft
- **AND** focus moves to the Settings window's current appropriate control
