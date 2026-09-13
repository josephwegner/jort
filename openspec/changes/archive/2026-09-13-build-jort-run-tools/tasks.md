## 1. Tool-package schema and registry

- [x] 1.1 Define the versioned `tool.json` schema for stable ID, package version, display metadata, slash command, script-entry contract, input mode, output operation, and byte and line caps.
- [x] 1.2 Define bundled and installed package locations, lazy discovery, schema and script validation, duplicate-ID and command resolution, and bounded diagnostics that isolate invalid packages.
- [x] 1.3 Implement non-UI registry operations to inspect, validate, install, enable, disable, update, remove, and restore tool packages.
- [x] 1.4 Implement immutable bundled definitions, persistent user overrides, resolution precedence, update preservation, and explicit restore behavior.
- [x] 1.5 Add manifest compatibility, malformed-package, conflict, override, update, restore, and unrelated-package-isolation tests.

## 2. Sandboxed JavaScript runtime

- [x] 2.1 Define the versioned asynchronous `tool.js` entry contract with one deeply frozen `content` input, structured output or error, deterministic host facilities, and cancellation observation.
- [x] 2.2 Implement an authority-free JavaScript host with no ambient network, filesystem, process, shell, application-state, native-bridge, plugin, dynamic-import, external-executable, package-discovery, or dynamic-evaluation access.
- [x] 2.3 Enforce per-execution generation ownership, cancellation, wall-clock timeout, memory and result bounds, exactly one terminal transition, and rejection of late or duplicate results.
- [x] 2.4 Convert script exceptions, sandbox violations, unavailable entry contracts, and resource exhaustion into bounded invocation-local failures without destabilizing the registry or app.
- [x] 2.5 Add adversarial sandbox-escape, dynamic-evaluation, native-bridge, timeout, cancellation-race, memory, duplicate-result, and exception-isolation tests.

## 3. Bundled tool packages

- [x] 3.1 Package `/date`, `/time`, `/uuid`, `/calc`, `/sort`, and `/dedupe` as ordinary `tool.json` and `tool.js` packages discovered through the installed-tool path.
- [x] 3.2 Implement injected captured-clock and UUID behavior plus documented locale-independent date and time defaults.
- [x] 3.3 Implement `/calc` as a purpose-built JavaScript lexer and parser for the bounded grammar, with deterministic arithmetic and no `eval`, `Function`, dynamic import, or host evaluation facility.
- [x] 3.4 Implement stable literal `/sort` and first-occurrence exact `/dedupe` transformations with trailing-newline preservation.
- [x] 3.5 Add bundled-manifest, shared-loader, no-native-fallback, deterministic-source, precedence, unary, malformed-syntax, zero-division, overflow, Unicode, duplicate, and empty-line tests.

## 4. Invocation and persistence model

- [x] 4.1 Add bounded invocation annotations containing package ID and version, entry contract, input mode and output operation, lifecycle generation and state, locks, stable anchors, input hash, output range, timestamp, and merge state.
- [x] 4.2 Extend snapshots, SQLite migrations, revision envelopes, current-state verification, history restore, and recovery with invocation annotations while excluding ephemeral prompt content.
- [x] 4.3 Implement committed-text recognition with exact enabled-registry and token-boundary matching while excluding provisional IME text and plain-text paste inference.
- [x] 4.4 Implement anchor updates around unrelated edits and invalidation when unsubmitted command text no longer resolves to a compatible enabled package.
- [x] 4.5 Add parser, migration, persistence, malformed-annotation, recovery, unmatched-punctuation, paste, IME, and schema-refusal tests.

## 5. Completion and three input modes

- [x] 5.1 Add slash-triggered completion backed by lazy package manifests and palette filtering without evaluating tool scripts.
- [x] 5.2 Implement Space and Return acceptance semantics for contained, contextual, and ephemeral commands without implicit execution.
- [x] 5.3 Implement contained canonical input ownership, Space inclusion, newline growth, focus entry and exit, and nested-invocation suppression.
- [x] 5.4 Implement contextual current-line initialization, contiguous scope with excluded invocation, text-selection-style handles, Command-Option character and line movement (with Option-Shift alias), exact content extraction, and collision clamping.
- [x] 5.5 Implement command-anchored single-line and multiline ephemeral prompts, focus transfer, offscreen movement, dismissal, irreversible prompt discard, and exclusion from copy, revisions, snapshots, and persistence.
- [x] 5.6 Add completion, Return, Space, Escape, click, keyboard, partial-line, multiline, offscreen-popover, context-extraction, focus, copy, and accessibility tests for all modes.

