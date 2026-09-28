## ADDED Requirements

### Requirement: One stable dispatcher owns normal validation
Jort SHALL expose normal formatting, project generation, analysis, build, Foundation, native, UI, sanitizer, packaging, and focused XCTest execution through one repository-owned validation dispatcher with enumerated arguments and no arbitrary command passthrough.

#### Scenario: Agent runs a focused Foundation test
- **WHEN** an agent supplies a valid Foundation XCTest identifier and supported build configuration
- **THEN** the dispatcher constructs and runs the canonical Xcode command with repository-owned environment and DerivedData settings
- **AND** the agent does not need to construct or approve a new `xcodebuild` shape

#### Scenario: Existing CI lane runs
- **WHEN** CI invokes an existing validation lane such as `fast`, `test`, `ui`, `analysis`, or `package`
- **THEN** the lane retains its documented checks and failure behavior
- **AND** uses the same logging and output contract as local focused validation

### Requirement: Validation execution is fresh and output is bounded
Jort SHALL execute every requested validation against the current workspace, SHALL NOT use a prior passing result to skip it, and SHALL keep complete command output on disk while emitting only a concise status or bounded failure excerpt to the caller.

#### Scenario: Identical test is requested twice
- **WHEN** the same test command is requested twice without intervening edits
- **THEN** the dispatcher executes it twice
- **AND** creates distinct run artifacts for both invocations

#### Scenario: Validation succeeds
- **WHEN** a check exits successfully
- **THEN** the dispatcher prints one concise status row with duration and log path
- **AND** writes its complete output and structured summary beneath the validation build directory

#### Scenario: Validation fails with a large log
- **WHEN** Xcode or another check produces a large failing log
- **THEN** the dispatcher prints only bounded relevant diagnostics and the complete artifact path
- **AND** never copies the entire log into normal caller output

### Requirement: Changed-file planning is deterministic and conservative
Jort SHALL map changed repository paths to a visible set of relevant validation checks and SHALL conservatively choose broader correctness checks for unknown production or test paths.

#### Scenario: Persistence source changes
- **WHEN** the selected diff contains persistence source or persistence tests
- **THEN** the plan includes formatting/project checks and focused Foundation persistence/recovery coverage
- **AND** prints that selection before execution

#### Scenario: Unknown source changes
- **WHEN** a changed production or test path has no narrower mapping
- **THEN** the plan includes the main correctness test lane
- **AND** does not silently classify the change as documentation-only

### Requirement: Xcode-backed checks do not contend
Jort SHALL serialize repository validation processes that invoke Xcode or macOS UI test runners through one bounded lock and SHALL report lock acquisition or timeout without starting a competing runner.

#### Scenario: Native validation is already active
- **WHEN** another dispatcher requests an Xcode-backed check
- **THEN** it waits for the repository validation lock up to the documented bound
- **AND** either proceeds as the sole owner or exits with a concise lock-timeout diagnostic

### Requirement: Repository guidance routes work by complexity
Jort SHALL provide concise root instructions, a detailed development skill, and narrow custom-agent roles that send deterministic work to scripts, bounded search/log triage to economical read-only agents, routine implementation to a balanced coding agent, and difficult cross-cutting reasoning to the most capable configured agent.

#### Scenario: Test output needs inspection
- **WHEN** a validation failure has already produced a bounded excerpt and stored log
- **THEN** deterministic extraction or a read-only low-cost triage agent examines only the relevant artifact
- **AND** the main coordinator does not ingest the complete build log

#### Scenario: Change requires difficult architectural reasoning
- **WHEN** a task spans concurrency, persistence invariants, complex AppKit behavior, or another explicitly difficult boundary
- **THEN** repository guidance permits delegation to the configured high-capability specialist with a bounded task
- **AND** routine searching and validation remain outside that specialist's context

### Requirement: Standard validation has a reusable approval surface
Jort SHALL define project-local execution rules for the enumerated validation dispatcher and SHALL keep those rules narrow enough that they cannot authorize arbitrary shell execution through dispatcher arguments.

#### Scenario: Trusted project runs standard validation
- **WHEN** Codex invokes an allowed dispatcher command matching the checked rule
- **THEN** standard validation can run without a new command-shape approval
- **AND** unrelated commands, shell passthrough, and destructive operations do not match the rule
