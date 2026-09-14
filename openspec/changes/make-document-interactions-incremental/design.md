## Context

`DocumentCoordinator` is correctly the only mutable owner of the live document, and `DocumentSnapshot` gives persistence and adapters coherent values. The current representation undermines that architecture at scale: AppKit submits the text view's complete `String`, `DocumentState.replaceText` shifts every trailing `LineMeta.location`, transaction completion performs `DocumentState.validate()` over all text and metadata, snapshots copy flat line/invocation collections, and tool edits construct temporary coordinators before replacing the authoritative state. The 10,000-line and 1,000,000-UTF-16-unit fixtures expose these costs on the main actor.

Wave 1 requires immediate lossless startup input and retains the current performance gate until evidence supports a deliberate change. Wave 2 establishes a read-only, viewport-bounded AppKit presentation pipeline, a pure invocation reducer, one headless execution coordinator, document-owned canonical mutations, and background-safe persistence/recovery barriers. This design builds on those future boundaries. It does not optimize draw callbacks or change the JavaScript process boundary.

The persisted document envelope and logical behavior are compatibility constraints. UTF-16/AppKit ranges, LF/CRLF/CR/NEL/line-separator/paragraph-separator handling, stable line IDs and timestamps, landmarks, invocation anchors and locks, stale-revision rejection, startup reconciliation, native undo/redo, recovery, and history all remain normative.

## Goals / Non-Goals

**Goals:**

- Make ordinary localized edit acceptance proportional to the affected text/lines and logarithmic index maintenance rather than total document length or trailing-line count.
- Preserve one authoritative coordinator while allowing immutable snapshots and undo roots to share unchanged storage.
- Define exact local proofs and explicit full-integrity boundaries so performance does not weaken correctness.
- Make native and tool-generated edits use one atomic incremental mutation surface.
- Keep snapshot flattening, complete validation, serialization, history, and durable IO off the synchronous input path.
- Measure interaction, prepared presentation, and background throughput independently with reproducible distributions and structural work evidence.

**Non-Goals:**

- Changing the Wave 2 read-only paint, viewport geometry, control reconciliation, or theme design.
- Moving QuickJS out of process or changing tool lifecycle semantics.
- Changing persisted document fields, user-visible newline content, line identity rules, history retention policy, recovery durability, or purge guarantees.
- Promising one universal latency number for every Mac or making whole-document paste/restore sublinear in payload size.
- Selecting a data structure solely from name or theoretical complexity without profiling it against Jort's real transaction mix.

## Decisions

### Use a property-driven persistent document index, selected by a measured implementation spike

Replace flat mutable text plus absolute line offsets with an internal persistent sequence index whose production implementation must provide:

- bounded UTF-16 text chunks rather than one rewritten contiguous buffer;
- ordered logical-line records carrying ID, length, and timestamps without stored global offsets;
- subtree aggregates for UTF-16 length and logical-line count;
- lookup and split/join by UTF-16 offset and by ordinal in logarithmic tree height;
- a persistent line-ID lookup that resolves an ID to its current sequence position without scanning every line;
- copy-on-write path replacement so an immutable snapshot retains a root while an edit allocates only changed paths/chunks; and
- deterministic iteration that flattens to the existing persisted text and absolute `LineMeta` representation.

The first implementation task builds bounded prototypes for an augmented chunked B-tree and any simpler contender justified by current profiling. The selected implementation must pass the same property suite and document measured edit, lookup, snapshot, flatten, and memory behavior in a checked decision record before the live model migrates. A monolithic `String` plus shifted `[LineMeta]`, a full-copy array gap buffer, and any representation that lacks stable-ID lookup are disqualified by the required properties. This stages the concrete branching/chunk constants without leaving the architectural contract open.

The coordinator remains the only mutable owner: it replaces its current root after an accepted transaction. A snapshot is an immutable root plus document identity, revision, landmark index, and invocation index. No adapter can mutate a root or maintain a second canonical buffer.

### Submit exact replacements instead of post-edit whole-document strings

Add a canonical replacement mutation containing base revision, origin, UTF-16 range, exact replacement `String`, undo policy, and optional typed metadata/invocation operations. AppKit captures the range and replacement from `shouldChangeTextIn` and commits it at the native edit boundary. Marked-text updates remain provisional; composition commit may use a bounded common-prefix/suffix fallback only when AppKit cannot provide a reliable committed replacement range. Services and genuinely whole-document replacements remain explicit bulk transactions.

