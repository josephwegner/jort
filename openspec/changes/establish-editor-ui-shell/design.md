## Context

The current native app renders one `NSScrollView` edge to edge beneath a transparent title bar. Its `NSRulerView` shares the canvas color, the title is visibly "Jort," the Pocket control is a right-side title-bar accessory, and save failures float over the lower canvas. Walk adds a fixed rectangular gutter control and a compact landmark mode, but the window has no footer or temporary modifier-driven reveal.

The PoC points toward a durable editor-first workspace, but several pictured surfaces do not exist yet. This change must establish useful present-day regions without adding inert Queue, History, capture, agent, or Ask Jort controls. It must also prepare for Run results that occupy vertical room beside real document lines: canonical content continues to determine line identity and numbering, while noncanonical UI belongs to the vertical band of an anchor line.

The editor remains AppKit/TextKit 2, the document remains plain text, and `DocumentCoordinator` remains the only mutable live-state owner. The 10,000-line fixture and viewport-bounded gutter behavior remain performance constraints.

## Goals / Non-Goals

**Goals:**

- Make title bar, gutter, canvas, and footer read as intentional, stable regions of one editor workspace.
- Keep the visible title bar quiet and unambiguous: native traffic lights on the left, Pocket on the right, and no duplicated Jort identity.
- Preserve the existing rectangular gutter-mode control and add an Option-key status affordance in the footer.
- Make holding Option a reversible, focus-neutral way to inspect the landmark index.
- Establish one geometry source for line numbers, landmarks, navigation, viewport anchoring, and future line-anchored accessories.
- Preserve native text input, Option-modified characters, IME, selection, scrolling, accessibility, persistence, and large-document performance.

**Non-Goals:**

- Queue, History, capture queue, run status, Ask Jort, tool/agent result content, merge/dismiss controls, or an overflow menu.
- A visible document/app title, a centered logo, changes to Pocket behavior, or replacement of the rectangular gutter toggle.
- Persisting accessory layout records or adding widget data to `DocumentSnapshot` before a feature owns that data.
- Rich text, block semantics, fake document lines, arbitrary accessory placement between character offsets, or a general-purpose panel framework.
- Redesigning the emoji picker, landmark lifecycle, command palette, document storage, or Run feature plans.

## Decisions

### 1. Compose the window from explicit shell regions

`EditorViewController` will own a root shell containing a fixed footer and a content region above it. The existing text scroll view remains the canvas; its vertical ruler remains the gutter. Shared `EditorMetrics` and palette values define the 48-point gutter, footer height, canvas inset, divider color, and one-device-pixel strokes. The gutter draws a distinct surface plus a trailing divider, and the footer draws a top divider and a vertical continuation at the gutter boundary.

The native title bar remains the window title bar so traffic lights, dragging, full screen, and accessibility retain standard macOS behavior. `window.title` stays "Jort" for system/window identity, while `titleVisibility` hides the visible title. The Pocket accessory remains at the right with its current icon, label, tooltip, and Command-K behavior. No placeholder views are installed for future title-bar actions.

The footer's left status item renders the Option symbol, a localized Landmarks label, and the current attached-landmark count. Its accessibility value also reports whether the landmark index is temporarily visible or latched. The center hosts only existing actionable persistence/recovery messaging when needed; it is empty in the healthy state. The right side remains empty.

Alternative considered: draw separators inside one edge-to-edge scroll view. That couples footer geometry to scrolling and makes future shell additions overlap the document. A custom replacement title bar was rejected because it would recreate native window behavior for no present product gain.

### 2. Separate latched landmark mode from the Option-held override

Landmark presentation will derive from two inputs: a user-controlled `latchedLandmarkMode` and a transient `optionHeld` flag. The effective mode is their logical OR. Clicking the existing rectangular control toggles the latched input. Pressing Option alone sets the transient input; releasing the final Option key clears it. Therefore release returns a previously unlatched gutter to line numbers, while a previously latched gutter stays open. A click made while Option is held updates the latched preference and becomes visible when Option is released.

A small injectable modifier-state controller will observe local `flagsChanged` events and relevant application/window activation notifications. The event monitor returns every event unchanged and never installs a key equivalent for Option, so Option-modified characters, navigation, menu access, and IME remain native. Loss of key-window/app-active state clears stale held state. Pressing or releasing Option does not change selection, focus, viewport, or the landmark index's independent scroll offset.

Alternative considered: synthesize clicks on the existing toggle. That loses the prior persistent state and makes focus loss or missed key-up events leave the gutter stuck open. Treating hold and latch as independent inputs makes recovery deterministic.

### 3. Give canonical lines ownership of expandable vertical bands

