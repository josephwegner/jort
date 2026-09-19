## ADDED Requirements

### Requirement: AppKit painting is side-effect free
Every Jort AppKit draw callback SHALL paint only from already committed immutable presentation state and SHALL NOT mutate text storage, force or recurse into layout, change view hierarchy or control frames, move focus or selection, schedule fallback reconciliation, or mutate document, persistence, or invocation state.

#### Scenario: Ruler is asked to draw
- **WHEN** AppKit invokes the ruler's hash-mark and label drawing path for any dirty rectangle
- **THEN** the ruler paints the intersecting prepared labels, landmarks, and decorations
- **AND** mounted subviews, frames, layout request count, selection, focus, and coordinator state remain unchanged

#### Scenario: Invocation decoration is asked to draw
- **WHEN** AppKit invokes invocation background, border, seam, completion, or overlay drawing
- **THEN** the view consumes the last committed matching presentation snapshot or paints a safe base state
- **AND** does not edit attributed text, rebuild controls, query layout in a forcing manner, or repair stale presentation

#### Scenario: Prepared state is temporarily stale
- **WHEN** a newer presentation epoch is pending while Core Animation requests paint
- **THEN** drawing remains side-effect free and uses only still-valid committed state
- **AND** the explicit invalidation pipeline, rather than drawing, is responsible for producing the next snapshot

### Requirement: Presentation reconciliation is explicit and coalesced
Jort SHALL collect typed content, lifecycle, layout, viewport, window, appearance, and accessibility invalidations on the main actor and SHALL reconcile them in bounded, non-reentrant passes that converge on the newest epoch.

#### Scenario: Several invalidations arrive in one event burst
- **WHEN** typing, layout, viewport, and lifecycle callbacks invalidate presentation before the scheduled pass runs
- **THEN** Jort unions their dirty reasons and performs at most one initial reconciliation for that event burst
- **AND** schedules at most one follow-up when inputs change during the pass

#### Scenario: Captured inputs become stale
- **WHEN** document revision, lifecycle generation, viewport, or layout epoch changes before a prepared snapshot can commit
- **THEN** Jort discards the stale snapshot without mounting its controls or styles
- **AND** schedules reconciliation against the newest authoritative inputs

#### Scenario: Reconciliation changes layout
- **WHEN** applying prepared presentation-only styles or controls produces a later layout invalidation
- **THEN** Jort records a new epoch for a subsequent guarded pass
- **AND** does not recursively force another reconciliation or layout from the current pass

### Requirement: Prepared geometry is shared and viewport bounded
Jort SHALL build one immutable visible presentation snapshot from already available TextKit fragments, indexed descriptors, and a finite documented overscan, and SHALL use it for ruler, invocation, accessory, control, scroll, and accessibility geometry.

#### Scenario: Large document scrolls rapidly
- **WHEN** the viewport moves through a document containing line landmarks and invocation presentation
- **THEN** geometry and mounting work inspect only visible fragments, bounded overscan, and descriptors indexed to that region
- **AND** do not force layout or enumerate controls for the complete document

#### Scenario: Wrapped or expanded content relayouts
- **WHEN** wrapping or presentation-only expansion changes visible line bands
- **THEN** ruler labels, hit targets, invocation shapes, controls, and accessories use the same committed bands
- **AND** remain aligned after the coalesced pass

#### Scenario: Geometry changes above the viewport
- **WHEN** a surviving stable line would move because a presentation band above it expands or collapses
- **THEN** reconciliation preserves that top visible line and its relative offset when practical
- **AND** preserves the current selection and intentional first responder

### Requirement: Presentation controls reconcile by stable identity
Jort SHALL mount, reconfigure, position, and recycle line and invocation controls by stable semantic identity and generation, SHALL preserve valid focused controls, and SHALL expose accessibility order matching canonical document order.

#### Scenario: Visible controls move during scroll or resize
- **WHEN** a landmark or invocation action remains valid but its prepared frame changes
- **THEN** Jort retains and repositions the same semantic control where practical
- **AND** does not remove and recreate the complete control hierarchy

#### Scenario: Focused prompt remains valid
- **WHEN** an ephemeral prompt remains owned by the same current invocation while geometry reconciles
- **THEN** it preserves its native value, selection, and first-responder status
- **AND** viewport recycling alone does not dismiss or replace it

#### Scenario: Lifecycle invalidates a control
- **WHEN** an invocation action or prompt is absent from the newest authoritative lifecycle projection
- **THEN** reconciliation unmounts it and prevents stale generation actions from firing
- **AND** rebuilds accessibility children in canonical document and action order

### Requirement: Presentation ownership is narrow and testable
Jort SHALL separate native text input, editor orchestration, persistence projection, ruler controls, completion, styling, geometry, painting, overlay lifecycle, and accessibility adaptation into narrowly owned internal components whose behavior can be tested without exposing broadly mutable UI controls.

#### Scenario: Presentation component is tested
- **WHEN** a test verifies geometry, styling intent, mounting, or action routing
- **THEN** it uses immutable snapshots, injected fixtures, typed actions, accessibility, or narrow internal probes
- **AND** does not require public mutation of unrelated production controls

#### Scenario: Draw purity is verified
- **WHEN** instrumented tests invoke each custom paint path
- **THEN** text-storage changes, layout requests, hierarchy identity, frames, selection, first responder, document revision, lifecycle state, and scheduler state are identical before and after drawing
- **AND** the native integration run emits no nested Core Animation transaction warning during the covered interactions

#### Scenario: Invocation behavior is tested
- **WHEN** tests cover lifecycle transition matrices and asynchronous races
- **THEN** those cases run in the extracted headless lifecycle suite
- **AND** AppKit tests concentrate on native event translation, geometry, focus, accessibility, and document integration
