## Why

After Walk, users can mark important lines but still cannot recover earlier document states or search the whole canvas from Jort's central navigation surface. This first Run slice adds local revision history and scalable current-document search without introducing text execution or AI.

## What Changes

- Retain meaningful, coalesced full-state revisions containing canonical text, line metadata, landmarks, and schema identity.
- Create revision boundaries from idle/lifecycle rules and meaningful landmark or bulk events without retaining every keystroke.
- Add palette actions to search the current document and browse local history.
- Present search matches with line context and navigate to the exact current range.
- Present history as a read-only split workspace with a complete-state snapshot, an optional derived changes view, and a newest-first revision rail.
- Preserve historical line ordinals and landmarks in previews, clearly replace live-editor footer affordances with contextual history status, and restore the normal shell on dismissal.
- Restore a selected revision atomically from an explicit confirmed action, preserving the state being replaced.
- Keep history and search local, lazy, off the launch/keystroke paths, and inaccessible to nonexistent agents or providers.

## Capabilities

### New Capabilities

- `local-version-history`: Coalesced full-state revision retention, browsing, preview, atomic restore, pruning, corruption handling, and accessibility.
- `document-search`: Palette-driven current-document search, result context, keyboard navigation, stale-result handling, performance, and accessibility.

### Modified Capabilities

None. This change depends on archived Crawl and Walk capabilities without altering their normative contracts.

## Impact

- Migrates SQLite from bounded current-state-only storage to separate bounded current-state plus retained revision storage.
- Adds background revision serialization/coalescing and a storage-budget pruning policy.
- Extends the Walk command palette with Search Document and Version History surfaces.
- Adds lazy derived-diff presentation, history preview/restore transactions, and search result navigation while preserving editor selection and viewport behavior.
- Adds a transient in-window history workspace without adding a permanent History title-bar control or changing the healthy live-editor shell.
- Adds no invocation parser, tools, agents, provider, script runtime, network access, or capture.
