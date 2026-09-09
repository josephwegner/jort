# Implementation handoff: `build-jort-run-tools`

Last updated: 2026-09-09. This is an active `openspec-apply-change` implementation, not an archive-ready change.

## Resume here

1. Read this file and `.codex/skills/openspec-apply-change/SKILL.md`.
2. Announce `Using change: build-jort-run-tools` and run:

   ```sh
   openspec status --change build-jort-run-tools --json
   openspec instructions apply --change build-jort-run-tools --json
   ```

3. The current checklist is **39/55 complete**. Do not mark the remaining tasks complete until their specific tests or audits pass.
4. Rebuild and rerun `ToolInvocationTests` first. The most recent source fixes compiled successfully, but were not exercised after the final build because the session ended.

## Current implementation

- Added ordinary versioned JavaScript tool packages (`tool.json` + `tool.js`) and a shared registry for bundled, installed, overridden, disabled, removed, and restored packages.
- Bundled `/date`, `/time`, `/uuid`, `/calc`, `/sort`, and `/dedupe` under `Jort/Resources/Tools`.
- Vendored QuickJS 2026-06-04 under `Vendor/QuickJS` with a small authority-free host in `Sources/JortJavaScript`. It has no module loader or OS bindings, disables dynamic evaluation after host compilation, and enforces memory, timeout, cancellation, stack, and result bounds.
- Added editable package-backed tools to the existing Settings → Tools pane. Bundled customization creates a persistent same-ID override; deleting it restores the shipped definition. Legacy settings scripts stay editable until explicitly saved into the package format.
- Added persisted invocation annotations, stable anchors, hashes, lifecycle state, locks, SQLite/payload migration, recovery, and history support. Ephemeral prompt text is never persisted.
- Added slash completion, palette tool insertion, contained/contextual/ephemeral input, explicit Run/Shift-Return, delayed processing, errors, cancellation, canonical pending output, Merge/Dismiss, three merge operations, Undo/Redo integration, and package-version reconciliation.
- Added connected teal/purple TextKit geometry, source/output seams, contextual drag/keyboard handles, spinner/X processing controls, icon-only Merge/X pending controls, empty-result presentation, accessibility labels, and canonical-only copy/accessibility values.
- Added package/runtime/persistence/editor/UI tests and `docs/tool-packages.md`.

## Important UX decisions already encoded

- Completion acceptance never executes. Space/Return select a tool; Shift-Return or Run submits only while invocation-owned content is focused.
- Contained/contextual input is canonical text. Ephemeral input is memory-only. Submitted source is locked but remains selectable/copyable.
- Pending output is canonical immediately and appears directly after the invocation. Merge applies the captured operation and removes provenance. Dismiss removes pending output and restores inputting.
- Multi-line/wrapped source is one connected green wrapper. Pending source and purple output form one compound silhouette. Processing is spinner + X only. Pending actions are merge icon + X with hover/accessibility labels.
- Long/multiline output places actions at the source/output junction; short inline output places them after output.
- Missing or corrupt metadata preserves every canonical character as plain text. Unmappable completed calls retain output without rerunning it.

## Verification already completed

- `openspec validate build-jort-run-tools --strict` passes.
- `git diff --check` passes.
- A full foundation run passed **89 tests** before the last small edits.
- Focused package/runtime tests passed before the last small edits.
- Persistence tests passed **6/6**, including malformed annotations, legacy payloads, relaunch/history, locks, and injected publication write failures.
- An earlier expanded tool run passed **13/13**, including package settings overrides, prompt restoration, all merge modes, cancellation, rendering, and the large-document benchmark.
- The full native suite previously ran **48 tests with two failures**. Both failures reproduce on a clean `HEAD` export and are pre-existing stale visual assertions:
  - `EditorTests.testRulerClipsControlsAndEditorGlyphsRender` expects a 24 pt inset while baseline uses 12 pt.
  - `EditorTests.testShellRenderedStates` expects the old footer-divider pixels.
- `build-for-testing` most recently succeeded after all current source and test edits.
- OpenSpec benchmark observations on `CrawlLargeDocument` (1,000,000 UTF-16 units): discovery 2.73 ms p95, validation 0.47 ms, host startup + calc 0.81 ms, visible geometry 2.39 ms. Whole-document invocation transactions remain slow: accept 324 ms, full-context movement 189 ms, submit/publish 552 ms, dismiss 269 ms. Keep task 10.1 open and document/qualify or optimize this.

## Test infrastructure issue

`xcodebuild test` became unreliable late in the session: one run could not connect to `testmanagerd`, another native runner hung before connecting, and the UI runner timed out while enabling automation mode. This was runner infrastructure, not a compiler failure.

