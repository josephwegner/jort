# Implementation verification

Status: all implementation tasks are complete. The strict Core Animation warning
gate passes after disabling animations in presentation test fixture windows.

## Verified

- Foundation: 94 document/persistence/settings tests, 9 lifecycle contract tests,
  and 58 runtime tests passed (`/private/tmp/jort-presentation-foundation.log`).
- Focused native presentation: 40 tests passed with zero Core Animation warnings,
  including two system-only native controls and direct draw mutation
  probes, stale epochs/actions, marked text, focus retention, wrapped/EOF ruler
  geometry, accessibility, and bounded native measurement on 10,000 lines.
- The first full native run passed 123 of 124 tests. Its autosave fixture assumed
  a save would finish during short nested run-loop waits. It now yields with
  Swift concurrency during editing and awaits startup/flush asynchronously; the
  corrected test passed independently. The final full native rerun passed on
  September 17 (`/private/tmp/jort-presentation-native-retry.log`).
- UI smoke: all 6 tests passed after retry on September 17, 2026
  (`/private/tmp/jort-presentation-ui-retry.log`). The Settings fixture now focuses
  the document before sending its keyboard shortcut, matching the other flows.
- First-party static analysis passed with no diagnostics. Formatting of 125 Swift
  files, localization discovery (75 keys/fallbacks), generated project consistency,
  `git diff --check`, and strict OpenSpec validation passed.

## Resolved warning investigation

The initial focused run recorded 19 `Invalid attempt to open a new transaction
during CA commit` warnings. The first single-window TextKit control did not trigger
them. That was insufficient evidence to attribute the warnings to Jort.

LLDB logging call-site traces identified this sequence:

1. Core Animation commits a transaction and drains its autorelease pool.
2. AppKit deallocates `_NSWindowTransformAnimation`, releasing its `NSWindow`.
3. Window destruction requests window-server transaction work during the commit.
4. AppKit's `_NSCGSTransaction` cleanup emits the nested-transaction warning.

The warning uses a `%s` log format. The suggested symbolic diagnostic breakpoint
aliases a shared AppKit stub on this OS; matching only the literal warning text or
that shared stub did not identify the cause. Logging call-site capture did.

On macOS 26.6.2 (25G83), Xcode 26.6 (17F113), the standalone
`scripts/diagnostics/native-window-animation.swift` reproduced five warnings from
five ordinary windows with `--manual-runloop`. It imports only AppKit and does
not link Jort or XCTest. The identical `--manual-runloop --no-animation` control
produced zero warnings, as did the normal `NSApplication.run()` control. Logs:

- `/private/tmp/jort-manual-animation.log`: five warnings.
- `/private/tmp/jort-manual-no-animation.log`: zero warnings.
- `/private/tmp/jort-standalone-animation.log`: normal application loop, zero warnings.
- `/private/tmp/jort-warning-formats-v2.log`: warning and window-deallocation stacks.

Presentation fixture windows now set `animationBehavior = .none` before display.
Production animation policy and presentation scheduling were not changed to work
around the native test-host behavior. All 40 focused assertions and the unchanged
strict warning checker passed (`/private/tmp/jort-presentation-no-animation.log`).
Direct paint mutation assertions remain enabled. Nothing is suppressed or waived.

Use `./scripts/validate presentation` for the quiet canonical validation lane; it
records complete logs and `summary.json` under `.build-validation/`.

Final quiet validation on September 17 passed:

- `./scripts/validate fast`: `.build-validation/20260917T160838Z-52508/summary.json`.
- `./scripts/validate presentation`: `.build-validation/20260917T160957Z-52772/summary.json`
  (75 localization keys, 40 native tests, zero nested-transaction warnings).
- Strict OpenSpec validation and `git diff --check` passed.

All 30 implementation tasks are complete. The change has not been archived.
