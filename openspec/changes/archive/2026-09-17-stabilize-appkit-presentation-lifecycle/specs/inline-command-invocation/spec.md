## ADDED Requirements

### Requirement: Invocation presentation projects authoritative lifecycle state
Jort SHALL derive invocation styles, geometry, prompts, handles, completion, action controls, and accessibility from committed document and headless lifecycle projections and SHALL reconcile that presentation outside drawing.

#### Scenario: Invocation changes phase
- **WHEN** the authoritative lifecycle transitions among inputting, submitted, processing, error, and pending Merge states
- **THEN** AppKit invalidates the matching presentation identity and prepares its new styles, geometry, controls, and accessibility actions
- **AND** no draw callback assigns a phase, edits canonical or attributed text, or rebuilds the action hierarchy

#### Scenario: Pending output is restored by Undo
- **WHEN** a document transaction restores valid pending output and lifecycle metadata
- **THEN** one coalesced reconciliation reapplies presentation-only source/output styles, geometry reservations, Merge/Dismiss actions, and accessibility order
- **AND** paint consumes the committed result without forcing layout or changing the restored document

#### Scenario: Invocation scrolls offscreen
- **WHEN** a valid invocation leaves the viewport and bounded overscan
- **THEN** AppKit may unmount its presentation controls while preserving authoritative document and lifecycle state
- **AND** returning to the viewport reconstructs equivalent presentation without re-executing or changing the invocation

#### Scenario: Stale action control is activated
- **WHEN** a recycled or delayed native action carries an older invocation generation than the current lifecycle projection
- **THEN** action routing ignores it without document mutation
- **AND** schedules presentation convergence when the stale control is still mounted
