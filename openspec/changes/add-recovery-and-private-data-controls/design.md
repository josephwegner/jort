## Context

Jort's persistence design favors recoverability: current state lives in SQLite WAL mode; two manifest-selected recovery slots and a legacy recovery file can exist; migrations and damage recovery preserve full directory backups; atomic swaps can leave old `.Replacement-*` directories; and local history protects recent revisions and every milestone from ordinary pruning. That durability is valuable, but a user who removes a secret from the visible document has no way to remove the older Jort-managed copies.

The recovery reader also calls `Data(contentsOf:)` for the manifest, legacy file, and slot before `PersistenceFormat.decode` enforces the 64 MiB payload cap. A regular file can therefore be allocated in full before rejection, and current path checks do not provide one reusable no-follow, bounded-read primitive.

The README and native storage spec already promise Command-S retry and Save Recovery Copy. `EditorViewController` implements the export panel and the nonmodal notice can invoke it, but the File menu contains only Close Window. The existing UI test can mistake an independent autosave success for Command-S behavior.

This design preserves the active startup contract: loading remains editable; failed load enters a non-writing recovery-editing state; ownership conflict remains terminal. It also respects the presentation-lifecycle proposal by driving menus and recovery UI from typed state rather than paint-time mutation.

## Goals / Non-Goals

**Goals:**

- Provide real, testable File-menu Save/Retry Save and Save Recovery Copy actions without promoting recovery into Pocket.
- Reject oversized, linked, special, or structurally unexpected recovery files before unbounded allocation or decode.
- Surface typed, actionable recovery outcomes while leaving the source unchanged on failure.
- Let the user establish a purge boundary that removes every older Jort-managed logical copy while preserving the authoritative current snapshot and all later accepted edits.
- Make purge atomic at the current-store boundary, crash-resumable, and honest about incomplete cleanup.
- Bound automatically retained diagnostic backups by age and count after healthy verification.
- State the limits of logical deletion accurately.

**Non-Goals:**

- Forensic overwrite of APFS blocks, filesystem snapshots, swap, Time Machine, cloud/external backups, or user-selected recovery exports.
- Per-store encryption, key rotation, or crypto-erasure.
- Importing a recovery copy into the canonical store or defining conflicts for such an import.
- Weakening two-slot recovery, milestones, or normal history retention outside an explicit confirmed purge.
- Purging another process's store, a future-version store, or a source that has never loaded into a verified authoritative state.

## Decisions

### Route persistence commands through typed editor actions

Add three explicit editor-facing actions:

- `Save` requests an immediate flush of the newest authoritative in-memory snapshot when the loaded store is dirty or writing.
- `Retry Save` uses the same Command-S action when a save failure episode needs a manual retry, resets the bounded retry budget, and targets the newest in-memory snapshot.
- `Save Recovery Copy…` exports the current in-memory snapshot (or the committed startup/recovery-editing draft representation) to a user-selected versioned JSON file without modifying or importing the source store.

The File menu dynamically presents `Save` or `Retry Save` from typed persistence state, assigns Command-S, and validates enablement through the active editor. During unresolved startup, ownership conflict, or a future-version refusal, canonical Save is disabled because no loaded store is safe to overwrite. Recovery copy remains available whenever the editor can produce a coherent export snapshot. A clean loaded snapshot makes Save a no-op or disables it according to standard AppKit validation.

`PersistenceController` exposes an awaitable/callback result identifying no-op-clean, saved revision, already-writing/coalesced, retry failure, or unavailable state. Tests inject a store whose autosave cannot independently satisfy the expectation and assert that the menu action caused the observed write attempt.

Adding recovery actions to Pocket was rejected because recovery should remain contextual and quiet. Treating Command-S as a generic `retry()` selector was rejected because healthy dirty saves and failed retries have different state transitions even though they share the shortcut.

### Represent recovery attention and maintenance as typed state

