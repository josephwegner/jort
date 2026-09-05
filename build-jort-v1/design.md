# Design: Jort V1

## Context

Jort is a native macOS scratch canvas built around one app-owned plain-text document. Its differentiator is not a novel document format; it is the combination of an extremely dependable typing path with optional organization, automation, AI, commands, and capture that never become prerequisites for editing.

The current React prototype is the interaction reference for dark-mode layout, the narrow gutter, landmark navigation, command palette placement, notifications, and inline invocation decoration. The older product brief uses the working name Scrib and shows earlier landmark and invocation treatments. Where they conflict, current decisions are authoritative:

- The product name is Jort.
- The command palette control lives in the title bar.
- A gutter button toggles between line numbers and a compact, top-aligned emoji landmark index within the same gutter width.
- An assigned emoji replaces its line number in normal gutter mode.
- Agent and command invocations decorate their actual document line; output becomes ordinary text immediately after that invocation.
- Context ranges are visibly shaded before Run.
- There is no permanent footer, sidebar, queue panel, or “Ask Jort” control.

The principal design risks are TextKit anchoring, logical-line identity across complex edits, useful revision coalescing, stale background mutations, and keeping every optional subsystem off the launch and keystroke paths.

## Goals and Non-goals

### Goals

- Make cold and warm launch feel like opening a minimal native text editor.
- Preserve canonical plain text while rendering metadata-rich behaviors around it.
- Establish deterministic identities for logical lines, paragraphs, ranges, and revisions.
- Make invocation context and authority visible at the moment of execution.
- Make background commits atomic, conflict-aware, undoable, and viewport-stable.
- Support local-first automation with narrow escape hatches for cloud models and registered executables.
- Provide external capture without turning the relay into a cloud note store.
- Build each subsystem behind a protocol boundary and lazy initialization point.

### Non-goals

- A multi-document architecture, file browser, notebook hierarchy, or blocks.
- Rich text, collaborative editing, or cross-device document sync in V1.
- A general agent runtime, assistant transcript, or streaming editor output.
- Arbitrary shell or filesystem access from JavaScriptCore.
- Final Mac App Store distribution selection before command sandbox prototypes.

## Architecture

```text
SwiftUI App Shell
├── Window/title controls, command palette, notifications, sheets
├── EditorHost (NSViewRepresentable)
│   └── JortTextView (NSTextView + TextKit 2)
│       ├── GutterCoordinator
│       ├── DecorationCoordinator
│       └── Viewport/selection preservation
├── DocumentActor
│   ├── In-memory DocumentState (authoritative while running)
│   ├── EditNormalizer / logical-line identity
│   ├── TransactionCoordinator / undo boundaries
│   └── PersistenceScheduler
├── SQLiteStore actor (WAL)
│   ├── Current state + metadata
│   ├── Full-state revisions
│   ├── Agent runs
│   └── External inbox
├── AutomationCoordinator
│   ├── Invocation parser + context manifest
│   ├── ProviderRegistry (lazy)
│   ├── JavaScriptCoreRuntime
│   └── CommandRegistry / ExternalCommandRunner
└── CaptureCoordinator
    ├── Relay client (lazy poll/push)
    ├── Connection routing
    └── Queue + acknowledgement state machine
```

The in-memory `DocumentState` is authoritative during a process lifetime. The editor sends normalized edit transactions to `DocumentActor`; it does not synchronously write SQLite. Background components request immutable snapshots and submit explicit transactions through the actor rather than mutating `NSTextStorage` directly.

## Core Data Model

Identifiers are UUIDs unless profiling proves a smaller representation is necessary.

```swift
struct DocumentState {
    var id: DocumentID
    var text: String
    var revision: Int64
    var lines: OrderedDictionary<LineID, LineMeta>
    var annotations: [AnnotationID: Annotation]
    var landmarks: [LandmarkID: Landmark]
}

struct LineMeta {
    var id: LineID
    var utf16Range: NSRange
    var createdAt: Date?
    var lastEditedAt: Date?
}

struct Landmark {
    var id: LandmarkID
    var lineID: LineID
    var emoji: String
    var label: String?
    var source: LandmarkSource
    var connectionID: ConnectionID?
}

struct ContextManifest {
    var invocationRange: AnchoredRange
    var submittedRanges: [AnchoredRange]
    var baseRevision: Int64
    var targetHashes: [TargetID: SHA256Digest]
    var capabilities: Set<Capability>
}
```

SQLite stores normalized current-state tables plus a versioned serialized full-state blob for revisions. The blob schema has an explicit version and migrations; restore never depends on reconstructing old state from an event log.

## Editing and Logical-line Identity

TextKit reports edits in UTF-16 coordinates. `EditNormalizer` captures the pre-edit logical lines intersecting the edited range plus one neighbor on each side, applies the edit, re-splits only that local window on newline boundaries, and maps old identities to new lines deterministically.

V1 inheritance rules:

