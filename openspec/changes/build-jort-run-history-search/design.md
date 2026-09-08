## Context

Crawl stores one verified current state plus two operational recovery checkpoints; those checkpoints are not history. Walk adds metadata landmarks and a palette. This change depends on both completed changes and deliberately separates user-visible revision retention from crash recovery.

## Goals / Non-Goals

**Goals:**

- Retain useful local revisions without recording every keystroke or slowing typing.
- Preview and atomically restore text, line metadata, and landmarks as one state.
- Make historical snapshots and their changes legible without confusing them with the live editor.
- Search the current in-memory document with useful context and exact navigation.
- Keep history and search lazy, local, accessible, and bounded.

**Non-Goals:**

- Event sourcing, stored diff chains or diffs as the authoritative restore format, cloud backup, sync, or collaboration.
- Searching all historical revisions in the initial slice.
- Agents reading history, text-generating commands, scripts, or providers.
- Adding a separate search window or replacing native text editing and selection.

## Decisions

### 1. Store independently restorable full-state revisions

Each revision stores a versioned compressed envelope containing canonical text, ordered line metadata, attached/detached landmarks, generation, reason, timestamp, and verification hashes. Restore never depends on replaying a diff chain. Revision rows are separate from Crawl current-state and recovery material, so a corrupt revision cannot invalidate startup.

Alternative considered: per-edit deltas. They reduce duplicate bytes but make restore dependent on an intact chain and add compaction complexity prematurely.

### 2. Coalesce ordinary typing and force semantic boundaries

An injectable revision coordinator creates a checkpoint after a configurable idle interval (one minute by default) and at deactivation/clean shutdown when the state differs from the latest revision. Landmark changes, restores, and later bulk/automation transactions request semantic boundaries. Identical state hashes do not create duplicate revisions. Current-state autosave remains governed by Crawl's faster durability deadlines.

### 3. Bound history by policy without touching recovery

History receives a configurable local byte budget and retains a minimum recent window plus milestone revisions. Background pruning removes oldest eligible revisions transactionally. Operational recovery checkpoints and current state do not count toward or get deleted by history pruning. The initial default is 256 MB, with the exact value exposed in local settings rather than inferred from free disk.

### 4. Present history as a transient split workspace

History opens lazily from the palette into a transient workspace in the existing window. The native title bar remains quiet with Pocket as its sole product action; History does not become permanent title-bar chrome. The workspace places a large read-only preview beside a fixed-width revision rail headed Version History. The rail lists verified revisions newest first, groups dates where useful, uses locale-formatted timestamps, shows the revision reason, and gives the selected row a restrained surface and non-color-only accent. Each visible revision row shows compact green addition and red deletion counts, derived lazily against its immediately preceding retained revision. Its reason uses muted text near the bottom of the row. Scrolling near the end loads the next metadata page automatically. Only counts are cached; decoded states and full comparisons are not retained for every row.

The preview offers a Changes / Snapshot segmented control. Selecting a revision decodes and verifies it off the main actor, then shows its complete read-only text and metadata without replacing the live editor. Snapshot displays the full selected state with its historical line ordinals and attached landmark emoji. The live `Option Landmarks: N` footer affordance is hidden because it operates on the live document and would be misleading in a historical preview; the footer keeps its stable height and instead identifies the selected timestamp, read-only state, and historical landmark count. Dismissal restores the normal footer, selection, viewport, and editor focus.

An explicit Restore action remains visible for a valid selected revision in a separated action area at the bottom of the revision rail alongside Done and always leads to confirmation. Restore first forces a revision of current state, then submits the selected full state as one undoable document transaction and persists it as current state. The restored state receives a new current generation while preserving historical line and landmark identities from the selected revision. Corrupt or otherwise unavailable revisions disable both preview and restore without disturbing the rest of the list.

Alternative considered: a permanent History title-bar button. That conflicts with the quiet live-editor shell and spends persistent chrome on a workflow already reachable through Pocket. A separate window was rejected because it weakens the relationship between preview, restore, and the current document.

