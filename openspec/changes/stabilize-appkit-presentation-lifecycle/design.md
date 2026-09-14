## Context

Jort's AppKit presentation is functionally rich and generally viewport-aware, but two critical draw paths currently reconcile mutable state. `LineRuler.drawHashMarksAndLabels` calls `refreshControls()`, which changes frames and adds/removes subviews. `ToolInvocationPresentation.draw` can call `refresh()`, which may edit text storage, force TextKit layout, recompute geometry, and rebuild controls. Native runs repeatedly report an invalid attempt to begin a transaction during Core Animation commit.

The behavior is difficult to isolate because `EditorViewController.swift` combines the text-view subclass, startup/persistence orchestration, native transaction adaptation, workspaces, and ruler controls, while `ToolInvocationPresentation.swift` combines completion, styling, geometry, painting, prompts, handles, and control lifecycle. The large AppKit invocation suite then reaches broad mutable control state to test domain and presentation behavior together.

This change must remain compatible with the active lossless-startup proposal: the editor is editable before load, selection is startup-relative, and reconciliation defers during marked text. It must also respect `extract-tool-execution-architecture`: AppKit receives committed lifecycle projections from the headless reducer/coordinator and does not become the authoritative invocation state machine.

## Goals / Non-Goals

**Goals:**

- Make every AppKit paint callback read-only with respect to text storage, layout, view hierarchy, constraints, control frames, focus, selection, lifecycle, and document state.
- Reconcile presentation from explicit invalidations in a coalesced main-actor pipeline using visible TextKit geometry plus bounded overscan.
- Preserve stable-line viewport position, selection, first responder, IME composition, native editing, accessibility order, and current visual behavior.
- Split oversized AppKit types at ownership boundaries and replace broad test access with narrow behavior-oriented seams.
- Apply the dark-only product appearance consistently from one application-level policy.
- Make production UI/error strings discoverable and localizable without rewriting product copy in the architectural refactor.

**Non-Goals:**

- Changing canonical document contents, persisted metadata, invocation lifecycle rules, package behavior, or output operations.
- Replacing AppKit, TextKit 2, the custom ruler, or current visual design.
- Solving document transaction/line-offset complexity or setting final performance budgets.
- Making Settings or the editor theme user-selectable.
- Adding new widgets, command surfaces, recovery controls, or product copy beyond what another accepted change requires.

## Decisions

### Drive presentation from explicit dirty reasons and epochs

Introduce one main-actor presentation coordinator per editor workspace. Producers invalidate it with typed reasons such as canonical document revision, invocation projection revision, text-layout generation, viewport bounds, window geometry/scale, appearance, accessibility, or control interaction. Invalidation only records reasons and schedules one reconciliation for the next eligible main-run-loop turn; it does not perform layout or mutate controls inline.

The coordinator tracks an epoch derived from all relevant revisions. If more invalidations arrive while a pass is scheduled or running, it unions their reasons and schedules at most one follow-up pass. A pass commits its snapshot only if its captured document/lifecycle/layout inputs still match; stale work is discarded and rescheduled. All mutations remain on the main actor.

Calling refresh synchronously from every scroll or document callback was rejected because it repeats geometry and hierarchy work during event bursts. Debouncing by a fixed wall-clock delay was rejected because it can make controls visibly lag typing; run-loop coalescing gives prompt next-turn updates without an arbitrary latency timer.

### Use an immutable prepared presentation snapshot

Reconciliation captures the current visible rect, stable top-line anchor and relative offset, selection, first responder, document revision, lifecycle projection, and already available TextKit 2 visible fragments. It computes an immutable snapshot containing:

- visible logical line bands and ordinals;
- ruler label, landmark, and hit-target geometry;
- invocation fragment unions, styling spans, seams, handles, prompts, and action frames;
- accessibility ordering and labels for mounted presentation controls;
- dirty display regions and the bounded control mount set; and
- the epoch that produced the snapshot.

Geometry construction is pure after its bounded input capture. It operates on visible fragments plus a documented finite overscan and indexed visible descriptors. It does not enumerate or force layout for the entire document.

Style reconciliation and hierarchy/frame reconciliation occur outside drawing after geometry has been prepared. Styling changes use presentation-only attributes and guarded text-storage edits that do not create canonical transactions or disturb marked text. Overlay controls are diffed against stable keys rather than removed and rebuilt wholesale. After the mutations settle, the coordinator commits the snapshot and invalidates only the required ruler/editor/overlay regions.

