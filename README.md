# Jort

A native macOS scratch canvas. One app-owned plain-text document, ready to type, saved on this Mac. No accounts, providers, network, folders, or setup.

This implementation targets the **Crawl MVP** described in `build-jort-v1/README.md`, which supersedes the archived V1 umbrella specification.

## Run

Open `dist/Jort.app` after building, or open `Jort.xcodeproj` in Xcode and run the **Jort** scheme. Requires macOS 14 or newer and full Xcode for development. The generated Xcode project is included; XcodeGen is only needed after editing `project.yml`.

```sh
./scripts/build.sh
open dist/Jort.app
./scripts/test.sh
```

The local build is unsigned and is intended for this Mac. Public distribution, Developer ID signing, and notarization are not configured.

## Use

- Type immediately into the single canvas. Rich clipboard content pastes as plain text.
- Changes save in the background every half second while typing, and on deactivation or quit. There is no need to pick a file.
- **⌘S** saves immediately or retries a failed save.
- **⌘Z / ⇧⌘Z** undo and redo text together with line metadata.
- **⌘F** opens native Find, including Replace.
- **⌘W** hides the window; **⌘0** reopens it. **⌘Q** quits after flushing changes.
- **File → Save Recovery Copy…** writes a separate JSON backup of the current in-memory text and line metadata, including when the canonical store cannot be opened.

Successful autosaves are silent. A failed save shows a title-bar alert and displays a nonmodal message and keeps editing available. Jort retries three times, then waits for manual retry. If quitting would lose unsaved edits, it asks whether to keep the app open.

## Storage and recovery

The canonical state lives in `~/Library/Application Support/Jort/Jort.sqlite`, using SQLite WAL and full synchronous commits on a serial background queue. `Recovery.json` is a separately atomic snapshot from the most recent successful save. Normal crashes may lose the latest fraction of a second of typing; the target is a loss window under one second on healthy local storage, not a guarantee under stalled or failing storage.

When SQLite is corrupt, Jort first copies the database and WAL companions into a uniquely named `Damaged-*` directory. It replaces the damaged database only after validating a recovery snapshot. If no valid snapshot exists, the damaged originals remain untouched, editing continues in memory, and Save Recovery Copy can preserve new work separately. Recovery copies are JSON backups, not a second document format or a document library; this MVP does not include an import UI. A future store schema is refused without downgrading it.

For isolated development runs, set `JORT_DATA_DIRECTORY` to an absolute directory before launching the executable. Tests use temporary stores.

## What shipped

- AppKit window and NSTextView with TextKit 2, dark appearance, plain-text paste, native selection, Find/Replace, wrapping, scrolling, and immediate focus after the local read.
- A fixed-width, viewport-driven logical-line gutter and a custom app icon.
- Stable line UUIDs, UTF-16 ranges, creation/edit timestamps, deterministic split/join rules, and metadata-aware undo/redo.
- Incremental reconciliation of the edited line neighborhood. Unaffected trailing offsets shift without reparsing their text. IME composition stays provisional until commit.
- Background autosave, atomic SQLite transactions, recovery snapshots, bounded retry, emergency backups, and unsaved-quit protection.

## Deliberately deferred

Landmarks, command palette, local version history, invocation decoration, agents/providers, scripting, external commands, capture, and integrations remain later roadmap phases. The native Find bar is included because it is standard NSTextView behavior.

See `docs/implementation.md` for architecture, validation, and remaining limits. The original specification files remain unchanged.
