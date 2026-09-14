## ADDED Requirements

### Requirement: Worker outcomes remain generation-local lifecycle actions
Jort SHALL map each broker/worker result, validation failure, busy/unavailable state, crash, hang, resource limit, cancellation, malformed protocol, and correlation failure into a bounded action for the exact invocation generation, and only the existing reducer plus document-owned patch path SHALL authorize canonical mutation.

#### Scenario: Worker returns successful output
- **WHEN** a complete bounded correlated result arrives for the current nonterminal generation
- **THEN** the reducer accepts that generation's success and may request the ordinary atomic pending-output publication patch
- **AND** broker/worker code never writes document text or invocation metadata directly

#### Scenario: Worker fails before publication
- **WHEN** validation, launch, sandbox bootstrap, timeout, CPU/memory limit, crash, cancellation, protocol, or output-bound failure occurs
- **THEN** the reducer enters the applicable invocation-local actionable state with no partial output publication
- **AND** unrelated editing and invocations remain available

#### Scenario: Terminal races occur
- **WHEN** success, cancel, watchdog, XPC interruption, child exit, or duplicate/late reply race for one generation
- **THEN** the first legal terminal reducer action wins and every later or mismatched action is ignored
- **AND** no losing event emits a document patch, focus change, or second announcement

#### Scenario: App relaunches after a worker was active
- **WHEN** persisted submitted/processing JavaScript metadata is restored in a new app process
- **THEN** Jort applies the existing interrupted-execution recovery behavior without reconnecting to or restarting that generation
- **AND** no worker state is considered durable invocation state
