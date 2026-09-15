## Why

Jort currently accepts input before asynchronous persistence loading finishes, but a pre-load edit changes the placeholder document and can cause that blank-derived state and UUID to replace the stored document. Immediate typing is a core product requirement, so startup must merge early input safely rather than solving the race by disabling the editor.

## What Changes

- Introduce an explicit editable-loading state that captures user-authored startup content without publishing the placeholder as an authoritative persistence snapshot.
- On successful load, preserve the stored document identity and metadata and prepend the startup content through the normal typed transaction path.
- Define deterministic newline-boundary, selection, focus, and undo behavior for the startup merge.
- On load failure, retain startup content in a distinct editable recovery state that cannot overwrite the failed source store.
- Expose actual typed load state to tests and UI coordination; `isEditable` is no longer treated as evidence that loading completed.
- Add deterministic delayed-load success and failure coverage, including relaunch after the merged state is saved.

## Capabilities

### New Capabilities

None. This change strengthens the existing native editor and resilient storage contracts.

### Modified Capabilities

- `native-editor`: Makes the one app-owned document editable during loading and defines how startup content is presented, merged, focused, selected, and undone.
- `resilient-document-storage`: Prevents placeholder/startup state from becoming a persistence replacement before load resolution and adds typed editable-loading and recovery-editing lifecycle semantics.

## Impact

- Startup orchestration and state projection in `EditorViewController`.
- The contract between `PersistenceController.load`, `DocumentCoordinator`, and the AppKit adapter.
- Native undo registration, selection mapping, first-responder behavior, and autosave scheduling at load resolution.
- AppKit test helpers and controlled persistence fixtures used to distinguish editable, loading, loaded, and failed states.
- Existing store formats and on-disk schemas are unchanged.
