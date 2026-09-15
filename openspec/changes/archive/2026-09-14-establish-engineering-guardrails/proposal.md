## Why

Jort's current repository and CI checks obscure actionable first-party problems: generated build products remain tracked, formatting has no enforceable baseline, vendored QuickJS dominates analyzer output, and test teardown removes SQLite files while connections remain open. These issues should be corrected before the larger Wave 2 and Wave 3 refactors so their diffs and failures remain reviewable.

## What Changes

- Remove generated build products from version control while preserving developers' local build outputs and ignoring all derived-data and local distribution paths consistently.
- Add a committed EditorConfig and pinned Swift formatting policy, apply the initial repository-wide formatting as a mechanical-only rewrite, and enforce formatting deterministically in CI.
- Separate first-party static-analysis enforcement from the vendored QuickJS audit lane so dependency diagnostics remain visible without masking or determining the first-party result.
- Make test fixtures explicitly close every SQLite-backed store before deleting its temporary directory, eliminating live-file teardown warnings and matching production ownership.
- Document which checks are blocking, which are informational dependency audits, and which known performance failures belong to later changes.

## Capabilities

### New Capabilities

- `engineering-quality-gates`: Defines repository cleanliness, deterministic formatting, separated first-party and vendored analysis, and resource-safe test teardown as enforceable project checks.

### Modified Capabilities

None. This change establishes engineering checks without changing Jort's user-facing product requirements.

## Impact

- Repository metadata and tracked generated files, including `.gitignore` and existing `build/` entries.
- Swift source formatting across production and test targets; the initial formatting diff must remain mechanically isolated from semantic edits.
- CI and local verification scripts in `.github/workflows/`, `scripts/`, and Xcode analysis schemes.
- AppKit and Settings test fixtures that own `SQLiteStore`, `SQLiteSettingsStore`, or package/settings stores backed by SQLite.
- Vendored QuickJS remains pinned and analyzed, but is not reformatted or patched merely to silence diagnostics.
