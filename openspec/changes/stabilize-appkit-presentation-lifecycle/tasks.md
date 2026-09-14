## 1. Characterize and Instrument Presentation

- [ ] 1.1 Add instrumentation that records text-storage edits, layout requests, hierarchy identities, control frames, selection, first responder, document/lifecycle revisions, scheduler state, and Core Animation warnings around custom draw paths.
- [ ] 1.2 Add direct draw-purity characterization tests for the ruler, invocation decoration, completion/overlay views, editor shell, and touched custom cells before moving mutations.
- [ ] 1.3 Add rapid typing, scrolling, resize, output publication, Undo restoration, marked-text, accessibility traversal, and viewport-anchor fixtures that expose current presentation convergence and warnings.

## 2. Build the Prepared Presentation Pipeline

- [ ] 2.1 Define typed presentation dirty reasons, input epochs, immutable line/invocation/control/accessibility snapshots, and test-visible finite overscan configuration.
- [ ] 2.2 Implement one main-actor run-loop coalescer that unions invalidations, prevents reentrant reconciliation, rejects stale snapshot commits, and schedules at most one follow-up pass for changes during reconciliation.
- [ ] 2.3 Implement pure geometry builders from authoritative document/lifecycle projections and already available visible TextKit fragments without forcing or enumerating whole-document layout.
- [ ] 2.4 Implement ordered style, hierarchy/frame, viewport-anchor, snapshot-commit, and bounded display-invalidation phases with marked-text deferral and no recursive layout.
- [ ] 2.5 Route canonical document, startup/storage projection, lifecycle, TextKit layout, viewport, window geometry/scale, appearance, and accessibility changes into explicit dirty reasons.

## 3. Make Ruler and Line Accessories Paint-Only

- [ ] 3.1 Extract ruler painting and ruler-control ownership from `EditorViewController.swift` into separate paint-only and mount-coordinator types using the shared prepared geometry.
- [ ] 3.2 Move `refreshControls` frame and hierarchy mutation out of `drawHashMarksAndLabels` and reconcile landmark/index controls by stable line/action identity outside drawing.
- [ ] 3.3 Make ruler, landmark hit targets, line accessories, scrolling destinations, and viewport restoration consume the same committed line-band snapshot.
- [ ] 3.4 Add ruler/accessory tests for wrapped lines, extra end rows, landmarks, expansion/collapse, fast scroll, resize, stale epochs, accessibility order, and zero draw-time mutation.

## 4. Make Invocation Presentation Paint-Only

- [ ] 4.1 Extract completion state/presentation, invocation style reconciliation, pure geometry construction, paint-only views, prompt/handle/action mounting, and accessibility adaptation from `ToolInvocationPresentation.swift`.
- [ ] 4.2 Replace wholesale control rebuilding with a stable semantic-key diff that reuses valid controls, preserves a valid focused ephemeral prompt, and rejects stale-generation actions.
- [ ] 4.3 Move all attributed-text edits, TextKit layout requests, hierarchy/frame changes, control configuration, and display invalidation out of invocation draw callbacks.
- [ ] 4.4 Project only committed document and extracted headless lifecycle state into invocation presentation, preserving source/output seams, wrapping, controls, errors, completion, Merge/Dismiss/Undo restoration, and offscreen recycling.
- [ ] 4.5 Add invocation presentation tests for every visible phase, multiple same-line invocations, contextual handles, empty output, wrapping, scrolling, output publication, Undo, stale actions, focus, accessibility, and zero draw-time mutation.

## 5. Decompose Editor Ownership Safely

- [ ] 5.1 Extract the native text-view subclass and its editing, IME, paste, find, Services, undo, and typed transaction callbacks without creating another document owner.
- [ ] 5.2 Extract editor workspace composition/event routing from startup and persistence projection while preserving the Wave 1 typed loading, resolving, ready, recovery-editing, and ownership-conflict states.
- [ ] 5.3 Ensure immediate startup typing, startup selection, marked-text reconciliation deferral, storage notices, focus, and native undo remain synchronous and independent of scheduled presentation work.
- [ ] 5.4 Narrow extracted component interfaces to immutable projections and typed actions and remove obsolete cross-owner mutable state and draw-time refresh entry points.

## 6. Narrow UI Surfaces, Theme, and Localize

- [ ] 6.1 Make mutable AppKit controls private/internal by default across the touched editor, invocation, ruler, and Tools Settings types, preserving the Wave 1 owned-save interface and replacing broad test mutation with narrow probes/actions.
- [ ] 6.2 Add an application-level dark appearance bootstrap before app-owned window creation and remove redundant per-window/per-view dark overrides after document, Settings, prompt, popover, history/search, and recovery surfaces inherit correctly.
- [ ] 6.3 Establish the base localization resource/key convention and migrate moved or touched labels, actions, accessibility names, statuses, warnings, and errors without changing their intended English wording.
- [ ] 6.4 Add theme inheritance and localization-discovery/fallback tests that are deterministic under non-default developer locales.

## 7. Split and Verify Native Coverage

- [ ] 7.1 Split oversized editor/invocation tests into focused geometry, reconciliation, drawing, accessibility, editor integration, and invocation integration suites; leave lifecycle transition/race matrices in the extracted headless architecture suites.
- [ ] 7.2 Enable draw mutation assertions and Core Animation warning checks for the native interaction fixtures, with state mutation—not console matching alone—as the correctness oracle.
- [ ] 7.3 Verify reconciliation work remains viewport-plus-overscan bounded and records no hidden whole-document TextKit layout under the 10,000-line fixture.
- [ ] 7.4 Run strict OpenSpec validation, formatting/static checks, headless lifecycle tests, startup/storage integration tests, all focused AppKit suites, rapid-interaction fixtures, and UI smoke tests.
- [ ] 7.5 Document extracted AppKit ownership, invalidation sources, reconciliation phase ordering, overscan choice, test seams, theme policy, and the boundary left for Wave 3 performance work.