The compiled test bundle can be run directly after `build-for-testing`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Jort.xcodeproj -scheme Jort \
  -derivedDataPath .build-tools-native \
  -destination 'platform=macOS' build-for-testing

DYLD_FRAMEWORK_PATH="$PWD/.build-tools-native/Build/Products/Debug" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest JortCoreTests.ToolInvocationTests \
  "$PWD/.build-tools-native/Build/Products/Debug/JortCoreTests.xctest"
```

The last direct run used an older build and reported three failures. All three were addressed afterward, but still require rerun:

- Ephemeral prompt was not first responder after refresh. Presentation now tracks visible prompt IDs and avoids hiding visible prompts.
- Narrow-window ephemeral prompt had the same focus symptom.
- Pasteboard test expected one type; macOS exposes both modern and legacy plain-text type names. The assertion now accepts only those two plain-text aliases.

If direct `xctest` hangs, terminate only the exact stale `xcodebuild`/`xctest` process after confirming its PID; do not kill broad process groups.

## Recent unverified edits

- Ephemeral prompts clamp horizontally to a narrow viewport, remain anchored with a short teal connector, and hide when their token is outside the laid-out viewport.
- IME commit arms slash completion only after committed text; paste still suppresses inference.
- Palette actions now include enabled tool manifests and insert an invocation at the caret without evaluating scripts.
- Context collision uses the other invocation's full occupied source-plus-output range.
- Invocation validation now enforces reverse-DNS IDs, command grammar, legal input/output combinations, canonical range placement, and output adjacency.
- Output line caps count CRLF as one line and also count CR, NEL, and Unicode line/paragraph separators.
- Undo/history restore now re-runs package reconciliation.
- Runtime now rejects failure to freeze the captured input.
- Tool acceptance rejects packages absent from the active enabled registry and caps active annotations at 1,000.

## Remaining checklist and likely next work

Unchecked tasks are 4.3, 4.5, 5.5, 5.6, 6.6, 7.3, 7.4, 7.6, 8.5, 8.6, 8.7, 9.6, and 10.1–10.4.

Recommended order:

1. Rerun `ToolInvocationTests` directly. Fix only real failures; do not change the two known baseline visuals.
2. Run package/runtime and persistence bundles directly, then the full foundation/native suites if Xcode's runner recovers.
3. Inspect fresh rendered captures. Existing captures are under `/private/tmp/jort-tools-*.png`; regenerate them because pending-action geometry changed after the last capture.
4. Complete exact Undo chronology tests: immediate publication Undo behaves like Dismiss, Merge Undo restores pending, Redo works, and unrelated edits unwind first while preserving selection/viewport/line IDs.
5. Complete migration fallback coverage for contained/contextual/ephemeral inputting, pending with output, and empty pending output.
6. Add/finish rendered and interaction coverage for context above/below, empty output, multiple same-line invocations, scrolling, hit targets, and prompt offscreen behavior. Programmatic accessibility checks do not substitute for a physical VoiceOver pass.
7. Retry `./scripts/test-ui.sh`. The new UI case exercises real keyboard `/calc`, pending Merge, canonical result, and relaunch. It has not executed because automation mode timed out.
8. Add a tool-specific security/audit section to `docs/run-verification.md`: same loader/runtime for bundled and installed packages; no network/filesystem/process/shell/provider/plugin/native bridge/dynamic evaluation/external executable authority.
9. Reconcile task 10.4 wording with the approved design: this change intentionally adapts the pre-existing Settings → Tools panel, but adds no marketplace, permission-granting UI, agent/provider/model UI, streaming, or background-agent run. Do not claim “no Settings panel” literally.
10. Mark tasks as they genuinely pass, rerun strict OpenSpec validation and `git diff --check`, then use `openspec-verify-change`. Do not archive until verification is complete.

## Files and logs

- Primary implementation: `Sources/JortAppKit/ToolInvocationController.swift`, `Sources/JortAppKit/ToolInvocationPresentation.swift`, `Sources/JortDocument/ToolInvocation.swift`, `Sources/JortSettings/ToolPackage*.swift`, `Sources/JortSettings/ToolRuntime.swift`, `Sources/JortJavaScript/*`.
- Package docs: `docs/tool-packages.md`.
- Checklist: `openspec/changes/build-jort-run-tools/tasks.md`.
- Useful logs: `/private/tmp/jort-tools-regression.log`, `/private/tmp/jort-tools-followup.log`, `/private/tmp/jort-tools-direct.log`, `/private/tmp/jort-tools-build.log`, `/private/tmp/jort-tools-ui.log`.
- The worktree contains all implementation edits and is intentionally uncommitted. Preserve unrelated existing work; do not reset or discard files.
