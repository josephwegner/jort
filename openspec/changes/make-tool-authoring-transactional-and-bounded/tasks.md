## 1. Bounded index schema and migration

- [ ] 1.1 Add version-two index DTOs that record one current and at most five newest-first previous generation UUIDs per installed ID, with global uniqueness and existing package-count bounds.
- [ ] 1.2 Implement strict version-two decode/validation and conservative version-one migration that imports only proven current generations with empty history.
- [ ] 1.3 Preserve the old index and all package directories when decode, validation, or migration fails, and preserve a pre-migration copy until the migrated registry reopens successfully.
- [ ] 1.4 Add fixtures for valid v1/v2 indexes, future/corrupt indexes, duplicate references, excessive histories, missing current generations, and invalid previous generations.

## 2. Crash-consistent package publication

- [ ] 2.1 Add a constrained staging-directory writer that creates manifest and implementation files without following links, syncs them and the directory, and reloads/validates the complete package.
- [ ] 2.2 Publish a verified staged package under a fresh final UUID name and sync the installed-tools parent before constructing the next index.
- [ ] 2.3 Add a shared durable index publisher that writes a bounded temporary file, syncs, atomically renames, syncs the parent, and updates in-memory authority only after success.
- [ ] 2.4 On update, move the prior current generation to the front of history, retain only the next four previous entries, and keep only the new current generation executable.
- [ ] 2.5 Add failure injection at every staging, verification, rename, index write/sync/rename, and in-memory publication boundary and prove the old or new complete state remains authoritative.

## 3. Safe cleanup, deletion, and restoration

- [ ] 3.1 Implement bounded direct-child cleanup that runs only from a trusted durable index, removes exact abandoned staging names and unreferenced non-symlink UUID directories, and preserves unexpected entries.
- [ ] 3.2 Retry nonfatal cleanup on trusted reload/save and expose a bounded maintenance diagnostic without converting a successfully published tool into a failed save.
- [ ] 3.3 Change custom deletion and bundled-override restoration to durably publish catalog removal before reclaiming current and previous generations.
- [ ] 3.4 Add crash/relaunch, symlink, unexpected-file, failed-cleanup, deletion, restoration, and repeated-update tests proving active plus five previous generations is the healthy-state maximum.

## 4. Owned single-flight save workflow

- [ ] 4.1 Define immutable draft submission and typed save-result values covering success, blocking diagnostics, conflict, storage/publication failure, and permitted pre-publication cancellation.
- [ ] 4.2 Give `ToolsSettingsViewController` one operation-tokened save task and one idempotent main-actor finalization path; repeated callers must await the same task.
- [ ] 4.3 Capture UI fields once, run injected validation and `SettingsStore.save`, clear the matching draft only on committed success, and preserve draft/selection/caret/source undo on every unsuccessful result.
- [ ] 4.4 Disable or serialize draft fields, enablement, duplicate, delete, tool selection, additional Save, and other conflicting mutations for the full in-flight operation.
- [ ] 4.5 Expose accessible saving state, restore useful focus after completion, and narrow touched UI controls to private/internal ownership with typed test hooks.

## 5. Awaited Settings transitions

- [ ] 5.1 Replace `resolvePendingChanges` polling with a callback-to-async bridge that awaits the owned save result and calls each transition completion exactly once on the main actor.
- [ ] 5.2 Route pane selection, tool selection, new/duplicate draft replacement, Settings close, and application termination through the same Save/Discard/Cancel resolution behavior.
- [ ] 5.3 Ensure transition requests arriving during an existing save share that task, proceed only on success, and leave the original draft/window open on diagnostics, conflict, cancellation, or storage failure.

## 6. Verification

- [ ] 6.1 Add controllable slow validator and slow/failing settings-store fixtures that prove no timeout, duplicate submission, stale late result, or overlapping expected-revision save occurs.
- [ ] 6.2 Add native tests for control disablement, accessible saving state, focus/undo preservation, pane/draft/window/termination outcomes, and exactly-once transition completion.
- [ ] 6.3 Run Settings, package registry, model/deterministic tool, migration, failure-injection, native workspace, and termination tests and document the version-two index rollback constraint.
