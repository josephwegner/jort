## ADDED Requirements

### Requirement: Persistence preparation stays outside the synchronous input path
Jort SHALL accept immutable revision roots through lightweight ordered bookkeeping, SHALL perform complete validation, flattening, encoding, recovery-checkpoint construction, and store IO in owned background work, and SHALL preserve all committed-revision, retry, recovery, ownership, and purge-boundary rules.

#### Scenario: New revision arrives during encoding
- **WHEN** persistence is flattening or encoding one immutable revision and the user accepts a newer edit
- **THEN** the newer edit becomes authoritative in memory without waiting for the older encoding
- **AND** older completion cannot mark the newer revision clean or replace its root

#### Scenario: Obsolete save preparation is coalesced
- **WHEN** a not-yet-durable ordinary snapshot is superseded before irreversible store publication begins
- **THEN** persistence may abandon its preparation, release its root, and prepare the newest permitted revision
- **AND** explicit flush, recovery, history, and purge acknowledgements still resolve against the exact requested boundary

#### Scenario: Purge boundary is active
- **WHEN** Clear History and Recovery Data captures authoritative root `P` and barriers the old store
- **THEN** replacement-store preparation completely validates and flattens `P` in background work while later edits remain accepted as descendant roots in memory
- **AND** no optimization submits either `P` or later roots to the old store after the barrier

#### Scenario: Boundary validation fails
- **WHEN** complete validation detects inconsistent indexed state before encode or recovery publication
- **THEN** persistence writes no candidate from that state and reports a typed integrity failure
- **AND** the in-memory coordinator and last verified durable state remain available for recovery handling
