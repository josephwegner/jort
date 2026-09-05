## ADDED Requirements

### Requirement: Registered slash commands are recognized in place
Jort SHALL recognize an exact registered `/command` token at its actual logical-line and character position after committed text input and SHALL leave unmatched or abandoned slash text as ordinary canonical text.

#### Scenario: Registered command is typed
- **WHEN** a slash token at line start or after whitespace exactly matches a registered command name
- **THEN** Jort records pending state anchored by `LineID` and line-relative range
- **AND** decorates that actual invocation line without inserting decoration content into text

#### Scenario: Slash text is unmatched
- **WHEN** typed slash text does not exactly match a registered name
- **THEN** Jort treats all characters as ordinary text and creates no invocation metadata

#### Scenario: IME composition contains slash text
- **WHEN** slash text exists only in provisional marked text
- **THEN** Jort does not recognize or execute it until composition commits

### Requirement: Completion inserts text but never implicitly executes
Jort SHALL offer registered command completion after slash input and SHALL treat completion selection as ordinary undoable text insertion rather than execution.

#### Scenario: Completion is selected
- **WHEN** the user selects a command from filtered completion
- **THEN** Jort inserts or completes its slash name in canonical text
- **AND** does not run the command

#### Scenario: Completion is dismissed
- **WHEN** the user presses Escape while completion is open
- **THEN** completion closes and focus remains in the editor
- **AND** already typed text remains unchanged

### Requirement: Execution is explicit
Jort SHALL execute a pending command only from its Run action or Shift-Return and SHALL preserve Return as native newline insertion.

#### Scenario: User presses Return
- **WHEN** a pending command is decorated and the user presses Return
- **THEN** the native editor inserts a newline
- **AND** Jort does not execute the command

#### Scenario: User runs the command
- **WHEN** the user activates Run or presses Shift-Return
- **THEN** both inputs dispatch one identical command execution path
- **AND** one activation cannot execute the command twice

#### Scenario: User abandons pending state
- **WHEN** the user presses Escape with no completion open or edits the token so it no longer matches
- **THEN** Jort removes pending decoration and metadata
- **AND** leaves invocation text as ordinary text

### Requirement: Invocation controls are accessible and layout stable
Jort SHALL expose pending command identity, scope, Run, preview, and error state through keyboard and accessibility APIs without changing canonical text or shifting unrelated editor layout.

#### Scenario: VoiceOver inspects a pending command
- **WHEN** VoiceOver reaches a pending invocation line
- **THEN** Jort announces command name, input scope, and Run action
- **AND** the underlying document value remains ordinary text only

#### Scenario: Invocation line wraps or scrolls
- **WHEN** a pending invocation wraps, moves in the viewport, or scrolls offscreen
- **THEN** its decoration remains anchored to its current logical line or is recycled when offscreen
- **AND** no whole-document layout is forced
