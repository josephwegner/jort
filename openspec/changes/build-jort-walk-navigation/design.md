## Context

Crawl provides one canonical LF plain-text document, stable `LineID` values, metadata-aware editing and undo, a viewport-bounded logical-line gutter, and asynchronous verified current-state persistence. Walk uses those foundations to add organization without introducing blocks, files, or text markup.

Landmarks are the first durable metadata beyond timestamps. Their main risk is not emoji rendering; it is preserving user intent when edits split, join, replace, delete, undo, or redo the anchored line. The palette is deliberately a small application-action surface so later changes can register history, search, tools, and agents without adding permanent chrome.

This change depends on the completed and archived `build-jort-crawl-editor` change.

## Goals / Non-Goals

**Goals:**

- Add and remove emoji landmarks without modifying canonical text.
- Keep landmarks attached to stable logical lines through deterministic edits and exact undo/redo.
- Navigate landmarks from a compact index without changing gutter width or editor layout.
- Provide one searchable, keyboard-first command palette that future phases can extend.
- Persist and recover landmark state with the same atomicity and failure isolation as text and line metadata.
- Preserve Crawl launch, typing, scrolling, viewport, and accessibility guarantees.

**Non-Goals:**

- Labels, nested sections, outlines, blocks, folders, or multiple documents.
- Commands that generate or transform text, `@agent` completion, history, or search results.
- Capture routing, connector configuration, notifications, scripts, providers, or network access.
- Automatically guessing a new destination when an anchored line is deleted ambiguously.

## Decisions

### 1. Store landmarks as metadata keyed by stable identity

Each `Landmark` has its own `LandmarkID`, a `LineID`, and one validated extended grapheme cluster that must have emoji presentation. Identity is independent of the displayed emoji, so duplicate emoji are allowed and changing an emoji does not replace the landmark. At most one landmark may anchor a logical line in Walk.

Alternative considered: embedding emoji in text or anchoring by ordinal/offset. Embedded characters would pollute copying and search; ordinals and offsets become stale after edits.

### 2. Make edit outcomes deterministic and undoable

Edits above or within a surviving line retain its landmark. On split, the landmark remains with the leading fragment because Crawl preserves the original `LineID` there. On a direct newline deletion, a landmark on the removed trailing line transfers to the surviving leading line only if that line does not already have a landmark; if both sides are landmarked, the leading landmark survives and the trailing landmark becomes detached. Deleting or replacing an anchored line without a uniquely surviving identity detaches the landmark rather than silently moving it to unrelated text.

Detached landmarks remain persisted and visible in a palette action for resolution or deletion, but do not appear as attached gutter entries. Each edit transaction records landmark deltas beside text and line metadata so Undo and Redo restore exact attachment and emoji state.

Alternative considered: always move a deleted landmark to the nearest line. That is convenient but can silently assign meaning to unrelated content.

### 3. Use the existing gutter for both presentation modes

Normal mode draws either a line number or its landmark emoji for visible logical lines. A fixed control at the top of the gutter toggles landmark mode. Landmark mode displays attached landmarks in document order as top-aligned rows within the same gutter width; it does not correspond vertically to document rows. Activating one resolves its current `LineID`, scrolls that paragraph into view, places an ordinary selection/insertion point there, and restores editor focus.

Emoji selection uses the native character palette initiated for the selected gutter line. The chosen value is normalized and validated before commit. Pointer and keyboard/accessibility actions expose equivalent add, replace, clear, toggle, and navigate operations.

Alternative considered: a sidebar outline. It would add permanent layout weight and imply block hierarchy that Jort does not have.

### 4. Make the command palette a registry-backed transient surface

A small registry provides stable action identifiers, title, optional keywords, enabled state, and an execution closure. The palette opens from a title-bar control and Command-K, filters actions case- and diacritic-insensitively, supports Arrow navigation, Return execution, and Escape dismissal, and restores the prior editor selection and focus after dismissal or execution unless the chosen action explicitly navigates.

Walk registers only application and landmark actions such as toggle landmark mode, add/change/clear landmark at the current line, next/previous landmark, and resolve detached landmarks. The registry boundary is intentionally reusable by later changes, but Walk does not add invocation completion or text-generating commands.

Alternative considered: hard-coding palette rows in the view. A registry is only slightly more structure now and prevents every later phase from rewriting palette behavior.

### 5. Migrate current-state persistence without creating history

The snapshot schema gains ordered landmark records, including detached state. Migration from Crawl creates an empty landmark collection and retains the same document and line identities. Text, line metadata, and landmarks commit and verify as one current generation; the two rotating operational checkpoints include the same complete state. Landmark mutations force an immediate persistence request but do not create retained revisions.

Unsupported newer schemas and migration failures follow Crawl's preservation and recovery rules. No palette registry data is persisted.

## Risks / Trade-offs

- **Emoji input can contain text-like or multi-scalar sequences** -> Validate one emoji-presenting grapheme cluster and test skin tones, flags, ZWJ sequences, and variation selectors.
- **Split/join behavior can surprise users** -> Use `LineID` inheritance, explicit detachment for ambiguity, and exact undo/redo tests rather than nearest-line guessing.
- **Landmark mode can trigger whole-document layout** -> Order landmarks from document metadata and resolve only the selected line; never enumerate TextKit layout for the entire document.
- **Palette focus can interfere with native Find or IME** -> Do not open during active marked-text composition; preserve and restore the previous responder and selection.
- **Snapshot growth increases write cost** -> Landmark records are bounded by logical-line count and remain in coalesced current-state writes; retain Crawl storage and latency benchmarks.

## Migration Plan

1. Require a completed Crawl store and add a versioned migration that introduces an empty landmark collection without changing text or `LineID` values.
2. Deploy landmark model and persistence support before enabling gutter mutation controls.
3. Enable gutter modes and palette actions after migration, undo, accessibility, and performance tests pass.
4. On rollback, an older build must preserve and refuse the newer schema rather than dropping landmark metadata.

## Open Questions

No blocking questions remain. Optional landmark labels and richer detached-landmark repair are deferred until demonstrated by use.
