## Context

Jort is generated from `project.yml`, uses Swift 6 strict concurrency, and runs headless, native AppKit, UI, packaging, static-analysis, and sanitizer checks. The repository nevertheless tracks an older `build/` tree even though current `.build*` paths are ignored. There is no formatter or EditorConfig contract, and many Swift files contain dense semicolon-chained lines that make later refactors harder to review.

The CI static-analysis command analyzes `JortAdapters`, whose dependency graph reaches vendored QuickJS. The reviewed run produced 61 analyzer diagnostics in four vendored C files and no identified first-party diagnostics. Those dependency findings should remain auditable, but they must not obscure or determine the first-party signal.

Several AppKit tests create SQLite-backed stores inline. The shared temporary-root helper schedules directory removal without owning all stores that use the directory, so teardown can unlink SQLite files while connections are still open. Production store types already expose asynchronous or throwing `close` operations; tests need explicit ownership and teardown ordering.

This change precedes source-moving and algorithmic work in later waves. Its output must therefore be a stable baseline rather than a mixture of cleanup and behavioral refactoring.

## Goals / Non-Goals

**Goals:**

- Ensure generated build and distribution artifacts cannot re-enter version control accidentally.
- Establish one deterministic Swift formatting contract and enforce it locally and in CI.
- Keep the initial formatting conversion mechanically reviewable.
- Make first-party analyzer failures blocking while preserving a separate visible QuickJS audit result.
- Ensure SQLite test resources close before their directories are removed.
- Document check ownership and known exceptions so later failures are not silently normalized.

**Non-Goals:**

- Refactoring large AppKit types or changing product behavior.
- Fixing the known native performance-budget failure.
- Modifying vendored QuickJS solely to reduce diagnostic count.
- Adopting SwiftLint or another semantic style dependency in addition to the formatter without a separately justified requirement.
- Deleting developers' untracked local build products as part of the repository migration.

## Decisions

### Use the selected Swift/Xcode toolchain formatter

Use the formatter shipped with the selected Swift toolchain, invoked through `xcrun swift format`, with a committed configuration at the repository root. The format check will enumerate tracked first-party Swift source roots explicitly and exclude `Vendor/`, generated products, and OpenSpec archives.

This avoids adding a network-fetched build dependency solely for formatting and keeps syntax support aligned with the compiler used by the project. The CI environment must report its Xcode and Swift versions so a toolchain change is visible when formatting output changes.

Alternatives considered:

- SwiftFormat: capable and widely used, but it adds a separately installed and pinned dependency.
- SwiftLint alone: useful for semantic linting but not a complete deterministic formatter.
- No repository-wide conversion: leaves the baseline inconsistent and pushes formatting churn into every later refactor.

### Isolate the mechanical conversion

The implementation sequence will first add configuration and checks, then apply the formatter to the agreed first-party roots without semantic edits. Any semantic cleanup revealed by formatting must be a later task or change. Generated Xcode output and vendored QuickJS are excluded.

This makes the large diff reproducible: running the formatter again must produce no changes. It also prevents file splitting or access-control changes from being hidden in mechanical churn.

### Remove tracked build output from the index, not from local workspaces

Update ignore rules for `build/`, `.build/`, `.build-*`, `dist/`, Xcode user data, generated test results, and other confirmed derived paths. Remove already tracked `build/` entries from the repository index while leaving the on-disk local tree intact during implementation.

The implementation must enumerate tracked targets before removal and must not use a broad recursive deletion against the workspace. A clean checkout after the change will naturally omit the artifacts.

### Create distinct first-party and vendored analyzer lanes

Configure the first-party analysis scheme or target settings so vendored QuickJS sources are not analyzed in the blocking first-party lane. Add a separate QuickJS analyzer invocation whose diagnostics are retained as an artifact and compared against a documented baseline or reviewed explicitly, without causing an unrelated first-party analysis result to become unreadable.

The preferred Xcode-level mechanism is to disable analyzer execution for the `JortJavaScript` target when reached as a dependency of the first-party scheme and provide a dedicated scheme/invocation that analyzes it directly. The implementation must verify actual logs rather than assume the setting works transitively.

Suppressing analyzer diagnostics globally was rejected because it would also hide future first-party defects. Patching vendored code without upstream analysis was rejected because it complicates provenance and upgrades.

### Make test fixtures own teardown resources explicitly

Tests that create SQLite-backed stores will retain those stores until teardown. Each test or fixture will close stores in dependency order before its temporary root is removed. Composite stores such as `PackageSettingsStore` must close both registry/settings resources they own or expose one explicit close operation that does so.

Prefer async teardown registered by the test when supported; otherwise use explicit `defer`/final cleanup in the async test. Directory removal remains last and reports unexpected failure rather than unconditionally hiding it. In-memory test doubles do not need artificial close methods.

### Classify checks instead of weakening known failures

Document the local and CI commands and whether each is blocking, informational, or conditionally enforced. The existing performance enforcement remains owned by `make-document-interactions-incremental`; this change may document the known failure but must not raise its threshold or disable CI enforcement.

## Risks / Trade-offs

- **Risk: The mechanical formatting diff is large and causes branch conflicts.** → Land it before source-moving Wave 2 work and keep it reproducible and semantic-free.
- **Risk: Formatter output changes with a future Xcode update.** → Record toolchain versions in CI and update the committed configuration/conversion in an isolated change when the selected toolchain changes.
- **Risk: Analyzer separation accidentally skips first-party code.** → Assert the analyzed target/source set in scripts and include an intentional first-party analyzer fixture or controlled verification during implementation.
- **Risk: Treating vendored findings as informational allows a real dependency defect to linger.** → Preserve the complete QuickJS report, pin its upstream version/checksum, and require explicit review in the later sandbox-runtime change.
- **Risk: Async teardown errors mask the test's primary assertion failure.** → Structure cleanup to preserve the primary failure while recording close/removal failures as secondary diagnostics.
- **Trade-off: No SwiftLint in the initial baseline.** → Prefer a small enforceable formatter contract now; add semantic lint rules only when they address demonstrated defects rather than style preference.

## Migration Plan

1. Inventory all tracked generated paths and all first-party Swift roots.
2. Add/normalize ignore rules, EditorConfig, formatter configuration, and local check scripts.
3. Apply the formatter as a reproducible mechanical conversion with no semantic changes.
4. Remove tracked `build/` artifacts from the index while preserving local files.
5. Split analyzer execution and capture both first-party and QuickJS outputs.
6. Fix test resource ownership and teardown ordering.
7. Run formatter verification, deterministic project generation, headless/native tests, first-party analysis, the QuickJS audit lane, and `git diff --check`.

Rollback is source-only: revert the configuration, mechanical conversion, CI changes, and index removals. No user data or production schema is migrated.

## Open Questions

- During implementation, confirm the exact `xcrun swift format` command and configuration schema supplied by the project's selected Xcode toolchain.
- Determine whether the vendored QuickJS lane should compare against a checked diagnostic-count baseline or remain a fully retained report with explicit review; it must not silently discard new diagnostics either way.
- Inventory whether SQLite lifecycle warnings occur outside AppKit settings tests and extend the same ownership fixture rather than fixing only the initially cited helper.
