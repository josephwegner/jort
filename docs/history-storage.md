# History storage foundation

`build-jort-run-history-search` adds retained-revision storage, checkpoint scheduling, pruning, recovery preservation, the history workspace, and current-document search. Release qualification remains open; see `run-verification.md`.

## Ownership and format

`SQLiteStore` implements both `DocumentStore` and `HistoryStore`. Its existing actor and ownership lock remain the only path to the database. History operations require a successful current-state load and reject snapshots belonging to another document. No AppKit types or mutable document state enter storage.

SQLite schema 4 adds `history_revisions` and `history_settings`. Current-state payloads remain version 3. The existing staged migration preserves the original database and recovery material before installing the new schema. Normal current-state loading does not enumerate history rows, decode history envelopes, or create retained revisions. The coordinator is created on the first edit, and seeds the verified initial state when the first retention boundary runs.

`HistoryRevisionFormat` version 1 wraps a validated complete persistence payload in a checksummed envelope. It records revision UUID, document UUID, live generation, timestamp, reason, milestone status, compression codec, uncompressed length, payload hash, and state hash. LZFSE compression falls back to raw bytes when compression is not smaller. Decoding bounds compressed-envelope input and uncompressed output before publishing a snapshot, validates the inner persistence payload, and checks all envelope-to-snapshot identities.

The state hash excludes only the live generation. Text, line IDs and timestamps, document identity, and attached/detached landmark records participate. Exact repeated state therefore deduplicates even after an undo creates a new generation. A duplicate is skipped only after the stored envelope is decoded and verified; a corrupt prior revision cannot satisfy a future pre-restore preservation request. Promoting a duplicate to a milestone rewrites that same revision transactionally while retaining its identity and timestamp.

## Isolation and ordering

Revision insertion, read-back validation, and commit form one SQLite transaction. Fault injection covers each boundary. Failed history writes do not change the current-state autosave or recovery-checkpoint success contract.

The list API pages by a monotonic SQLite sequence, not by timestamps or live generation. It reads bounded metadata without decoding snapshot payloads. A damaged metadata row remains represented by its sequence with unavailable metadata, preserving access to neighboring rows. Selection verifies both the envelope and its agreement with the list metadata. History schema validation runs on history access, so history-table damage does not itself disable current-state loading or saving.

Settings are validated and durable. Each checkpoint is followed by transactional pruning on the storage actor, deleting the oldest eligible rows until their serialized byte total meets the budget. The minimum recent count, milestones, and rows with unverifiable metadata are protected. If those protections prevent meeting the budget, the editor reports that condition rather than deleting protected revisions. SQLite can reuse freed pages; the policy budgets serialized history data rather than claiming an exact physical file-size limit.

Recovery inspects a private copy and carries verified revisions and valid settings into the staged replacement while retaining revision UUIDs and sequence numbers. Unreadable history is preserved in the original diagnostic backup, and a durable `HistoryRecoveryIncomplete` marker reports the partial recovery independently of the current document's health. A destination write failure aborts replacement, leaving the original database intact. A future schema is refused.

## Scheduling

`HistoryCoordinator` accepts immutable snapshots and typed `HistoryBoundary` values. An injectable clock and delay support deterministic boundary tests. Ordinary edits reset an idle timer; semantic boundaries queue snapshots in order. A serialized task chain drains those boundaries without starting concurrent history writers. Persistence retains its existing half-second autosave cadence and independent retry state.

Deactivation, window close, and termination call `flushLifecycle`. Current-state saving completes before that lifecycle history attempt, and shutdown waits for the attempt. If edits arrive while history is completing, the lifecycle operation drains the new current state before reporting completion. History failures appear separately in the footer and do not classify a successful current-state save as failed; Command-S retries retention after saving. Restore transactions request a semantic boundary.

## History workspace

`HistoryBrowserModel` owns paged revision discovery and cancellable selected-pair loading. The rail loads additional metadata pages as scrolling approaches the end and computes compact change counts for visible rows. Only counts are cached for those rows. `HistoryComparison` derives presentation rows from verified immutable snapshots off the main actor, using stable line identities and an O(n log n) ordered-subsequence comparison. It is never a restore format. An unavailable immediate predecessor disables Changes instead of silently comparing a different pair.

`HistoryWorkspaceController` owns read-only Snapshot and Changes views, the revision rail, confirmation, and contextual footer. Restore and Done live in a separated action area inside the rail. Snapshot uses the historical logical-line gutter; Changes uses a dark compact gutter with landmarks before old/new ordinals, explicit markers, contiguous change blocks, and visible expansion buttons. Dismissal returns the live selection, viewport, footer, and focus without changing the document.

Restore revalidates the chosen revision and durably preserves the current complete state as a milestone before publishing any mutation. It rejects a live generation change during that await. The document coordinator then applies one full-state transaction with native grouped Undo/Redo, including selection and viewport restoration. Current-state persistence remains independent of derived comparisons.

`HistoryWorkspaceTests` covers preview modes, historical landmarks, narrow-window geometry, focus and footer restoration, superseded selections, corruption, confirmation cancellation, keyboard context expansion, failed preservation, concurrent live changes, full-state Undo/Redo, and reopening the restored database. Physical VoiceOver and normative-hardware performance checks remain release gates.

## Verification

`HistoryStorageTests` covers full-state and Unicode round trips, generation-independent deduplication, milestone promotion, corrupt or unsupported envelopes, bounded decoding, document ownership, reopening, damaged metadata, payload substitution, transaction rollback, concurrent retention, sequence-based paging, settings validation, migration from schema 3, typing coalescence, semantic ordering, idle timing, pruning protections and rollback, storage growth, partial recovery, destination write failure, autosave independence, and edits during shutdown. Existing foundation and native editor suites remain regression gates.