The coordinator applies the same replacement to its persistent index and verifies the resulting local facts against the native text-system event. It must not read `NSTextView.string`, compare it with complete canonical text, or materialize a flat snapshot on the synchronous ordinary-edit path. Programmatic display remains a projection of accepted coordinator results.

### Define a transaction-local proof and reserve full validation for integrity boundaries

Each ordinary replacement starts with the intersecting logical lines plus one line on either side, expanding only when required to disambiguate a split newline sequence. The transaction rebuilds that window, preserves/creates/detaches identities according to existing rules, and proves:

1. the replacement range and resulting UTF-16 aggregates are valid;
2. local line records exactly partition the rebuilt window and join correctly to unchanged neighbors;
3. inherited and newly generated line IDs are unique through the persistent ID index;
4. timestamp, landmark attachment, invocation lock/anchor, and remap invariants hold for affected records;
5. unchanged roots outside the replaced paths are reused; and
6. document identity and revision advance exactly once from the stated base.

Metadata-only operations use ID lookup and validate only the target plus changed collection/index entries. Tool patches validate their declared preconditions and every affected replacement/annotation in one prospective root before publication. No partially validated state becomes current.

Complete validation is mandatory after persistence decode and migration before publication, immediately before persistence encode (on background work), for recovery/restore candidates, for explicit integrity diagnostics, and in reference/randomized tests. Debug builds schedule coalesced complete validation of immutable accepted snapshots outside the synchronous input callback; test/debug failures are loud, while stale verification work is discarded. Bulk replacements may perform complete validation because their work is already proportional to the full payload.

### Make snapshot and undo sharing explicit and bounded

`DocumentSnapshot` becomes a `Sendable` immutable view over persistent roots. It offers indexed text/range/line/ID queries for ordinary consumers and a deliberate flatten operation for Codable, export, search algorithms that require contiguous input, and diagnostics. Flattening is never implicit in equality checks on the input path.

Undo entries retain before/after roots and selection/restoration facts, so unchanged chunks and indexes are shared. The native undo store remains bounded to 200 complete user groups and a checked 256 MiB retained-payload estimate, evicting oldest whole groups when either bound is exceeded while always retaining the newest completed group. Eviction releases roots immediately; no snapshot, transaction callback, persistence completion, or history entry owns a back-reference to the coordinator or an unbounded ancestor chain.

Background persistence/history jobs retain only the immutable root for the exact revision they process. Once flattened/encoded or superseded, they release it. On-disk history retains encoded values under the existing retention contract, not live graph roots. Structural-sharing tests track live node/chunk counts and weak root release after undo eviction, save coalescing, history completion, and purge boundaries.

### Replace tool snapshot substitution with atomic document patches

Remove the temporary-coordinator `replacing` flow and the `.tools(DocumentSnapshot, edit:, replacementLength:)` mutation shortcut. `JortDocument` exposes a typed atomic patch containing ordered nonoverlapping text replacements and bounded landmark/invocation insert/update/remove operations plus revision, anchor, hash, lifecycle-generation, and package-generation preconditions.

The extracted reducer emits intent; document integration translates that intent into a patch; the authoritative coordinator validates and applies it with the same sequence primitives as native edits. Publication, Merge, Dismiss, cancellation restoration, and Undo either commit one coherent revision or change nothing. Runtime and AppKit never manufacture a trusted post-mutation snapshot.

### Separate synchronous interaction, prepared presentation, and background throughput

Instrumentation defines three categories:

- **Interaction:** native commit callback to accepted coordinator revision, and the corresponding revision becoming visible in the native text system. This path includes local validation and necessary viewport invalidation, but excludes autosave, history, complete validation, and deferred decoration convergence.
- **Prepared presentation:** accepted revision/viewport invalidation to a committed Wave 2 viewport snapshot and first paint of matching visible decorations. It is separately bounded by visible fragments and finite overscan.
- **Background throughput:** flatten/encode, complete validation, SQLite save, recovery checkpoint, history retain/list/decode/compare/prune, and restore preparation. These may scale with snapshot size but cannot synchronously block input or publish a stale revision.

Use signposts and test clocks around stable boundaries, and publish p50, p95, p99, maximum structural work, build configuration, fixture hash/size, warm-up/sample counts, macOS/Xcode/architecture, and reference-machine/CI class. Debug and optimized results are never pooled.

### Calibrate CI from checked evidence without erasing the existing failure

