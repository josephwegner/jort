## ADDED Requirements

### Requirement: Native edit acceptance uses exact incremental replacements
For an ordinary committed native edit, Jort SHALL submit the AppKit-provided UTF-16 affected range and exact replacement text to the authoritative coordinator, SHALL keep marked-text updates provisional, and SHALL NOT copy or compare the complete text view or materialize a flat document snapshot on the synchronous input path.

#### Scenario: Ordinary typing commits
- **WHEN** AppKit commits an insertion, deletion, or bounded replacement with a reliable affected range and replacement string
- **THEN** the adapter submits those exact values as one native document transaction
- **AND** the accepted canonical revision becomes visible without waiting for complete validation, persistence, history, or prepared decoration convergence

#### Scenario: Composition commits without one reliable replacement range
- **WHEN** marked text commits and AppKit does not supply one stable range/replacement pair
- **THEN** Jort derives the committed replacement through its bounded UTF-16 prefix/suffix fallback and submits one transaction
- **AND** provisional composition updates created no canonical revision or durable snapshot

#### Scenario: External operation replaces the complete text
- **WHEN** a Service or other native path genuinely returns a whole-document replacement without bounded edit facts
- **THEN** Jort classifies it as one explicit bulk transaction
- **AND** preserves native selection, undo grouping, and atomic publication even though work may scale with the payload

### Requirement: Interaction readiness is measured independently
Jort SHALL measure native edit acceptance and matching visible text separately from prepared gutter/invocation presentation and background persistence/history throughput, and SHALL keep background work from synchronously delaying accepted input.

#### Scenario: Autosave and history are slow
- **WHEN** injected persistence and history work remain blocked after a native edit
- **THEN** the edit is accepted, visible, selectable, and undoable through the current in-memory revision
- **AND** save/history completion later acknowledges only its exact immutable revision

#### Scenario: Decorations reconcile on the next prepared pass
- **WHEN** accepted text invalidates line or invocation presentation
- **THEN** canonical text visibility is recorded on the interaction path and viewport-bounded decoration convergence is recorded on the presentation path
- **AND** one category's latency is not reported as the other's result
