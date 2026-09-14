## Context

Jort stores each custom tool package in an immutable UUID-named directory and atomically selects active generations through `Tools/index.json`. This provides a sound publication boundary, but the version-one index records only one active generation per tool. Every update leaves the prior directory behind, failed saves can leave an unindexed directory, and delete/restore removes only the index entry. Storage therefore grows without a retention bound.

Tools Settings has a separate lifecycle problem. `saveDraft()` launches an unowned task and returns. When a pane, draft, window, or application transition needs to resolve unsaved changes, `resolvePendingChanges` invokes that method and polls draft state every 10 ms for up to two seconds. Slow validation/storage can make the transition report failure while the save later succeeds, and repeated actions can submit overlapping saves with the same expected revision.

The existing settings and package APIs already provide revision-conflict checks and actor isolation. The change strengthens publication metadata and gives the UI one owned asynchronous operation rather than redesigning the entire settings store.

## Goals / Non-Goals

**Goals:**

- Make one Save action correspond to one awaitable validation/publication result.
- Prevent overlapping tool mutations and stale duplicate submissions while saving.
- Preserve drafts and editor state on validation, conflict, storage, or cleanup failure.
- Retain the active package plus exactly the five most recent previously published valid generations for each active custom tool.
- Make generation and index publication crash-consistent and garbage collection safe.
- Migrate the existing index without treating unindexed directories as proven published history.
- Remove all generations of a deliberately deleted custom tool or restored bundled override after the catalog change is durable.

**Non-Goals:**

- Adding a user-facing version browser, rollback command, or automatic fallback execution.
- Executing or dynamically testing tool source from Settings.
- Moving QuickJS out of process or reorganizing tool modules.
- Replacing immutable generation storage with mutable in-place package files.
- Redesigning the entire Settings window or navigation API.

## Decisions

### Upgrade the index to explicitly own generation history

Introduce an index schema version whose installed entry records ordered generation ownership:

```swift
struct InstalledGenerations: Codable {
    var current: String
    var previous: [String] // newest first, maximum five
}

struct Index: Codable {
    var schemaVersion: Int
    var installed: [String: InstalledGenerations]
    var disabled: Set<String>
}
```

Validation requires at most 1,000 installed IDs, at most five previous generations per ID, valid UUID directory names, no duplicate generation reference within or across IDs, and existing bounds for disabled IDs. Only `current` participates in catalog resolution and execution. Previous entries are recovery material and are never silently selected if current is damaged.

Inferring history on every launch by scanning and sorting all UUID directories was rejected because the registry cannot prove that an unindexed generation was ever durably published. Explicit index ownership makes retention deterministic and garbage collection safe.

### Migrate version-one indexes conservatively

For each version-one `id -> currentGeneration` entry, migrate that generation as `current` with an empty `previous` list. Durably publish the validated version-two index before removing unreferenced directories. Existing unindexed directories are not imported as history because they may be abandoned or partially published generations.

This intentionally starts the five-version history at migration time rather than labeling uncertain files as successful prior versions. If index validation or migration fails, preserve all package files and expose the existing unavailable/diagnostic state; do not garbage-collect against an untrusted index.

### Publish generation, then index, then garbage-collect

Use this save order:

1. Validate the complete package and expected version.
2. Create a hidden staging directory inside the installed tools directory without following links.
3. Write manifest and implementation files, sync the files and staging directory, reload through `ToolPackage.load`, and rerun validation.
4. Rename the verified staging directory to a fresh UUID generation and sync the parent directory.
5. Construct the next index with the old current generation at the front of `previous`, retain the four newest existing previous entries after it, and identify anything beyond the five-entry window as unreferenced.
6. Encode the complete bounded index to a temporary file, sync it, atomically rename it over `index.json`, sync the parent directory, then update in-memory index/snapshot state.
7. Best-effort remove now-unreferenced valid generation and staging directories without following links.

If generation publication fails, the old index remains authoritative. If index publication fails after the final UUID directory exists, that directory is an orphan and the old index remains authoritative. If garbage collection fails, the save remains published and cleanup is retried on next save/reload with an actionable diagnostic; cleanup failure never rolls the index back to a generation that may already have been exposed.

Writing directly into the final UUID directory was rejected because readers can observe partial files. Treating garbage collection as part of the atomic save result was rejected because failure to remove an obsolete file should not invalidate a successfully published current package.

### Garbage-collect only from a trusted index

After decoding, validating, and if necessary durably migrating the index, compute its complete referenced set (`current` plus all `previous`). Enumerate only direct children of the installed tools directory with a bounded count. Remove:

- hidden directories matching the registry's exact staging naming contract; and
- UUID-named, non-symbolic-link directories absent from the referenced set.

Never recurse through symbolic links, never act on an unexpected filename, and never remove `index.json` or bundled package paths. If the index is absent, invalid, future-versioned, or cannot be durably migrated, preserve all candidate directories and perform no destructive cleanup.

Current-generation validation failure does not authorize automatic fallback to a previous executable generation. The catalog reports the invalid current candidate and retains history for explicit future recovery tooling.

