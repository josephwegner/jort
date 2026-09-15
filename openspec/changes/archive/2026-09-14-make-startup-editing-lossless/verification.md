# Startup editing verification — 2026-09-14

## Implemented behavior

The editor exposes typed loading, reconciliation, ready, recovery-editing, and terminal ownership-conflict phases. The transitional coordinator accepts native edits and undo immediately, but never publishes them to persistence. Persistence independently rejects changes before successful loading, before changing pending state or creating history work.

Successful loading prepends accepted startup text through a `startupMerge` transaction on the loaded coordinator. The stored identity and revision lineage survive. Transitional undo is replaced with one loaded-document merge group; selection and viewport remain startup-relative, and reconciliation does not move first responder. Marked text delays reconciliation until native input returns, so composition and its undo group finish before coordinator replacement. Failure retains the editable draft and undo, with separate recovery-copy export and no ordinary store/history writes.

Generic insertion reconciliation needed one correction: its inserted-before test recognized only LF and CR. It now also recognizes NEL, line separator, and paragraph separator, preserving the untouched stored first line's identity and timestamps and its pending invocation anchors. No store schema or line parser changed.

## Results

- Foundation: **129 tests passed**. Includes controlled loading success/failure/future-version/ownership refusal, every pair of supported newline boundaries, empty inputs, line timestamps and landmarks, stored pending-invocation preservation, explicitly held in-flight startup saving followed by a newer edit, and real SQLite history baseline/failure protection. Existing save-failure/retry and crash/failure-injection suites passed.
- Native: **105 tests passed** on the final source. Includes four new controlled-startup tests covering no draft, Unicode draft selection and focus, pre/post-load Undo/Redo, immediate continued typing, IME commit/cancel, editable recovery and export, terminal ownership conflict, and SQLite save/reopen identity verification.
- UI: five of six tests passed in the full run, including keyboard find/undo/relaunch, bundled-tool merge/relaunch, shell, model settings, and landmark navigation. `testSettingsWindowAndCustomToolDraft` initially failed to find the settings window; it passed on an isolated rerun with no code or assertion change. The full UI run was therefore not clean on its first attempt.
- First-party production build and C analysis passed with **zero diagnostics**.
- Formatting check passed for 73 first-party Swift files. Deterministic XcodeGen project generation, fresh-packaging/failure-preservation tests, strict OpenSpec validation, and whitespace checks passed.

## Limits

Functional suites used the existing local default `JORT_PERFORMANCE_ENFORCE=0`. Native sustained editing p95 measured **199.14 ms**, above the existing 100 ms budget. This remains owned by `make-document-interactions-incremental`; thresholds and CI enforcement are unchanged. Passing functional tests does not qualify that performance gate. Physical IME/input-source and VoiceOver journeys were not performed; automated marked-text and accessibility tests were run.

## Local evidence

- `/private/tmp/startup-foundation-complete.log`
- `/private/tmp/startup-native-complete.log`
- `/private/tmp/startup-ui.log`
- `/private/tmp/startup-ui-retry.log`
- `/private/tmp/startup-analysis.log`
- `/private/tmp/startup-packaging.log`

The project was relocated from `jort-astra-test` to `jort` during the session; final runs use the latter path.
