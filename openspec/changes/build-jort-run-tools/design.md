## Context

This change depends on completed Crawl, Walk, Run history/search, and editor-shell changes. Its purpose is to prove the invocation, asynchronous lifecycle, and mutation UX with local deterministic code before agents or providers add external authority risks. Invocation tokens, contained input, contextual input, and published output remain ordinary canonical text; input boundaries, locks, lifecycle state, controls, and provenance are metadata-backed presentation.

The editor shell already provides `LinePresentationLayout`: presentation-only accessories can expand a canonical line's vertical band without creating fake lines or entering copied, searched, saved, or exported text. Tool UI extends that geometry from line-local accessories to connected decorations over exact canonical ranges, including ranges that wrap or cross real newlines.

## Goals / Non-Goals

**Goals:**

- Recognize only registered slash commands without changing unmatched typing.
- Define one inspectable, installable JavaScript tool-package format shared by bundled and user-authored tools.
- Run every tool in a bounded sandbox without ambient authority or a privileged bundled-tool execution path.
- Support contained canonical input, adjustable contextual canonical input, and ephemeral anchored prompt input through one command contract.
- Preserve ordinary plain-text copy, paste, save, recovery, line numbering, and revision behavior for all canonical command content.
- Keep Return as newline insertion after completion acceptance and make execution explicit through Shift-Return or Run.
- Make invocation ownership and contextual scope visible through one connected, accessible wrapper across visual wraps and logical lines.
- Give every invocation an asynchronous submitted, processing, error, pending-merge, Merge, Dismiss, Cancel, and Undo lifecycle.
- Publish successful output atomically as canonical text before Merge, then apply the tool's declared output operation on confirmation.
- Establish bounded provenance, recovery, and tool-version behavior reusable by agents.

**Non-Goals:**

- `@agent` recognition, model providers, network access, background agent runs, or provider configuration.
- Settings-panel UI, marketplace/distribution UI, or permissions for network, filesystem, process, shell, native bridging, plugins, or external executables.
- Nested or overlapping invocation-owned ranges.
- Per-tool visual styling or multiple input modes for one tool definition.
- Streaming or partially canonical output.

## Decisions

### 1. Register every tool through one package manifest

Every tool is a package containing a declarative `tool.json` manifest and a `tool.js` implementation. Bundled and user-installed packages use the same loader, schema validation, registry, sandbox, lifecycle, cancellation, timeout, and output validation. Bundled tools have no privileged native executor path.

The manifest contains a stable reverse-DNS-style tool ID, positive integer package version, display name, slash command, description, script-entry contract version, one input mode, one output operation, and byte and line output caps. Input modes are `contained`, `contextual`, `ephemeralSingleLine`, and `ephemeralMultiline`. Output operations initially include `replace-invocation`, `replace-context`, and `insert-at-invocation`; defaults are `replace-invocation` for contained input, `replace-context` for contextual input, and `insert-at-invocation` for ephemeral input. Merge confirmation is always required.

The manifest, rather than arbitrary script behavior, determines invocation presentation and merge semantics. Each package exposes one asynchronous script entry point that receives a deeply frozen input object containing exactly one `content` string, explicit captured deterministic host facilities, and cancellation state. It returns a bounded structured result containing output text or a structured failure and cannot mutate the document directly. Commands have no separately parsed arguments.

The registry discovers bundled and installed packages and exposes non-UI operations to inspect, validate, install, enable, disable, update, remove, and restore them. The separate Settings change consumes those operations. Editing a bundled tool creates a user override while its shipped definition remains immutable and restorable; application updates never overwrite that override. Resolution precedence is a valid enabled user override, then its bundled definition, then unavailable. Duplicate IDs or slash commands, malformed manifests, and invalid scripts disable only the affected package and produce bounded diagnostics.

### 2. Run scripts inside an authority-free JavaScript boundary

The JavaScript host exposes only the frozen invocation object, deterministic clock/UUID facilities, result construction, and cancellation observation required by the declared entry contract. Tool code has no ambient network, filesystem, process, shell, application-state, native-bridge, plugin, dynamic-import, external-executable, or package-discovery authority. Manifest text cannot grant authority. Any future capability-bearing API requires a separate permission design and specification.

The runtime enforces wall-clock timeout, cancellation, memory and result bounds, and exactly one terminal result. Each submission receives a generation; cancellation, timeout, or completion claims its terminal transition, and late results from cancelled or superseded generations are ignored. Script exceptions and sandbox violations become invocation-local execution failures rather than application failures.

