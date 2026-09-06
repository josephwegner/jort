## 1. Shell composition and title bar

- [x] 1.1 Add shared `EditorMetrics` and dark shell palette values for gutter width, footer height, content insets, region backgrounds, and backing-scale-aware one-pixel separators.
- [x] 1.2 Refactor `EditorViewController` into explicit content and footer regions while keeping the scroll view, Find bar, first-responder timing, minimum window behavior, and remaining-space canvas layout intact.
- [x] 1.3 Keep the system window title as the accessible Jort identity but hide it visually, retain native traffic lights, and verify Pocket remains the sole right title-bar product control with its current icon and Command-K behavior.
- [x] 1.4 Add AppKit shell-layout tests for minimum, default, and expanded window sizes, including stable gutter/footer dimensions and nonoverlapping canvas, ruler, scroller, and Find-bar frames.

## 2. Gutter and footer presentation

- [x] 2.1 Give the existing `LineRuler` a distinct shell surface and trailing separator while preserving its 48-point width, line/emoji alignment, hit targets, menus, and independent landmark-index scrolling.
- [x] 2.2 Build the footer's left landmark status with the Option symbol, localized label, live attached-landmark count, and effective held/latched accessibility value.
- [x] 2.3 Move existing persistence-attention copy and retry/recovery action into the conditional center footer region, leaving it empty when healthy and preserving editor focus for every state transition and action.
- [x] 2.4 Draw the footer top separator at one physical pixel for supported backing scales while leaving the Option symbol and landmark label visually connected; add rendered-image assertions for contrast.
- [x] 2.5 Add accessibility tests proving shell controls have stable names, roles, values, order, and keyboard actions while the text area's value remains canonical text only.

## 3. Press-and-hold Option landmark mode

- [x] 3.1 Extract an injectable landmark-mode state model with independent latched and Option-held inputs and an effective `latched || held` presentation value.
- [x] 3.2 Use the footer landmark status as the latched-mode toggle and wire the ruler plus footer status to the effective mode without resetting index scroll or editor state on modifier transitions.
- [x] 3.3 Add a lifecycle-owned local modifier monitor that returns `flagsChanged` events unchanged, handles aggregate left/right Option state, and clears transient state when the window or application resigns active.
- [x] 3.4 Add state and AppKit tests for hold/release from both latched states, toggling while held, repeated flags, missed release on deactivation, empty landmark sets, and teardown without leaked event monitors.
- [x] 3.5 Add native text-input regressions showing Option-modified characters, Option navigation, IME composition, selection, undo, viewport, and first responder behave identically while the gutter reveal is active.

## 4. Line-anchored presentation geometry

- [x] 4.1 Define AppKit-only bounded accessory descriptors keyed by `LineID` and a `LinePresentationLayout` that reports visible canonical line bands, text origins, reserved after-text space, and accessory frames without entering `DocumentSnapshot`.
- [x] 4.2 Implement presentation-only line expansion after the anchor's final wrapped fragment, proving the zero-descriptor path is geometry-identical and contributes no text, line metadata, typing attributes, copy, Find, undo, or persistence content.
- [x] 4.3 Migrate ruler labels, landmark buttons and hit targets, scroll-to-line behavior, and top-line viewport restoration to the shared presentation geometry source.
- [x] 4.4 Add descriptor invalidation for deleted anchors and preserve selection, first responder, and top visible `LineID` plus relative offset when bands expand or collapse.
- [x] 4.5 Add a test-only accessory provider that demonstrates expansion on line 5, ordinary numbered content on lines 6 and 7, and controls within line 7's expanded band without exposing any shipped widget UI.
- [x] 4.6 Add accessibility-order tests for canonical anchor text, its separate accessory, and the next canonical line, including landmarked and wrapped anchors.

## 5. Regression and release gates

- [x] 5.1 Add deterministic rendered snapshots for the healthy empty shell, populated landmarks, active Option hold, actionable persistence failure, narrow/short windows, and the test-only expanded-line fixture.
- [x] 5.2 Run AppKit and UI coverage for launch focus, typing, wrapping, scrolling, Find, Pocket, landmark editing/navigation, menu actions, persistence notices, window reopen, and accessibility.
- [x] 5.3 Benchmark normal and expanded-band layout, gutter refresh, Option transitions, scrolling, and navigation with the committed 10,000-line fixture and a high landmark/accessory count, retaining viewport-bounded regression ceilings.
- [x] 5.4 Run project generation drift checks, the foundation/native test suites, strict concurrency diagnostics, and the isolated UI smoke path required by the repository.
- [x] 5.5 Audit the shipped window and update user-facing documentation to confirm there is no visible title/logo duplication, plus button, Queue, History, overflow, capture queue, activity placeholder, result widget, Merge/Dismiss UI, or Ask Jort control.
- [x] 5.6 Record this change as a prerequisite for the Run history/search, tools, and agents implementation sequence so those changes consume the shell and line-anchored layout instead of recreating window or card geometry.