1. An unchanged line keeps its identity and timestamps.
2. Editing within one line keeps that line identity and `createdAt`, and advances `lastEditedAt`.
3. Splitting a line keeps the original identity on the leading fragment; each non-empty trailing fragment receives a new identity and creation/edit timestamps at the edit time.
4. Joining lines keeps the identity of the leading line; removed identities become tombstones for the current undo group so undo can restore them.
5. A full-line replacement keeps identity only when the surrounding newline boundaries remain and the edit transaction identifies it as the same target; otherwise it creates a new identity.
6. Whitespace-only lines retain structural identity while present but have nil provenance timestamps.
7. Undo and redo replay the text plus identity delta as one undo group.

IME marked-text updates remain provisional. Identity reconciliation and persistence scheduling occur when composition commits, while decorations follow the temporary TextKit ranges for rendering.

## Landmark Anchoring and Gutter

Landmarks reference `LineID`, never a raw line number. `GutterCoordinator` derives visible logical-line rows from TextKit 2 viewport layout fragments and renders either:

- normal mode: line number or the line’s assigned emoji; or
- landmark mode: a top-aligned, dense list of landmark emoji in document order, one editor-line high per entry.

The toggle occupies a fixed slot above gutter content. Switching modes does not change gutter width or the text container origin. Clicking a landmark entry resolves its `LineID` to the current range, scrolls that paragraph into view, and returns focus to the editor.

When an edit deletes a landmark’s line, the edit transaction applies a deterministic policy: transfer to the surviving joined leading line only for a direct join; otherwise mark the landmark detached and require an explicit resolution. A connection targeting a detached/deleted landmark becomes unresolved and queues captures.

## Invocation and Context Decoration

The invocation parser observes edited logical lines and recognizes registered names after `@` or `/`. It records the actual invocation range and line identity. Unmatched text remains ordinary text.

Pending invocation UI is a TextKit decoration plus AppKit overlay controls anchored to the layout fragment for the invocation line. The decoration is constrained to that line height. Provider/locality, context control, and Run fit within the trailing overlay without modifying canonical text.

Context choices produce a `ContextManifest` before execution:

- prompt-only: invocation prompt range;
- full-line: the complete containing logical line;
- bounded before/after: explicit whole or partial ranges defined by the agent;
- entire document/history: never selectable without a separate preview and confirmation flow.

Selected context is drawn as background/border annotations behind the exact ranges. Changing the selection updates the manifest and decoration synchronously. Shift+Enter and Run call the same submission path.

## Run, Conflict, and Insertion Transactions

`AutomationCoordinator` receives an immutable input snapshot. A run may expose progress and Cancel in a fixed-height attachment but does not mutate text until completion.

On completion, `DocumentActor` validates the base revision and hashes:

- If the insertion anchor still resolves and nearby text has not invalidated placement, insert the complete output immediately after the invocation line.
- If the user edited elsewhere, rebase the anchor by `LineID` and preserve current selection/viewport.
- If the invocation line or mutation target changed materially, do not overwrite it. Offer a safe insertion at the current resolved boundary or an explicit conflict choice.

The commit is one undo group and one revision boundary. Inserted characters are canonical text. An `Annotation(kind: .insertion)` stores run ID, provider, timestamp, input manifest hash, and state. Merge deletes that annotation only; Delete is a separate explicit text mutation; Retry creates a new run.

## Permission Model

Agent configuration declares potential capabilities; each run receives only the subset granted by its manifest and fresh confirmations.

| Capability | Default | Enforcement |
|---|---|---|
| Prompt text | Allowed | Exact submitted range |
| Full logical line | Declared | Visible decorated line before Run |
| Bounded nearby text | Declared | Exact decorated ranges before Run |
| Entire document | Denied | Fresh preview + confirmation every request |
| Version history | Denied | Exact revision preview + confirmation every request |
| Network | Denied unless declared | Provider/tool identity visible before Run |
| Mutation | Narrow targets | Anchored ranges, revision, and hashes |
| External command | User invocation only in V1 | Registry lookup; agent requests rejected |

Consent records are run-scoped and auditable. There is no “always allow whole document/history” setting.

## Persistence and Revisions

`PersistenceScheduler` receives document transactions from `DocumentActor`, coalesces ordinary typing on an idle timer, and flushes on app deactivation/termination best-effort boundaries. Automation, capture, landmark changes, restore, and explicit bulk edits force meaningful revision checkpoints.

SQLite uses WAL, prepared statements, schema migrations, foreign keys, and explicit transactions. Suggested tables:

- `document`
- `line_meta`
- `annotation`
- `landmark`
- `revision`
- `agent_run`
- `provider_config`
- `script`
- `registered_command`
- `capture_connection`
- `external_inbox`
- `settings`

Revision coalescing starts with idle-, event-, and lifecycle-based rules and is tuned with real usage. Restoring a revision submits its full state through `DocumentActor`, creates an undo boundary, and writes a new revision that preserves the state being replaced.

