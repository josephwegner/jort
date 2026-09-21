# Persistent representation selection

Status: select the fanout-16 sequence and 2,048-unit text chunks for production implementation.
The live model has not migrated. This record selects a representation; it does not claim
transaction semantics, native integration, or rollout gates are complete.

## Selected structure and constants

- Immutable augmented ordered sequence: at most 16 children per branch and 16 logical records per leaf.
- Each record carries a stable 128-bit identity and a persistent UTF-16 text root.
- Text roots use balanced binary branches and immutable leaves of at most 2,048 UTF-16 units.
- Every sequence subtree caches UTF-16 length and record count; every text subtree caches length, height, and first/last units.
- A persistent radix-16 map indexes full 128-bit IDs and node-parent edges, with at most 32 radix levels. It is not a hash-to-offset dictionary.
- Copy-on-write replacement rebuilds split/join boundary paths, affected leaves, and their ID/parent-map paths.
- Ordered traversal explicitly flattens at linear cost. Snapshot capture shares roots without a coordinator back-reference.

## Evidence

Both fixtures ran in separate Debug and Release processes for each candidate.
Each process performed 20 warm-up edits followed by 200 measured edits and retained 200 snapshots.
The same workload measures early replacements, distributed offset/ID lookup, snapshot capture,
and complete UTF-16 flattening. Peak resident memory includes the property checks and retained roots;
it is not incremental retained-payload accounting or an allocator trace.

The full results, source hash, all measured categories, and work estimates are in
document-sequence-spike.json. Hardware matches document-environment.json. This is a
bounded selection spike, not the five-process end-to-end baseline or a timing gate.

| Build | Lines | Fanout / leaf records | Edit p95 ms | ID lookup p95 ms | Flatten p95 ms | Peak resident MiB |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| Debug | 10000 | 0 / 0 | 0.0440 | 1.98867 | 4.109 | 62.2 |
| Debug | 10000 | 16 / 16 | 1.0082 | 0.00512 | 4.955 | 34.1 |
| Debug | 10000 | 32 / 32 | 1.2279 | 0.00287 | 4.659 | 36.4 |
| Debug | 25000 | 0 / 0 | 0.1359 | 5.22617 | 10.594 | 144.8 |
| Debug | 25000 | 16 / 16 | 1.0746 | 0.00388 | 12.200 | 50.4 |
| Debug | 25000 | 32 / 32 | 1.3244 | 0.00371 | 11.415 | 50.9 |
| Release | 10000 | 0 / 0 | 0.0451 | 0.91300 | 0.743 | 62.6 |
| Release | 10000 | 16 / 16 | 0.1618 | 0.00167 | 0.816 | 28.8 |
| Release | 10000 | 32 / 32 | 0.2019 | 0.00362 | 0.803 | 37.6 |
| Release | 25000 | 0 / 0 | 0.1429 | 2.46638 | 2.018 | 149.5 |
| Release | 25000 | 16 / 16 | 0.2096 | 0.00221 | 1.991 | 48.5 |
| Release | 25000 | 32 / 32 | 0.2531 | 0.00400 | 1.905 | 51.0 |

## Selection rationale and rejected alternatives

Fanout 16 has lower measured replacement cost and fewer allocated index nodes than fanout 32
on both fixture sizes in both configurations, with comparable flattening and low lookup cost.
The constants balance path height against the cost of updating bounded child/ID entries.
The 2,048-unit text bound is a conservative implementation constant, not an empirically
optimal value; changing it requires rerunning chunk-boundary properties and the spike.

The flat-array control is faster for isolated record replacement at these sizes. It is rejected
because retained snapshots copy entire record arrays on the next mutation and ID/offset queries
scan records. Its payload is deliberately a sequence control, not the complete current document
model; do not compare its sub-millisecond edit with the native baseline as an application speedup.
A monolithic String with shifted absolute LineMeta offsets and a full-copy gap array fail the same
required locality/sharing properties. An offset-only rope is rejected because it lacks stable-ID lookup.

## Property and locality argument

Immutable leaf buffers, child arrays and radix nodes form acyclic value graphs. Mutation replaces
paths and reuses untouched children; parent information is stored as value IDs in a separate
persistent map, never as mutable parent pointers or coordinator references. Retained roots therefore
preserve their old text, line order and lookup positions while new roots advance independently.

Offset selection subtracts cached child lengths along one sequence path. ID lookup resolves
a record-to-leaf edge and adds cached edge prefixes while following the parent path; each edge
lookup has a fixed maximum of 32 radix levels. A suffix location changes because an ancestor
prefix changed, not because each suffix record was rewritten. For bounded branching, changed
sequence paths imply bounded child-edge updates per level. Complete flattening remains linear.

The spike checks 200 seeded insert/delete/split/join operations against an independent flat
record array, including text, identities, offsets, ordinals, aggregate values, branch/leaf bounds
and height. It also checks 500 seeded UTF-16 edits across chunk boundaries, surrogate pairs,
combining marks and all supported newline units; retained roots stay equal to their captured
values. Structural-sharing assertions require most sequence nodes to survive a localized edit.
Weak-root checks prove unowned text and sequence roots are released.

## Production qualification still required

Use complete UUID values in the production ID namespace and keep internal node IDs disjoint
from persisted line IDs. The spike uses deterministic full-width IDs for reproducibility.
Preserve empty/final structural lines, metadata and invocation semantics in the separate
transaction reference suite. The spike is a storage-property oracle, not that semantic oracle.
Production split/join must retain explicit balance invariants under adversarial deletion as well
as the measured workloads; add blocking path/allocation bounds and lifetime accounting.
Do not remove the flat live model or synchronous complete proof until the planned parity gates pass.
No latency ceiling or CI enforcement was changed by this selection.

## Reproduction

Run scripts/benchmark-document-sequence.py with --work-dir and --output, after other timing
jobs finish. It compiles the standalone probe in scripts/diagnostics for Debug and Release,
verifies the generated million-unit fixture hash, and launches an isolated process per candidate.