`/date`, `/time`, `/uuid`, `/calc`, `/sort`, and `/dedupe` ship as ordinary bundled packages in this same format. Explicit captured clock and UUID facilities keep their tests deterministic without exposing ambient host state. A package may provide bounded migration logic that maps persisted input and output state from an older version.

### 3. Parse invocations as metadata over canonical text

The lazy command registry exposes validated package identities and manifest presentation contracts without eagerly evaluating `tool.js` implementations. The parser observes committed text and recognizes only commands from enabled valid packages. Pending state stores stable line identities and line-relative UTF-16 anchors rather than relying on untracked global offsets. Unmatched, abandoned, copied, or pasted slash text remains ordinary text with no inferred rich semantics.

### 4. Make completion acceptance distinct from execution

Typing `/` opens filtered command completion. Space or Return accepts a selected command without running it. Space is inserted into canonical text for contained and contextual modes; Return is consumed during acceptance. Ephemeral modes consume either acceptance key and transfer focus into their popover. Once completion closes, Return resumes its native meaning and inserts a newline in multiline canonical input. Shift-Return and the visible Run action dispatch one identical execution path only while invocation-owned content or a contextual boundary is focused; Shift-Return does nothing during unrelated document editing.

Editing a recognized command token before submission immediately revalidates it. If it no longer names a compatible command, Jort drops invocation metadata and leaves all canonical token and input characters as ordinary text. Changing an ephemeral command closes its popover and discards the noncanonical prompt. Escape closes completion first; when no completion is open, it abandons an unsubmitted canonical invocation, or closes an ephemeral prompt, while retaining canonical text.

### 5. Model three input ownership experiences

**Contained canonical input.** Accepting the command creates an empty owned range immediately after the command. A Space used for acceptance becomes its first character. The command and subsequently typed input form one invocation-owned canonical range; Return inserts a real newline and expands that range. Clicking outside leaves the invocation valid but unfocused, and clicking or navigating back inside resumes it. Contained boundaries are extended by editing from within rather than by draggable handles. Nested invocation recognition is disabled inside the range.

**Contextual canonical input.** Accepting the command places scope boundaries at the beginning and end of its current logical line, excluding the newline. The user can move either boundary to any legal character position by dragging text-selection-style handles or by using Option-Shift with Left, Right, Up, or Down. Ordinary Shift-arrow remains native text selection. Scope is one contiguous canonical range containing exactly one excluded invocation-token range; the executor receives the exact text before and after `/command` concatenated in document order. Jort removes only the command characters from submitted content and otherwise preserves whitespace and newlines exactly. Boundaries stop at the nearest legal position before another active invocation and ranges may never overlap.

Before submission, contextual source remains editable and its anchors track ordinary edits. Clicking or keyboard-navigating inside its connected wrapper makes the invocation active without changing normal caret behavior. Clicking outside deactivates it but does not dismiss it.

**Ephemeral prompt input.** An ephemeral tool opens a focused single-line field or multiline text area whose left edge begins at the command token's right edge and whose top edge begins at the token's bottom edge. The popover remains anchored to the token and naturally moves offscreen with it. Its input never enters canonical text, copy, paste, revisions, snapshots, persistence, or recovery. Escape or its X action closes the popover, discards its content, and leaves the command as plain text. Multiple nonoverlapping ephemeral prompts may remain open.

### 6. Use a single asynchronous state machine for every tool

Every tool, including fast deterministic built-ins, uses the same asynchronous coordinator:

```text
completion -> inputting -> submitted/locked -> processing -> pending merge
                   ^              |               |             |     |
                   |              |               |             |     +-> Merge
                   |              |               |             +-------> Dismiss
                   |              |               +---------------------> error -> Dismiss
                   |              +-------------------------------------> Cancel -> plain text
                   +---------------------------------------------------- Undo/Dismiss
```

Shift-Return or Run validates manifest-declared constraints, captures immutable package identity, version, entry contract, anchors, content, input hash, output operation, and execution context, and only then evaluates the package script. Validation failure does not submit: it retains editable input and uses an orange warning treatment. Submission locks the command plus contained input or the complete contextual scope. Selection and copy can cross locked text, but any editing command whose selection contains locked text is rejected in full. Unrelated surrounding text remains editable and stable anchors track those edits.

