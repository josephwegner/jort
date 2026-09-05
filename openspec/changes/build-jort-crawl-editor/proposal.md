## Why

Jort needs a trustworthy native editing foundation before any organization or automation features can be added. The Crawl MVP establishes that foundation as a directly usable one-document macOS editor whose typing path remains responsive and whose current state survives ordinary relaunches, storage failures, and recoverable corruption.

## What Changes

- Add a native macOS Jort application that opens directly into one focused, editable, app-owned plain-text document after startup has safely resolved the current state.
- Target arm64 Apple-silicon Macs running macOS 14 or later, with the original M1/8 GB hardware class as the normative performance baseline.
- Generate the native project from a checked-in XcodeGen manifest, keep the generated Xcode project disposable, and use a version-pinned GRDB package as the only third-party runtime dependency.
- Preserve standard macOS text interaction, including keyboard navigation and selection, undo/redo, copy/paste, find, wrapping, IME composition, configured spellchecking, accessibility, and scrolling.
- Canonicalize accepted line separators to U+000A LF, keep provisional IME marked text outside canonical state until commit, and use pinned Unicode 17.0 whitespace classification for logical-line metadata.
- Track only stable logical-line identity plus the minimal creation/edit metadata needed by later Jort phases; keep this metadata invisible and outside canonical text.
- Keep the live document authoritative in memory and autosave snapshots asynchronously to SQLite in WAL mode, typically within 250 ms and within one second under normal supported load.
- Isolate write failures from editing, report storage problems ephemerally without persistent window chrome, retry automatically a small bounded number of times, and expose manual Retry without ever replacing the in-memory document.
- Add a two-second startup safety ceiling for resolving whether a blank document is legitimate; unresolved state continues in a neutral recovery/loading presentation rather than exposing an editable blank that could later be reset.
- Add explicit startup and recovery behavior for first launch, an intentionally empty document, interrupted shutdown, disk-full/write failures, and database corruption, including preservation of the damaged store and recovery of the newest verified state when possible.
- Add measurable launch, focus, typing, scrolling, persistence, crash-loss, accessibility, and recovery acceptance criteria.
- Exclude landmarks, command palette, visible timestamps, revision history, search indexing, AI, tools, providers, capture, connectors, non-storage notifications, and export from this change.

## Capabilities

### New Capabilities

- `native-editor`: The one-document native macOS editing experience, normative keyboard and accessibility behavior, safe startup focus, and interaction performance.
- `logical-line-metadata`: Invisible stable identity and minimal timestamps for U+000A LF-delimited logical lines, including deterministic edit, IME, and undo/redo behavior.
- `resilient-document-storage`: Asynchronous SQLite/WAL autosave, storage-health handling, bounded retry, crash durability, corruption preservation, and verified recovery.

### Modified Capabilities

None. There are no active product specifications yet; the roadmap artifacts are source material rather than active specs.

## Impact

- Introduces the initial arm64 Swift/AppKit macOS application and test targets alongside the existing disposable interaction prototype. A checked-in XcodeGen manifest is the native-project source of truth; generated project files are reproducible build products rather than hand-maintained configuration.
- Adds an `NSTextView`/TextKit-based editor boundary, an in-memory document model, a background persistence coordinator, and a SQLite store with migrations and WAL recovery.
- Establishes a bounded current-state on-disk schema for canonical LF text and logical-line metadata, implemented behind a narrow storage module with a version-pinned GRDB dependency; immutable handoff snapshots are coalesced rather than accumulated as history, and later changes must migrate this schema without weakening Crawl recovery guarantees.
- Uses SHA-256 verification, versioned deterministic UTF-8 JSON recovery envelopes, and atomically renamed same-volume store directories for corruption quarantine and recovered-store publication.
- Adds performance instrumentation, large-document fixtures, failure injection, accessibility/UI tests, and crash/relaunch integration coverage.
- Adds no network service, account, provider, plugin, capture, export, or automation dependency.
