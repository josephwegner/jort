## ADDED Requirements

### Requirement: Every tool uses one declarative JavaScript package format
Jort SHALL define each tool as a package containing a schema-valid `tool.json` manifest and one `tool.js` implementation and SHALL use that format for bundled and user-installed tools without a privileged native execution path.

#### Scenario: A package manifest is loaded
- **WHEN** Jort discovers a candidate tool package
- **THEN** it validates the manifest's stable reverse-DNS-style ID, positive integer version, display name, slash command, description, script-entry contract version, input mode, output operation, and byte and line caps
- **AND** does not evaluate `tool.js` merely to discover or display the package

#### Scenario: A valid package is enabled
- **WHEN** `tool.json` and `tool.js` satisfy the supported package contract
- **THEN** Jort registers its command, metadata, validation, and asynchronous entry point through the shared registry
- **AND** makes no distinction between bundled and installed execution privileges

#### Scenario: A package is malformed or conflicting
- **WHEN** a manifest, script, stable ID, or slash command is invalid or conflicts with another package at the same precedence
- **THEN** Jort disables only the affected package and reports a bounded diagnostic
- **AND** continues discovering and running unrelated valid packages

### Requirement: The registry supports bundled definitions and user overrides
Jort SHALL expose non-UI operations to inspect, validate, install, enable, disable, update, remove, and restore tool packages and SHALL resolve a valid enabled user override before its immutable bundled definition.

#### Scenario: Bundled tool is edited
- **WHEN** a consumer saves an edit to a bundled tool
- **THEN** Jort creates or updates a user override rather than modifying the shipped definition
- **AND** preserves the bundled package as a restorable fallback

#### Scenario: Application updates bundled tools
- **WHEN** an application update contains a newer bundled package and a user override exists
- **THEN** Jort retains and resolves the user override
- **AND** does not overwrite user-authored manifest or script content

#### Scenario: User restores a bundled tool
- **WHEN** a registry consumer removes or explicitly restores a bundled tool's override
- **THEN** Jort resolves the current immutable bundled definition
- **AND** exposes its validation state through the same registry

#### Scenario: Settings consumes the registry
- **WHEN** another feature needs to list or manage tools
- **THEN** the registry exposes package identity, origin, override, enabled, validation, and diagnostic state
- **AND** this capability does not prescribe or create a Settings-panel UI

#### Scenario: A user saves a new tool in the existing Settings panel
- **WHEN** a valid new tool is saved
- **THEN** Jort saves without a leave-editor warning and exposes the enabled package in open editors' command completion
- **AND** new tools default to enabled, while the draft's enable toggle controls that draft
- **AND** unsaved-change warnings remain applicable when actually leaving an edited tool
- **AND** the Enabled checkbox remains visible beside the Tools heading for both saved tools and new drafts
- **AND** the source editor and its ruler clip their drawing within the source editor area

### Requirement: Tool scripts run without ambient authority
Jort SHALL evaluate `tool.js` inside a bounded JavaScript host that exposes only a deeply frozen invocation object, explicit deterministic host facilities, result construction, and cancellation observation.

#### Scenario: Script begins execution
- **WHEN** a registered tool is submitted
- **THEN** its asynchronous entry point receives exactly one canonical or ephemeral `content` string plus explicitly injected captured clock, UUID, and cancellation facilities supported by the entry contract
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
Jort SHALL ship `/date`, `/time`, `/uuid`, `/calc`, `/sort`, and `/dedupe` as valid packages discovered, registered, sandboxed, and executed through the same path as user-installed tools.

#### Scenario: Date or time package runs
- **WHEN** `/date` or `/time` receives valid content
- **THEN** its script produces one result from the execution's injected captured clock
- **AND** uses a documented locale-independent default format
- **AND** appends the exact input content after the generated date or time, preserving whitespace and newlines

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
- **WHEN** the six bundled manifests are loaded
- **THEN** `/date`, `/time`, `/uuid`, and `/calc` declare contained input with default `replace-invocation`
- **AND** `/sort` and `/dedupe` declare contextual input with default `replace-context`

