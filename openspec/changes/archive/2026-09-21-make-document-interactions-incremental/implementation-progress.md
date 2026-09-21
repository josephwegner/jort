# Incremental document implementation

The persistent document engine, native adapter, atomic tool patches, bounded undo,
and background persistence/history ownership are implemented. The task checklist
is authoritative; all 38 tasks are complete.

## Implementation

- Immutable indexed snapshots use fanout-16/leaf-16 logical-line storage,
  2,048-unit UTF-16 chunks, and complete UUID radix lookup. Local replacements
  copy affected index paths and share unchanged subtrees.
- Ordinary native input submits exact replacements. Provisional IME input,
  startup-prefix reconciliation, bounded untracked-input discovery, selection,
  native grouping and explicit bulk fallback preserve the existing contracts.
- Local proof precedes atomic publication. Complete validation remains at
  persistence, recovery, bulk, restore and explicit integrity boundaries; Debug
  verification runs in a coalesced background worker.
- Tool effects publish bounded atomic patches with revision, anchor, hash and
  exact invocation preconditions. Temporary coordinators and trusted snapshot
  mutation shortcuts are removed.
- Undo retains shared roots with a distinct-storage ledger, 200 whole groups and
  a 256 MiB payload estimate. History admits 32 explicit boundaries plus one
  coalesced idle root, returning a retryable failure at capacity.
- Save notifications capture immutable roots; background completion acknowledges
  exact revisions. Slow-worker tests cover coalescing, root release and continued
  input. Existing purge/store-replacement barriers remain intact.

API contracts and limitations are documented in `docs/incremental-documents.md`.
`DocumentState` remains the complete-scanning reference, local-window lineage
implementation and explicit bulk boundary; it is not the live storage owner.

## Correctness and structural verification

- Full Foundation gate: 136 document/storage tests, 9 tool-contract tests and 58
  tool-runtime tests passed.
- Full native gate: 131 tests passed.
- Full UI gate: 7 tests passed, including keyboard undo/search, landmarks, tool
  publication/Merge/relaunch, settings and private-data purge.
- Formatter: 149 first-party Swift files checked. Project generation matched.
  Localization checked 100 keys. First-party Swift/C analysis and dependency
  audit passed with zero C diagnostics. Strict OpenSpec validation passed.
- Deterministic reference tests cover Unicode/newline edits, metadata, root
  restoration and persistence. Shrinking found split-surrogate normalization
  mismatches; the fix includes three reduced regressions.
- Structural tests enforce no ordinary-input flattening or complete validation,
  local index work, fixed-viewport presentation bounds, atomic patch rejection,
  shared storage release and bounded undo/history/save retention.
- Native verification found and fixed automatic undo event-group closure and
  retained tool paragraph indentation after Merge.

## Performance evidence

The unchanged baseline and representation-selection experiment are checked into
`docs/performance/`. The completed post-change capture ran five independent processes
per suite and build configuration, serially, on the same reference runner.
Acceptance, first native paint, prepared convergence and background throughput
have separate distributions. New first-paint/convergence metrics do not have
pre-change distributions. Evidence collection disables timing enforcement and
never changes XCTest budgets; correctness success is not a timing-budget claim.

## Final rollout evidence

The intermediate capture in `docs/performance/document-after.json` identified
three redundant persistent-index decodes in each save. Phase timing showed about
100 ms in encode, 137 ms in SQLite read/decode, and 282 ms in checkpoint work in
Release; SQLite writing itself was below 1 ms after warm-up. Save publication now
checks exact bytes produced by the completely validated encoder, while load and
recovery retain full decode and validation. Decode also constructs the persistent
index once in the common case.

The final 20-process capture and comparison are in
`docs/performance/document-after-optimized.json` and
`document-after-optimized.md`. Release native edit p95 improved from 268.302 ms
to 1.620 ms (99.4%). Release save-and-recovery improved from 299.323 ms to
109.036 ms (63.6%); the five-process range is 107.244–110.543 ms. Debug
save-and-recovery is 120.733 ms with a 120.478–126.676 ms range. Every existing
absolute ceiling passes without a budget change.

History decode, comparison, retention and search remain slower than the flat
baseline and are recorded as measured limitations for follow-up work. They did
not receive a new allowance. The flat live owner and trusted tool shortcut are
removed, parity and rollout gates pass, and the incremental API documentation is
complete.
