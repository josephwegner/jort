## ADDED Requirements

### Requirement: Custom tool save is awaited and single-flight
Tools Settings SHALL represent validation and persistence of a draft as one owned awaitable operation, SHALL permit at most one such operation at a time, and SHALL apply its typed result exactly once to the matching draft.

#### Scenario: Valid draft saves slowly
- **WHEN** injected validation or package persistence takes longer than an ordinary UI transition delay
- **THEN** Settings remains in a visible saving state and awaits the operation without polling draft state or reporting a timeout
- **AND** clears the matching draft only after the committed snapshot is returned

#### Scenario: Save is activated repeatedly
- **WHEN** the user presses Save more than once while the first save is in flight
- **THEN** Jort performs exactly one validation and persistence submission for that draft and base revision
- **AND** every waiter observes the same final result

#### Scenario: Draft fails injected validation
- **WHEN** asynchronous validation returns a blocking diagnostic
- **THEN** the save result identifies the blocking diagnostics and performs no package or index publication
- **AND** preserves the draft, selected source range, caret, and local source-editor undo state

#### Scenario: Draft conflicts with a newer revision
- **WHEN** persistence rejects the captured base revision because the committed tool changed
- **THEN** the save reports an explicit conflict and applies no UI state from the stale submission
- **AND** preserves the draft for deliberate reload or reconciliation

#### Scenario: Package publication fails
- **WHEN** generation or index publication fails
- **THEN** Settings reports an actionable save error and keeps the draft dirty
- **AND** the previously committed catalog snapshot remains authoritative

### Requirement: Conflicting authoring controls are unavailable during save
While a custom-tool save is in flight, Tools Settings SHALL prevent draft mutation, enablement changes, duplicate/delete actions, tool-selection replacement, and additional persistence operations that could race with the captured submission.

#### Scenario: Save begins
- **WHEN** Tools Settings captures a valid draft for asynchronous save
- **THEN** every conflicting authoring and catalog mutation control becomes disabled or ignores activation until the result is finalized
- **AND** the draft remains visibly unsaved until success

#### Scenario: Save finishes unsuccessfully
- **WHEN** validation, conflict, or persistence returns an unsuccessful result
- **THEN** applicable controls are restored against the unchanged draft
- **AND** focus and editable state return without constructing a replacement draft

#### Scenario: Save finishes successfully
- **WHEN** persistence returns the committed catalog snapshot for the captured draft
- **THEN** Tools Settings finalizes the operation once, rebuilds from that snapshot, and selects the saved tool
- **AND** no late callback can reapply the result to another draft

### Requirement: Deleted custom package data is eventually reclaimed
After confirmed deletion of a custom tool succeeds, Jort SHALL remove all of that tool's retained package generations after catalog removal is durable, while a failed deletion SHALL preserve both catalog state and referenced generations.

#### Scenario: Confirmed deletion publishes successfully
- **WHEN** the custom tool is durably removed from the registry index
- **THEN** Settings publishes one catalog revision in which the tool is no longer executable
- **AND** registry cleanup removes its former current and previous generations or records them for safe cleanup on the next reload

#### Scenario: User cancels or deletion conflicts
- **WHEN** the user cancels deletion or the expected tool revision conflicts
- **THEN** Jort changes neither the catalog nor the retained generation set
- **AND** the draft and current selection remain available
