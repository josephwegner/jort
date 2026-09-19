# AppKit presentation lifecycle

The document coordinator and headless invocation coordinator remain authoritative.
Presentation does not submit edits from drawing, layout, styling, or accessibility
queries. `JortTextView` owns native input/IME/paste/find/Services translation and
native undo actions. `EditorViewController` composes the workspace and adapts
transactions; `EditorStorageProjection` owns startup/storage presentation facts.
Immediate startup input and canonical selection do not wait for presentation.

## Invalidation and reconciliation

Each workspace owns one `PresentationCoordinator`. Typed dirty reasons cover
committed document/lifecycle changes, native layout, viewport bounds, window scale,
appearance, accessibility display settings, interaction, and storage notices.
Invalidations union until a main-run-loop turn in default or event-tracking mode.
A running pass cannot recurse. Invalidations during preparation reject its commit;
invalidations during application schedule one follow-up. Tests inspect epochs,
reasons, scheduled/running state, and pass count without driving mutable controls.

The workspace prepares viewport layout outside painting, rejects changed input
epochs, and reconciles presentation-only attributes. An attribute change schedules
a later pass so geometry is captured after TextKit processes the change. That pass
captures line bands, prepares invocation geometry, reconciles native mounts,
restores surviving accessory viewport anchors, commits paint/accessibility state,
and invalidates the visible editor/ruler region. Marked text defers these operations
until composition commits. Error accessory changes defer layout to the next pass.

`LinePresentationLayout` is the native measurement adapter. `PresentationGeometry`
builds line bands from captured fragment values; `InvocationGeometry` builds shapes
and action rectangles from captured canonical rectangles and glyph boundaries.
Neither pure builder can access a text storage or layout manager. Native segment
queries clip ranges to the viewport, and no fragment enumeration requests
`ensuresLayout`. Explicit navigation can request layout for one destination point;
normal presentation does not request layout for a document-wide range.

The initial overscan is **0 points** beyond TextKit's available viewport. This
finite, test-visible bound avoids prelaying out offscreen content; retained controls
are reused when their semantic key stays visible. The 10,000-line fixtures record
fragment visits, measured range length, targeted layout requests, and selection.
Future overscan changes must retain those bounds and measure control churn.

## Ownership and controls

- `LineRuler` paints prepared labels. `RulerControlMounts` retains buttons by stable
  line identity. Ruler hit targets and line accessories share committed bands.
- `InvocationCompletionController` consumes text, selection, and package projections
  synchronously so keyboard acceptance does not depend on the presentation turn.
- `InvocationStyleReconciler` receives a committed snapshot and a scoped text-storage
  adapter. It changes attributes only, preserving canonical characters and undo.
- `InvocationControlMounts` owns semantic action/progress/completion controls and
  immutable frame/accessibility descriptors. It removes only obsolete mounts.
- `InvocationOverlayCoordinator` owns prompts and scope handles. It emits typed
  native actions through a generation-checked adapter. A valid focused prompt keeps
  its input value and responder identity when its anchor leaves the viewport.
- `InvocationPaintSnapshot` paints committed paths only. It cannot invalidate,
  mount, measure, or update document state. Accessibility children commit in
  canonical invocation/action order alongside presentation.

Mutable native controls are internal/private. Application termination uses
`finishComposition()` rather than reaching into the editor's text view.
Tools Settings retains its existing owned-save transition interface.

## Theme and localization

`ApplicationTheme.install` sets the application appearance before app-owned windows
are constructed. Document, Settings, prompts, popovers, history/search, and recovery
surfaces inherit that policy. Test hosts install the same policy explicitly.

`LocalizedCopy` resolves stable keys from the AppKit framework's
`Resources/en.lproj/Localizable.strings` with an explicit English fallback. Keep a
key stable when changing wording; format keys own argument positions and names.
Run `python3 scripts/check-localization.py` to validate discovery, duplicate keys,
base values, and obvious raw literals in extracted presentation components.

## Verification and remaining performance boundary

`PresentationDrawingTests` compares storage edit notifications, native hierarchy
identities/frames, selection, responder, canonical/lifecycle state, layout counters,
and scheduler state across direct draws, including a deliberately dirty epoch.
Coordinator tests cover bursts, stale preparation, and nonrecursive follow-ups.
Native suites cover wrapped/extra rows, landmarks/accessories, invocation phases,
Merge/Dismiss/Undo, prompt focus, IME, resize/scroll, and accessibility actions.

Run `./scripts/validate presentation` for localization, focused native tests **and**
the strict Core Animation warning gate. The validation runner prints concise results
and stores complete logs and a JSON summary under `.build-validation/`.
A passing mutation test does not waive a remaining nested-transaction warning.
The full native, foundation, UI, formatting, project, and first-party analyzer
commands remain documented in `engineering-guardrails.md`.

Canonical line indexing, full-document attribute cleanup after document revisions,
transaction cost, and end-to-end latency qualification remain Wave 3 work. This
change bounds native viewport measurement and mounting; it does not claim that all
canonical projection rebuilding is incremental.

## Native window-animation diagnostic

On the tested macOS 26.6.2 / Xcode 26.6 environment, rapid animated-window teardown
under a test host can emit `Invalid attempt to open a new transaction during CA
commit`. A minimal fixture using only `NSWindow`, `NSViewController`, and
`NSTextView` reproduced the warning without any Jort views or coordinators.
The captured stack releases `_NSWindowTransformAnimation`, deallocates its window,
and destroys the window-server window while Core Animation is committing. AppKit's
subsequent transaction cleanup emits the warning. This is separate from mutation
in a custom draw callback.

Presentation fixture windows set `animationBehavior = .none` before being shown.
The same native controls, layout, painting, and interaction assertions still run;
production window animation policy is unchanged. The strict warning checker remains
enabled. The system-only lifecycle fixture also participates in the presentation lane.

`scripts/diagnostics/native-window-animation.swift` is a standalone AppKit probe
with no Jort or XCTest dependency. Compile and compare its default animation with
`--no-animation`, using `OS_ACTIVITY_DT_MODE=YES` to expose AppKit diagnostics.
Its default event loop calls `NSApplication.run()`; `--manual-runloop` instead
pumps the run loop like a test host. The file contains the compile command.
The standalone manual-loop run reproduced five warnings from five window cycles;
the animation-disabled control and the normal `NSApplication.run()` control each
produced zero. Neither Jort nor XCTest is required for this reproduction.
