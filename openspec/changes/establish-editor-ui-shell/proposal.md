## Why

Jort's dependable editor and Walk navigation affordances currently sit in an undifferentiated window, while the planned Run features assume a clearer editor-first workspace and line-local room for transient UI. Establishing that shell before Run prevents later queue, history, tool, and agent work from hard-coding the old geometry or turning Jort into a stack of full-width cards.

## What Changes

- Give the document window distinct title-bar, gutter, canvas, and footer regions while keeping the editor as the dominant product surface.
- Keep the native traffic lights at the left and the existing Pocket control at the right of an otherwise quiet title bar; do not add a second Jort logo, document title, Queue, History, or overflow placeholders.
- Visually separate the fixed-width landmark/line-number gutter from the canvas without changing canonical text or line numbering; use the footer landmark status as the mode control rather than duplicating it in the gutter.
- Add a visually separated footer with a left-aligned Option-key landmark hint and count, while leaving the center and right free of speculative activity or Ask Jort controls.
- Temporarily reveal landmark navigation while Option is held and restore the prior gutter mode when it is released, without consuming Option-modified typing or shortcuts.
- Introduce a viewport-bounded layout contract for future UI anchored to a logical line: an accessory expands only its anchor line's vertical band, subsequent canonical lines keep real consecutive line numbers, and actions for that accessory remain inside the same expanded band.
- Add no queue, history, capture-queue, agent, tool, widget content, or Ask Jort behavior in this change.

## Capabilities

### New Capabilities

- `editor-workspace-shell`: Window chrome, region separation, title-bar and footer contents, Pocket placement, landmark status, and press-and-hold Option interaction.
- `line-anchored-layout`: Geometry and numbering rules that allow future noncanonical UI to expand one logical line without masquerading as document lines or forcing whole-document layout.

### Modified Capabilities

None. Crawl and Walk remain unarchived changes; this change composes their existing editor, gutter, landmarks, and Pocket behavior without weakening their contracts.

## Impact

- Refactors `Jort/JortApp.swift` window composition and `Sources/JortAppKit/EditorViewController.swift` from one edge-to-edge scroll view into explicit shell regions.
- Extends the existing viewport-bounded `LineRuler` and TextKit 2 layout integration with temporary mode ownership and line-anchored vertical geometry.
- Adds modifier-state observation, accessibility labels/values, reduced-motion-safe visual state, layout tests, UI tests, and large-document regression coverage.
- Changes no document or persistence format and adds no dependency, network authority, provider, or background service.
