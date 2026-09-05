## Why

The Crawl editor is dependable but offers no lightweight way to mark or navigate meaningful places in the single document. The Walk MVP adds optional organization and a scalable command entry point without changing Jort's canonical plain-text model or typing-first behavior.

## What Changes

- Add emoji landmarks anchored to stable logical-line identity and stored outside canonical text.
- Let users add, replace, move, and clear a landmark from the gutter using native emoji selection.
- Replace a landmarked line's number with its emoji in normal gutter mode.
- Add a compact landmark navigation mode in the existing gutter width, ordered by document position.
- Add a transient, searchable, keyboard-accessible command palette opened from the title bar or a conventional keyboard shortcut.
- Populate the palette only with Walk navigation and application actions; commands, agents, history, and indexed search remain later changes.
- Persist landmarks through the existing asynchronous current-state and recovery paths without weakening Crawl durability, launch, or interaction guarantees.

## Capabilities

### New Capabilities

- `emoji-landmarks`: Landmark creation, stable anchoring, gutter presentation, navigation, editing behavior, persistence, and accessibility.
- `command-palette`: Transient title-bar and keyboard command discovery, filtering, navigation, execution, focus restoration, and accessibility.

### Modified Capabilities

None. Crawl is not yet archived into active specifications; this change depends on its native editor, logical-line identity, and resilient storage contracts without redefining them.

## Impact

- Extends the document state and persisted snapshot schema with landmark records and a schema migration.
- Extends the existing viewport-bounded gutter with interaction, emoji rendering, mode switching, and landmark navigation.
- Adds a title-bar palette control and transient palette presentation while keeping the editor as the ordinary first responder.
- Adds metadata-aware landmark undo/redo, migration, recovery, UI, accessibility, and large-document tests.
- Adds no network access, provider, agent, script runtime, external command, history retention, or search index.
