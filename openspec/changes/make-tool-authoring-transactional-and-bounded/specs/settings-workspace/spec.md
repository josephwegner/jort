## ADDED Requirements

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