Introduce an AppKit-only `LinePresentationLayout` keyed by stable `LineID`. It derives visible line bands from TextKit 2 layout fragments and may accept transient accessory descriptors with a bounded requested height and placement after the anchor line's text. Descriptors do not contain document content and are not persisted by this change. With no descriptors, text geometry must remain identical to today's editor.

When a later feature supplies a descriptor, the layout adds presentation-only space after the anchor paragraph and positions the accessory inside that expanded band. Wrapped text remains part of the same logical line; the accessory follows the final visual fragment. The next canonical line begins after the expanded band and receives the next real ordinal. Multiple pieces of one result can anchor to different real lines: for example, explanatory UI can expand line 5, canonical `Decision:` and `Next:` text remains lines 6 and 7, and action controls can expand line 7.

The line ruler, landmark hit targets, scroll-to-line behavior, viewport restoration, and accessory placement consume the same band geometry. They must enumerate only visible TextKit fragments plus bounded overscan and indexed visible descriptors; no operation lays out every line. Accessibility orders the anchor line's text before its accessory and then the next canonical line, without adding the accessory to the text area's value.

The implementation may use presentation-only paragraph spacing or a custom TextKit layout-fragment path after a focused spike. The choice must pass native edit, IME, wrapping, undo, copy, and viewport tests and must never write layout attributes into canonical snapshots. A test-only accessory view/provider proves expansion and numbering now; product widget visuals wait for their owning Run changes.

Alternative considered: render future results as independent full-width cards between lines. That makes card rows look like document content and breaks meaningful numbering. Overlaying a widget without reserving layout height was rejected because it obscures text and destabilizes hit testing.

### 4. Centralize shell state without creating a second document owner

Shell state contains only presentation facts: latched mode, transient modifier state, landmark count, persistence notice, and transient accessory descriptors. `DocumentCoordinator` continues to own text, line metadata, and landmarks; shell observers receive immutable snapshots or derived values. Landmark mutations, Pocket actions, and persistence flow remain unchanged.

Layout updates preserve the caret, selection, top visible `LineID` plus relative Y offset, and editor first responder. Removing or invalidating an accessory descriptor collapses its band; if its anchor no longer exists, the descriptor is dropped rather than moved to a neighboring line.

Alternative considered: store accessory heights on `LineMeta`. That would turn temporary UI geometry into durable document state before Run defines its lifecycle and migration semantics.

### 5. Treat the reference images as direction, not a feature checklist

Acceptance snapshots will cover the current empty/healthy shell and a test-fixture expanded-line state. The healthy shell contains no PoC plus button, center logo/title, Queue, History, overflow dots, capture card, activity prose, or Ask Jort control. Pocket remains the sole right title-bar action. The fixture demonstrates geometry only and is not reachable as product UI.

Alternative considered: install disabled placeholders for roadmap features. Disabled chrome implies availability and commits scarce title/footer space before those workflows have product requirements.

## Risks / Trade-offs

- **Option hold conflicts with normal typing or produces a stuck mode** -> Observe and return modifier events unchanged, model hold separately from latch, clear transient state on deactivation, and test Option-modified input and left/right Option transitions.
- **Presentation spacing leaks into canonical text or undo** -> Keep descriptors in AppKit, assert snapshots/copy/native Find are unchanged, and isolate any text-storage attributes from document transactions.
- **Expanded bands destabilize scrolling and gutter alignment** -> Use one `LinePresentationLayout` geometry source and preserve top-line anchors across relayout.
- **Future widgets need more placement modes than the first contract** -> Support only bounded after-text space now; extend from measured Run needs rather than inventing a full block system.
- **Extra shell chrome reduces small-window canvas area** -> Keep the footer compact, retain the current minimum window size, and test narrow/short windows, wrapping, find bar, and accessibility.
- **Snapshot styling drifts from native title-bar appearance** -> Preserve the system title bar and encode only Jort-owned colors/metrics in shared tokens.

## Migration Plan

1. Add shared shell metrics/colors and hide only the visible window title while preserving the system title and Pocket accessory.
2. Introduce the root content/footer composition and move current persistence notices into the footer's conditional center region.
3. Restyle the existing ruler surface/dividers and bind the footer landmark count without changing gutter interactions.
4. Add the modifier-state controller and split latched versus held landmark state.
5. Add the line-presentation geometry seam and test-only accessory provider, then migrate ruler/navigation/viewport calculations to it.
6. Run native, UI, accessibility, and large-document regression gates before Run changes consume the new shell.

Rollback removes the shell/footer and transient layout provider without migrating stored data; document and landmark formats are unchanged.

## Open Questions

No blocking questions remain. Exact color values, footer height, and accessory spacing will be tuned against native rendered snapshots during implementation. Product-owned accessory types, queue/history destinations, run status language, and Ask Jort remain decisions for their respective Run changes.
