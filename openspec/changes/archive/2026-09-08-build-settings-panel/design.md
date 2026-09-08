## Context

Jort currently composes one editor window directly in `AppDelegate`. Its durable state is almost entirely canonical document state and retained history; there is no application-preference domain, Settings lifecycle, or configuration UI. `build-jort-run-tools` proposes a command registry and built-ins, but its current artifacts explicitly exclude JavaScript and user-defined tools. This change establishes a separate configuration boundary that can be adopted when that tool runtime is revised, without making Settings responsible for executing untrusted code.

The Settings window is modeless application chrome. It must remain available when the editor window is closed, must not participate in document undo/history, and must not make corrupt settings prevent access to the user's document. The app remains native AppKit, Swift 6 strict-concurrency compliant, local-only, and free of new third-party dependencies.

## Goals / Non-Goals

**Goals:**

- Provide one native Settings window with stable pane navigation and room for many future settings areas.
- Keep application configuration in a versioned, observable, independently recoverable domain.
- Provide a complete management experience for bundled tool templates and user-defined JavaScript tool definitions.
- Give the eventual tool runtime a coherent, revisioned catalog snapshot rather than access to view controllers or mutable UI state.
- Preserve native keyboard, text editing, focus, window, and accessibility behavior.

**Non-Goals:**

- Execute, preview-run, sandbox, debug, sign, download, import, export, or share JavaScript tools.
- Define tool permissions, ambient authority, package resolution, network access, shell access, or external-process access.
- Add a full IDE, language server, package-based editor, web view, or arbitrary preference-schema renderer.
- Move document, history-retention, or window-frame state into the new settings database.
- Redesign the editor window or place settings controls inside the document canvas.

## Decisions

### 1. Compose a native sidebar-and-detail Settings window from registered panes

`SettingsWindowController` owns one modeless `NSWindow` and an `NSSplitViewController`. Its source-list sidebar renders stable `SettingsPaneDescriptor` values (`id`, localized title, symbol, search keywords, and a view-controller factory). Each pane owns its view, draft state, validation, and commands behind a small context object; the application delegate only builds descriptors and routes window presentation.

The controller is retained for the process lifetime. Closing orders the window out, while reopening activates the same controller and last selected valid pane. Pane IDs, not row indexes, are persisted. If a pane disappears, selection falls back deterministically to the first available pane. The window uses autosaved frame state with explicit minimum sizes and collapses no pane below usable bounds.

Alternative considered: a toolbar-style `NSWindow` matching small macOS preference windows. A source list scales better once Jort accumulates tool, agent, storage, privacy, and editor settings and avoids continuously changing the toolbar structure.

### 2. Introduce a configuration domain independent of document persistence

Add a `JortSettings` framework containing Sendable models, validation, snapshots, revision tokens, and store protocols. `JortAppKit` renders those models; `Jort` composes the concrete store and pane adapters. The document coordinator never imports this module. This prevents settings changes from creating document transactions, autosaves, retained revisions, recovery checkpoints, or document Undo entries.

An actor-isolated concrete store uses the already-linked system SQLite library in `Application Support/<store name>/Settings/Settings.sqlite`. It has its own schema version and migrations, with normalized preference, bundled-template-override, and custom-tool records. Every mutation validates first and commits in one SQLite transaction. Observers receive one immutable `SettingsSnapshot` only after commit. Tests inject an in-memory store or isolated `JORT_DATA_DIRECTORY`.

Alternative considered: `UserDefaults`. It is appropriate for incidental scalar UI state such as the last selected pane, but not for multi-field tool records, bounded source blobs, per-record revisions, transactional updates, or preservation of unsupported future schemas. A single JSON file was also rejected because one malformed or large tool would couple every preference and tool update to rewriting the entire catalog.

### 3. Fail settings independently and preserve unsupported data

Settings load is asynchronous and cannot block construction of the document editor. A missing store creates current defaults. Known older schemas migrate transactionally after a pre-migration copy. A corrupt or future-version store is left untouched, custom tools remain unavailable, and Settings shows an actionable unavailable/read-only state with the source path and retry option. Jort does not silently replace that store with defaults. Bundled templates can still be presented from app resources, but runtime enablement must fail closed until persisted overrides are known.

The store enforces bounded record count, UTF-8 source size, string length, and decoded payload size before allocation or commit. SQLite errors are normalized and surfaced through the Settings pane without covering document text or terminating the app.

Alternative considered: automatically quarantine and reset on any settings error. That would keep the pane operational but could make user-authored source appear lost. Explicit recovery can be added later once import/export semantics exist.

### 4. Treat bundled tools as immutable templates and customization as duplication

Bundled `ToolTemplate` records live in versioned application resources and have stable IDs, display metadata, default enablement, command names, and JavaScript source. Settings may toggle their enablement and inspect their source, but does not edit the bundled record. “Duplicate to Customize” creates an independent `UserToolDefinition` with a new UUID, an optional `basedOnTemplateID`, copied fields/source, and a conflict-free proposed command name. App upgrades can therefore replace bundled templates without merging into user-authored code.

