## 1. Characterize State and Failure Boundaries

- [ ] 1.1 Add controlled store fixtures that independently block/fail load, autosave, manual Save, retry, recovery publication, history, and cleanup so tests cannot pass from unrelated persistence activity.
- [ ] 1.2 Add current-layout fixtures containing history revisions and milestones, SQLite free pages/WAL/SHM, legacy and two-slot recovery, `PreMigration-*`, `Damaged-*`, `.Replacement-*`, inspection, checkpoint, and abandoned staging data with unique sentinel content.
- [ ] 1.3 Define typed recovery source roles, rejection reasons, recovery dispositions, explicit save outcomes, purge phases/results, remaining-copy reports, and nonfatal maintenance warnings without embedding AppKit copy.
- [ ] 1.4 Extend failure-injection stages for bounded read, inventory, replacement creation, WAL checkpoint, marker publication, swap, reopen, cleanup removal, and directory sync.

## 2. Bound Recovery File Ingestion

- [ ] 2.1 Implement a directory-relative regular-file reader using fixed child names, `openat`, `O_NOFOLLOW`, `fstat`, regular-file and single-link checks, fixed-size chunks, and a limit-plus-one growth check.
- [ ] 2.2 Apply the 64 KiB manifest limit and 64 MiB payload limit before decode for `Recovery-manifest.json`, `Recovery.json`, `Recovery-0.json`, and `Recovery-1.json`.
- [ ] 2.3 Route checkpoint post-publication verification through the same opened-descriptor bounded reader and eliminate `Data(contentsOf:)` from recovery candidate paths.
- [ ] 2.4 Add tests for exact-limit and over-limit regular/sparse files, symlinks, hard links, directories/devices/FIFOs, truncation/growth during read, malformed manifests, arbitrary slot/path attempts, checksum mismatch, and supported/future payloads.

## 3. Add Explicit Save and Recovery Commands

- [ ] 3.1 Add typed immediate-save behavior that distinguishes clean no-op, dirty Save, coalesced in-flight Save, exhausted-failure Retry Save, failure, and unavailable source while always using the newest authoritative loaded snapshot.
- [ ] 3.2 Add dynamic File-menu Save/Retry Save with Command-S and menu validation for loading, clean, dirty, writing, failed, future-version, ownership-conflict, recovery-editing, and purge states.
- [ ] 3.3 Add File-menu Save Recovery Copy using the newest coherent loaded or recovery-editing snapshot and preserve the existing native save-panel/versioned-JSON behavior without importing or healing the source.
- [ ] 3.4 Add accessibility and localization for command titles, state, success, failure, and export results, and verify neither command appears in Pocket.
- [ ] 3.5 Add native/UI tests proving Command-S itself starts the expected store attempt while autosave is blocked and proving recovery export works without changing unhealthy source files.

## 4. Surface Actionable Recovery State

- [ ] 4.1 Propagate bounded recovery role/rejection/disposition values through `SQLiteStore` and `PersistenceController` while preserving unsupported-version and ownership semantics.
- [ ] 4.2 Present automatic recovery and failed-candidate outcomes through concise localized nonmodal or launch-context UI that states what was preserved and offers only valid Retry, Continue in Memory, Save Recovery Copy, or cleanup actions.
- [ ] 4.3 Preserve Wave 1 immediate startup typing, marked-text deferral, typed recovery-editing state, native selection/undo, and the prohibition on source writes after failed load.
- [ ] 4.4 Add confirmed rejected-recovery cleanup constrained to the fixed candidates from the current failed attempt, with no-follow deletion and no SQLite/backup/unknown-entry removal.
- [ ] 4.5 Add recovery tests for valid newest/older slot fallback, legacy fallback, automatic damaged-store recovery, every typed rejection, no-valid-candidate recovery editing, cleanup cancellation/success/failure, and unchanged source bytes.

## 5. Inventory and Retain Managed Copies

