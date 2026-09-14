## ADDED Requirements

### Requirement: History work consumes bounded immutable revision roots
Jort SHALL capture an immutable document root for an exact history boundary with constant-time structural sharing, SHALL perform flattening, complete validation, encode, decode, comparison, pruning, and restore preparation outside the synchronous input path, and SHALL release each live root when its owned work completes or is superseded.

#### Scenario: History retain is slow while editing continues
- **WHEN** encoding or retaining a history revision remains in progress after newer native edits are accepted
- **THEN** the history job continues against only its captured immutable revision while newer coordinator roots remain editable
- **AND** completion does not replace, mark durable, or retain the newer state accidentally

#### Scenario: Obsolete history work is coalesced
- **WHEN** ordinary retention boundaries are superseded according to the existing history cadence
- **THEN** Jort cancels or drops the obsolete job and releases its root when no bounded consumer remains
- **AND** milestone and explicit restore boundaries retain their existing non-coalescing guarantees

#### Scenario: History restore is prepared
- **WHEN** a selected encoded revision is decoded and completely validated in background work
- **THEN** the authoritative coordinator applies it through one stale-revision-checked restore transaction
- **AND** input accepted during preparation prevents stale restoration without being blocked or overwritten