### Delete catalog state before package data

For a custom-tool deletion or bundled-override restoration, durably publish an index with that installed ID removed. Only after the catalog resolves without the tool/override may cleanup remove its former current and previous directories. A crash between these steps leaves non-executable orphans that startup cleanup removes. A crash before index publication leaves the old tool and every referenced generation intact.

This matches user intent better than retaining hidden deleted source indefinitely and avoids a filesystem-first deletion window that would leave the index pointing to missing code.

### Represent UI saving as one owned task and typed result

Give `ToolsSettingsViewController` one optional `Task<ToolDraftSaveResult, Never>` plus an operation token. Capture an immutable draft submission and base revision on the main actor, then run injected validation and `SettingsStore.save`. The task returns a typed outcome covering:

- success with the committed snapshot;
- blocking diagnostics;
- revision conflict with the current revision;
- storage/publication failure; and
- cancellation only when the owning workflow explicitly cancels before publication begins.

One main-actor completion method applies the result exactly once. Success clears the matching draft and rebuilds selection from the committed snapshot. Every unsuccessful result keeps the draft, source selection, caret, and local source-editor undo manager intact and restores appropriate controls.

An untracked `Task` plus polling was rejected because UI state is not a completion primitive. Allowing each caller to create a task was rejected because revision checks alone do not make duplicate user actions comprehensible.

### Make transitions await the same task

The Save button starts or awaits the owned save task. While it is active, draft fields, enablement, duplicate, delete, selection-changing controls, and additional Save actions are disabled or ignored. `hasUnsavedChanges` remains true until success.

`resolvePendingChanges` keeps its callback-shaped AppKit interface but bridges it to the owned task:

- Save starts the task if necessary and awaits its exact result.
- The requested pane/draft/window/termination transition continues only on success.
- Validation, conflict, cancellation, or storage failure completes the transition callback with `false` and leaves the draft visible.
- Discard remains synchronous and completes the transition.
- Cancel performs no mutation.

If another transition request arrives while a save is active, it awaits the same task rather than creating another save. Every transition completion is called exactly once on the main actor.

### Narrow UI visibility without making tests timing-dependent

Controls should be private unless another production type owns a legitimate interaction. Internal test hooks may expose typed state, actions, selection identifiers, and save-operation status under `@testable`; tests should not require public mutable fields. Accessibility-based UI tests remain appropriate for user-observable control behavior.

The broader file decomposition belongs to `stabilize-appkit-presentation-lifecycle`; this change narrows only the controls it touches.

## Risks / Trade-offs

- **Risk: Index migration deletes a useful old directory.** → Publish the trusted migrated index first, import only the proven current generation, and restrict cleanup to exact safe names; document that pre-v2 unindexed files were not authoritative history.
- **Risk: Garbage collection follows a malicious link or escapes the tools directory.** → Reject symbolic links, operate only on direct children with exact staging/UUID names, and never resolve user-supplied paths for deletion.
- **Risk: Cleanup failure permits temporary growth.** → Keep publication successful, report maintenance diagnostics, and retry cleanup on every trusted reload/save; healthy operation remains bounded.
- **Risk: An in-flight save outlives its view controller.** → Keep the task owned by the pane/settings termination workflow and ensure all waiters complete exactly once before release.
- **Risk: UI controls re-enable against a stale draft.** → Associate finalization with an operation token and immutable draft ID/base revision.
- **Risk: Retained old code is executed after current corruption.** → Never automatically fall back to a previous generation; only the index current entry is executable.
- **Trade-off: Version-one orphaned generations are not retained as history.** → Prefer provable publication history over guessing from version numbers or modification timestamps.

## Migration Plan

1. Add version-two index DTOs, validation, decoding, and a failure-safe version-one migration with no cleanup before durable publication.
2. Add staged generation publication and durable index publication helpers with failure injection at every filesystem boundary.
3. Track current plus five previous generations on update and add trusted-index garbage collection.
4. Apply index-first deletion/restoration and startup orphan/staging cleanup.
5. Add the typed save result, owned task, operation token, and single finalization path in Tools Settings.
6. Route Save, pane/draft changes, Settings close, and application termination through the same awaited operation; disable conflicting controls.
7. Narrow control visibility and update tests to use typed hooks/actions.
8. Run package migration, failure-injection, retention, deletion, Settings navigation, slow validation/store, conflict, close, and termination tests.

Rollback after a version-two index has been written requires the old build either to understand the new schema or a deliberate reverse migration. The implementation should treat this as a forward settings-format migration and preserve a pre-migration copy until the new registry has reopened successfully.

## Open Questions

- Determine the repository's preferred durable file-publication helper so index fsync/rename behavior is shared rather than reimplemented inconsistently.
- Confirm a bounded enumeration ceiling for legacy installed directories that is high enough to clean the reviewed unbounded state without allowing pathological startup work.
- Decide where nonfatal cleanup diagnostics surface in Settings without turning successful saves into apparent failures.
