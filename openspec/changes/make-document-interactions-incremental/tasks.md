## 1. Baseline and representation selection

- [ ] 1.1 Add transaction, native-visibility, prepared-presentation, persistence, and history signposts plus test-only counters for visited lines/chunks/index nodes, allocated storage, flattening, and complete validation.
- [ ] 1.2 Add a checked performance environment/fixture manifest and capture before-change debug and optimized p50/p95/p99 results from at least five declared process runs without changing existing ceilings.
- [ ] 1.3 Build property-compatible augmented chunked-sequence prototypes and benchmark edit, offset/ID lookup, snapshot, flatten, and peak-memory behavior against the current 10,000-line and 1,000,000-unit fixtures.
- [ ] 1.4 Commit the representation-selection record, including rejected alternatives, chosen branching/chunk constants, measured evidence, and proof that the winner satisfies persistent UTF-16 sequence and stable-ID lookup properties.

## 2. Persistent document index and snapshots

- [ ] 2.1 Implement immutable bounded UTF-16 chunks, logical-line records, subtree length/count aggregates, split/join/rebalance operations, and deterministic ordered iteration.
- [ ] 2.2 Implement the persistent stable-line-ID lookup and exact UTF-16 offset, line ordinal, line range, and neighboring-line queries without complete line scans.
- [ ] 2.3 Implement boundary summaries and chunk-safe handling for LF, CRLF, CR, NEL, line separator, paragraph separator, surrogate pairs, combining marks, empty text, and final structural lines.
- [ ] 2.4 Refactor `DocumentSnapshot` into a `Sendable` immutable indexed root with deliberate flat text/line materialization and no mutable coordinator back-reference.
- [ ] 2.5 Preserve the existing persistence envelope by flattening indexed roots to canonical text and absolute line metadata and reconstructing/fully validating equivalent roots on decode.
- [ ] 2.6 Add storage-lifetime instrumentation and tests proving unchanged subtree sharing and release of roots/chunks when bounded consumers finish.

## 3. Incremental transaction and validation engine

- [ ] 3.1 Add the exact UTF-16 replacement transaction and use indexed split/join operations to rebuild only the affected logical-line window and required newline-neighbor context.
- [ ] 3.2 Implement local proof for ranges, aggregates, line partitions, identity uniqueness, timestamps, landmark attachment, invocation anchors/locks/remapping, document identity, and single revision advancement.
- [ ] 3.3 Implement indexed metadata-only landmark operations and explicit bulk replacement/restore paths with atomic publication and stale-revision rejection.
- [ ] 3.4 Add complete validation for decoded, migrated, pre-encode, recovery, restore, explicit-integrity, bulk, and reference-test boundaries.
- [ ] 3.5 Add coalesced asynchronous complete validation for debug builds with loud invariant reporting and stale-root result rejection outside the input callback.
- [ ] 3.6 Dual-run incremental transactions against the retained complete-scanning reference implementation until all parity suites pass, then remove synchronous full validation from ordinary edits.

## 4. Native editing and bounded undo

- [ ] 4.1 Change the AppKit edit adapter to capture and submit exact affected ranges and replacements without reading, comparing, or copying the complete text view for ordinary commits.
- [ ] 4.2 Preserve marked-text provisional behavior and implement the bounded commit-time UTF-16 diff fallback plus an explicit bulk classification for genuinely unbounded Services/external replacements.
- [ ] 4.3 Integrate immediate lossless startup-prefix reconciliation with the incremental replacement path while preserving stored identity, selection, focus, newline, and one-group undo semantics.
- [ ] 4.4 Store undo/redo entries as shared before/after roots with selection/restoration facts and enforce 200 whole groups plus the 256 MiB retained-payload estimate without splitting the newest group.
- [ ] 4.5 Verify native typing, paste, Services, IME, selection, focus, viewport, Undo/Redo, and accessibility behavior through the prepared Wave 2 editor boundaries.

## 5. Tool document patches

- [ ] 5.1 Define bounded atomic document patches for ordered nonoverlapping replacements and landmark/invocation insert/update/remove operations with revision, anchor, hash, lifecycle-generation, and package-generation preconditions.
- [ ] 5.2 Translate reducer-authorized publication, Merge, Dismiss, and restoration effects into document patches and return typed success/rejection actions to the headless lifecycle.
- [ ] 5.3 Apply each tool patch through the authoritative coordinator's incremental primitives and prove all-or-nothing text plus annotation publication.
- [ ] 5.4 Remove temporary `DocumentCoordinator` construction and the trusted `.tools(DocumentSnapshot, edit:, replacementLength:)` mutation shortcut.
- [ ] 5.5 Add headless and native integration tests for stale preconditions, cancellation/completion races, locked ranges, undo/redo, persistence round trips, and bounded work in large documents.

## 6. Persistence and history background boundaries

- [ ] 6.1 Make persistence change notification perform only immutable-root capture and revision ordering/coalescing bookkeeping on the main actor.
- [ ] 6.2 Move complete pre-encode validation, flattening/streaming encode, recovery-checkpoint construction, and SQLite save work into bounded owned background tasks that acknowledge exact revisions.
- [ ] 6.3 Move history retain, decode, comparison, pruning, and restore preparation onto bounded immutable background roots and release superseded roots promptly.
- [ ] 6.4 Preserve manual flush, autosave, retry, committed-revision, recovery, ownership, and stale-completion behavior under injected slow/failing workers.
- [ ] 6.5 Preserve the private-data purge boundary `P`, old-store write barrier, replacement validation/swap order, and later in-memory descendant edits under background preparation.
- [ ] 6.6 Add peak-memory, coalescing, cancellation, root-release, and input-responsiveness tests for concurrent save/history/recovery/purge work.

## 7. Correctness, performance, and rollout gates

- [ ] 7.1 Add deterministic seeded and shrinking reference-model tests across Unicode/newline boundary edits, metadata, invocations, startup merge, undo/redo, encode/decode, and restoration.
- [ ] 7.2 Add blocking structural tests proving localized document work and viewport presentation work remain within affected-region/index-path and visible-fragment/overscan bounds.
- [ ] 7.3 Split performance reporting into interaction acceptance/visibility, prepared presentation convergence, and background save/history/recovery/restore distributions for debug and optimized builds.
- [ ] 7.4 Capture post-change results on the checked reference runner, document absolute and relative variance, and submit any budget recalibration as an explicit evidence-bearing manifest diff rather than a self-adjusting test.
- [ ] 7.5 Run formatter, project generation, first-party analysis, Foundation/native/UI suites, persisted backward-compatibility fixtures, recovery/private-data failure injection, and strict OpenSpec validation.
- [ ] 7.6 Remove the flat live-model comparison path only after parity and gates pass, then document the incremental transaction/query APIs and measured limitations for future contributors.