### 5. Derive changes from independently restorable snapshots

Changes compares the selected verified revision with its immediately preceding retained verified revision. Both snapshots are decoded and compared off the main actor with cancellation when selection changes. The result is presentation data only: no diff or patch chain is required for preview or restore, and pruning either snapshot cannot corrupt another revision. When no valid retained baseline exists, Jort selects Snapshot, disables Changes, and explains that no comparison is available.

The changes renderer uses continuous addition and deletion blocks without vertical gaps, plus explicit `+` and `-` markers so meaning never depends on color. A compact dark gutter separates landmark emoji, old/new ordinals, and change markers from the text; landmarks appear to the left of the ordinals. Changed regions expose old and new ordinals where the two sides differ, preserve the applicable historical landmark emoji, and retain enough unchanged context to orient the user. Snapshot remains the complete canonical preview; Changes may collapse unchanged regions when each collapse has a visible, keyboard-accessible expansion button. The former bottom metadata section is removed. Baseline context remains available through accessibility help and the presentation control tooltip.

Alternative considered: persist per-revision patches or precomputed list statistics. That complicates pruning and risks making the UI summary look authoritative. Comparisons for the selected pair and currently visible rows keep full-state envelopes as the only restore contract and avoid decoding the entire history to populate the rail.

### 6. Search immutable current text without a persistent index initially

Search captures the current generation and scans an immutable text snapshot off the main actor using locale-independent literal matching with case-sensitive and whole-word options. Results contain an anchored line identity, matched text hash, UTF-16 range within that line, ordinal, and bounded context from that logical line only; snippets never insert newline glyphs. Selecting a result resolves it against current state; a stale result is revalidated or removed rather than selecting unrelated text.

Command-F and Search Document open the same floating overlay at the top-right of the editor. With an empty query it shows only the search field and close button. Typing expands it to reveal options, matches, and previous/next arrows. Clicking a result selects the exact matched text and scrolls the editor while leaving search open. Escape (including after focus returns to the editor) or the close button dismisses it. Live edits refresh results. The overlay preserves window geometry and adapts to resizing.

This avoids index migration and update cost for the Crawl fixture. A persistent index is deferred until measured search latency requires one.

## Risks / Trade-offs

- **Full-state revisions consume disk** -> Compress, deduplicate by hash, enforce a visible byte budget, and measure growth.
- **Coalescing may produce too many or too few revisions** -> Keep policy injectable, distinguish semantic boundaries, and test realistic typing sessions.
- **Restore could mix state generations** -> Verify complete envelopes and commit text plus metadata as one document transaction.
- **Derived changes could be mistaken for the stored or restorable state** -> Label the comparison baseline, keep Snapshot as the complete-state view, and restore only the selected verified envelope.
- **Diff computation or rapid selection could stall the workspace** -> Decode and compare only the selected pair off the main actor, cancel superseded work, and show progressive unavailable/loading states.
- **History chrome could imply that the live editor is active** -> Replace live footer controls with explicit read-only revision context and restore the shell state on dismissal.
- **Search results become stale while typing** -> Tag results by generation and revalidate their line identity/range before navigation.
- **Scanning large text can consume CPU** -> Debounce queries, cancel superseded scans, use immutable snapshots, and keep work off the main actor.

## Migration Plan

1. Add revision tables and settings without modifying existing current-state or recovery records.
2. Create the first user-visible revision from the verified current state after migration completes.
3. Enable the history rail and complete Snapshot preview after verification, shell-restoration, and accessibility tests pass.
4. Enable derived Changes presentation and restore after comparison cancellation, corruption, confirmation, and undo tests pass.
5. Enable document search after verification and cancellation tests pass.
6. Older builds must preserve and refuse the newer schema rather than dropping history or landmarks.

## Open Questions

The 256 MB default history budget and idle coalescing interval should be tuned from instrumented usage; neither blocks the storage model.
