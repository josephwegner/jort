## 1. Configuration domain and project structure

- [x] 1.1 Add the `JortSettings` framework, generated-project dependencies, test target coverage, and strict-concurrency build settings through `project.yml`.
- [x] 1.2 Define stable preference, template, custom-tool, draft, diagnostic, record-revision, catalog-revision, and immutable snapshot models.
- [x] 1.3 Define configured count, string, decoded-payload, and UTF-8 source bounds plus command-name normalization and catalog-wide uniqueness validation.
- [x] 1.4 Define actor-safe settings-store commands, compare-and-swap results, snapshot observation, tool-validator, and read-only executable-catalog protocols.
- [x] 1.5 Add model and protocol-contract tests for Unicode, identifiers, normalization, bounds, Sendable snapshots, validation ranges, and revision ordering.

## 2. Independent settings persistence

- [x] 2.1 Implement an actor-isolated system-SQLite settings store at `Settings/Settings.sqlite` with its own schema version, normalized preference, template-override, and custom-tool records.
- [x] 2.2 Create a missing store from current defaults and load it asynchronously without delaying or changing document-store initialization.
- [x] 2.3 Implement validated transactional preference, enablement, custom-tool create/update, and delete commands that advance one coherent catalog revision only after commit.
- [x] 2.4 Implement per-record compare-and-swap conflict detection and return the current revision without overwriting a stale writer.
- [x] 2.5 Implement supported migrations with pre-migration preservation and reject corrupt or future schemas without opening a writable downgrade path or silently resetting data.
- [x] 2.6 Normalize load/write failures into observable unavailable and retry states while retaining the last authoritative committed snapshot.
- [x] 2.7 Add round-trip, atomic rollback, stale-writer, bounds, corrupt/future schema, migration-copy, injected-failure, concurrent-reader, and relaunch tests.
- [x] 2.8 Prove with integration tests that settings mutations and failures create no document transaction, Undo entry, autosave generation, recovery checkpoint, history revision, or restore side effect.

## 3. Extensible Settings workspace

- [x] 3.1 Define `SettingsPaneDescriptor`, pane lifecycle and dirty-transition contracts, and the small composition context supplied to pane factories.
- [x] 3.2 Implement a process-retained modeless `SettingsWindowController` with an `NSSplitViewController`, accessible source-list sidebar, one detail host, and deterministic initial selection.
- [x] 3.3 Persist the selected stable pane ID and window frame, enforce usable sidebar/detail minimums, and fall back safely when a remembered pane is unavailable.
- [x] 3.4 Implement asynchronous Save, Discard, and Cancel negotiation for pane changes, window close, and draft replacement, preserving focus and draft state after failed save or Cancel.
- [x] 3.5 Add the Jort-menu Settings command and Command-comma shortcut through one presenter, keeping Settings usable when the editor window is closed.
- [x] 3.6 Register Open Settings in Pocket and route it through the same presenter while preserving document selection and viewport.
- [x] 3.7 Add controller tests for singleton presentation, reopen behavior, pane registration/removal, focus restoration, resizing, dirty transitions, editor-window closure, and Pocket routing.

## 4. Bundled templates and committed tool catalog

- [x] 4.1 Define and validate a versioned bundled-template resource format with stable IDs, metadata, default enablement, JavaScript source, and deterministic loading order.
- [x] 4.2 Add representative bundled-template fixtures for tests and wire the production resource loader so the revised tools change can supply the actual initial template set without UI changes.
- [x] 4.3 Merge bundled defaults, persisted enablement overrides, and committed custom tools into one immutable catalog snapshot while preserving overrides across template-version updates.
- [x] 4.4 Implement New Tool and Duplicate to Customize domain commands with new UUIDs, optional ancestry, copied source, explicit defaults, and conflict-free proposed command names.
- [x] 4.5 Project only committed, enabled, valid, non-conflicting definitions into the read-only executable catalog and fail closed whenever settings state is unavailable.
- [x] 4.6 Add tests for template upgrades, removed/added templates, override retention, independent duplicates, command collisions, invalid definitions, deterministic ordering, and executable filtering.