- [ ] 5.1 Define exact bounded direct-child naming and role rules for active Store files, timestamp-plus-UUID and legacy diagnostic backups, replacements, inspections, checkpoint temporaries, purge replacements, and maintenance markers.
- [ ] 5.2 Implement no-follow managed-copy inventory that rejects traversal, never leaves the owned data root, bounds enumeration, and reports unrecognized/link/special entries without classifying their targets as managed content.
- [ ] 5.3 Name new `PreMigration` and `Damaged` backups with durable UTC timestamp plus UUID metadata while retaining safe recognition of legacy UUID-only backups.
- [ ] 5.4 After healthy owned-store verification only, remove backups older than 30 days and all but the two newest in each diagnostic class, sync the parent, and expose cleanup failure as a nonfatal typed warning.
- [ ] 5.5 Add retention/inventory tests for independent classes, count and age intersections, legacy ordering, clock boundaries, unhealthy/future/ownership/purge states, links/special/unknown entries, interrupted cleanup, and parent-sync failure.

## 6. Build the Current-Only Purge Store

- [ ] 6.1 Add a persistence barrier that captures authoritative boundary snapshot P, prevents old-store save/history publication, discards pending pre-boundary history work, and queues later accepted edits without blocking native editing.
- [ ] 6.2 Build a uniquely named fresh current-schema replacement containing exactly P, valid history settings but no history rows, and only minimum newly generated recovery checkpoint/manifest data.
- [ ] 6.3 Checkpoint/truncate replacement WAL, close all SQLite handles, sync files/directories, reopen for verification, and prove exact snapshot/hash/revision, empty history, valid recovery, current schema, and no unexpected residue.
- [ ] 6.4 Add raw managed-file sentinel scanning in tests to prove deleted pre-boundary history/recovery text is absent from the validated replacement before swap.

## 7. Publish, Resume, and Finish Purge

- [ ] 7.1 Define and durably publish the bounded text-free purge marker with operation ID, document ID, baseline revision/hash, exact stage name, phase, and recognized cleanup targets.
- [ ] 7.2 Atomically swap the validated replacement with `Store`, sync the data root, reopen and verify the new active store, and advance the marker before classifying the swapped old bundle as removable.
- [ ] 7.3 Remove and sync the swapped old store plus every recognized pre-boundary history, recovery, diagnostic, replacement, inspection, checkpoint, and staging copy without following links.
- [ ] 7.4 Prove cleanup inventory is empty before deleting/syncing the marker, reporting success, releasing the persistence barrier, and publishing queued post-boundary edits/history only to the new store.
- [ ] 7.5 Implement launch-time marker reconciliation that can abandon pre-swap preparation, resume cleanup for a proven active current-only store, retain the old authoritative store, or preserve both and request attention when state is ambiguous.
- [ ] 7.6 Keep the new store authoritative and expose Retry Cleanup when removal/sync fails after swap; never roll back to or report deletion of a known remaining old copy.
- [ ] 7.7 Add failure/crash tests at every preparation, marker, swap, reopen, removal, and sync boundary and verify either the original store or current-only replacement remains recoverable with later edits intact.

## 8. Expose and Verify the Private-Data Workflow

- [ ] 8.1 Add File-menu Clear History and Recovery Data with typed availability and a localized keyboard/VoiceOver-accessible confirmation naming milestones, current preservation, and logical-deletion limits.
- [ ] 8.2 Add preparing/swapping/cleaning/incomplete/completed presentation and Retry Cleanup without stealing focus; keep editing responsive and keep purge/recovery actions out of Pocket.
- [ ] 8.3 Add end-to-end tests for cancellation, healthy and save-failed purge, typing after boundary capture, every history/recovery/backup class, partial cleanup, relaunch resumption, inaccessible actions, and fresh history created only after completion.
- [ ] 8.4 Verify successful purge leaves exact boundary/current text, valid minimum new recovery material, no pre-boundary revisions or milestones, no old WAL/free-page/backup/replacement sentinels in any managed file, and no false physical-erasure claim.
- [ ] 8.5 Run strict OpenSpec validation, formatting/static checks, persistence/history/failure-injection suites, startup/recovery AppKit suites, File-menu/UI/accessibility tests, and full native regression checks.
- [ ] 8.6 Document bounded recovery ingestion, recovery actions, the two-per-class/30-day backup policy, purge crash recovery, external-copy exclusions, and the deferred encryption/crypto-erasure boundary.
