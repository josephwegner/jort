# Automation Runtime Specification

## ADDED Requirements

### Requirement: Small provider contract
Jort SHALL expose local and cloud model providers through a lowest-common-denominator contract accepting messages and returning complete messages or simple bounded tool requests.

#### Scenario: Lazy provider initialization
- **WHEN** the user launches and types without invoking an agent
- **THEN** no model registry, provider SDK, process, token refresh, account lookup, or network probe initializes

#### Scenario: Provider identity
- **WHEN** a pending agent invocation is decorated
- **THEN** Jort shows whether the selected provider is local or networked before Run

#### Scenario: Provider unavailable
- **WHEN** the selected provider is unavailable
- **THEN** the invocation remains ordinary recoverable text
- **AND** the editor remains fully usable

### Requirement: Local and compatible cloud providers
Jort SHALL support an Apple on-device provider when available and at least one OpenAI-compatible URLSession provider, while allowing advanced compatible endpoints without making them part of first-run setup.

#### Scenario: Offline use
- **WHEN** Wi-Fi and all provider credentials are unavailable
- **THEN** the editor, landmarks, local persistence, history, and local commands remain functional

### Requirement: JavaScriptCore sandbox
Jort SHALL execute local deterministic scripts in JavaScriptCore using a narrow bridged API and SHALL NOT expose Node compatibility or ambient process, filesystem, package-loading, shell, or network authority.

#### Scenario: Script input
- **WHEN** a script is invoked
- **THEN** it receives only declared invocation text, selected text, and explicitly granted Jort tool handles

#### Scenario: Script output
- **WHEN** a script succeeds
- **THEN** it may return text, add or change a landmark through a narrow tool, or request another declared Jort tool
- **AND** its text result commits as one atomic document transaction

### Requirement: Built-in and registered commands
Jort SHALL provide deterministic local built-ins and SHALL keep registered external executables separate from JavaScriptCore.

#### Scenario: Built-in command
- **WHEN** the user invokes a built-in such as `/date`, `/time`, `/uuid`, `/calc`, `/sort`, or `/dedupe`
- **THEN** it runs locally without network access

#### Scenario: Registered external command
- **WHEN** the user invokes an external command
- **THEN** Jort runs only the registered exact executable with structured arguments, declared input, timeout, output cap, and output disposition
- **AND** never interprets arbitrary document text as a shell command

#### Scenario: External command failure
- **WHEN** an external command exits unsuccessfully, times out, or exceeds its cap
- **THEN** Jort displays a quiet inline error
- **AND** does not degrade typing or corrupt document text

### Requirement: Run and insertion lifecycle
Jort SHALL maintain operational run records outside canonical text until output is committed and SHALL not create an assistant conversation.

#### Scenario: In-progress run
- **WHEN** a run is executing
- **THEN** Jort may show a fixed-height transient progress attachment with Cancel
- **AND** does not stream output into the document

#### Scenario: Completed insertion
- **WHEN** output commits
- **THEN** it becomes ordinary text plus provenance metadata
- **AND** Merge removes only decoration and metadata
- **AND** Delete removes text only through an explicit user action
- **AND** Retry starts a new run rather than extending a thread

### Requirement: Tool requests are bounded
Jort SHALL allow an agent to request only declared Jort tools and simple decisions during a run.

#### Scenario: Sensitive capability escalation
- **WHEN** a tool requests network access, broad document context, history, mutation outside its hashed target, or another high-sensitivity capability
- **THEN** Jort displays the requesting agent/tool, exact scope, and required fresh consent before execution

#### Scenario: External command requested by agent
- **WHEN** an agent requests a registered external command in V1
- **THEN** Jort rejects the request unless a later product decision explicitly enables a per-run confirmation policy

