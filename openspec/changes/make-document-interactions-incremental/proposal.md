## Why

Ordinary edits currently rebuild or validate complete document structures on the main actor, shift every trailing line offset, and copy full snapshots into undo and tool-edit workflows. On the reviewed large-document fixture this makes accepted edits visibly pause, and the existing elapsed-time gates neither identify the responsible work nor distinguish interaction latency from prepared presentation and background storage throughput.

## What Changes

- Make localized native, startup, metadata, and tool-generated transactions validate and update only the affected line/anchor region plus explicitly bounded neighboring context.
- Replace globally shifted absolute-offset maintenance with an indexed document representation that preserves UTF-16 ranges and stable identities while making lookup and suffix relocation sublinear for localized edits.
- Use persistent structural sharing for immutable snapshots and undo/redo states while retaining one authoritative mutable `DocumentCoordinator` and flat Codable compatibility at persistence boundaries.
- Apply tool publication, Merge, Dismiss, and restoration through the same coordinator transaction primitives without constructing temporary full coordinators or accepting prebuilt replacement snapshots as a mutation shortcut.
- Move encoding, history retention/decoding/pruning, and durable save work off the input path while preserving immutable revision ordering, recovery guarantees, and purge barriers.
- Establish reproducible debug and optimized performance baselines with p50/p95/p99 distributions, separate interaction/presentation/background categories, structural work counters, and evidence-based CI regression budgets.
- Add deterministic adversarial and randomized edit/undo/redo tests that compare incremental state with a full-validation reference model.

## Capabilities

### New Capabilities

- `incremental-document-interactions`: Defines bounded transaction work, indexed snapshot/undo semantics, full-validation boundaries, performance evidence, and regression-budget policy.

### Modified Capabilities

- `logical-line-metadata`: Requires indexed localized line maintenance and affected-region proof while preserving every identity, timestamp, newline, and UTF-16 rule.
- `native-editor`: Separates synchronous edit acceptance from prepared presentation and background persistence, with key-to-visible interaction measurements that preserve native IME, selection, and undo behavior.
- `inline-command-invocation`: Requires tool-generated canonical mutations to use the shared incremental transaction primitives without temporary coordinators or snapshot replacement shortcuts.
- `local-version-history`: Requires history encode, decode, retain, compare, prune, and restore preparation to consume immutable snapshots off the input path without retaining unbounded document graphs.
- `resilient-document-storage`: Requires save serialization and recovery preparation to use immutable revision snapshots in background work without weakening ordering, recovery, or private-data maintenance barriers.

## Impact

- Reworks the internal document text/line index, snapshots, validation, transaction results, and undo payloads in `JortDocument` while keeping persisted document encoding compatible.
- Changes the AppKit edit adapter to submit exact replacement text and UTF-16 ranges rather than copying the complete text view for ordinary accepted edits.
- Changes invocation document integration to request typed edits against the authoritative coordinator.
- Changes persistence/history adapters to flatten structurally shared snapshots only at explicit background boundaries and to release obsolete roots after completion.
- Adds reference-model, randomized, complexity-instrumentation, and calibrated performance fixtures across Foundation and native test targets; it does not change the Wave 2 read-only paint pipeline or the JavaScript runtime boundary.