Add a checked performance manifest and baseline report. Calibration runs at least five independent processes per build configuration after declared warm-up and uses per-process distributions so one hot process does not hide startup or allocator variance. Structural assertions are blocking on every CI machine: localized work may touch only affected chunks/lines plus bounded tree paths and prepared presentation only visible fragments plus overscan.

The current p95 ceilings remain enforced until the baseline report, implementation result, variance, and user-facing rationale are reviewed together. A changed ceiling must be an explicit manifest diff; it cannot be calculated dynamically from the run under test or raised merely to make CI pass. Hardware-timing gates run only on the documented reference runner class. Other CI reports distributions and enforces deterministic structural/correctness gates. Regression ceilings include an absolute reviewed value and a bounded relative allowance against the checked optimized baseline; crossing either applicable guard fails.

### Preserve persistence and private-data barriers while moving work off input

`PersistenceController.changed` receives an immutable revision root and performs only ordering/coalescing bookkeeping on the main actor. Complete validation, flattening, encoding, recovery checkpoint construction, SQLite work, and history work execute in owned background tasks/actors. Results acknowledge their exact revision; completion of an older job never makes a newer state clean or replaces current memory.

The Wave 2 purge boundary can freeze root `P`, reject further jobs against the old store, and let later edits form roots from `P` in memory. Store replacement, recovery verification, WAL handling, and cleanup retain their specified durability order. Optimization cannot skip complete boundary validation or weaken recovery-copy limits.

## Risks / Trade-offs

- **Risk: Persistent indexing adds substantial correctness complexity.** → Select using a reference-backed spike, keep the full scanner as a test oracle, use seeded randomized state-machine tests, and compare every resulting text/line/anchor/invocation value.
- **Risk: AppKit provides incomplete replacement information for IME or Services.** → Preserve provisional marked text and use the bounded diff fallback only at commit; classify unbounded external replacement as an explicit bulk transaction.
- **Risk: Chunk boundaries split surrogate pairs or newline sequences.** → Index in UTF-16 but split only at validated boundaries, carry boundary summaries, and test CRLF, Unicode separators, combining marks, and surrogate pairs at every chunk edge.
- **Risk: Structural sharing retains unexpectedly large old content.** → Enforce undo count and retained-payload budgets, release superseded background roots, expose live-node diagnostics in tests, and prohibit parent/back-reference cycles.
- **Risk: Background flattening produces memory spikes.** → Use streaming/chunk iteration where persistence encoders permit it, bound concurrent flatten jobs, coalesce obsolete revisions, and measure peak resident growth as part of the candidate decision.
- **Risk: Timing tests remain noisy.** → Make structural bounds the universal gate, isolate reference-runner timing, record environment and distributions, and require explicit reviewed baseline changes.
- **Trade-off: Full-document replace, decode, encode, and integrity checks remain linear.** → They move off ordinary interaction paths and are measured as bulk/background operations; correctness boundaries remain complete.

## Migration Plan

1. Add signposts, structural counters, checked environment metadata, and before-change debug/optimized baselines without changing current enforcement.
2. Build candidate index prototypes behind a test-only property interface, run the required correctness/performance/memory fixtures, and commit the selection record plus constants.
3. Introduce persistent text/line/ID roots and indexed snapshot queries alongside the flat model; dual-run transactions against the full reference implementation in tests.
4. Change native committed edits to exact replacement transactions while retaining the bulk/IME fallback and Wave 1 startup behavior.
5. Migrate landmarks, invocation anchors/locks, transaction validation, snapshots, and bounded undo to the index; remove synchronous full validation after parity and structural tests pass.
6. Introduce atomic tool patches and remove temporary coordinators and trusted snapshot substitution.
7. Move validation/flatten/encode/history/store work behind owned background boundaries and verify save, recovery, purge, and stale-revision failure matrices.
8. Enable the checked structural gates, collect post-change distributions, and review any timing-manifest adjustment as a separate evidence-bearing diff.
9. Remove the flat live-model path and comparison mode only after persisted round-trip, randomized, native, recovery, and performance suites pass.

Rollback before step 9 uses the retained flat implementation because the persisted schema is unchanged. After removal, source rollback remains possible against the same stored data; no storage downgrade or user-data rewrite is required.

## Open Questions

None at proposal time. The concrete tree branching/chunk constants are deliberately resolved by the mandatory measured spike and checked selection record, not by product semantics. Timing values may change only through the explicit evidence/review process above; the requirements and structural bounds do not depend on those machine-specific constants.