Extend persistence-facing state with bounded value types for recovery source role, rejection reason, recovery disposition, and maintenance progress. Reasons distinguish missing, oversized, non-regular, symbolic link, unexpected hard link, read changed/exceeded bound, malformed, checksum mismatch, unsupported version, and IO failure without requiring UI to parse error strings.

Outcomes include normal load, automatic recovery from a verified slot/legacy candidate, recovery candidates rejected with the original source preserved, load failure with editable in-memory work, purge preparing/swapping/cleaning, purge incomplete with known remaining managed copies, and purge complete. AppKit maps these values to localized copy and actions.

Successful automatic corruption recovery may remain automatic, but Jort shows a concise nonmodal notice that a damaged backup was preserved and gives access to relevant storage actions. If no verified candidate exists, Jort never creates an empty canonical store. It enters the Wave 1 non-writing recovery-editing state and explains what remains untouched and whether the user can retry, continue in memory, export a copy, or confirm removal of specifically rejected unusable recovery files.

Removal of rejected recovery files is narrower than the full purge, requires confirmation, operates only on the fixed rejected candidate paths recorded by the current load attempt, and never deletes the SQLite source or diagnostic backups. A differently typed error does not silently broaden that target set.

### Read recovery payloads through directory-relative no-follow descriptors

Add one bounded regular-file reader in Persistence. It opens the already validated store directory with `O_RDONLY | O_DIRECTORY | O_CLOEXEC`, then opens a fixed direct-child filename with `openat` using `O_RDONLY | O_NOFOLLOW | O_CLOEXEC`. It immediately calls `fstat` and requires:

- a regular file;
- link count exactly one;
- a nonnegative advertised size no greater than the role limit; and
- no directory or path traversal supplied by persisted metadata.

The manifest role receives a small explicit cap (64 KiB). The legacy recovery and two fixed slot roles receive `PersistenceFormat.maximumBytes` (64 MiB). Reading uses fixed-size chunks and stops at at most limit plus one byte, so a file that grows after `fstat` is rejected without allocating beyond the bound. EOF before the advertised size, read errors, and post-read metadata inconsistency reject the candidate. Decode occurs only after the bounded bytes are complete.

The manifest may select only slots 0 and 1; stored data never supplies a filename. The same primitive is used for post-publication recovery verification. Recovery-copy export remains a write-only user-selected operation and is not treated as a candidate for automatic import.

Checking `URLResourceValues` before `Data(contentsOf:)` was rejected because path replacement between calls can reintroduce link/type races. Memory mapping was rejected because it obscures allocation/fault behavior and does not enforce the streaming cap as directly.

### Inventory only exact Jort-managed copies

Define an internal managed-copy inventory rooted at the owned data directory. It recognizes the active `Store` bundle and direct children with exact generated naming contracts for `PreMigration-*`, `Damaged-*`, `.Replacement-*`, `.Inspect-*`, `.HistoryInspect-*`, and known staging/checkpoint temporaries. It recognizes only a valid UUID suffix or the new timestamp-plus-UUID suffix. Within the active or staged bundle it recognizes only declared SQLite companions, recovery names, and maintenance markers.

Inventory enumeration is bounded, directory-relative, and no-follow. Unexpected names, special files, and symbolic links are never traversed or classified as Jort-managed content; they produce a diagnostic when they block an expected operation. Cleanup never resolves a user-supplied path and never leaves the data root.

User-selected recovery exports and external filesystem backups are explicitly outside this inventory. The UI describes purge as removing “history and recovery data managed by Jort on this Mac,” not as secure erase.

### Use a durable purge marker and a current-only replacement

`Clear History and Recovery Data…` is available only after Jort has loaded a verified authoritative document while holding the store lock. It remains available when ordinary saving is unhealthy because rebuilding can be the recovery path. It is unavailable during initial load, recovery editing without a valid loaded source, future-version refusal, or ownership conflict.

