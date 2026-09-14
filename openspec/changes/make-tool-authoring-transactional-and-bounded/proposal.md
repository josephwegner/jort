## Why

Tools Settings currently starts an unowned asynchronous save and then polls draft state for up to two seconds when the user tries to leave, so a slow save can be reported as failed while later committing and repeated actions can overlap on the same revision. At the storage layer every save creates another immutable UUID generation, but old, deleted, orphaned, and partially written generations are never reclaimed.

## What Changes

- Make draft save an awaited, typed, single-flight operation that owns validation, durable publication, conflict/failure reporting, and final UI reconciliation.
- Serialize or disable conflicting Tools Settings mutations while a save is in flight, and make pane changes, draft replacement, window close, and termination await the exact save result instead of polling UI state.
- Preserve failed or conflicting drafts, including selection, caret, and source-editor undo state.
- Upgrade the tool package index to track the active generation and the five most recent previous valid generations for each active custom tool.
- Publish and verify a staged immutable generation, durably publish the new index, and only then garbage-collect generations outside the retention set.
- Clean abandoned staging and unreferenced generation directories safely during startup; a deliberate deletion or bundled-override restoration removes all retained generations only after the new index is durable.
- Narrow mutable Tools Settings controls to internal/private ownership and test user-observable behavior through actions or focused fixtures.

## Capabilities

### New Capabilities

None. This change strengthens existing tool registry, tool configuration, and Settings transition behavior.

### Modified Capabilities

- `deterministic-builtins`: Bounds immutable user-package generations, makes package/index publication crash-safe, and defines safe startup garbage collection and deletion ordering.
- `tool-configuration`: Makes validated custom-tool save single-flight and awaited, and aligns deletion with durable removal of retained package data.
- `settings-workspace`: Requires pane, draft, close, and termination transitions to await the owned save result without polling or permitting overlapping mutation.

## Impact

- `ToolPackageRegistry` index schema, immutable generation layout, staging, validation, migration, and garbage collection.
- `PackageSettingsStore` save/delete sequencing and package publication errors.
- `ToolsSettingsViewController` save ownership, control enablement, draft lifecycle, and transition resolution.
- `SettingsWindowController` and application termination paths that wait for active-pane resolution.
- Package registry failure-injection/migration tests and native Settings tests.
- Bundled package files remain immutable, and Settings still never executes tool source.