A processing indicator appears only after a configured delay so fast commands do not flash transient chrome. Processing UI lives inside the invocation's green region and contains only a spinner and an X action labeled Cancel for accessibility and hover. Each invocation owns its indicator, allowing multiple independent invocations on one line or elsewhere. Cancel drops lifecycle metadata and leaves invocation and canonical input as ordinary text. Executors support cancellation now even though deterministic built-ins normally finish quickly.

Execution failure or timeout publishes no output, retains locked source, applies a red error treatment, and offers Dismiss only. Dismiss returns the invocation to its exact pre-submit editable state. There is no Retry control; the user can submit again after dismissal.

### 7. Draw canonical ranges as connected presentation geometry

Contained and contextual wrappers are the geometric union of their visible TextKit fragment rectangles, not independent rounded rectangles per fragment. Consecutive visual fragments and canonical lines share internal edges; only the union's exposed outer corners are rounded. The decoration follows partial first and last lines, visual wrapping, and any intervening full-width fragments as one continuous silhouette. Green tint and border identify invocation and input ownership, with the slash command rendered in a stronger weight while input retains document typography.

Canonical newlines continue to create numbered logical lines. The wrapper never includes the gutter: the first visual fragment of a logical line aligns with its number, wrapped fragments use ordinary blank gutter space, and noncanonical status rows expand their anchor line's presentation band without receiving an ordinal. Geometry remains viewport-bounded with bounded overscan and uses the shell's shared `LinePresentationLayout` source so decoration, handles, hit targets, gutter positions, scrolling, and viewport restoration stay aligned.

Pending output uses a purple tint and border and joins the green source region as one compound silhouette. Inline output shares a flush seam with its invocation. Output on later fragments or lines connects through a shared edge or short neck aligned to the invocation, rather than appearing as a detached card. Source and output remain semantically distinct ranges inside the connected shape. Multiple invocations on one line retain separate silhouettes and controls.

### 8. Publish canonical output before Merge

A tool script returns either one complete bounded UTF-8 result or a structured error and never mutates the editor directly. On success, the coordinator revalidates package identity, captured manifest contract, source anchors, and input hash, then inserts the complete result immediately after the owned invocation as canonical text. Output characters, lifecycle metadata, line metadata, undo registration, persistence, and a semantic history boundary normally commit in one transaction. No streaming or partial publication occurs.

An empty successful result still enters pending merge but inserts no canonical characters. A presentation-only empty-result state appears in the connected pending region; Merge remains enabled because empty replacement may be intentional, including deletion under `replace-context`.

Pending actions live inside the purple output region near the command token. Merge uses a pull-request-style merge icon and Dismiss uses an X; neither has a persistent text label or separate explanatory row. Hover or keyboard focus exposes the labels, and accessibility always exposes named actions with adequate hit targets. Purple styling and connected geometry communicate pending state without grey hint prose or a redundant status label.

### 9. Define Merge, Dismiss, locking, and Undo as transactions

Merge applies the captured output operation atomically. `replace-invocation` deletes the command and contained input so output moves to the invocation's start. `replace-context` deletes contextual source and the invocation and places output at the scope's start. `insert-at-invocation` deletes the invocation and leaves contextual or ephemeral source plus output in their declared order. Merge removes lifecycle provenance after applying the mutation.

Dismiss from pending merge deletes canonical output and restores the exact pre-submit editable invocation, source, selection anchors, viewport, and metadata. Dismiss from an execution error performs the same restoration without output deletion. Cancel during processing differs intentionally: it removes metadata and leaves invocation and input as ordinary text.

Immediate Undo after output publication behaves like Dismiss and restores inputting state. Undo after Merge restores the prior pending source-plus-output compound state. Unrelated edits participate in ordinary chronological Undo order, so reversing later edits occurs before reversing publication or Merge. Edits that partially or wholly select locked text are rejected rather than interpreted as Dismiss; lifecycle actions remain explicit.

### 10. Persist bounded state and degrade to canonical text

Snapshots and SQLite persistence store bounded invocation state: package ID and version, entry contract, captured input mode and output operation, invocation identity and anchors, content/input hash, contextual or contained boundaries, output anchor and range, lifecycle state, timestamp, and merged state when applicable. Ephemeral content is never stored. Canonical output and matching lifecycle metadata normally persist in one atomic transaction.

On relaunch, an inputting or pending invocation restores its connected decoration when all anchors and hashes validate. Missing, malformed, or corrupted metadata is dropped without altering canonical content, even when this leaves a peculiar but recoverable mixture of invocation, input, and output as plain text.

