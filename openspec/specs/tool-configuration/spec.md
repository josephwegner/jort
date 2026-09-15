## Purpose

Define user-facing configuration and safe catalog publication for bundled and custom Jort tools.

## Requirements

### Requirement: Settings distinguishes bundled templates from user tools
Jort SHALL list versioned bundled tool templates and user-defined tools with stable identities, origin, command name, description, enablement, and validation state.

#### Scenario: Bundled template is inspected
- **WHEN** the user selects a bundled template
- **THEN** Settings shows its metadata and executor-specific implementation as read-only template content
- **AND** offers enablement and Duplicate to Customize without allowing in-place implementation edits

#### Scenario: Template is duplicated
- **WHEN** the user chooses Duplicate to Customize
- **THEN** Jort creates an unsaved user-owned draft with a new stable identifier, copied fields and executor-specific implementation, optional template ancestry, and a conflict-free proposed command name
- **AND** later bundled-template updates cannot overwrite that custom implementation

#### Scenario: New custom tool is created
- **WHEN** the user chooses New Tool
- **THEN** Settings opens a user-owned draft with explicit defaults and an empty bounded JavaScript source field
- **AND** the tool does not enter the committed or executable catalog until Save succeeds

### Requirement: Tool enablement is explicit and persistent
Jort SHALL let users enable or disable each valid bundled template or committed custom tool and SHALL persist that choice by stable tool identity.

#### Scenario: User disables a tool
- **WHEN** the user turns off an enabled tool and persistence succeeds
- **THEN** Settings updates the row to disabled and publishes a new committed catalog revision
- **AND** the tool is absent from the executable projection without deleting its definition or source

#### Scenario: Enablement write fails
- **WHEN** persistence fails while changing a tool's enablement
- **THEN** Settings restores the last committed toggle value and presents an actionable error
- **AND** runtime consumers continue using the prior catalog revision

#### Scenario: Bundled template is upgraded
- **WHEN** a later app version supplies a newer bundled template with the same stable identity
- **THEN** Jort applies the new bundled content while preserving the user's explicit enablement override
- **AND** does not alter independent user tools previously duplicated from it

### Requirement: Custom tool edits are validated and revisioned
Jort SHALL edit custom tools through local drafts, SHALL require a display name, a normalized unique slash command name, and bounded executor-specific content, including instructions and a bundled model selection for model tools, and SHALL save only against the draft's base revision.

#### Scenario: Valid custom tool saves
- **WHEN** the draft passes structural validation and every diagnostic from the injected tool validator is non-blocking
- **THEN** Jort atomically commits the complete definition and publishes one new catalog revision
- **AND** clears the draft's dirty state without clearing its editor selection or local undo history prematurely

#### Scenario: Draft has blocking diagnostics
- **WHEN** required fields, command syntax, uniqueness, implementation bounds, or an injected validator produce a blocking diagnostic
- **THEN** Save performs no persistence mutation and Settings exposes each diagnostic with an associated field or source range when available
- **AND** does not describe structural validation as proof that the tool is safe to execute

#### Scenario: Definition changed since editing began
- **WHEN** Save targets a custom tool whose committed revision differs from the draft's base revision
- **THEN** Jort keeps the draft open and reports a conflict
- **AND** does not silently merge or overwrite either implementation version

### Requirement: Custom tool deletion is deliberate
Jort SHALL require confirmation before deleting a committed custom tool and SHALL never delete bundled templates through Settings.

#### Scenario: User confirms deletion
- **WHEN** the user confirms deletion of a custom tool and persistence succeeds
- **THEN** Jort removes the complete definition from the committed catalog in one transaction
- **AND** publishes one revision in which the tool is no longer executable

#### Scenario: User cancels deletion
- **WHEN** the user cancels the confirmation
- **THEN** the definition, selection, enablement, and catalog revision remain unchanged

#### Scenario: User attempts to delete a template
- **WHEN** a bundled template is selected
- **THEN** Settings exposes no destructive delete action for that template
- **AND** offers disable or Duplicate to Customize instead

### Requirement: JavaScript source editing preserves code exactly
Jort SHALL provide a native plain-text source editor with monospaced text, line numbers, scrolling, selection, Find, local Undo and Redo, standard clipboard operations, and exact UTF-8 source round-tripping.

#### Scenario: Source is typed or pasted
- **WHEN** the user enters or pastes JavaScript source
- **THEN** the editor preserves the entered characters as plain text and updates draft dirty and validation state
- **AND** rich attachments, smart quotes, smart dashes, spelling changes, and automatic text substitutions do not modify the source

#### Scenario: Source edit is undone
- **WHEN** the user invokes Undo while focus is in the source editor
- **THEN** the source editor reverses its latest draft edit and updates diagnostics
- **AND** document text and the document Undo stack remain unchanged

#### Scenario: Diagnostic is selected
- **WHEN** the user activates a source diagnostic that has a valid range
- **THEN** the editor selects and reveals that range and announces its line, column, severity, and message accessibly
- **AND** the diagnostic itself is not inserted into source text

### Requirement: Settings does not execute tool source
Jort SHALL expose only committed, enabled, valid tool definitions through a read-only executable catalog projection and SHALL NOT execute JavaScript or models, check provider credentials, or grant tool authority from the Settings workspace.

#### Scenario: User saves a tool
- **WHEN** a custom definition is successfully saved
- **THEN** Settings publishes its committed catalog data for a separate runtime consumer
- **AND** performs no preview run, JavaScript evaluation, model request, credential verification, OAuth connection, network request, shell operation, file access, or external-process launch

#### Scenario: Tool state is unsafe to publish
- **WHEN** settings are unavailable or a definition is disabled, invalid, or in command-name conflict
- **THEN** that definition is absent from the executable projection
- **AND** its preserved configuration remains visible for explicit repair when the settings store can be read safely

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

#### Scenario: Publication durability is uncertain
- **WHEN** replacement is visible but durable publication cannot be confirmed
- **THEN** Settings keeps the draft and pending transition open, reports uncertainty, and offers Show Recovery Files for the preserved indexes and package sources