## 6. Asynchronous lifecycle and locking

- [x] 6.1 Implement focused Run and Shift-Return submission with manifest validation and immutable capture of package contract, content, anchors, hashes, deterministic facilities, and output operation.
- [x] 6.2 Lock submitted invocation plus contained input or complete contextual scope, permit selection and copy, reject editing commands touching locked text except confirmed pending deletions, and preserve unrelated edits.
- [x] 6.3 Add delayed processing presentation with only a spinner and accessible X Cancel action inside the owning green invocation region.
- [x] 6.4 Implement Cancel-to-plain-text, orange editable validation warnings, red locked execution errors and timeouts, Dismiss-to-inputting, and exactly one terminal transition per generation.
- [x] 6.5 Support concurrent nonoverlapping inputting, processing, error, and pending invocations, including several independently controlled invocations on one logical line.
- [x] 6.6 Add validation, lock-intersection, selection, copy, surrounding-edit, delayed-indicator, Cancel, timeout, Dismiss, duplicate-dispatch, concurrency, overlap, and cancellation-race tests.

## 7. Connected invocation geometry

- [x] 7.1 Derive connected decoration paths as unions of visible TextKit fragment rectangles across partial lines, visual wraps, and canonical newlines, removing shared internal edges and rounding only exposed corners.
- [x] 7.2 Render command-emphasized green source/input regions and purple canonical-output regions as one compound silhouette using a flush seam, shared edge, or short aligned neck.
- [x] 7.3 Integrate range geometry, contextual handles, control hit targets, gutter positions, noncanonical expanded rows, scroll destinations, and viewport restoration through `LinePresentationLayout` with bounded overscan.
- [x] 7.4 Place per-invocation spinner and Cancel controls inside green regions and icon-only Merge and Dismiss controls inside purple regions near the command token, with hover/focus labels and named accessibility actions.
- [x] 7.5 Preserve canonical line numbers for real newlines, blank gutter space for wraps and accessory rows, separate silhouettes for concurrent invocations, and canonical-only document accessibility values.
- [x] 7.6 Add rendered snapshots and interaction tests for midline, narrow-width, multiline, wrap, context-above/below, empty output, multiple-same-line, scrolling, focus, hit-target, VoiceOver, and large-document cases.

## 8. Canonical output and merge transactions

- [x] 8.1 Revalidate captured package contract, invocation anchor, content hash, generation, and output limits before publishing one complete result immediately after its owned invocation.
- [x] 8.2 Commit canonical output, line metadata, pending provenance, locks, undo registration, persistence, and semantic history boundary in one transaction without streaming or partial publication.
- [x] 8.3 Implement presentation-only empty-result pending state with enabled Merge and Dismiss actions and no canonical result characters.
- [x] 8.4 Implement atomic `replace-invocation`, `replace-context`, and `insert-at-invocation` Merge operations using the captured manifest contract.
- [x] 8.5 Implement pending Dismiss, execution-error Dismiss, immediate publication Undo, Merge Undo, Redo, and ordinary chronological ordering around unrelated edits.
- [x] 8.6 Preserve exact unrelated text, selection anchors, viewport position, line metadata, provenance, persistence, and history across successful, empty, dismissed, merged, undone, and failed transactions.
- [x] 8.7 Add atomicity, output-cap, empty-replacement, each-operation, Undo/Redo, write-failure, relaunch, history-restore, and viewport tests.

## 9. Package migration and recovery

- [x] 9.1 Capture package ID, version, entry contract, input mode, and output operation in persisted invocation state and implement bounded package-provided mapping without rerunning completed output.
- [x] 9.2 Implement unmappable inputting fallbacks that retain contained `/tool` plus input, contextual `/tool` plus source, and ephemeral `/tool` as ordinary canonical text.
- [x] 9.3 Implement unmappable completed fallbacks that remove `/tool` and contained input where applicable, retain canonical output, and leave no replacement for empty completed output.
- [x] 9.4 Drop missing, malformed, hash-mismatched, or corrupt metadata and locks while preserving every canonical character as ordinary text.
- [x] 9.5 Verify bundled-package updates preserve user overrides, override removal restores current bundled definitions, and invalid overrides isolate failures without erasing user files.
- [x] 9.6 Add version-mapping, inputting fallback, pending-output fallback, empty-output fallback, corrupt-metadata, interrupted-write, override-update, and restore tests.

