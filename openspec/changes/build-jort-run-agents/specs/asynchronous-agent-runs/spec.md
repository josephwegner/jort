## ADDED Requirements

### Requirement: Providers initialize lazily behind a bounded interface
Jort SHALL initialize a model provider only after explicit Run, SHALL identify whether it uses the network before consent, and SHALL pass only the immutable request authorized by the context manifest.

#### Scenario: Jort launches without an agent run
- **WHEN** the app starts and the user only edits, searches, browses history, or runs deterministic commands
- **THEN** no provider initializes and no provider network request occurs

#### Scenario: Configured network provider runs
- **WHEN** the user runs an agent after reviewing its network provider identity
- **THEN** Jort sends only the manifest-authorized content through the configured endpoint
- **AND** obtains credentials from Keychain without exposing them in logs or run records

#### Scenario: Provider response exceeds limits
- **WHEN** a provider exceeds timeout or response-byte limits
- **THEN** Jort terminates or ignores the request, records a bounded typed failure, and makes no text mutation

### Requirement: The document remains editable during an asynchronous run
Jort SHALL execute providers outside the main-actor typing path, SHALL show bounded progress and Cancel, and SHALL preserve editor selection and viewport during run-state updates.

#### Scenario: User edits during a run
- **WHEN** an agent is running and the user types, navigates, searches, or edits elsewhere
- **THEN** those operations remain available within existing performance budgets
- **AND** the running overlay does not move the selection or viewport

#### Scenario: User cancels
- **WHEN** the user activates Cancel before the run reaches a terminal state
- **THEN** Jort requests provider cancellation and transitions the run exactly once to cancelled
- **AND** any later provider completion cannot insert text

### Requirement: Completion inserts only at a validated safe anchor
Jort SHALL resolve the invocation by stable `LineID` and validate invocation text and insertion-boundary hashes before automatically inserting a complete result.

#### Scenario: Unrelated text changed elsewhere
- **WHEN** the invocation line and insertion boundary still validate but edits elsewhere advanced the document generation
- **THEN** Jort rebases the insertion anchor by `LineID` and inserts the complete output immediately after the invocation line

#### Scenario: Invocation moved because lines above changed
- **WHEN** edits above move an otherwise unchanged invocation line
- **THEN** Jort resolves its new ordinal by `LineID` and safely inserts at its current boundary

#### Scenario: Invocation or boundary changed materially
- **WHEN** the invocation text, identity, or insertion boundary no longer validates
- **THEN** Jort does not automatically mutate the document
- **AND** presents conflict actions to insert at an unambiguous current boundary, copy output, or discard it

### Requirement: Successful output commits atomically with provenance
Jort SHALL insert only a complete bounded agent response as ordinary text in one transaction with line metadata, provenance, undo, persistence, and a semantic history boundary and SHALL NOT stream partial tokens into canonical text.

#### Scenario: Run completes safely
- **WHEN** the provider returns a valid complete response and the target validates
- **THEN** Jort inserts it immediately after the invocation line as one undoable transaction
- **AND** records bounded provenance linking the inserted range to the run

#### Scenario: User merges output
- **WHEN** the user activates Merge on completed output
- **THEN** Jort removes provenance and decoration while leaving ordinary result text unchanged

#### Scenario: User undoes insertion
- **WHEN** the user invokes Undo after agent output is inserted
- **THEN** output text, line metadata, provenance, and selection return to their exact prior state in one operation

### Requirement: Run terminal states persist without automatic retry
Jort SHALL persist running, succeeded, failed, timed-out, cancelled, interrupted, and conflicted operational states with bounded diagnostics and SHALL never automatically retry a terminal or interrupted run.

#### Scenario: App relaunches during a run
- **WHEN** Jort starts and finds a run persisted as running
- **THEN** it marks that run interrupted and inserts no output
- **AND** any Retry action creates a new run from newly previewed current context

#### Scenario: Failed run offers Retry
- **WHEN** a failed, timed-out, cancelled, or interrupted run supports manual Retry
- **THEN** Jort requires the user to review current context and execute a new run
- **AND** does not reuse stale consent or mutation hashes

### Requirement: Agent failures remain isolated and accessible
Jort SHALL keep editing, landmarks, search, history, and deterministic commands available when provider setup, network, decoding, timeout, cancellation, or commit validation fails, and SHALL expose run states and actions accessibly.

#### Scenario: Provider is unavailable
- **WHEN** the selected provider lacks configuration, credentials, network availability, or supported capability
- **THEN** Jort reports a concise inline failure and performs no text mutation
- **AND** all local editor features remain available

#### Scenario: VoiceOver follows a run
- **WHEN** a VoiceOver user starts, monitors, cancels, resolves conflict, merges, or retries a run
- **THEN** Jort announces agent/provider identity, state transitions, and available actions without repeatedly announcing progress noise
