# Verification: build-jort-run-tools

Updated September 13, 2026. The implementation, user feedback, and release qualification are complete. This change is ready to archive.

## Final qualification — September 13

- Removed the unused input-shape concept from the package artifacts; the four manifest input modes are the complete input contract.
- Documented the optional asynchronous `validate` entry point and explicit completion-acceptance recognition chosen for this product.
- Registry inspection now exposes bounded structured records for valid, invalid, and conflicting bundled or installed candidates while executable and Settings projections remain valid-only.
- Validation warnings are transient presentation state. They create no document revision, persistence write, Undo action, or history boundary, and validation and execution share one captured frozen input.
- Pending and error Dismiss plus immediate publication Undo restore pre-submit invocation metadata, selection, and stable viewport state. Restoration metadata survives persistence and older payloads decode safely.
- Added focused interaction coverage for completion Escape, native Return, contained focus exit, token invalidation, fast execution, same-line ownership, empty contextual validation, input/output limits, pending relaunch, and compatible-version relaunch without execution.
- Foundation suite: **103/103 passed** (`./scripts/test-foundation.sh`).
- Native suite: **91/91 passed** (`./scripts/test-native.sh`), including **51/51** tool invocation tests and the corrected current visual baselines.
- Real application UI suite: **5/5 passed** (`./scripts/test-ui.sh`), covering launch, typing, native Find dismissal, history/recovery, Settings tool creation and enablement, command palette, accessibility, tool Merge, save, and relaunch.
- Strict OpenSpec validation and `git diff --check` pass. Tasks 7.6 and 10.2 are complete; overall progress is **76/76**.

## Feedback verification

### Glyph-boundary and overlay follow-up — September 12

- Reproduced contextual `pearA` overlap with an assertion against the next glyph origin **before applying the clipping fix** (`/private/tmp/jort-feedback5-before.log`). The previous newline-only test did not cover this midline boundary.
- TextKit selection/insertion positions partition kerning advances; fixed offsets are not reliable glyph edges. Boundary clipping now reads shaped glyph positions from the attributed visual line and keeps the wrapper's stroke before the next character. Canonical text remains unchanged.
- Persistent ephemeral prompts now live in the editor root overlay, above the text view and its rebuilt controls. Explicit dark appearance preserves their prior visual theme. The new overlapping-controls test verifies hit-testing belongs to the prompt after repeated control rebuilds, rather than merely checking view frames.
- Native tool/accessibility suite **38/38 passed** (`/private/tmp/jort-feedback5-native.log`), including contextual midline boundary after Merge Undo, inline suffix/button clearance, and prompt anchoring/focus/offscreen behavior. Rendered boundary and overlay captures inspected. No computer use performed.
- Tasks 15.1–15.3 complete; overall **74/76**, with original release/physical qualification gates still open.

### Reopened cursor/viewport feedback — September 12

The third pass did not reproduce all user cases. The EOF test checked current geometry, not cached painted paths after scrolling; the suffix test covered inline output, not a contextual range ending with a newline.

- The text view now partitions its I-beam cursor rectangles around embedded action buttons, with a mouse-movement fallback and explicit button accessibility roles.
- Painting refreshes tool geometry when the visible rectangle, document view size, or TextKit viewport end changes. It does not rebuild controls on an unchanged paint pass.
- Contextual decoration omits the exclusive insertion position after a trailing newline while keeping canonical text and range metadata unchanged.
- New regression tests exercise accessibility actions and cursor routing, cached decoration after scrolling through 25 result lines appended beyond EOF, and the contextual newline followed by an unowned `a`.
- Accessibility-based XCTest app workflow **1/1 passed**, including Merge/Dismiss hover/hittability, merge, persistence, and relaunch (`/private/tmp/jort-feedback4-ui.log`). No computer-use interaction was performed. Native cursor state is asserted separately; XCTest hover alone does not prove the OS cursor image.
- Final native tool/accessibility suite **36/36 passed** (`/private/tmp/jort-feedback4-native.log`). Build-for-testing, strict OpenSpec validation, and diff whitespace checks pass. Tasks 14.1–14.4 complete; overall **71/73**, with the original broad release and physical accessibility/IME qualifications still open.

