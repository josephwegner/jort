## Why

Editor and tool paint callbacks currently rebuild controls, edit text storage, and force layout during Core Animation commits, producing nested-transaction warnings and making presentation timing fragile. The same oversized types also combine orchestration, persistence projection, geometry, styling, drawing, and control ownership, which makes fixes risky and obscures the boundary established by the tool-execution extraction.

## What Changes

- Make every AppKit draw callback consume previously prepared immutable geometry/style state and perform painting only.
- Move text styling, visible geometry construction, control mounting/recycling, and frame reconciliation into explicit content, layout, viewport, and lifecycle update paths.
- Coalesce presentation invalidations on the main actor, reconcile only visible content plus bounded overscan, and invalidate display after prepared state is committed.
- Split editor text-view behavior, editor orchestration, persistence projection, ruler presentation, invocation completion, styling, geometry, drawing, and control lifecycle into narrowly owned types.
- Preserve canonical text, native TextKit/IME/selection/undo behavior, stable-line viewport restoration, invocation semantics, accessibility order/actions, and existing visual design.
- Narrow mutable control visibility and expose tests through actions, accessibility, typed state, and focused fixtures.
- Apply Jort's dark-only appearance at the application theme boundary so document, Settings, panels, and future windows are consistent.
- Establish localized-string ownership for production UI and actionable error copy without changing product language as part of the refactor.
- Split AppKit tests by presentation responsibility and retain only native integration coverage that belongs above the extracted headless invocation lifecycle.

## Capabilities

### New Capabilities
- `appkit-presentation-lifecycle`: Defines read-only painting, prepared presentation snapshots, coalesced viewport-bounded reconciliation, control ownership, mutation guards, and presentation diagnostics.

### Modified Capabilities
- `native-editor`: Requires editor/ruler presentation updates to preserve immediate startup editing and native text-system behavior while draw paths remain mutation-free.
- `line-anchored-layout`: Requires the shared visible geometry source to be prepared outside paint and reconciled without recursive or whole-document layout.
- `inline-command-invocation`: Requires invocation styling, geometry, overlays, and accessibility controls to project authoritative lifecycle state through the prepared presentation pipeline.
- `editor-workspace-shell`: Applies the dark-only product appearance consistently and establishes localizable ownership of shell and error copy.

## Impact

- Decomposes `Sources/JortAppKit/EditorViewController.swift` and `Sources/JortAppKit/ToolInvocationPresentation.swift`, with focused changes to `ToolsSettingsViewController.swift`, `SettingsWindowController.swift`, `EditorShell.swift`, and `Jort/JortApp.swift`.
- Changes internal AppKit APIs and test fixtures, including the large invocation and editor test suites, but does not intentionally change public product behavior or persisted formats.
- Coordinates with `make-startup-editing-lossless`: loading remains immediately editable and marked-text reconciliation remains deferred safely.
- Coordinates with `extract-tool-execution-architecture`: the extracted reducer/coordinator owns invocation lifecycle; this change owns only native translation and presentation.
- Establishes the presentation boundary required before `make-document-interactions-incremental` qualifies end-to-end interaction and viewport latency.
