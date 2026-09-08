## 1. Revision storage foundation

- [x] 1.1 Define versioned full-state revision envelopes containing text, line metadata, landmarks, generation, reason, timestamp, compression metadata, and hashes.
- [x] 1.2 Add SQLite revision and history-settings migrations without changing current-state or recovery-checkpoint semantics.
- [x] 1.3 Implement off-main-actor revision encode, compression, write, decode, and complete-state validation.
- [x] 1.4 Add tests for round trips, unsupported schemas, corruption, malformed metadata, transaction interruption, and independence from current-state startup.

## 2. Revision policy and retention

- [x] 2.1 Implement injectable idle, lifecycle, and semantic revision boundaries with complete-state hash deduplication.
- [x] 2.2 Integrate landmark changes and restore operations as semantic boundaries while preserving Crawl autosave deadlines.
- [x] 2.3 Implement the configurable byte budget, minimum recent window, milestones, and transactional background pruning.
- [x] 2.4 Add realistic typing-session, duplicate-state, lifecycle, concurrent-write, disk-full, pruning, and storage-growth tests.
- [x] 2.5 Preserve readable retained history across current-state recovery; keep unreadable originals backed up and report any unavailable history independently of recovered editor health. Test this before exposing history in the UI.

## 3. History browsing and restore

- [x] 3.1 Register Version History in the Walk palette and build a restrained newest-first revision rail with locale-formatted timestamps, reasons, selection, and unavailable states.
- [x] 3.2 Build the transient split history workspace with keyboard-accessible complete Snapshot preview, historical ordinals and landmark gutter state, contextual read-only footer, stable shell geometry, and exact shell restoration on dismissal.
- [x] 3.3 Implement cancellable off-main-actor comparison of the selected revision with its immediately preceding retained verified revision, including labeled baseline, selected-revision summary, Changes / Snapshot switching, non-color-only markers, old/new ordinals, historical landmarks, expandable unchanged regions, and no-baseline behavior.
- [x] 3.4 Implement the visible Restore action, confirmation, pre-restore revision creation, atomic full-state restore, new generation publication, and persistence.
- [x] 3.5 Integrate restore with native Undo/Redo and preserve selection/viewport anchors where applicable.
- [x] 3.6 Add UI and integration tests for rail browsing, rapid-selection cancellation, Snapshot and Changes modes, no-baseline and corrupt states, keyboard expansion, resize, footer substitution/restoration, landmark rendering, restore, undo, relaunch, write failure, accessibility, reduced-color dependence, and focus restoration.

## 4. Current-document search

- [x] 4.1 Define cancellable immutable-snapshot search with literal, case-sensitive, and whole-word options.
- [x] 4.2 Produce bounded snippets and anchored results containing generation, `LineID`, line-relative UTF-16 range, and matched-text hash.
- [x] 4.3 Register Search Document in the palette and build keyboard-first query, options, result list, count, and empty state.
- [x] 4.4 Revalidate each selected result against current state, navigate valid matches, and refresh or remove stale matches.
- [x] 4.5 Add Unicode, combining-mark, emoji, case, word-boundary, cancellation, mutation-during-search, wrapping, and accessibility tests.

## 5. Release gates

- [x] 5.1 Benchmark search first-result latency and revision creation, browsing, selected-pair comparison, pruning, and restore with `CrawlLargeDocument`.
- [ ] 5.2 Re-run Crawl and Walk launch, typing, scrolling, persistence, recovery, storage-growth, gutter, IME, and accessibility gates.
- [x] 5.3 Verify search/history initialize only on explicit use and no history data leaves the Mac.
- [x] 5.4 Audit the finished slice to confirm no invocation parser, text-generating tool, agent, provider, script runtime, external command, capture, or connector is present.

## 6. User feedback refinements

- [x] 6.1 Preserve pending committed text when applying landmarks and test complete text-plus-landmark retention.
- [x] 6.2 Adopt a one-minute idle default, upgrade the prior default policy, and preserve custom settings.
- [x] 6.3 Fix disappearing gutter ordinals after repeated newline insertion without requiring scrolling or landmarks.
- [x] 6.4 Tighten the diff gutter, move landmarks before ordinals, join change blocks, and provide visible expansion buttons.
- [x] 6.5 Replace the search panel with a Command-F overlay supporting single-line snippets, persistent result navigation, arrows, Escape, and close.
- [x] 6.6 Add visible-row change counts, muted reasons, an in-rail action area, and automatic pagination.
- [x] 6.7 Run broad regressions, inspect rendered results, and refresh the local Release package.
