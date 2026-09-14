# Engineering guardrails

## Migration inventory

The exact index-removal manifest is `engineering-generated-files.txt`: 276 files under
`build/` and the generated `Jort/Resources/AppIcon.icns`. Local files are preserved.
The icon is reproduced from the tracked PNG and generation script. XcodeGen runs
the icon generator before enumerating resources, so a clean checkout generates the
same project even though the icon itself is untracked. Keep the tracked
Xcode project, shared schemes and Info.plist: deterministic generation checks compare
these with `project.yml`. Keep `build-jort-v1/`: despite its name, it contains planning
inputs, not build output. Keep fixtures, icon source art and bundled tools.

Derived outputs: `build/`, `.build/` (release), `.build-*` (foundation/native/UI tests,
analyzers and sanitizers), `dist/` (packaged app, DMG and staging), `*.xcresult`,
Xcode user data, generated AppIcon.icns and Python caches. Icon staging and packaging
tests also use system temporary directories. UI snapshots use the system temporary
`jort-shell-snapshots` directory.

First-party Swift roots: `Jort/`, `Sources/`, `Tests/`, `Tools/` (68 tracked files
at inventory). Vendor and planning/archive trees are excluded.

## Formatting

The baseline uses Xcode 26.6 (17F113), Swift 6.3.3, and its `xcrun swift format`.
`.swift-format` commits the complete version-1 configuration emitted by this toolchain.
Syntax-transforming lint rules are disabled; semicolon removal and layout are mechanical.
Toolchain upgrades require an explicit formatting review. CI reports actual versions.

## Analyzer ownership

`JortEngineering` explicitly builds all seven production targets: Jort, JortAppKit,
JortDocument, JortPersistence, JortSettings, JortJavaScript and StoreLockProbe.
The analysis script checks the scheme's target IDs against all non-test native
project targets and refuses missing coverage. Swift is checked by its compiler;
Clang's path-sensitive analyzer applies to C-family sources, not Swift.
The first-party lane builds the full graph, then invokes Clang only on Jort-owned
C-family translation units. This explicitly separates the bridge in the mixed
JortJavaScript target from Vendor without disabling any analyzer checker. It avoids
relying on transitive Xcode analyze settings for a target containing both owners.
Compiler/build failures and any first-party analyzer diagnostic are blocking.

The analyzer uses the project’s GNU C11, DEBUG=1, no-common and macOS 14 deployment
settings. The QuickJS lane analyzes all five vendored C translation units with the same
Clang invocation and retains complete plist paths, textual logs, normalized
locations/checkers/messages, input hashes, toolchain versions and baseline diff.
Its initial baseline contains 59 diagnostics: 40 dead stores, 6 call/argument
findings, 6 null dereferences, 2 shifts, 2 undefined binary operands, 2 uninitialized
assignments and 1 uninitialized branch. Four files have findings; cutils.c is clean.
This is an inventory, not acceptance of those findings as safe or false positives.
The earlier Xcode review reported 61; counts from different invocations/toolchains
are not interchangeable. No vendor code or checker is suppressed to meet a count.
The sandbox-runtime follow-up owns dependency investigation.

`Vendor/QuickJS/JORT.md` pins upstream 2026-06-04 and the archive SHA-256
`b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`.
The tree includes documented local extensions, so the upstream archive checksum
is not a checksum of the extracted, modified sources. The committed
`quickjs-analyzer-provenance.json` records the actual vendored file hashes and
toolchain used with `quickjs-analyzer-baseline.json`.

A changed diagnostic set, source hash or toolchain produces a nonzero audit result
and a CI summary. The dedicated job is informational (`continue-on-error`); it
cannot alter the separate blocking first-party job. Review added and removed
findings and full reports before copying `diagnostics.json` and `provenance.json`
from `.build-analysis-quickjs/` to the two committed baseline files. Never update
these files merely to make a changed audit green.

## Test resource inventory and close order

`StoreTestCase` owns every SQLiteStore, SQLiteSettingsStore and PackageSettingsStore
created in the Foundation, Settings and AppKit suites. The affected fixtures are
Storage, Migration, HistoryStorage, Landmark, Process, Performance, RunPerformance,
ToolPersistence, Settings, ModelTool, ToolPackage, Editor, DocumentSearchWorkspace,
HistoryWorkspace, SettingsWorkspace and ToolInvocation tests.
HistoryStore is an interface on the same SQLiteStore, not another connection.
ToolPackageRegistry owns package files and a JSON index, not SQLite; its composite
PackageSettingsStore closes SQLiteSettingsStore preferences and finishes streams.
In-memory Scheduler and UI test doubles need no synthetic close operations.
Process probes release their SQLite resources on process termination.

Each constructor is retained immediately, before the first potentially failing
operation. Existing explicit closes needed for lock/reopen assertions remain;
close is idempotent and teardown covers thrown errors and early returns as well.
The shared teardown first drains editor persistence/history work, then closes
retained stores in reverse construction order (composites before their preferences),
then removes registered temporary directories. All closes are attempted even if
one fails. A failed close records a secondary XCTest issue and preserves directories
rather than unlinking potentially live files. Removal failures also become secondary
issues; teardown never throws over the original test error. Direct SQLite fixture
handles use scoped close/finalize, including the busy-store early-return path.

