# Crawl MVP implementation notes

## Scope and choices

The archived roadmap explicitly prioritizes a dependable editor before optional features. This build follows that scope rather than presenting an incomplete V1. It uses an AppKit window shell and TextKit 2 NSTextView directly; the initially attempted SwiftUI host added no product benefit and was removed during native layout verification.

`EditorViewController` owns the live document on the main thread. Native edits update the text view immediately. It captures AppKit's UTF-16 edit range and reconciles a local line window plus one neighbor on each side, accounting for CRLF joins/splits. Composition without a single stable edit range uses a common-prefix/suffix fallback on commit. Plain ASCII, emoji, combining characters, Japanese, LF, CRLF, and CR fixtures are covered.

The leading line keeps its UUID through splits and joins; inserted trailing fragments receive new IDs. Unaffected lines preserve their timestamps. Empty/whitespace lines retain their IDs but have nil timestamps. Metadata undo actions pair with native text actions and restore exact prior metadata. This MVP breaks native edit coalescing to keep those pairs deterministic; typing may undo in smaller steps than TextEdit. Undo state is memory-only and does not survive relaunch.

The gutter reads already visible TextKit 2 layout fragments and binary-searches their logical-line starts. It does not force whole-document layout during scrolling. Its background drawing is restricted to the gutter; the native scroll view paints the canvas. The editor remains an accessible native text area, with an explicit label and help text.

`PersistenceController` schedules fixed half-second flushes rather than a trailing debounce that could postpone saving indefinitely during continuous typing. Immutable snapshots cross to one serial utility queue. `SQLiteStore` uses prepared statements, WAL, synchronous FULL, a schema version, and transactional replacement of a versioned JSON state blob. This small MVP uses a blob rather than premature tables for deferred metadata types. Serialization and disk I/O stay off the typing path. Healthy lifecycle flushes drain the latest state before quit.

SQLite corruption is distinguished from busy, permission, and future-schema errors. Automatic recovery preserves database/WAL files before replacement. A valid separate JSON snapshot is required before a damaged store is replaced. Unrecoverable initial-load failure never overwrites the original; the user can save current in-memory work as a separate recovery copy.

## Validation

The XCTest suite covers:

- Split/join UUID inheritance and whitespace timestamp clearing.
- Unicode and newline range correctness.
- 1,500 randomized text mutations and 1,000 range-based incremental edits.
- Persistence round trip, damaged-database recovery, preservation without a safe snapshot, and refusal of a future SQLite schema.
- Native NSTextView layout, text/metadata undo and redo, and persistence of the resulting state.
- Provisional marked text and committed Japanese composition.
- Saving during continuous typing without an idle gap.
- Injected disk errors, exactly three automatic retries, continued in-memory editing, and manual retry saving the latest text.
- A 10,000-line, roughly 560 KB fixture. The debug incremental edit plus validation measured approximately 10 ms on the development Mac; this is a local measurement, not an end-to-end typing latency claim.

Direct running-app checks cover visible text, first-responder/accessibility exposure, native menus, plain-text entry, Unicode, logical-line wrapping, Find, and relaunch recovery. The text rendering problem found in that pass was fixed before delivery.

## Remaining limits

- No complete VoiceOver user journey, physical IME/input-source matrix, performance distribution, power-loss testing, or signed-distribution checks have been completed.
- The 0.5-second save cadence targets a sub-second crash window on healthy storage. OS scheduling, composition in progress, slow disks, and save failures can extend it.
- Line array offsets after an edit still shift in O(number of trailing lines), and undo retains line-array snapshots. This is suitable for the tested scratch-canvas size, not a claim of multi-gigabyte scalability.
- Successful recovery restores the newest validated separate snapshot available, which can be slightly behind the latest SQLite commit if the process died between those two writes.
- Initial storage failures leave the original files untouched and require recovery-copy/manual repair if no safe snapshot is available. There is no recovery-copy import UI yet.
- Rich-text authoring, user-facing history, landmarks, palette, automation, and capture are intentionally absent.

## Budget experiment

The user reported 86% of the Plus usage window remaining during the initial build/test pass and 44% remaining at completion. The final scope was deliberately held at the tested Crawl MVP; no separate agents or alternate models were used. Twelve XCTest cases passed and the Release build succeeded. These percentages are user-reported usage-window values, not measured token counts.

## Feedback fixes

The app icon is declared in an explicit Info.plist and loaded as the application icon at launch. Routine saving/saved messages are no longer displayed. The gutter includes TextKit 2's extra empty end-of-document row and refreshes after selection/layout changes. A fixed 24-point paragraph line height gives blank and populated rows the same spacing. A native regression test checks the numbers and spacing immediately after Return; all 13 tests pass.