### Third feedback pass — September 12

- Build-for-testing succeeds. Native tool suite: **33/33 passed** (`/private/tmp/jort-feedback3-native-final.log`); Settings: **5/5 passed** (`/private/tmp/jort-feedback3-settings.log`). Clipboard and confirmation-sheet checks required the approved unsandboxed native test run.
- New checks cover every visible paragraph of multiline output appended at EOF, canonical seam advance, unrelated suffix clearance, bottom-edge prompt flipping, populated Settings sidebar, and editor-column growth. The Undo regression now checks styling immediately, without explicitly refreshing it in the test.
- Final rendered inspection caught an overly aggressive control-width reduction. Corrected for TextKit's half-kern segment bounds, added an output-glyph clearance assertion, and reran the three affected spacing/publication/Undo tests: **3/3 passed** (`/private/tmp/jort-feedback3-spacing-final.log`). The resulting inline and restored multiline captures were inspected again.
- Pending color is shared with history badges and composited against the canvas to avoid green-source tint changing purple. Both the buttons and parent text view enforce hand cursors. Duplicate canonical replacement during replay is avoided, and presentation is restored before selection/scroll layout.
- Native rendered captures were inspected. Live pointer interaction and animated Undo/Redo were not re-qualified in the running application during this pass; those remain part of the existing interactive release gates.
- OpenSpec strict validation and `git diff --check` pass. Tasks 13.1–13.4 complete; overall **67/69**, with the existing physical accessibility/IME and release gates open.

### Second feedback pass — September 11

- Build-for-testing succeeds. Native tool suite: **30/30 passed** (`/private/tmp/jort-feedback2-native.log`); Settings suite: **5/5 passed** (`/private/tmp/jort-feedback2-settings.log`).
- Added regressions for Merge Undo restoring the control kern, matched source/output heights, a trailing empty contained line, no duplicate ephemeral inline Run, single-space input normalization, visible enablement, and source/ruler clipping.
- Inspected captures of restored pending output, trailing empty input, canonical action spacing, and ephemeral input. Settings offscreen capture is limited by transparent AppKit surfaces; visibility/clipping properties are checked by native tests.
- Extended real-app test coverage for the Enabled checkbox. Its launch was declined, so **the real-app UI suite was not rerun for this pass**. Earlier two-workflow results below belong to the first feedback pass.
- Feedback tasks 12.1–12.4 are complete. Overall progress: **63/65**; the existing physical accessibility/IME and release qualification gates remain open.

### First feedback pass

- Foundation: **96/96 passed**, including history metadata-only comparisons and date/time/UUID content preservation (`/private/tmp/jort-feedback-foundation.log`).
- Focused editor: **27/27 passed**, including confirmed partial/multiple pending deletion and Undo, processing-lock rejection, immediate context keyboard control, Escape from output, error explanation, completion, and geometry (`/private/tmp/jort-tools-direct.log`).
- Settings: **5/5 passed**, including draft enablement, Save without a leave warning, executable package registration, and discovery in an editor (`/private/tmp/jort-feedback-settings.log`).
- Real application UI: **2/2 passed**, covering creation → save → autocomplete → Enter acceptance → pending output, plus bundled calc → merge → save → relaunch (`/private/tmp/jort-feedback-ui.log`).
- Inspected native captures for input/output spacing, embedded control placement, connected wrapped/multiline content, and readable execution errors. Paragraph-end glyph geometry does not include the trailing kern reservation; explicit trailing control space handles that case.
- Broad native regression: **64/66 passed** (`/private/tmp/jort-feedback-native-all.log`); only the two established ruler/footer baseline visual assertions failed. The subsequent focused 27-test run also covers the final paragraph-end and narrow-window control-space fixes.
- OpenSpec strict validation and `git diff --check` pass. Feedback tasks 11.1–11.6 are complete; overall progress is 59/61, with the existing release qualification gates open.

