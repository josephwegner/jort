## 1. Revision storage foundation

- [ ] 1.1 Define versioned full-state revision envelopes containing text, line metadata, landmarks, generation, reason, timestamp, compression metadata, and hashes.
- [ ] 1.2 Add SQLite revision and history-settings migrations without changing current-state or recovery-checkpoint semantics.
- [ ] 1.3 Implement off-main-actor revision encode, compression, write, decode, and complete-state validation.
- [ ] 1.4 Add tests for round trips, unsupported schemas, corruption, malformed metadata, transaction interruption, and independence from current-state startup.

## 2. Revision policy and retention

- [ ] 2.1 Implement injectable idle, lifecycle, and semantic revision boundaries with complete-state hash deduplication.
- [ ] 2.2 Integrate landmark changes and restore operations as semantic boundaries while preserving Crawl autosave deadlines.
- [ ] 2.3 Implement the configurable byte budget, minimum recent window, milestones, and transactional background pruning.
- [ ] 2.4 Add realistic typing-session, duplicate-state, lifecycle, concurrent-write, disk-full, pruning, and storage-growth tests.

## 3. History browsing and restore

- [ ] 3.1 Register Version History in the Walk palette and lazily list verified revision metadata newest first.
- [ ] 3.2 Build keyboard-accessible read-only full-text preview with metadata summary and corrupt-revision state.
- [ ] 3.3 Implement confirmation, pre-restore revision creation, atomic full-state restore, new generation publication, and persistence.
- [ ] 3.4 Integrate restore with native Undo/Redo and preserve selection/viewport anchors where applicable.
- [ ] 3.5 Add UI and integration tests for browse, preview, cancel, restore, undo, relaunch, corruption, write failure, and focus restoration.

## 4. Current-document search

- [ ] 4.1 Define cancellable immutable-snapshot search with literal, case-sensitive, and whole-word options.
- [ ] 4.2 Produce bounded snippets and anchored results containing generation, `LineID`, line-relative UTF-16 range, and matched-text hash.
- [ ] 4.3 Register Search Document in the palette and build keyboard-first query, options, result list, count, and empty state.
- [ ] 4.4 Revalidate each selected result against current state, navigate valid matches, and refresh or remove stale matches.
- [ ] 4.5 Add Unicode, combining-mark, emoji, case, word-boundary, cancellation, mutation-during-search, wrapping, and accessibility tests.

## 5. Release gates

- [ ] 5.1 Benchmark search first-result latency and revision creation, browsing, pruning, and restore with `CrawlLargeDocument`.
- [ ] 5.2 Re-run Crawl and Walk launch, typing, scrolling, persistence, recovery, storage-growth, gutter, IME, and accessibility gates.
- [ ] 5.3 Verify search/history initialize only on explicit use and no history data leaves the Mac.
- [ ] 5.4 Audit the finished slice to confirm no invocation parser, text-generating tool, agent, provider, script runtime, external command, capture, or connector is present.