### Requirement: Contextual deterministic packages transform exact content
Jort SHALL pass `/sort` and `/dedupe` the exact contextual `content` string and SHALL let their packages return a complete bounded replacement without direct document access.

#### Scenario: Sort context runs
- **WHEN** `/sort` receives contextual content containing logical lines
- **THEN** its script returns those lines in stable literal sorted order
- **AND** preserves content outside the captured context

#### Scenario: Dedupe context runs
- **WHEN** `/dedupe` receives contextual content containing duplicate logical lines
- **THEN** its script retains the first exact occurrence of each line
- **AND** preserves the input's trailing-newline convention

#### Scenario: Context is missing
- **WHEN** a contextual command has empty or invalid scope under its package validation
- **THEN** Jort presents an editable validation warning
- **AND** does not infer whole-document scope or execute the script

### Requirement: Successful output publishes canonically before Merge
Jort SHALL validate one complete bounded script result and insert it immediately after the owned invocation as canonical text in one atomic pending-output transaction before applying the declared output operation.

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

### Requirement: Merge applies the captured output operation atomically
Jort SHALL apply the input mode's default or manifest-declared output operation only after explicit Merge and SHALL retain ordinary Undo and Dismiss behavior around that transaction.

#### Scenario: Replace invocation is merged
- **WHEN** a contained result using `replace-invocation` is merged
- **THEN** Jort deletes the slash command and contained input so the canonical output moves to the invocation's original start
- **AND** removes lifecycle provenance and decoration in the same transaction

#### Scenario: Replace context is merged
- **WHEN** a contextual result using `replace-context` is merged
- **THEN** Jort deletes the exact contextual scope plus its excluded invocation and places output at the scope beginning
- **AND** preserves every unrelated character and anchor

#### Scenario: Insert at invocation is merged
- **WHEN** a result using `insert-at-invocation` is merged
- **THEN** Jort removes the invocation and retains its context plus output in the captured declared order
- **AND** removes lifecycle provenance and decoration

#### Scenario: Empty replacement is merged
- **WHEN** the user merges an empty result
- **THEN** Jort applies the captured output operation even when it deletes source without inserting characters
- **AND** registers the complete mutation as one undoable transaction

#### Scenario: Pending result is dismissed
- **WHEN** the user activates Dismiss before Merge
- **THEN** Jort deletes canonical output and restores the exact pre-submit editable invocation, source, anchors, viewport, and metadata
- **AND** performs no merge operation

#### Scenario: User undoes output publication
- **WHEN** output publication is the latest undoable document transaction and the user invokes Undo
- **THEN** Jort removes pending output and restores inputting state as Dismiss would

#### Scenario: User undoes Merge
- **WHEN** Merge is the latest undoable document transaction and the user invokes Undo
- **THEN** Jort restores the prior locked source, canonical output, provenance, and pending decoration in one operation

### Requirement: Package identity and provenance are bounded and migratable
Jort SHALL persist only bounded lifecycle metadata containing package identity and version, script-entry contract, captured input and output modes, invocation and output anchors, input hash, state, timestamp, and merge status.

#### Scenario: Package version changes before relaunch
- **WHEN** persisted invocation state names an older package version
- **THEN** Jort attempts only the package's bounded declared mapping to the current contract
- **AND** does not re-execute already published output

#### Scenario: Inputting invocation cannot migrate
- **WHEN** package mapping cannot preserve an inputting invocation
- **THEN** contained mode retains `/tool` and input, contextual mode retains `/tool` and source, and ephemeral mode retains `/tool` as ordinary text

#### Scenario: Completed invocation cannot migrate
- **WHEN** package mapping cannot preserve pending canonical output
- **THEN** Jort removes `/tool` and contained input where applicable and retains canonical output
- **AND** removes `/tool` and contained input without replacement when completed output is empty