Confirmation states that all history revisions and milestones, recovery checkpoints, and Jort diagnostic backups will be removed; the current document will remain; the action cannot remove exported copies or system backups; and ordinary new edits can create new recovery/history data after the purge boundary.

On confirmation, the main actor captures the exact authoritative snapshot `P` and establishes a persistence barrier. Editing remains available; accepted later snapshots are queued as post-boundary work and are never written into the old store. History retention is paused and its pending pre-boundary work is discarded for this operation.

The storage actor then:

1. Creates a uniquely named, no-follow purge replacement under the owned data root.
2. Creates a fresh current schema and writes only `P`; it copies history settings if valid but inserts no history revisions.
3. Publishes only the minimum valid recovery checkpoint/manifest required for `P`; it creates no legacy `Recovery.json`.
4. Executes `wal_checkpoint(TRUNCATE)`, closes every SQLite handle, syncs the files/directories, reopens read-only for verification, and proves the current snapshot equals `P`, history is empty, and no unexpected WAL payload or managed copy exists in the replacement.
5. Writes and syncs a bounded text-free purge marker containing operation ID, document ID, baseline revision/hash, recognized replacement name, phase, and cleanup targets.
6. Atomically swaps the replacement with `Store`, syncs the parent, reopens and verifies the new active store, and advances the marker phase.
7. Removes the swapped old store and every recognized pre-boundary diagnostic/replacement/inspection/staging copy, syncing affected directories.
8. Deletes and syncs the marker only after inventory proves no known pre-boundary managed copy remains, then reports success and releases queued post-boundary saves/history to the new store.

If edits occur after `P`, they stay authoritative in memory and are persisted only after the new store is active. The deletion promise applies to content absent from `P` and copies existing at the confirmed boundary; post-boundary edits are ordinary new data and may create fresh checkpoints/history after success.

Deleting history rows and running `VACUUM` in the existing database was rejected because recovery slots, backups, and old SQLite pages remain separate concerns and a partially failed in-place operation is harder to recover. Overwriting files was rejected because it is unreliable on APFS and would overstate the security guarantee.

### Resume or safely stop an interrupted purge

The purge marker and exact stage name make every phase deterministic:

- Before swap, `Store` remains authoritative; an intact validated replacement can be discarded or the operation retried, and no cleanup of old data is reported as complete.
- If a crash occurs around the swap, relaunch validates both exact locations against the marker. If active `Store` is the verified current-only baseline, Jort resumes cleanup. If `Store` is the old verified bundle and the stage is the current-only candidate, Jort leaves the old store authoritative and reports the purge incomplete. If neither relationship can be proven, it preserves both and enters recovery attention rather than guessing.
- After the new store is verified, cleanup failure never swaps the old store back. Jort reports an incomplete purge with the remaining recognized copies and offers Retry Cleanup. It does not report successful deletion until inventory and directory sync succeed.

Failure injection covers every create/write/checkpoint/close/validate/marker/swap/reopen/remove/sync phase. At every stop point, either the original valid store or the validated current-only replacement remains recoverable.

### Bound diagnostic backup retention independently of purge

New diagnostic directories use names containing a UTC creation timestamp and UUID. Legacy UUID-only directories use no-follow directory metadata as their best available age/order signal. After—and only after—the process owns and verifies a healthy canonical `Store`, automatic maintenance evaluates `PreMigration` and `Damaged` classes independently:

- retain no more than the two newest verified directories in each class; and
- retain no directory older than 30 days.

Both limits apply, so a class may retain zero, one, or two backups. Oldest excess/expired recognized directories are removed and parent changes synced. A cleanup failure does not make the healthy current store unavailable, but it creates a typed maintenance warning and the explicit purge remains able to retry. No automatic deletion runs while load is blocked, the active store is unhealthy/unverified, ownership is absent, a purge is unresolved, or a candidate is a link/special/unrecognized entry.

