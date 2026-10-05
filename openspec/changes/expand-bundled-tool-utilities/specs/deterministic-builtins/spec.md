## MODIFIED Requirements

### Requirement: Every tool uses one declarative JavaScript package format
Jort SHALL define each tool as a package containing a schema-valid `tool.json` manifest and exactly one declared executor: JavaScript using `tool.js`, or model using bounded `instructions.txt` and a bundled model identifier. Jort SHALL use the same registry and invocation lifecycle for both executors, and SHALL decode legacy definitions without an executor as JavaScript. Schema 3 / entry contract 2 SHALL add bounded argument declarations, captured-data requests, and declared host-action kinds while retaining schema 1/2 / entry contract 1 execution. Bundled and custom packages SHALL use the same validation and action policy.

#### Scenario: A package manifest is loaded
- **WHEN** Jort discovers a candidate tool package
- **THEN** it validates the manifest's stable reverse-DNS-style ID, positive integer version, display name, slash command, description, executor and entry contract version, input mode, output operation, and byte and line caps
- **AND** does not evaluate `tool.js` merely to discover or display the package

#### Scenario: A valid package is enabled
- **WHEN** the manifest and executor-specific implementation satisfy the supported package contract
- **THEN** Jort registers its command, metadata, validation, and asynchronous entry point through the shared registry
- **AND** makes no distinction between bundled and installed execution privileges

#### Scenario: A package is malformed or conflicting
- **WHEN** a manifest, implementation, stable ID, or slash command is invalid or conflicts with another package at the same precedence
- **THEN** Jort disables only the affected package and reports a bounded diagnostic
- **AND** continues discovering and running unrelated valid packages

### Requirement: Tool scripts run without ambient authority
Jort SHALL evaluate `tool.js` inside a bounded JavaScript host that exposes only a deeply frozen invocation object, explicit captured host data, result construction, and cancellation observation. Contract 2 scripts SHALL be able to return inert typed action requests for independent app-side validation and execution, without receiving an I/O bridge.

#### Scenario: Script begins execution
- **WHEN** a registered tool is submitted
- **THEN** its asynchronous entry point receives exactly one canonical or ephemeral `content` string plus explicitly injected captured clock, UUID, and cancellation facilities supported by the entry contract; contract 2 additionally receives separate validated arguments and bounded declared local calendar, entropy, and pure text-analysis data
- **AND** receives no mutable document or application object

#### Scenario: Script validates input before execution
- **WHEN** a package exports the optional asynchronous `validate` entry point
- **THEN** Jort invokes it with the same captured frozen input used by the main entry point before locking source or executing the tool
- **AND** a structured validation failure remains presentation-only and creates no document mutation or history boundary

#### Scenario: Script requests ambient authority
- **WHEN** script code attempts network, filesystem, process, shell, application-state, native-bridge, plugin, dynamic-import, external-executable, package-discovery, or dynamic-evaluation access
- **THEN** the host denies that access
- **AND** manifest declarations alone cannot grant it

#### Scenario: Script exceeds a resource bound
- **WHEN** script execution exceeds its wall-clock timeout, memory limit, cancellation boundary, or result cap
- **THEN** Jort terminates or invalidates its generation and returns one structured invocation-local failure
- **AND** publishes no partial canonical output

#### Scenario: Cancellation races with completion
- **WHEN** cancellation, timeout, and script completion race for one submission generation
- **THEN** exactly one terminal transition wins
- **AND** Jort ignores every late or duplicate result

### Requirement: Bundled deterministic commands are ordinary tool packages
Jort SHALL ship the deterministic commands defined by bundled-note-utilities as ordinary editable packages, discovered and executed through the same path as user-installed tools. Jort SHALL retain `/date`, `/uuid`, `/calc`, `/sort`, and `/dedupe` as compatibility packages, preserving upgrade enablement and user overrides while disabling these five by default on fresh installations.

#### Scenario: Date compatibility package runs
- **WHEN** `/date` receives valid content
- **THEN** its script produces one result from the injected captured clock using its legacy format
- **AND** appends the exact input content, preserving whitespace and newlines

#### Scenario: Current timestamp package runs
- **WHEN** `/now`, `/today`, or the new bundled `/time` executes with no arguments
- **THEN** its script formats captured local calendar values using an easily edited JavaScript format constant
- **AND** outputs only the timestamp, with defaults `Sept 12, 10:28am`, `Sat, Sept 12`, and `10:28am` respectively for the matching local instant

#### Scenario: UUID package runs
- **WHEN** `/uuid` executes
- **THEN** its script produces one lowercase hyphenated UUID from the injected generator
- **AND** appends the exact input content after that UUID

#### Scenario: Calculator package runs
- **WHEN** `/calc` receives a valid bounded expression containing decimal numbers, parentheses, unary signs, and supported arithmetic operators
- **THEN** its script returns a deterministic finite result from a purpose-built parser
- **AND** does not use `eval`, `Function`, dynamic import, or another dynamic-evaluation facility

#### Scenario: Calculator content is invalid
- **WHEN** `/calc` receives invalid syntax, division by zero, overflow, or a nonfinite result
- **THEN** it returns a structured validation or execution failure according to when the condition is detected
- **AND** makes no canonical output mutation

#### Scenario: Bundled package declarations are inspected
- **WHEN** legacy and new bundled manifests are loaded
- **THEN** compatibility `/date`, `/uuid`, `/calc` and new timestamp generators declare contained input with default `replace-invocation`
- **AND** `/sort` and `/dedupe` declare contextual input with default `replace-context`

### Requirement: Successful output publishes canonically before Merge
For a text result, Jort SHALL validate one complete bounded script result and insert it immediately after the owned invocation as canonical text in one atomic pending-output transaction before applying the declared output operation.

#### Scenario: Tool returns output
- **WHEN** a script returns valid output and its captured package contract, invocation anchor, and input hash still validate
- **THEN** Jort atomically inserts the complete output with line metadata, pending provenance, undo registration, persistence, and a semantic history boundary
- **AND** does not stream or partially publish the result

#### Scenario: Tool returns empty output
- **WHEN** a script succeeds with an empty output string
- **THEN** Jort enters pending merge without inserting canonical result characters
- **AND** presents a noncanonical empty-result indication with Merge and Dismiss available

#### Scenario: Output exceeds a manifest limit
- **WHEN** output exceeds its package's byte or line cap
- **THEN** Jort reports an invocation-local execution failure
- **AND** inserts no partial output

#### Scenario: Metadata is lost after publication
- **WHEN** canonical output remains but its pending provenance is missing or corrupt
- **THEN** Jort preserves all canonical source and output characters as ordinary text
- **AND** removes invalid lifecycle decoration and locks

#### Scenario: Report or host-action result completes
- **WHEN** contract 2 returns a validated report or an acknowledged host-action completion
- **THEN** Jort uses the presentation-only completion path specified by tool-host-actions
- **AND** inserts no canonical status string or empty pending replacement
