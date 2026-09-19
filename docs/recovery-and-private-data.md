# Recovery and private data

File → Save (⌘S) immediately requests the newest loaded in-memory revision. After a
save failure it becomes Retry Save and starts a fresh bounded retry episode. A clean
document needs no write. Save is unavailable until startup has established a safe
source, and while a purge is holding later edits in memory.

File → Save Recovery Copy… exports the newest coherent document to a user-chosen,
versioned JSON file. This works while editing after a failed load. It does not import
the export, overwrite the damaged source, or mark that source healthy. Recovery and
purge commands are deliberately absent from Pocket.

## Bounded recovery

Recovery candidates are fixed direct children: `Recovery-manifest.json`,
`Recovery-0.json`, `Recovery-1.json`, and the legacy `Recovery.json`. The manifest is
limited to 64 KiB, payloads to 64 MiB. Directory-relative no-follow descriptors,
regular-file/single-link checks, 16 KiB reads, and a limit-plus-one growth check
precede decoding. Truncated or changing files are rejected. Persisted metadata
cannot select an arbitrary filename. Publication verification uses the same reader.

The newest valid advertised slot wins, then an older advertised slot, then legacy
recovery. A future-version manifest or payload stops recovery rather than silently
downgrading it. Typed results distinguish missing, oversized, linked, nonregular,
changing, malformed, checksum-invalid, unsupported, and unreadable candidates.
Automatic recovery preserves the old bundle and reports recovery nonmodally.
Without a usable candidate, source files remain intact and typing stays in memory.

Remove Rejected Recovery Files requires confirmation and only removes fixed files
recorded by the current failed attempt whose identity has not changed. It unlinks
links themselves without following them; directories, SQLite files, diagnostic
backups, exports, and unknown files are not cleanup targets.

## Diagnostic retention

Only after an owned canonical store has been verified does automatic maintenance
retain at most two `PreMigration` and two `Damaged` backups, independently. Both
classes also have a 30-day maximum age. New names contain a UTC creation timestamp
and UUID. Legacy UUID-only names use no-follow creation metadata (modification time
when creation time is unavailable). Unknown or linked entries are preserved.
Removal and directory-sync failures produce nonfatal maintenance warnings.

## Clear History and Recovery Data

The File menu confirmation names revisions, milestones, recovery checkpoints, and
diagnostic backups. Cancel changes nothing. Confirm captures the exact current
snapshot P, drains in-flight persistence/history work, and discards queued old
history. Editing continues; later accepted edits wait in memory for cleanup.

A fresh database receives exactly P, valid history settings, no history rows, a
unique text-free operation identity, and one newly generated recovery slot plus its
manifest. It is WAL-checkpointed, switched to DELETE journal mode, closed, synced,
and verified through an immutable read-only connection after proving WAL is empty.
The operation identity distinguishes it from an older database with identical text
but potentially different free pages. Ordinary WAL mode resumes for its active writer.

A bounded text-free `Purge.json` marker records the operation, baseline identity and
hash, original hash, exact stage name, phase, and fixed cleanup targets. The verified
replacement is atomically swapped with Store, the root synced, and the new active
store reverified before old copies become removable. Cleanup handles declared
SQLite companions, recovery files, diagnostic directories, replacements, inspections,
and checkpoint/purge staging. Exact-name, bounded no-follow inventory gates every
removal. Unknown, linked, and special entries are preserved and can prevent completion.

After a crash, the marker and replacement operation identity prove whether to retain
the original store or resume cleanup of old copies. Ambiguous relationships preserve
both candidates and block source writes. A failed post-swap cleanup never rolls back
the new store: the UI offers Retry Cleanup, and accepted edits remain in memory until
cleanup finishes. No success is reported while known old managed copies remain or
required directory sync has failed. Abandoned preparation is reported as not cleared.
The marker is removed only after cleanup verification; subsequent edits may create a
new ordinary history/recovery timeline.

This removes **logical copies managed by Jort on this Mac**. It does not physically
overwrite APFS blocks or erase filesystem snapshots, Time Machine, cloud/external
backups, swap, or user-exported recovery copies. Reliable stronger erasure requires a
separate encrypted-store/key-destruction design; encryption and crypto-erasure are
not provided by this operation.