The feedback adds no execution authority. Deleting pending text is a confirmed atomic exception to the existing lock policy, with remaining text converted to ordinary text. Processing/error locks remain in force. Ephemeral acceptance inserts a separator outside its owned token; the prompt itself remains noncanonical.

| Dimension | Assessment |
| --- | --- |
| Completeness | Core implementation complete; see `tasks.md` for remaining verification gates |
| Correctness | Package/runtime, persistence, native editor, and real-app tool workflows exercised |
| Coherence | Shared package execution, canonical text, explicit merge, and connected decoration model implemented |

## Requirement evidence

| Requirements | Implementation | Tests |
| --- | --- | --- |
| Declarative format, registry/overrides, ordinary bundled tools | `Sources/JortSettings/ToolPackage.swift`, `ToolPackageRegistry.swift`, `PackageSettingsStore.swift`; `Jort/Resources/Tools` | `Tests/Settings/ToolPackageTests.swift` |
| Authority-free execution | `Sources/JortJavaScript/JortJavaScript.c`, `Sources/JortSettings/ToolRuntime.swift` | `Tests/Settings/ToolRuntimeTests.swift` |
| Exact contextual transforms | `Jort/Resources/Tools/sort/tool.js`, `dedupe/tool.js` | Bundled Unicode, duplicates, ordering, and empty-line tests |
| Canonical publication and atomic captured merge operation | `Sources/JortAppKit/ToolInvocationController.swift`, `Sources/JortDocument/Transactions.swift` | `ToolInvocationTests`, `ToolPersistenceTests` |
| Bounded provenance and safe recovery/package migration | `Sources/JortDocument/ToolInvocation.swift`, `Sources/JortPersistence/PersistenceFormat.swift`, `HistoryRevision.swift` | Persistence fault/legacy tests and native package-removal/upgrade tests |
| Registry recognition and non-executing completion | `ToolInvocationPresentation.swift`, `EditorViewController.swift` | Native keyboard/IME/paste tests and real-app `/calc` completion test |
| Contained, contextual, and ephemeral input | `ToolInvocationController.swift`, `ToolInvocationPresentation.swift` | Native ownership, context handles, ephemeral focus/discard, and state-matrix tests |
| Explicit focus-owned execution, source locking, cancellable lifecycle | `ToolInvocationController.swift`, `ToolRangeEditing` | Cancellation, concurrency, lock intersection, copy, delayed processing, and Undo chronology tests |
| Connected, accessible, layout-stable decoration | `ToolInvocationPresentation.swift`, `LinePresentationLayout.swift`, `JortTextView.accessibilityChildren()` | Rendered captures, real-app Merge, repeated handle focus, viewport/selection, newline and empty-output tests |

## Must complete before archive

None.

## Warnings and limits

- Large-document transitions still take hundreds of milliseconds. The final native run measured geometry at about 3.1 ms p95, recognition and acceptance at 367 ms, full-context movement at 200 ms, publication at 700 ms, and Dismiss at 338 ms. These are recorded performance characteristics rather than correctness failures.
- Prompt placement prefers the specified below/right anchor. Near a narrow window edge it shifts left with an attachment to that anchor so the form stays usable. It still moves offscreen with its document anchor. This is a practical edge-placement refinement to the preferred geometry.
- The existing Tools settings pane was adapted under the user's explicit authorization. The planning exclusion of a new Settings panel does not prohibit this integration.

## Verification scope

No core requirement or planned automated gate was skipped. Native accessibility APIs and real-app accessibility automation passed; this does not claim an independent assistive-technology usability study. Engine-host contract checks are not an independent security audit of the vendored QuickJS C implementation.
