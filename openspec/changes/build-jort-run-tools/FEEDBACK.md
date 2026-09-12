# User feedback handoff — 2026-09-10

Implementation update, 2026-09-10: the feedback below is implemented in the working tree and reflected in the change's design/specs. See `VERIFICATION.md` for current test evidence and remaining release qualifications. The original feedback and screenshot references are retained for review.

## Behavior and usability

Second feedback pass implemented: matched green/purple heights, compact right-aligned Run actions, pointing-hand/hover treatment, visible Enabled checkbox beside the heading, fresh styling after Merge Undo, trailing empty contained-line coverage, source/ruler clipping, popover-only ephemeral Submit, and exactly one leading U+0020 removed from submitted content. See `VERIFICATION.md` for current evidence and the declined real-app rerun.

- **Tool acceptance:** Enter selecting a completion must insert a space after the command. Acceptance still does not execute the tool.
- **Errors:** Show a readable explanation of what went wrong, such as for `/calc foo`. Color or a dismiss tooltip alone is insufficient.
- **Context handles:** Make start/end boundaries visually understandable and distinguishable; a caret at the top is a suggested treatment. Fix the after-command handle's drag hit area, apparently overlapped by Submit. Keyboard boundary movement must work immediately without first dragging a handle. User reports **Cmd+Opt+Arrow**; reconcile this with the existing Option+Shift implementation/spec.
- **Pending deletion — spec amendment:** Allow deleting a selection that intersects some or all of pending-merge calls, after warning **“N mergeable responses will be deleted”**. Count affected responses once each. When partially deleted, the affected call's remaining text becomes ordinary text with its invocation metadata removed. Do not infer permission to delete text outside the user's selection. Cover cancellation, multiple responses, partial/full deletion, and Undo. This request does not relax processing-state locks.
- **Escape:** With the caret inside purple pending output, Esc dismisses the pending result and returns to the tool prompt/inputting state.
- **Built-ins:** `/uuid` returns `${uuid}${input}`; `/time` and `/date` likewise append the input to their generated value. Preserve the single `content` input model; this is not argument parsing.
- **Diff/history:** Add simple visual indications of invocation/pending metadata so tool-related changes are recognizable in the diff view.
- **Settings Save:** Saving a new tool must save without the “unsaved JavaScript will be deleted when you leave” prompt. Keep the unsaved-changes warning for actually leaving/closing an unsaved editor.
- **Custom tool availability:** Newly created tools currently never appear in editor autocomplete. Investigate save/registration, enablement, and propagation to open editors; verify the complete create → save → invoke flow.

## Layout and visual polish

- **Pending controls (image 1):** Result text overlaps Merge/Dismiss. Reserve actual layout space/padding for controls, including at a multiline source/output junction.
- **Submit (image 2):** Submit overlaps the end of input. Reserve space without blocking caret or context-handle interaction. Visibly show **⇧↵** for Shift+Enter; these glyphs may be the entire button.
- **Source/result seam (image 3):** Increase visual separation between input and pending result; currently `/calc 3+3` and `6` run together. Keep the compound green/purple wrapper connected. Prefer decoration/layout spacing, preserving canonical text.
- **Multiline wrapper (image 4):** Clamp the green wrapper to the longest content line rather than filling the editor width where possible. Preserve one connected wrapper across lines and wraps.
- **Autocomplete (image 5, Slack reference in image 6):** Fix layering so the popover appears above editor text. Match Pocket/command-palette rounded styling, use a compact content-sized window, left-align commands, right-align names in muted text, and use row highlighting instead of the leading `>` marker. Slack's mention menu illustrates the intended visual cues.
- Retain previous decisions: processing shows spinner + X attached inside the invocation shell; pending actions are merge icon + X with hover/accessibility labels; source and output feel like one connected widget.

## Suggested starting points

- `Sources/JortAppKit/ToolInvocationPresentation.swift`: wrapper geometry, reserved control space, handles, completion popover, errors, key handling.
- `Sources/JortAppKit/ToolInvocationController.swift`: acceptance spacing, focused invocation lookup, Dismiss, boundary movement.
- `Sources/JortAppKit/EditorViewController.swift` and `Sources/JortDocument/ToolInvocation.swift`: edit locks, pending deletion, transactional metadata changes, Undo.
- `Sources/JortAppKit/ToolsSettingsViewController.swift`, `Sources/JortSettings/PackageSettingsStore.swift`, `ToolPackageRegistry.swift`, and `Jort/JortApp.swift`: save warning and registry/editor refresh. Suspected causes are not yet confirmed.
- `Jort/Resources/Tools/{uuid,time,date}/`: bundled JavaScript and validation updates.
- Verify real rendered behavior, especially multiple invocations on one line, empty inputs/results, wrapped content, and contextual handles adjacent to controls. Earlier automated passes did not catch these user-visible issues.

## Previous implementation checkpoint

The older `HANDOFF.md` contains useful architecture and commands, but its progress/test counts are stale. The preceding session reported 53/55 tasks checked, with rendered/accessibility qualification and release gates still open. New feedback requires additional work and revalidation.

Latest code work before this feedback added `ToolActionButton.accessibilityPerformPress` and context-handle accessibility increment/decrement. Those edits need verification. A prior 22-test tool run had three failures in `testRenderedContextAndEphemeralStateMatrixWithAccessibleActions` because native accessibility press returned false after removing its own button; the action itself succeeded. Do not treat the subsequent patch as verified. Earlier foundation results were 95/95; focused real UI calc completion/merge/relaunch passed. Two native visual assertions were previously reproduced on baseline. See `VERIFICATION.md` and `/private/tmp/jort-tools-*.log` for evidence, checking freshness before relying on it.

## Screenshot references

Original attachments are temporary paths and may expire. The numbered descriptions above preserve the essential evidence.

1. Pending control/output overlap: `/var/folders/wj/s44vmxpj6ls_9w08ptlj_pmm0000gn/T/codex-clipboard-5ea669fd-0529-45ac-ac2c-21eba227eb03.png`
2. Submit/input overlap: `/var/folders/wj/s44vmxpj6ls_9w08ptlj_pmm0000gn/T/codex-clipboard-0eb20934-37ff-48a7-9724-2c2e1f2cba5f.png`
3. Tight source/result seam: `/var/folders/wj/s44vmxpj6ls_9w08ptlj_pmm0000gn/T/codex-clipboard-4f947940-d5b5-4629-a195-fc4f53c78131.png`
4. Full-width multiline wrapper: `/var/folders/wj/s44vmxpj6ls_9w08ptlj_pmm0000gn/T/codex-clipboard-22612dae-09fc-49fe-8bac-ad4d72e8833a.png`
5. Current autocomplete: `/var/folders/wj/s44vmxpj6ls_9w08ptlj_pmm0000gn/T/codex-clipboard-3cd90102-3f3f-41ec-b939-a09e313f5b86.png`
6. Slack reference: `/var/folders/wj/s44vmxpj6ls_9w08ptlj_pmm0000gn/T/codex-clipboard-9741ecb9-a4e2-4fac-ae23-42ab0d215f05.png`
