## 1. Registry, parser, and annotation model

- [ ] 1.1 Define local command descriptors, stable IDs, aliases, input modes, output limits, and lazy registry behavior.
- [ ] 1.2 Add pending invocation and completed provenance annotation models using `LineID` and line-relative anchored ranges.
- [ ] 1.3 Extend snapshots, SQLite migrations, revision envelopes, current-state verification, and recovery with bounded command annotations.
- [ ] 1.4 Implement committed-line parsing with exact registry and token-boundary matching while excluding provisional IME text.
- [ ] 1.5 Add parser, migration, persistence, malformed-annotation, recovery, and unmatched-punctuation tests.

## 2. Completion and invocation UX

- [ ] 2.1 Add slash-triggered completion backed by the command registry and palette filtering behavior.
- [ ] 2.2 Implement completion insertion and dismissal as native text/focus operations without execution.
- [ ] 2.3 Render pending decoration and Run controls at the actual invocation line using viewport-bounded TextKit geometry.
- [ ] 2.4 Route Shift-Return and Run through one execution path while preserving Return and Escape semantics.
- [ ] 2.5 Add wrapping, scrolling, editing, IME, native Find, keyboard, duplicate-dispatch, and accessibility tests.

## 3. Deterministic insertion built-ins

- [ ] 3.1 Implement injected execution context for clock and UUID sources and documented locale-independent date/time defaults.
- [ ] 3.2 Implement `/date`, `/time`, and `/uuid` argument validation and bounded output.
- [ ] 3.3 Implement the purpose-built `/calc` lexer, parser, arithmetic semantics, finite-result checks, and diagnostics.
- [ ] 3.4 Add exhaustive and randomized calculator tests including precedence, unary operators, malformed syntax, zero division, overflow, and denial of dynamic evaluation.

## 4. Previewed selection transforms

- [ ] 4.1 Capture explicit selected logical-line ranges with generation, stable anchors, and input hashes.
- [ ] 4.2 Implement stable literal `/sort` and first-occurrence exact `/dedupe` transformations with trailing-newline preservation.
- [ ] 4.3 Build complete replacement preview, keyboard confirmation/cancellation, and exact visible scope decoration.
- [ ] 4.4 Revalidate selection anchors and hashes immediately before commit and reject missing or stale scope.
- [ ] 4.5 Add Unicode, duplicate, empty-line, partial-line-selection, stale-input, large-selection, and accessibility tests.

## 5. Atomic transaction and provenance

- [ ] 5.1 Implement one document mutation API for bounded insertion or replacement, line metadata, provenance, undo, persistence, and semantic history boundaries.
- [ ] 5.2 Insert command output immediately after the invocation line and preserve selection/viewport around background model synchronization.
- [ ] 5.3 Implement Merge as provenance removal and leave deletion to ordinary explicit text editing.
- [ ] 5.4 Add atomicity, Undo/Redo, relaunch, write-failure, history-restore, output-cap, and viewport tests.

## 6. Release gates

- [ ] 6.1 Benchmark invocation parsing, decoration, completion, preview, and command commit with `CrawlLargeDocument`.
- [ ] 6.2 Re-run prior launch, typing, scrolling, search, history, persistence, recovery, gutter, IME, and accessibility gates.
- [ ] 6.3 Audit built-ins to prove no network, provider, JavaScript, plugin, shell, filesystem, or external-process authority is reachable.
- [ ] 6.4 Confirm no `@agent`, asynchronous run, progress, cancellation, stale-target rebase, or provider configuration is implemented in this slice.
