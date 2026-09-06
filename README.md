# Jort

A native, dark macOS scratch canvas: one app-owned plain-text document, local persistence, no account or network requirement. Walk adds emoji landmarks and Pocket; automation remains a later product phase. See [Walk validation](docs/walk-validation.md) for current release gates.

## Build and test

Requires macOS 14+, full Xcode with Swift 6, and XcodeGen **2.46.0**. `project.yml` is the configuration source of truth; `.xcodegen-version` pins the generator. Generated project/plist files are included and checked for drift.

```sh
python3 scripts/check-project.py
./scripts/test.sh
```

Normal tests build only frameworks and command-line test bundles. Document/persistence tests do not construct AppKit objects; separate native adapter tests exercise their own AppKit views inside `xctest`. Neither suite builds or modifies an installed Jort application. Computer Use is not part of the test workflow.

These commands are intentionally separate and should be run by the user when desired:

```sh
./scripts/test-ui.sh  # Builds and ad-hoc signs an isolated accessibility test app/runner
./scripts/build.sh    # Produces dist/Jort.app, unsigned and local-only
```

The UI smoke test uses `JORT_DATA_DIRECTORY` to isolate its text. It may require normal macOS developer/accessibility permissions. Do not disable Gatekeeper or remove security attributes to run it. Signing/notarization for public distribution remain deferred.

**Quit older Jort builds before launching version 0.2.** The new process lock cannot constrain the old 0.1 binary, which did not implement locking. On first 0.2 launch, the old store migrates without deleting its original files.

## Editing

The app target generates `AppIcon.icns` from `Jort/Resources/IconSources/jort-color.png` when the artwork changes, for both Xcode and script builds. Original artwork is excluded from the packaged resources.

Type into the single canvas. Paste is plain text. Native selection, wrapping, Find/Replace, and scrolling remain available. Successful autosaves are silent. A failed save stays visibly actionable, retries three times, and then waits for manual retry. Quitting waits for the latest save and warns if changes remain unsaved.

- **⌘S**: save or retry.
- **⌘Z / ⇧⌘Z**: undo/redo text and metadata as one transaction.
- **⌘F**: native Find/Replace.
- **⌘K**: search application and landmark actions, including moving or deleting detached landmarks.
- Click a gutter line to add/change its emoji using the native character picker; right-click a landmark for change, clear, or move actions.
- The fixed gutter control toggles a compact landmark index. Its entries navigate by stable line identity; scrolling the index does not scroll the document.
- **⌘W / ⌘0**: close/reopen the one window.
- **File → Save Recovery Copy…**: save a separate versioned JSON snapshot when needed.

Saving is best-effort and runs off the typing path. The internal scheduler targets frequent saves during continuous typing; it is not a strict half-second deadline or a guarantee under stalled/failing storage.

## Local data and migration

The data root is `~/Library/Application Support/Jort`, or an explicit `JORT_DATA_DIRECTORY` for development. A process holds a nonblocking OS advisory lock on `Jort.lock` for its store lifetime. A second process cannot open, recover, or write that store; different roots can run independently.

Version 0.3 uses:

- `Store/Jort.sqlite` plus SQLite WAL/SHM companions.
- `Store/Recovery-0.json` and `Store/Recovery-1.json`, with `Recovery-manifest.json` advertising verified snapshots. Each publication replaces the inactive slot and retains the prior verified slot.
- `PreMigration-*` and `Damaged-*` diagnostic backups.

Legacy `Jort.sqlite`/`Recovery.json` files are preserved during migration. SQLite schema version 3 and payload envelope version 3 are separate, explicitly decoded formats. Version 3 includes sorted JSON keys, a SHA-256 payload checksum, and validated attached/detached landmark records. Released v1/v2 fixtures are committed. Migration preserves valid prototype landmarks and their identities. Unknown schemas and future versions are refused without modifying the originals.

Migration/recovery builds a sibling store, closes and reopens it for validation, then atomically swaps the whole directory. This keeps SQLite, WAL, SHM, and recovery state together. Recovery verifies advertised checkpoints newest first and falls back to the prior slot when needed. An old generation may also remain in `.Replacement-*` after a swap for diagnostic safety. A damaged store is never removed before a valid replacement exists.

The maximum serialized payload is **64 MiB**. Oversize, busy, permissions, disk, and recovery-snapshot errors remain failed saves. Any failure in the save operation keeps the live document dirty, even if SQLite itself already committed. Unsafe initial-load editing and recovery-copy import retain their previous limitations and are deferred product-design work.

## Architecture and validation

- `JortDocument`: authoritative main-actor coordinator, immutable Sendable snapshots, typed transactions, line lineage, anchors, and revisions. No AppKit dependency.
- `JortPersistence`: storage actor, locking, versioned codecs, atomic migration/recovery, typed main-actor scheduling.
- `JortAppKit`: native text, gutter, coordinator-backed undo, selection/viewport mapping, localized status presentation.
- `Jort`: composition, menus, and lifecycle.

See [review implementation status](docs/review-status.md), [normative line identity](docs/line-identity.md), and [performance budgets](docs/performance.md). CI configuration includes clean generation checks, tests, static analysis, sanitizer checks, accessibility smoke testing, and a fresh Release package. This workspace is not yet a Git repository, so remote CI has not been executed here.