## Commands and enforcement

Run commands from the repository root. Scripts default DEVELOPER_DIR to
`/Applications/Xcode.app/Contents/Developer`; set it explicitly to select another
installed toolchain. XcodeGen must match `.xcodegen-version`.

| Command | Enforcement and purpose |
| --- | --- |
| `python3 scripts/format.py` | Local mechanical formatting; includes new Swift files within the four explicit roots. |
| `python3 scripts/format.py --check` | Blocking local/CI byte-for-byte formatting check, without writes. |
| `python3 scripts/check-project.py` | Blocking local/CI deterministic project/plist generation. Run `xcodegen generate` after changing project.yml and review the resulting project/scheme diff. |
| `./scripts/test.sh` | Blocking correctness checks: foundation, native and packaging. Performance is conditional as below. |
| `./scripts/test-foundation.sh` | Blocking headless document, persistence, settings and fixture tests. |
| `./scripts/test-native.sh` | Blocking AppKit correctness tests; requires a macOS test-runner session. |
| `JORT_PERFORMANCE_ENFORCE=1 ./scripts/test.sh` | Blocking CI performance budgets, unchanged. Local default 0 reports timing without enforcing those budgets. |
| `./scripts/test-ui.sh` | Blocking CI accessibility smoke checks; ad-hoc signs an isolated app/test runner and requires GUI/accessibility support. |
| `python3 scripts/analyze.py first-party` | Blocking full production build and first-party C-family analysis. Reports in `.build-analysis-first-party/`. |
| `python3 scripts/analyze.py first-party --self-test` | Controlled gate verification: deliberately exits 1 with a null dereference. Run the normal lane afterward to restore a clean report. |
| `python3 scripts/analyze.py quickjs` | Informational dependency audit; changes return nonzero for review but do not determine first-party status. |
| `xcodebuild -project Jort.xcodeproj -scheme JortFoundation -configuration Debug -derivedDataPath .build-tsan -destination 'platform=macOS' -enableThreadSanitizer YES test` | Blocking CI foundation Thread Sanitizer. |
| `xcodebuild -project Jort.xcodeproj -scheme JortNativeTests -configuration Debug -derivedDataPath .build-native-tsan -destination 'platform=macOS' -enableThreadSanitizer YES test` | Blocking CI native Thread Sanitizer. |
| `./scripts/build.sh` | Blocking CI Release build and unsigned local packaging. |
| `python3 scripts/test-packaging.py` | Blocking local/CI fresh packaging and failed-validation preservation tests. |
| `./scripts/package-dmg.sh` | Conditional, manually requested local DMG packaging; needs an existing dist app/background and Finder session. |
| `git diff --check` | Blocking whitespace check before completion. |

The known native performance-budget failure belongs to
`make-document-interactions-incremental`. This change does not raise a threshold,
change performance assertions, or remove `JORT_PERFORMANCE_ENFORCE=1` from CI.
Existing native visual failures, if reproduced, remain correctness failures and
must be reported rather than reclassified as informational performance output.

## Verification record — 2026-09-14

- Xcode 26.6 (17F113), Swift 6.3.3, XcodeGen 2.46.0; arm64 macOS.
- 277 inventoried generated paths removed from the index; all local originals
  preserved. A source-only temporary checkout contained no build tree or icon and
  passed deterministic generation, recreating its icon from source.
- Formatting passes for 70 Swift files, including two new fixture/test files.
  A deliberately malformed new Swift file was rejected with its path identified.
  All 45 production/tool Swift files exactly match formatting applied to HEAD,
  confirming no semantic production edits. Vendor sources are unchanged.
- Foundation: 124 tests passed, including two teardown ordering/failure regressions.
  Native: 101 tests passed. Neither suite emitted `vnode unlinked while in use`.
  The macOS test runner required execution outside the filesystem/process sandbox.
- First-party lane: seven production targets built, one C bridge analyzed, zero
  diagnostics. The isolated self-test returned 1 for its intentional null dereference.
- Deterministic project generation, packaging regression tests, strict OpenSpec
  validation and `git diff --check` passed.
- Enforced native performance: sustained editing p95 200.15 ms exceeds the existing
  100 ms budget in `testSustainedEditingAutosaveScrollingAndBoundedUndo`.
  `testWalkLargeDocumentGutterAndNavigation` passed. The known failure remains owned
  by `make-document-interactions-incremental`; CI enforcement is unchanged.
- Full UI/accessibility, Thread Sanitizer and Release/DMG checks were not rerun for
  this change. They remain in their existing CI/manual enforcement lanes. The
  first-party lane did build the Debug app, and packaging regression tests passed.

- Final QuickJS audit: five translation units, 59 retained diagnostics, zero added
  or removed findings, and matching source/toolchain/compiler-flag provenance.
