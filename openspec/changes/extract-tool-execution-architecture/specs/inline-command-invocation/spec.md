## ADDED Requirements

### Requirement: Invocation lifecycle authority is outside AppKit
Jort SHALL make a headless invocation reducer and coordinator authoritative for lifecycle transitions and asynchronous generation ownership, while AppKit SHALL be limited to native event translation and presentation of committed state.

#### Scenario: Invocation execution begins
- **WHEN** AppKit forwards an explicit Submit action with current native selection and focus facts
- **THEN** the headless lifecycle determines validation, locking, execution, cancellation, and presentation effects for one generation
- **AND** no AppKit controller independently assigns a lifecycle phase or owns the executor task

#### Scenario: Invocation state is restored
- **WHEN** sanitized persisted invocation metadata is loaded or recovered
- **THEN** the headless coordinator reconciles it with the current package contract and absence of prior-process jobs
- **AND** AppKit renders the resulting actionable state without re-executing previously published output

#### Scenario: Native integration reports stale document facts
- **WHEN** document anchors, hashes, package identity, or generation no longer match an outstanding lifecycle effect
- **THEN** the headless lifecycle rejects or reconciles the stale action deterministically
- **AND** AppKit cannot force publication or Merge by mutating its presentation state