User definitions contain a stable ID, revision, display name, slash command name, summary, enabled state, and bounded UTF-8 JavaScript source. Command names are normalized and unique across bundled and user definitions whether enabled or disabled, avoiding runtime ambiguity. Custom definitions can be created, edited, enabled, disabled, and explicitly deleted after confirmation.

Alternative considered: editing a bundled template in place with sparse overrides. Source-level rebasing across app updates is hard to explain and can silently change behavior; independent copies make ownership and upgrade behavior explicit.

### 5. Save tool edits through explicit revisioned draft sessions

Selecting Create, Duplicate, or Edit opens a `ToolDraft` copied from one catalog revision. Simple enablement toggles commit immediately. Field and source edits remain local until Save. Save runs structural validation and an injected `ToolDefinitionValidator`, then performs a compare-and-swap against the base revision. A stale draft remains open and reports the conflict; it never overwrites the newer record.

Changing selection, closing Settings, or invoking another draft-producing action while dirty offers Save, Discard, or Cancel. Save failure leaves the draft and its local undo stack intact. Delete requires confirmation and cannot target bundled templates. Runtime observers see only committed snapshots, never partial drafts.

The validator boundary lets `build-jort-run-tools` later supply JavaScript parse and runtime-specific diagnostics. Before that integration, Settings validates required fields, command syntax and uniqueness, UTF-8/source bounds, and disallowed control characters, but does not claim JavaScript syntax or safety validation.

### 6. Build the source field as a focused native code-editing component

`JavaScriptSourceEditor` wraps a plain-text `NSTextView` in an `NSScrollView`, with monospaced text, line numbers, native selection, scrolling, Find, local Undo/Redo, and standard clipboard behavior. Rich-text paste, attachments, smart quotes, smart dashes, automatic substitutions, and spell checking are disabled so source round-trips exactly. The component reports line/column and accessible diagnostics, and keeps its undo manager local to the draft.

The first version does not add semantic highlighting, autocomplete, code execution, or a dependency. Diagnostics are rendered outside canonical source and selecting one moves the caret to its range. This keeps the editor lightweight while leaving a stable validator/diagnostic model for later enhancement.

Alternative considered: embedding a web editor such as Monaco. Its runtime size, accessibility surface, keybinding differences, and web-process/security cost are disproportionate to bounded scripts in the first tool release.

### 7. Expose a read-only catalog snapshot to execution code

`ToolCatalog` publishes immutable, validated, monotonically revisioned snapshots and change notifications. Settings mutates through typed store commands; a runtime consumes snapshots through the protocol and cannot reach draft or view state. Definitions whose persisted state is unavailable, invalid, conflicting, or disabled are absent from the executable projection. Settings itself never instantiates JavaScriptCore or calls an executor.

The current `build-jort-run-tools` artifacts use native deterministic executor closures and explicitly exclude JavaScript. They will require a later artifact revision to adopt this catalog and define execution/sandbox semantics. This change can be implemented and tested with a non-executing catalog adapter before that revision lands.

### 8. Route every entry point through one presenter

The Jort application menu adds “Settings…” with Command-comma. Pocket registers “Open Settings,” and both routes call the same presenter. If the window is already open, presentation activates it without creating another window, discarding a draft, resetting navigation, or stealing focus from the source editor inside Settings. Closing the final editor window does not terminate Settings or the app.

## Risks / Trade-offs

- **The Settings contract may precede the final JavaScript runtime design** → Keep execution, permissions, and runtime diagnostics behind narrow protocols; revise the tool change before connecting the executable projection.
- **A second SQLite store adds migration and failure paths** → Reuse existing low-level SQLite conventions, isolate its schema and tests, and never make document startup depend on Settings health.
- **Sidebar architecture is more structure than one pane needs** → Keep descriptors and context deliberately small; the stable pane boundary pays off as settings categories grow.
- **Users may mistake stored source for safe or runnable source** → Label validation accurately, provide no Run affordance, and never describe structural validation as a security guarantee.
- **Dirty-draft prompts can interrupt navigation** → Prompt only on destructive transitions, preserve draft/caret/undo state after failed saves, and allow Cancel to remain in place.
- **Bundled-template names can conflict with older custom definitions after an upgrade** → Validate the complete effective catalog; preserve the custom record and keep conflicting definitions non-executable until the user resolves the name.

## Migration Plan

1. Add the `JortSettings` models, protocols, empty schema, and isolated failure tests without exposing UI.
2. Add the Settings presenter, registered-pane shell, application menu command, and Pocket action with an initial Tools pane.
3. Seed versioned bundled template resources and enablement overrides, then add custom-tool CRUD and revisioned drafts.
4. Add the native JavaScript editor, validation/diagnostic presentation, dirty-transition handling, and accessibility coverage.
5. Revise `build-jort-run-tools` before runtime integration so its registry consumes committed executable catalog snapshots and defines JavaScript sandboxing separately.

Rollback removes the entry points and runtime consumption but leaves `Settings/Settings.sqlite` untouched for a future compatible build. Released schema versions are never downgraded or destructively rewritten.

## Open Questions

No blocking questions remain for the Settings foundation. JavaScript engine choice, permission manifests, runtime API shape, signing/trust, template update cadence, and import/export format belong to the revised tool-runtime change.