A single monolithic `refresh()` that both measures and mutates was rejected because it cannot prove what is safe in paint or isolate stale input. Independent geometry sources for ruler and invocation controls were rejected because they drift under wrapping, accessory expansion, and viewport restoration.

### Paint methods consume the last committed snapshot only

`draw(_:)`, ruler drawing, background drawing, and custom cell drawing receive the committed presentation snapshot and paint the intersection with their dirty rect. They may allocate transient drawing values and query immutable colors/fonts, but they must not:

- edit attributed or canonical text storage;
- call layout-forcing APIs or recursively invoke `layoutSubtreeIfNeeded`;
- add, remove, reorder, or reparent views;
- change constraints, frames, hidden/enabled state, focus, or selection;
- schedule reconciliation as a fallback; or
- mutate document/lifecycle/persistence state.

If no snapshot is ready or it is older than the current epoch, draw paints the safe base content and any still-valid portion of the previous snapshot. Explicit invalidation sources are responsible for scheduling reconciliation. Paint never tries to repair stale state.

Permitting draw to schedule an asynchronous refresh was rejected because it hides missing invalidation sources and can create continuous redraw loops. Recomputing geometry inside draw without hierarchy mutation was also rejected because TextKit queries can force layout during Core Animation commit.

### Reconcile layout and controls in ordered phases

Each pass runs these phases outside a paint callback:

1. Capture authoritative document and headless invocation projections plus native viewport/focus/selection facts.
2. Ask TextKit for layout only for the visible viewport plus bounded overscan from a layout/viewport callback where layout is permitted.
3. Build the immutable shared geometry snapshot.
4. Reconcile presentation-only text attributes without altering canonical characters, selection, undo, or marked text.
5. Diff mounted ruler and invocation views by stable semantic key; configure labels/actions/accessibility and apply prepared frames.
6. Restore the stable top-line anchor and relative offset only when reconciliation above the viewport changed vertical geometry and the anchor survives.
7. Commit the new snapshot and invalidate bounded display regions.

Hierarchy or text-layout changes caused by phase 4 or 5 are observed as a new dirty epoch rather than recursively forcing phase 2. During active marked-text composition, any styling or hierarchy operation that would disturb the marked range is deferred while safe unrelated viewport painting continues.

Doing all work in `layout()` was rejected because layout can be reentrant and control changes can trigger another layout immediately. The coordinator may be called from layout/viewport notifications, but applies one guarded pass with explicit reentrancy and epoch handling.

### Reuse controls by stable semantic identity

Ruler landmark buttons, invocation actions, contextual handles, ephemeral prompts, and completion rows use stable keys such as feature kind, invocation/line identity, generation where relevant, and action. The mount coordinator reconfigures and repositions retained controls, mounts missing visible controls, and unmounts offscreen or invalid controls after the new desired set is known.

Focus is not moved merely because a control is recycled. If a focused ephemeral prompt remains valid, it retains its view and local value. If its underlying lifecycle state becomes invalid, dismissal follows the authoritative lifecycle action rather than an incidental viewport recycle. Accessibility children follow canonical document order and the existing per-invocation action order after every diff.

Wholesale remove/re-add was rejected because it causes focus and accessibility churn and multiplies hierarchy transactions while scrolling.

### Split files by ownership with narrow internal interfaces

The target structure is responsibility-based rather than constrained by an arbitrary line count:

- a text-view subclass for native editing, text input, paste, find, and transaction callbacks;
- an editor workspace controller for child-controller composition and native event routing;
- a startup/persistence projection component that presents typed storage state but does not own the document;
- a ruler view plus ruler-control coordinator using prepared shared geometry;
- a completion controller/model;
- an invocation style reconciler;
- pure invocation/line geometry builders;
- an invocation overlay mount coordinator;
- paint-only views; and
- small action/accessibility adapters.

Mutable controls are `private` unless another production owner has a required interface. Tests use public user actions, accessibility, immutable presentation snapshots, injected geometry/layout fixtures, and narrow `internal` state probes under `@testable`. The Wave 1 owned-save API remains the only authority for Tools Settings save transitions.

Splitting solely to meet a line limit was rejected because it would preserve tangled ownership across more files. Exposing each extracted view publicly for tests was rejected because it would recreate the current mutable surface.

### Enforce one dark application theme and localizable string ownership

Define an application theme policy and apply `.darkAqua` at the `NSApplication` boundary before ordinary windows are constructed. Document, Settings, popovers, and panels inherit it unless a system-owned surface requires native handling. Remove ad hoc window/view overrides that duplicate the same policy. Tests create windows through the same theme bootstrap or explicitly install the theme in their harness.

