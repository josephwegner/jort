## ADDED Requirements

### Requirement: Localized transactions perform bounded indexed work
Jort SHALL apply an ordinary localized document transaction through one authoritative coordinator using an indexed persistent representation, SHALL make UTF-16 and stable-line-identity lookup logarithmic in index height, and SHALL touch only the affected records, bounded newline-neighbor context, and changed index paths rather than traversing or shifting every trailing line.

#### Scenario: Character is inserted near the start of a large document
- **WHEN** one character is inserted into one logical line of a document with at least 25,000 trailing lines
- **THEN** the transaction rebuilds the affected line window plus at most the bounded context required to resolve a split newline sequence
- **AND** structural instrumentation proves that trailing line records and unchanged text chunks are shared rather than individually visited or offset-adjusted

#### Scenario: Edit crosses several local line boundaries
- **WHEN** a replacement joins or splits a bounded set of adjacent logical lines
- **THEN** Jort updates the intersecting records, required neighboring boundary records, aggregate counts, and logarithmic index paths
- **AND** does not make work proportional to unrelated prefix or suffix line count

#### Scenario: Whole-document content is replaced
- **WHEN** a paste, Service, restore, or explicit bulk operation replaces the complete document
- **THEN** Jort MAY perform work proportional to the replacement payload and resulting metadata
- **AND** publishes the result atomically as one coherent revision

### Requirement: Ordinary transactions use local proof and integrity boundaries use full proof
Jort SHALL validate range, aggregate, line-boundary, identity, timestamp, landmark, invocation, document-identity, and revision invariants affected by an ordinary transaction before publication, and SHALL perform complete validation at persistence decode, migration, pre-encode, recovery/restore, explicit integrity-check, randomized-reference-test, and asynchronous debug-verification boundaries.

#### Scenario: Local proof succeeds
- **WHEN** an ordinary replacement has a valid base revision and its affected records join valid unchanged neighbors
- **THEN** Jort proves all affected invariants and atomically advances the live revision without rescanning the complete document
- **AND** unchanged regions retain their existing immutable index nodes

#### Scenario: Local proof detects an invalid anchor or duplicate identity
- **WHEN** a prospective transaction would leave an affected landmark or invocation invalid or would introduce an existing line ID
- **THEN** Jort rejects the complete transaction before changing the coordinator root
- **AND** exposes a typed document failure rather than attempting repair after publication

#### Scenario: Snapshot reaches a persistence boundary
- **WHEN** a decoded, migrated, recovery, restore, or soon-to-be-encoded snapshot crosses its integrity boundary
- **THEN** Jort validates the complete text partition, identities, metadata, anchors, invocations, document identity, and revision
- **AND** performs that proof outside the synchronous ordinary-input callback

#### Scenario: Debug verification follows accepted edits
- **WHEN** a debug build accepts several revisions faster than complete verification can run
- **THEN** Jort coalesces verification over immutable snapshots and loudly reports an invariant failure for the newest verified root
- **AND** discards stale verification results without blocking input or publishing state

### Requirement: Immutable snapshots and undo share structure within explicit bounds
Jort SHALL represent snapshots and undo states as immutable `Sendable` roots that share unchanged text, line, and lookup storage, SHALL retain no mutable back-reference to the coordinator, and SHALL bound native undo by 200 complete groups and a 256 MiB retained-payload estimate while retaining the newest completed group.

#### Scenario: Repeated local edits create snapshots
- **WHEN** many localized transactions occur in a large otherwise unchanged document
- **THEN** successive snapshots share unchanged chunks and index subtrees
- **AND** allocation instrumentation attributes new storage only to replacements, affected records, and bounded index paths

#### Scenario: Undo bound is exceeded
- **WHEN** completed undo groups exceed 200 or their retained-payload estimate exceeds 256 MiB
- **THEN** Jort evicts the oldest whole groups until both bounds are satisfied or only the newest group remains
- **AND** immediately releases roots not owned by another bounded operation

#### Scenario: Background consumer finishes or is superseded
- **WHEN** save, history, search, comparison, or integrity work no longer needs an immutable revision root
- **THEN** it releases that root and any exclusively retained graph
- **AND** transaction callbacks and persisted history entries retain no hidden coordinator or ancestor chain

### Requirement: Flat persisted compatibility is preserved at deliberate boundaries
Jort SHALL flatten indexed state into the existing canonical Unicode text, absolute line metadata, landmarks, invocations, document identity, and revision representation for persisted Codable compatibility, and SHALL reconstruct an equivalent indexed root before publishing decoded state.

#### Scenario: Existing store is opened
- **WHEN** Jort decodes a valid snapshot written by the immediately previous release
- **THEN** it constructs an indexed snapshot with exactly equivalent text, line identities/ranges/timestamps, landmarks, invocations, identity, and revision
- **AND** complete validation succeeds before the snapshot becomes authoritative

#### Scenario: Indexed snapshot round-trips
- **WHEN** a document containing every supported newline form, Unicode boundary case, landmarks, and invocation anchors is encoded and decoded
- **THEN** its flattened public values are equal to the pre-encode values
- **AND** the round trip does not expose index chunking or internal node identity in persisted data

### Requirement: Performance evidence separates categories and proves bounded work
Jort SHALL record debug and optimized p50, p95, and p99 distributions separately for synchronous interaction, prepared presentation, and background throughput, SHALL pair elapsed results with structural work counters, and SHALL run hardware timing gates only on a checked reference runner definition.

#### Scenario: Performance baseline is recorded
- **WHEN** a baseline or budget changes
- **THEN** the checked report identifies build configuration, fixture hash and size, sample/warm-up/process counts, macOS, Xcode, architecture, and reference runner class
- **AND** includes interaction, presentation, save, history, recovery, and restore distributions applicable to the change

#### Scenario: Non-reference CI runs
- **WHEN** a CI runner does not match the checked timing profile
- **THEN** it still enforces correctness and structural affected-region/viewport bounds and reports timing distributions
- **AND** does not reinterpret those timings as the reference hardware gate

#### Scenario: Timing ceiling is revised
- **WHEN** evidence supports changing an existing absolute or relative regression ceiling
- **THEN** the reviewed change updates the checked manifest and rationale explicitly
- **AND** no test calculates its own passing ceiling or raises a limit merely because the current run failed

#### Scenario: Local edit appears fast but performs global work
- **WHEN** elapsed time happens to pass while instrumentation shows a localized transaction traversed or shifted unrelated trailing records
- **THEN** the structural regression gate fails
- **AND** the timing result cannot waive the complexity failure

### Requirement: Incremental correctness is checked against a full reference model
Jort SHALL run deterministic seeded state-machine tests that compare incremental transactions with a complete-scanning reference model across native edits, startup merge, metadata changes, tool patches, undo, redo, encode/decode, and restoration.

#### Scenario: Randomized edit sequence runs
- **WHEN** generated operations exercise insertions, deletions, replacements, split newline sequences, Unicode, landmarks, invocations, undo, and redo
- **THEN** every accepted step has equal flattened text, line IDs/ranges/timestamps, metadata, anchors, and revision behavior in the incremental and reference models
- **AND** every rejected step leaves both models unchanged with the same failure class

#### Scenario: Failure is reproduced
- **WHEN** a seeded randomized sequence finds a mismatch
- **THEN** the test reports the seed and minimized operation trace needed to reproduce it
- **AND** the implementation cannot update the reference result from incremental output to make the test pass