## 5. Tools settings pane and draft workflow

- [x] 5.1 Implement the Tools pane master-detail layout with origin, display name, command name, enablement, and validation status exposed without relying on color alone.
- [x] 5.2 Render bundled template metadata and source read-only with Enable/Disable and Duplicate to Customize actions, and expose no destructive template delete action.
- [x] 5.3 Implement custom-tool creation and editing with display-name, slash-command, description, enablement, and source fields backed by an isolated revisioned `ToolDraft`.
- [x] 5.4 Validate drafts incrementally through structural checks and the injected validator, associate diagnostics with fields or source ranges, and block Save only for blocking diagnostics.
- [x] 5.5 Implement explicit Save and Discard, preserving caret, selection, and local undo state on validation, storage, or stale-revision failure.
- [x] 5.6 Implement immediate enablement commits with last-value restoration and actionable feedback on failure, without exposing an uncommitted toggle to catalog observers.
- [x] 5.7 Implement confirmed custom-tool deletion with transactional catalog removal and Cancel behavior that preserves selection and revision.
- [x] 5.8 Present loading, empty, unavailable, retry, and conflict states inside the pane without blocking or covering the document editor.
- [x] 5.9 Add view-model and native-view tests for selection, row states, duplicate/create/save/discard/delete, validation, stale drafts, failed writes, dirty-transition negotiation, and accessibility labels/actions.

## 6. Lightweight JavaScript source editor

- [x] 6.1 Build `JavaScriptSourceEditor` from `NSTextView` and `NSScrollView` with monospaced plain text, bounded input, stable line numbers, line/column status, wrapping/scrolling, and exact UTF-8 round trips.
- [x] 6.2 Disable rich attachments, smart quotes, smart dashes, spelling, automatic substitutions, and other source-altering text services while preserving normal selection and clipboard behavior.
- [x] 6.3 Provide a draft-local Undo manager, Redo, native Find, and expected keyboard routing without reaching the document editor's Undo stack or selection.
- [x] 6.4 Render diagnostics outside source text and make diagnostic activation reveal the valid source range with accessible line, column, severity, and message announcements.
- [x] 6.5 Add Unicode, tabs/newlines, large bounded source, oversize rejection, paste, exact-save/reload, Undo/Redo, Find, line-number scrolling, diagnostic navigation, IME, and accessibility tests.

## 7. Failure isolation and lifecycle integration

- [x] 7.1 Compose the concrete settings store, bundled-template loader, validator, catalog, Settings presenter, and registered Tools pane in `JortApp` without giving view code direct storage access.
- [x] 7.2 Ensure application launch, editor use, document save/restore, window reopen, and termination remain functional when settings loading is slow, corrupt, future-versioned, or fails writes.
- [x] 7.3 Ensure window dismissal, application deactivation, and termination resolve dirty Settings drafts without prematurely destroying their local state or delaying unrelated document persistence.
- [x] 7.4 Audit the Settings target and UI to prove it does not instantiate a JavaScript engine, invoke a tool, request network/shell/filesystem authority for scripts, or launch an external process.

## 8. Release gates and tool-runtime handoff

- [x] 8.1 Add UI smoke coverage for menu, Command-comma, Pocket, singleton Settings lifecycle, keyboard-only tool creation, failed validation, save/relaunch, toggle, and confirmed deletion.
- [ ] 8.2 Re-run generated-project drift, formatting, strict-concurrency, foundation, native AppKit, persistence, UI, accessibility, migration, recovery, performance, and clean Release-package gates.
- [x] 8.3 Benchmark Settings startup, large bounded catalog load, sidebar selection, source editing, validation, and snapshot publication while confirming no editor typing or scrolling regression.
- [x] 8.4 Document local settings storage, template-versus-custom ownership, recovery behavior, validation limits, and the explicit absence of script execution in this change.
- [x] 8.5 Verify the Settings implementation against a non-executing catalog adapter and document the exact follow-up contract `build-jort-run-tools` must adopt before JavaScript runtime integration.
