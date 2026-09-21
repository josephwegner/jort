# Incremental document interactions

`DocumentCoordinator` owns one immutable `DocumentSnapshot` root. Ordinary input
submits `.replace(range:text:)`; UTF-16 offsets are canonical. The coordinator
rejects a stale base revision before doing document work, constructs the changed
root privately, and publishes one revision and one callback only after validation.
Programmatic line insertion and metadata changes use the same indexed boundary.

## Queries and materialization

Use `utf16Count`, `lineCount`, `line(id:)`, `line(at:)`,
`line(containingUTF16Offset:)`, `ordinal(of:)`, `utf16(in:)` and `text(in:)`.
`lines` is a read-only random-access `DocumentLineView`; iteration is ordered.
Snapshot equality compares shared roots first and streams values when needed.

`text`, `lines.materialized()` and `validatedMaterialization()` are deliberate
full-document operations. Encoding, export, search and integrity workers may use
them. Input, completion, viewport geometry and stable-ID lookup must not. The
legacy `.edit(text:range:replacementLength:)` API is a fully validated bulk
compatibility boundary; new interactive callers must use exact replacement.
`DocumentState` remains the complete-scanning reference and local-window lineage
implementation, not the coordinator's live storage.

## Representation and local proof

The persistent logical-line sequence uses fanout 16 and leaves of at most 16
records. UTF-16 text uses immutable chunks of at most 2,048 units. Subtrees carry
length/count aggregates. A persistent radix index uses all 128 UUID bits plus a
node/line namespace to resolve stable IDs through relative parent addresses.
Full construction builds final radix nodes directly; local edits copy touched
paths. Unchanged text and index subtrees remain shared.

Replacement reconstructs intersecting logical lines plus newline-neighbor
context, preserving LF, CRLF, CR, NEL, line/paragraph separators, final structural
lines, timestamps and landmark lineage. Range/partition checks, stable-ID
uniqueness and invocation anchor/hash checks precede publication. A range that
splits a surrogate pair uses the reference String normalization before storing
its replacement, so encode/decode cannot change the root's text representation.
An affected very long logical line can still require a scan of that entire line.

Complete validation remains mandatory at decode, migration, pre-encode, recovery,
bulk, restore and explicit integrity boundaries. Debug builds additionally own
one asynchronous validation worker and one newest-root pending slot. Stale
validation results cannot diagnose a newer live revision.

## Native input and patches

The AppKit adapter captures exact replacements and accumulates provisional IME
ranges in the original root's coordinates. Untracked Services input gets bounded
prefix/suffix discovery (4,096 units per side and a 65,536-unit replacement
window); changes beyond those bounds use explicit bulk processing. The native
adapter does not project an already-visible accepted replacement back into the
text view. Startup prefix reconciliation preserves the stored root's identity.

`DocumentPatch` supports at most 256 ordered nonoverlapping replacements and
bounded annotation operations. Each replacement carries an anchor and source
hash. Exact expected invocation values include package metadata, lifecycle
generation, anchors and hashes. Text and annotation changes are validated and
published atomically. Tool effect planning stays within the document module;
there is no temporary coordinator or trusted post-mutation snapshot shortcut.
Native projection applies the accepted ranges and clears changed tool decoration
attributes within their affected scopes. Viewport preparation queries visible
invocations and bounded text fragments.

## Retained work

Undo uses shared before/after roots and native grouping. It retains at most 200
whole groups and a 256 MiB estimated payload, keeping the newest completed group
even if that group alone exceeds the estimate. `DocumentRetainedStorage` charges
distinct graph nodes/chunks once and conservatively charges annotation values per
snapshot. Estimates exclude allocator overhead, AppKit allocations and resident
memory. Eviction removes a whole native target and releases its roots.

Persistence notifications capture roots and reject older or foreign-document
notifications. SQLite encoding, verification, checkpoint and history operations
stay on the storage actor. Save completion acknowledges exactly its captured
revision and cannot make a newer pending root clean. Purge retains the existing
old-store write barrier and replacement ordering.

History owns a bounded queue of 32 explicit boundaries, plus a newest idle root.
Obsolete idle retention coalesces. A full explicit queue returns a retryable
failure; in particular, pre-restore preservation cannot silently skip its
milestone and proceed. Purge drops pending idle work and drains entered/queued
work before the existing store replacement protocol.

## Evidence and limits

See `performance/document-before.json`, `performance/document-sequence-spike.json`
and `performance/document-representation-selection.md` for the checked baseline
and representation selection. The final post-change capture and variance tables
are in `performance/document-after-optimized.json` and
`performance/document-after-optimized.md`. An intermediate diagnostic capture
in `performance/document-after.json` exposed three redundant persistent-index
decodes per save. Exact byte readback now verifies writes produced by the fully
validated encoder; load and recovery still decode and completely validate.
Save-and-recovery p95 is 120.733 ms in Debug and 109.036 ms in Release, below the
unchanged 250 ms ceiling in every measured process.
The performance collector never changes or dynamically calibrates XCTest limits.
Interaction acceptance, first NSTextView paint, prepared convergence and
background throughput are separate distributions. A first paint is a completed
native draw, not a display-server scanout guarantee.

Structural gates cover local replacement paths, immutable sharing/release,
atomic patch rejection, fixed-viewport work, bounded undo/history retention and
save coalescing. Seeded reference scenarios shrink failures and retain reduced
surrogate-boundary regressions. The persisted wire format is unchanged.
