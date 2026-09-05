## Context

Crawl stores one verified current state plus two operational recovery checkpoints; those checkpoints are not history. Walk adds metadata landmarks and a palette. This change depends on both completed changes and deliberately separates user-visible revision retention from crash recovery.

## Goals / Non-Goals

**Goals:**

- Retain useful local revisions without recording every keystroke or slowing typing.
- Preview and atomically restore text, line metadata, and landmarks as one state.
- Search the current in-memory document with useful context and exact navigation.
- Keep history and search lazy, local, accessible, and bounded.

**Non-Goals:**

- Event sourcing, diffs as the authoritative restore format, cloud backup, sync, or collaboration.
- Searching all historical revisions in the initial slice.
- Agents reading history, text-generating commands, scripts, or providers.
- Replacing native Command-F; native Find remains available for conventional incremental find/replace.

## Decisions

### 1. Store independently restorable full-state revisions

Each revision stores a versioned compressed envelope containing canonical text, ordered line metadata, attached/detached landmarks, generation, reason, timestamp, and verification hashes. Restore never depends on replaying a diff chain. Revision rows are separate from Crawl current-state and recovery material, so a corrupt revision cannot invalidate startup.

Alternative considered: per-edit deltas. They reduce duplicate bytes but make restore dependent on an intact chain and add compaction complexity prematurely.

### 2. Coalesce ordinary typing and force semantic boundaries

An injectable revision coordinator creates a checkpoint after a configurable idle interval and at deactivation/clean shutdown when the state differs from the latest revision. Landmark changes, restores, and later bulk/automation transactions request semantic boundaries. Identical state hashes do not create duplicate revisions. Current-state autosave remains governed by Crawl's faster durability deadlines.

### 3. Bound history by policy without touching recovery

History receives a configurable local byte budget and retains a minimum recent window plus milestone revisions. Background pruning removes oldest eligible revisions transactionally. Operational recovery checkpoints and current state do not count toward or get deleted by history pruning. The initial default is 256 MB, with the exact value exposed in local settings rather than inferred from free disk.

### 4. Preview decoded immutable state and restore through one document transaction

History opens lazily from the palette. Selecting a revision decodes and verifies it off the main actor, then shows read-only text and metadata summary without replacing the live editor. Restore first forces a revision of current state, then submits the selected full state as one undoable document transaction and persists it as current state. The restored state receives a new current generation while preserving historical line and landmark identities from the selected revision.

### 5. Search immutable current text without a persistent index initially

Search captures the current generation and scans an immutable text snapshot off the main actor using locale-independent literal matching with case-sensitive and whole-word options. Results contain an anchored line identity, matched text hash, UTF-16 range within that line, ordinal, and bounded snippet. Selecting a result resolves it against current state; a stale result is revalidated or removed rather than selecting unrelated text.

This avoids index migration and update cost for the Crawl fixture. A persistent index is deferred until measured search latency requires one.

## Risks / Trade-offs

- **Full-state revisions consume disk** -> Compress, deduplicate by hash, enforce a visible byte budget, and measure growth.
- **Coalescing may produce too many or too few revisions** -> Keep policy injectable, distinguish semantic boundaries, and test realistic typing sessions.
- **Restore could mix state generations** -> Verify complete envelopes and commit text plus metadata as one document transaction.
- **Search results become stale while typing** -> Tag results by generation and revalidate their line identity/range before navigation.
- **Scanning large text can consume CPU** -> Debounce queries, cancel superseded scans, use immutable snapshots, and keep work off the main actor.

## Migration Plan

1. Add revision tables and settings without modifying existing current-state or recovery records.
2. Create the first user-visible revision from the verified current state after migration completes.
3. Enable history browse/restore and document search only after verification and cancellation tests pass.
4. Older builds must preserve and refuse the newer schema rather than dropping history or landmarks.

## Open Questions

The 256 MB default history budget and idle coalescing interval should be tuned from instrumented usage; neither blocks the storage model.