When a package version or manifest contract changes, Jort first attempts its bounded mapping without executing completed output again. If it cannot map an inputting state, contained input retains `/tool` and its input, contextual input retains `/tool` and source, and an ephemeral invocation retains `/tool`; all become ordinary text. If it cannot map completed output, Jort removes the command and contained input where applicable but preserves canonical output. An empty completed output removes the command and contained input and leaves no replacement.

### 11. Keep bundled deterministic packages bounded and uniform

The bundled `/date`, `/time`, `/uuid`, and `/calc` manifests declare contained canonical input and default to `replace-invocation`. Bundled `/sort` and `/dedupe` declare contextual input and default to `replace-context`. All packages use the shared asynchronous lifecycle even when their execution completes before the processing-indicator delay.

The `/calc` package implements a purpose-built expression parser for decimal numbers, parentheses, unary signs, and `+ - * / % ^`; it does not use `eval`, `Function`, dynamic import, locale-dependent parsing, or any host dynamic-evaluation facility. `/sort` sorts selected logical lines using stable literal ordering, and `/dedupe` retains the first exact occurrence of each selected logical line. Division by zero, invalid syntax, overflow or nonfinite results, stale anchors, and output over manifest byte or line caps fail without canonical mutation.

## Risks / Trade-offs

- **Connected wrappers can fragment or disturb TextKit layout** -> Union only visible fragment rectangles, remove shared internal edges, use one presentation geometry source, and retain wrap/newline/viewport snapshots.
- **Range locking can break native editing expectations** -> Reject whole edits that contain locked text, keep selection and copy native, expose explicit Cancel/Dismiss, and test delete, replace, paste, IME, and Undo paths.
- **Context can collide with another invocation** -> Index active ranges and clamp pointer and keyboard boundary movement to the nearest legal character.
- **Cancellation can race with completion** -> Give each submission one generation and accept exactly one terminal transition; late results from cancelled or superseded generations are discarded.
- **Canonical output can outlive its metadata** -> Commit output and metadata atomically in normal operation and preserve all canonical characters if metadata is later absent or corrupt.
- **Tool definitions can drift across relaunch** -> Capture ID/version/operation, attempt explicit bounded migration, and otherwise apply the documented plain-text fallback.
- **User scripts can escape or exhaust their host** -> Expose no ambient bridge or authority, validate scripts before enabling them, enforce runtime resource limits, and add adversarial sandbox and denial-of-service tests.
- **Bundled updates can overwrite user intent** -> Resolve a valid user override before its immutable bundled definition and require explicit restore or override removal.
- **Malformed or conflicting packages can poison discovery** -> Isolate validation, diagnose duplicate identities and commands deterministically, and disable only affected packages.
- **Large multiline wrappers can affect scrolling and action discovery** -> Keep actions near the command token, preserve the top visible stable line and relative offset, and benchmark viewport-bounded geometry on large documents.
- **Calculator parsing creates security or correctness risk** -> Implement a small deterministic grammar with exhaustive parser and numeric-limit tests.
- **Commands can create huge output** -> Enforce byte and line caps before document mutation.

## Migration Plan

1. Define and validate the `tool.json` schema, `tool.js` entry contract, package locations, registry precedence, user overrides, and bounded diagnostics.
2. Add the authority-free JavaScript host, cancellation and timeout enforcement, deterministic host facilities, resource bounds, and sandbox-adversarial tests.
3. Package `/date`, `/time`, `/uuid`, `/calc`, `/sort`, and `/dedupe` through the same discovery path used for installed tools, with no native executor fallback.
4. Extend persisted annotations with package version, entry contract, input mode, output operation, state, anchors, hashes, and bounded migration behavior without enabling recognition.
5. Add completion acceptance and the contained, contextual, and ephemeral input experiences with script execution disabled.
6. Add connected range-union geometry, focus, handles, overlap prevention, keyboard movement, accessibility, and locking.
7. Add the cancellable asynchronous coordinator, delayed processing indicator, validation warnings, execution errors, and timeout handling.
8. Publish bounded canonical output into pending merge and add connected green/purple geometry, empty-result presentation, Merge, Dismiss, and complete Undo semantics.
9. Enable bundled and user-installed packages after atomicity, override, migration, recovery, and sandbox tests pass.
10. Run native editing, persistence, recovery, accessibility, viewport, and large-document regression gates before later Settings and agent features consume the contract.

Older builds preserve and refuse the newer annotation schema rather than dropping invocation state.

## Open Questions

No blocking questions remain. Locale-aware sorting, configurable calculator precision, alternate output placements, and per-tool user-overridable input modes are deferred.