Keeping backups forever was rejected because they silently retain sensitive text. Keeping only a count with no age limit was rejected because a rarely used app could retain a secret indefinitely. A 30-day/two-copy policy balances short-term migration diagnostics with a bounded privacy exposure.

## Risks / Trade-offs

- **Risk: A purge removes the last useful damaged-store diagnostic.** → Require explicit confirmation, preserve the verified current boundary snapshot first, and make the scope clear; automatic retention runs only after healthy verification.
- **Risk: File replacement races bounded validation.** → Use directory-relative `openat`, `O_NOFOLLOW`, immediate `fstat`, fixed filenames, link-count checks, and bounded reads on the opened descriptor.
- **Risk: Continuous editing complicates a stable purge snapshot.** → Establish an explicit boundary snapshot and persistence barrier; continue accepting edits in memory and write them only to the new store after old-copy cleanup.
- **Risk: Cleanup fails after the new store is active.** → Keep the new store authoritative, retain a durable marker and remaining-copy inventory, expose Retry Cleanup, and never claim success early.
- **Risk: Legacy backup timestamps are imprecise.** → Use conservative no-follow metadata for legacy ordering, adopt timestamped names going forward, and never delete unrecognized or ambiguous entries automatically.
- **Risk: Full history purge surprises a user who relies on milestones.** → Use explicit destructive confirmation that names milestones/history and leave ordinary pruning rules unchanged.
- **Trade-off: The fresh store still contains the permitted boundary snapshot in SQLite and minimum recovery material.** → The purpose is to remove older/deleted content while preserving the current document, not to eliminate all copies of current content.
- **Trade-off: APFS or external backups may retain old blocks/content.** → State the logical deletion boundary in UI and documentation; reserve strong erasure for a separately designed encrypted store with crypto-erasure.

## Migration Plan

1. Add typed recovery roles/rejection/disposition and maintenance states plus controlled failing-store/menu characterization tests.
2. Implement and fuzz the directory-relative bounded regular-file reader; route manifest, legacy recovery, slot loading, and post-publication verification through it.
3. Add File-menu Save/Retry Save and Save Recovery Copy actions with state validation, awaitable results, accessibility/localization, and tests that prevent autosave from masking Command-S.
4. Add actionable recovery notices for automatic recovery and rejected/unavailable candidates while preserving Wave 1 recovery-editing and ownership behavior.
5. Add exact managed-copy naming, bounded no-follow inventory, timestamped new diagnostic backups, and healthy-store-only two-per-class/30-day retention.
6. Add purge marker/state, persistence barrier, current-only replacement construction, WAL truncation, full validation, atomic swap, cleanup inventory, and crash resumption.
7. Add the confirmed File-menu purge and Retry Cleanup UI, with editing continuity and precise logical-deletion copy.
8. Add failure injection for every purge boundary and fixtures for history milestones, free pages, WAL/SHM, both recovery slots, legacy recovery, diagnostic backups, replacements, inspections, staging data, links, and unknown entries.
9. Run strict OpenSpec validation, persistence/history suites, startup/recovery native suites, menu/UI tests, crash-resumption tests, and a post-purge raw managed-file scan for deleted sentinel text.

Rollback before a purge is used is source-only. Once the new naming policy or a completed purge has run, an older build can still open the unchanged current SQLite schema and recovery checkpoint format; removed history/backups are intentionally not reconstructible. An unresolved purge marker must be handled by the new build or manually preserved—not ignored by a rollback build during validation.

## Open Questions

- Choose the exact public names for typed maintenance results and the File-menu purge item during implementation while preserving the specified states and copy.
- Confirm whether the base recovery checkpoint requirement can safely use one manifest entry after a fresh purge or whether current recovery publication always creates a two-slot structure over subsequent saves; no old pre-boundary slot may be copied.
- Decide where the nonfatal diagnostic-retention warning is surfaced when storage is otherwise healthy, consistent with the presentation-lifecycle and localization policies.
