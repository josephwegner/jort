## MODIFIED Requirements

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

