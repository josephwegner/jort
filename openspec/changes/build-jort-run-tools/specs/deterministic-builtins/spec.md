## ADDED Requirements

### Requirement: Jort provides bounded deterministic insertion commands
Jort SHALL provide local `/date`, `/time`, `/uuid`, and `/calc` commands whose result depends only on explicit arguments and injected deterministic clock or UUID sources and SHALL perform no network, script, plugin, or external-process operation.

#### Scenario: Date or time runs
- **WHEN** `/date` or `/time` executes with valid optional formatting arguments
- **THEN** Jort produces one result from the execution's captured clock value
- **AND** uses a documented locale-independent default format

#### Scenario: UUID runs
- **WHEN** `/uuid` executes
- **THEN** Jort produces one lowercase hyphenated UUID from the injected generator

#### Scenario: Calculator runs
- **WHEN** `/calc` receives a valid bounded expression using decimal numbers, parentheses, unary signs, and supported arithmetic operators
- **THEN** Jort returns its deterministic finite result
- **AND** does not evaluate source code or access ambient authority

#### Scenario: Calculator input is invalid
- **WHEN** `/calc` receives invalid syntax, division by zero, overflow, or a nonfinite result
- **THEN** Jort presents a non-destructive inline error
- **AND** makes no document mutation or history boundary

### Requirement: Selection transforms require visible previewable scope
Jort SHALL require an explicit nonempty selection for `/sort` and `/dedupe`, SHALL visibly identify the exact proposed input range, and SHALL show the complete proposed replacement before commit.

#### Scenario: Sort selected lines
- **WHEN** `/sort` runs against a confirmed selection of logical lines
- **THEN** Jort previews those lines in stable literal sorted order
- **AND** changes no text until the user confirms

#### Scenario: Dedupe selected lines
- **WHEN** `/dedupe` runs against a confirmed selection of logical lines
- **THEN** Jort previews a replacement retaining the first exact occurrence of each line
- **AND** preserves the selected range's trailing-newline convention

#### Scenario: Selection is missing or stale
- **WHEN** a transform has no nonempty selection or the selected input hash changes before commit
- **THEN** Jort refuses the mutation and asks the user to select or preview again
- **AND** does not infer whole-document scope

### Requirement: Built-in results commit atomically as ordinary text
Jort SHALL insert a successful insertion-command result immediately after the invocation line or replace a confirmed transform selection as one document transaction including line metadata, provenance, undo, persistence, and a semantic history boundary.

#### Scenario: Insertion command succeeds
- **WHEN** a built-in returns a valid bounded result and its invocation anchor still resolves
- **THEN** Jort inserts the complete result immediately after the invocation line in one transaction
- **AND** does not stream or partially publish output

#### Scenario: Transform is confirmed
- **WHEN** the user confirms a valid preview and the input range still matches
- **THEN** Jort replaces exactly that range as one undoable transaction
- **AND** preserves unrelated text, selection anchors, and viewport position

#### Scenario: User undoes execution
- **WHEN** the user invokes Undo after a successful built-in
- **THEN** inserted or replaced text, line metadata, and provenance return to their exact pre-run state in one operation

### Requirement: Output and provenance are bounded
Jort SHALL reject command output above configured byte or line limits before mutation and SHALL retain only bounded removable provenance metadata for completed output.

#### Scenario: Output exceeds a limit
- **WHEN** a command result exceeds its configured byte or line cap
- **THEN** Jort reports an inline error and inserts no partial output

#### Scenario: User merges completed output
- **WHEN** the user activates Merge for completed command output
- **THEN** Jort removes the provenance association and decoration
- **AND** leaves the result as ordinary canonical text