## 10. Release gates

- [x] 10.1 Benchmark package discovery, manifest validation, JavaScript-host startup, invocation parsing, connected geometry, contextual movement, lifecycle transitions, and command commit with `CrawlLargeDocument`.
- [x] 10.2 Re-run prior launch, typing, scrolling, search, history, persistence, recovery, gutter, landmark, IME, native Find, command-palette, and accessibility gates.
- [x] 10.3 Audit bundled and installed packages to prove loader/runtime parity and no ambient network, filesystem, provider, native bridge, dynamic evaluation, plugin, shell, process, or external-executable authority.
- [x] 10.4 Confirm no new Settings panel, marketplace/distribution UI, permission-granting system, `@agent`, model provider, streaming output, background agent run, or provider configuration is implemented in this slice. The existing Tools settings panel is adapted as explicitly authorized during implementation.

## 11. User feedback follow-up

- [x] 11.1 Insert acceptance spaces, expose errors, support immediate Command-Option context movement, distinguish handles, and dismiss pending output with Escape.
- [x] 11.2 Confirm pending deletions, preserve unselected canonical text, and support atomic Undo while retaining processing locks.
- [x] 11.3 Append content in date/time/UUID packages and fix new-tool Save, enablement, and editor discovery.
- [x] 11.4 Fix control/text overlap and seam spacing, clamp multiline wrappers, show Shift-Enter on Run, and redesign completion as a compact rounded overlay.
- [x] 11.5 Surface invocation and pending metadata simply in history comparisons, including metadata-only changes.
- [x] 11.6 Verify feedback with focused native/settings/history tests and rendered interaction checks; record remaining release qualifications.

## 12. Follow-up polish and Undo regression

- [x] 12.1 Align source/output wrapper heights, tighten Run spacing, add pointer/hover affordances, extend contained wrappers onto trailing empty lines, and remove duplicate ephemeral inline Run.
- [x] 12.2 Invalidate decoration styling whenever canonical storage is replaced, including Merge Undo; verify pending controls reserve space after restoration.
- [x] 12.3 Expose enablement beside the Tools heading and clip the source editor/ruler to their own bounds.
- [x] 12.4 Strip exactly one leading U+0020 from submitted content for every input mode without changing canonical text; verify behavior and rendered regressions.

## 13. Final layout feedback

- [x] 13.1 Preserve canonical result alignment, unify pending colors, prevent trailing action overlap, and enforce hand cursors through text-view cursor handling.
- [x] 13.2 Populate Settings categories and direct window growth into the tool editor.
- [x] 13.3 Flip bottom-edge prompts, decorate appended EOF output, and restore Undo/Redo presentation synchronously.
- [x] 13.4 Verify native layout regressions and record remaining interactive qualification.

## 14. Reopened cursor and viewport regressions

- [x] 14.1 Exclude embedded buttons from the text view's I-beam cursor regions and verify named accessible actions/cursor routing.
- [x] 14.2 Refresh cached decoration on viewport changes during painting, including scrolling into output beyond the old EOF viewport.
- [x] 14.3 Exclude a contextual range's trailing newline insertion position from its painted silhouette so the next unowned character is not wrapped.
- [x] 14.4 Run accessibility-based app tests and the full native tool suite for these regressions.

## 15. Glyph boundaries and ephemeral overlay stacking

- [x] 15.1 Reproduce contextual midline suffix overlap before fixing it; bound source/output silhouettes by the next shaped glyph rather than padded selection rectangles.
- [x] 15.2 Move persistent ephemeral prompts to the root overlay above rebuilt inline controls, preserving dark appearance, anchoring, focus, and offscreen behavior.
- [x] 15.3 Verify pending/source suffix clearance, Undo, overlay hit-testing after repeated refreshes, and native tool/accessibility regressions.