All user-visible production labels, accessibility names, warnings, errors, and action text touched or moved by this change use stable localization keys with translator context where ambiguity exists. Add a base localization resource or string-catalog ownership rule and a test that audits obvious new raw UI literals. Existing wording is preserved unless a string was already inconsistent or inaccessible.

Per-window theme assignment was rejected because new secondary windows can silently miss it. A theme preference was rejected because user-selectable appearance is not a requirement of this remediation.

### Verify absence of mutation, not only absence of console text

Add instrumented tests around paint callbacks that snapshot text-storage change counts, layout requests, mounted view identities/hierarchy, frames, selection, first responder, document revision, lifecycle projection, and pending coordinator state before and after drawing. A direct draw invocation must change none of them. Separate integration runs assert the Core Animation nested-transaction warning is absent, but console-string matching alone is not the correctness oracle.

Add burst tests for typing, scroll, resize, output publication, Undo restoration, and accessibility traversal. They assert coalescing, bounded fragment work, stable alignment, focus/selection preservation, and eventual convergence to the latest epoch.

## Risks / Trade-offs

- **Risk: Missing an invalidation source leaves stale presentation.** → Model dirty reasons explicitly, audit every producer, expose epochs in tests, and make stale snapshots observable without allowing draw-time repair.
- **Risk: Coalescing delays an action control by one run-loop turn.** → Use next-turn coalescing without a fixed debounce and keep canonical text/native selection synchronous.
- **Risk: Presentation-only text attributes disturb IME or undo.** → Never change characters, suppress canonical transaction handling for owned attribute edits, preserve selection, and defer marked-range-affecting work.
- **Risk: View reuse associates an action with stale invocation state.** → Key views by semantic identity/generation, replace action payloads atomically during diff, and validate lifecycle generation at activation.
- **Risk: Extraction overlaps the tool architecture refactor.** → Land the headless lifecycle extraction first or preserve a narrow adapter seam; do not move reducer decisions back into new presentation types.
- **Risk: App-wide appearance changes system or test surfaces unexpectedly.** → Apply the policy before app-owned windows, inventory system panels, and test document, Settings, completion, and recovery surfaces.
- **Trade-off: The last valid snapshot can paint briefly while a newer epoch is pending.** → Prefer a stable, read-only frame for at most one coalesced turn over unsafe synchronous mutation; canonical text remains native and immediate.

## Migration Plan

1. Add presentation mutation instrumentation, draw purity characterization, epoch diagnostics, Core Animation log capture, and native burst fixtures before changing ownership.
2. Introduce dirty reasons, run-loop coalescing, immutable presentation snapshots, and pure geometry builders alongside the existing presentation path.
3. Move ruler geometry/control reconciliation outside `drawHashMarksAndLabels`, diff controls by stable line/action identity, and switch ruler paint to snapshot consumption.
4. Move invocation completion, styling, geometry, overlay mounting, prompts/handles/actions, and accessibility ordering into focused components; switch invocation paint to snapshot consumption.
5. Route document, lifecycle, layout, viewport, window, appearance, and accessibility invalidations into the coordinator and remove every draw-time refresh/layout fallback.
6. Extract the native text view, editor workspace orchestration, persistence projection, and ruler code from `EditorViewController.swift` while preserving the active startup-state contract.
7. Narrow Tools Settings and other touched control visibility and update tests to use actions, accessibility, snapshots, and injected fixtures.
8. Apply the app-level dark theme, move touched production strings to stable localization ownership, and remove redundant appearance overrides.
9. Split native tests by geometry, reconciliation, drawing, accessibility, editor integration, and invocation integration; keep headless lifecycle cases in the architecture change's test targets.
10. Run draw-purity, rapid interaction, viewport, IME, accessibility, native, and UI suites and confirm no nested Core Animation transaction warnings remain.

The migration can retain a temporary comparison mode that computes old and new geometry for fixtures without mounting both control trees. Rollback is source-only because no persistence or package schema changes. Do not leave the legacy draw-time refresh as a fallback after snapshot presentation becomes authoritative.

## Open Questions

- Choose the exact TextKit 2 viewport/layout notification hooks during implementation based on the existing deployment target and confirm they do not cause hidden whole-document layout.
- Define a small, documented overscan bound after measuring control churn during fast scrolling; it must remain finite and test-visible.
- Decide whether the localization audit uses the selected Xcode string catalog tooling, a repository script, or both, consistent with the engineering guardrails change.