## Provider and Automation Boundaries

`ModelProvider` is intentionally small: initialize lazily, report availability, execute messages with simple tool definitions, and return a complete response/tool request. Apple on-device and OpenAI-compatible URLSession implementations conform to the same protocol. Provider-specific features do not enter editor models.

`JavaScriptCoreRuntime` creates a fresh or pooled constrained context with only frozen bridge objects. It has execution time limits and output caps. No `process`, `require`, dynamic native module loading, ambient filesystem, or general network API exists.

`ExternalCommandRunner` accepts only a `RegisteredCommand` record containing an absolute executable identity/bookmark, structured argument template, declared stdin source, output mode, timeout, environment allowlist, and byte cap. It does not invoke a shell. V1 permits direct user `/command` invocation only.

## External Capture

The relay stores encrypted/authenticated opaque inbox payloads with source, recipient identity, received time, expiry, and acknowledgement state. It never stores the canonical Jort document.

`CaptureCoordinator` lazily fetches after the canvas is ready. For each item it resolves the connection’s stable `LandmarkID`:

1. Present and unambiguous: route using the connection policy.
2. Missing/detached: retain in `external_inbox` as queued and notify.
3. Deterministic section boundary: chronological append before the next landmark/boundary.
4. Fuzzy boundary: insert immediately below the landmark in V1.

Only after a local durable transaction does the client acknowledge delivery. Batch resolution commits queued items in source order as one undoable transaction.

## Performance and Failure Isolation

- Create and focus the editor before opening SQLite beyond the minimal current-state read or starting any optional service.
- Never initialize providers, JSC, command runners, relay polling, or plugin discovery on launch.
- Keep gutter calculation viewport-bounded; do not lay out the entire document for every scroll.
- Incrementally update logical-line metadata around edit windows.
- Perform SQLite, hashing of large ranges, search indexing, revision serialization, and network work off the main actor.
- Preserve and restore TextKit selection and viewport anchors around background commits.
- Use cancellation and actor isolation for every run/capture operation.
- Treat optional subsystem crashes and timeouts as operational records, not editor failures.

## Testing Strategy

- Text-edit property tests for split/join/replace/undo identity invariants.
- TextKit integration fixtures for wrapping, paste, IME composition, marked text, accessibility, and viewport gutter alignment.
- Snapshot/UI tests for normal and landmark gutter modes, inline invocation, context decoration, notification drawer, and history.
- SQLite migration, crash-recovery, coalescing, and atomic-restore tests.
- Run-conflict tests covering edits above, within, and after invocation targets.
- Permission tests proving whole-document/history access always requires fresh confirmation.
- JSC adversarial tests for missing globals, timeouts, output caps, and bridge authority.
- External command tests proving no shell expansion and enforcement of registration/limits.
- Capture state-machine tests for offline delivery, duplicates, missing landmarks, ordered resolution, acknowledgement, and expiry.
- Large-document benchmarks with explicit budgets for launch-to-focus, typing latency, gutter scroll, search, snapshots, and insertion.

## Rollout Sequence

1. Native editor and launch invariants.
2. In-memory logical-line identity, gutter, and anchoring stress tests.
3. SQLite current state and revision history.
4. Landmark navigation mode and large-document performance.
5. Built-in commands and JavaScriptCore.
6. Fake delayed agent with context decoration and atomic insertion.
7. Local provider and one compatible cloud provider.
8. Permission previews and stale-target resolution.
9. Registered external commands, user-only.
10. Relay inbox, capture routing, queue, and acknowledgement.

## Risks and Trade-offs

- **TextKit 2 maturity:** `NSTextView` may require targeted fallback behavior or AppKit-specific workarounds. Keep editor abstractions narrow and prototype viewport/gutter APIs first.
- **Line identity complexity:** Deterministic split/join rules add metadata machinery to a plain-text app. The alternative—raw offsets—would make timestamps, landmarks, undo, and background mutation unreliable.
- **Full-state revision size:** Simple restore semantics cost storage. Start with compression/coalescing and measure before adopting deltas.
- **External command distribution:** Direct distribution supports broader authority than the App Store sandbox. Keep this module isolated so the channel decision does not infect the editor.
- **Capture privacy/cost:** Relay retention, encryption, deletion, and pricing remain product decisions. Do not ship the relay before those are specified.
- **Broad V1 scope:** The architecture supports the full product, but implementation is deliberately gated by vertical slices so AI and capture cannot precede editor trust.

## Open Decisions and Prototype Gates

- Final paragraph-anchor rules for complex attributed-string edits and IME behavior.
- Revision coalescing thresholds and storage budget.
- Deterministic capture-section boundary definition.
- Exact large-document fixtures and latency budgets.
- Direct-provider and gateway first-run setup hierarchy.
- Relay encryption, retention, deletion, abuse prevention, and pricing.
- Mac App Store versus direct distribution after external-command prototype.
- Whether post-V1 agents may request registered commands with per-run confirmation.

