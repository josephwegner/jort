# Run history and search verification

## Search architecture

`DocumentSearch` scans immutable canonical text off the main actor. Query text is escaped and never interpreted as a regular expression; Unicode-aware, locale-independent case matching and explicit whole-word options are supported. Whole-word boundaries exclude adjacent Unicode letters, combining marks, numbers, and connector punctuation. Multiline literal matches anchor at the starting logical line.

Results carry document identity, generation, logical-line UUID, line-relative UTF-16 range, and a SHA-256 hash of the exact matched UTF-8 text. Navigation resolves the identity and verifies the range and hash against the current snapshot. Missing or changed matches refresh the panel without changing editor selection. A shifted but unchanged logical line remains navigable.

Context is bounded to 181 UTF-16 units including an optional ellipsis without splitting a composed character. A single oversized grapheme is omitted rather than defeating that bound. Scanning checks task cancellation through Foundation's progress callbacks. The initial page contains at most 1,000 matches; Show more matches explicitly increases that limit. No persistent index is created.

`DocumentSearchModel` owns the 100 ms debounce, detached scan, cancellation propagation, and latest-request publication guard. `DocumentSearchController` owns the in-window overlay, query/options, accessible result context and counts, keyboard selection, arrows, and dismissal. Neither owns the live document. The editor resolves navigation at activation time and returns focus without mutating text. Command-F opens this overlay. Navigation keeps it open; snippets contain context from the matching logical line only.

## Feedback follow-up — September 8, 2026

Landmark actions now synchronize committed native text before applying metadata, and the native text view reports changes directly as well as through its delegate. Regression coverage verifies that pending text and a landmark survive together in the retained complete snapshot. The idle policy defaults to 60 seconds and upgrades the former unversioned 30-second default while preserving other custom intervals.

Gutter enumeration stops at the physical scroll viewport boundary. TextKit can temporarily keep an obsolete viewport end offset after newline insertion; using that offset omitted visible rows. The fix does not force offscreen layout. Repeated insertion tests verify every visible ordinal without scrolling or adding landmarks.

Search now stays in the editor, expands on typing, uses single-line context, keeps matches selectable after navigation, and supports arrows, Escape, and a close button. History has compact continuous diff blocks, a dark gutter with landmarks before ordinals, visible expansion buttons, per-row counts/reasons, a rail action area, and automatic page loading. Counts are derived only for visible rows and cached without keeping decoded documents.

Verification: 61 foundation tests passed; all 15 history/search workspace tests passed. The full native suite passed 33 of 35, retaining the same two baseline visual-assertion failures described below. Focused gutter and navigation checks passed after removing unnecessary forced layout. The final local debug navigation sample measured 22.1 ms p95, scrolling/gutter 23.0 ms, and typing 420.0 ms; typing remains above the existing ceiling and performance qualification is still open. Programmatic rendered-window checks verify the overlay placement, window-size preservation, diff gutter, and rail actions.

## Earlier automated verification — September 7, 2026

- Foundation: 60 tests passed, including storage, recovery, fault injection, process crashes, search anchors/Unicode/cancellation, comparison reconstruction, and performance reporting.
- History/search AppKit: all 12 tests passed, including stale results, superseded requests, wrapping, keyboard navigation, IME-composition command protection, footer/focus restoration, corruption, restore confirmation, Undo/Redo, failure, and reopening restored state.
- Full native suite: 30 of 32 passed. The existing ruler-inset assertion (24 expected, 12 actual) and footer pixel-color assertion fail identically on the untouched baseline; they are not new history/search failures.
- App build, generated-project consistency, whitespace check, and strict OpenSpec validation passed.
- Rendered history and search panels were inspected at native test-window sizes. These are programmatic rendering and accessibility-API checks, not a physical VoiceOver user-journey sign-off.

## Local performance observations

Debug build, macOS 26.6.2, 12 samples per Run operation using `CrawlLargeDocument` (25,000 logical lines / 1,000,000 UTF-16 units). These are local measurements, not normative-hardware acceptance. p95 uses the nearest-rank sample.

| Operation | p95 |
| --- | ---: |
| Search, first 1,000 common matches or absent query | 32.2 ms |
| Search plus configured debounce, excluding UI render | 132.2 ms |
| Retain complete verified revision | 919.7 ms |
| List revision metadata | 0.45 ms |
| Decode and verify selected revision | 552.4 ms |
| Compare selected snapshots | 210.9 ms |
| Restore transaction plus current-state save | 869.1 ms |
| Prune old eligible revisions | 2.48 ms |

The restore number excludes pre-restore retention and selection decode; those are separately measured above. The benchmark uses a small retained window and does not characterize years of history or physical disk exhaustion.

Existing native sustained-edit p95 measured 219.6 ms, above the 100 ms regression ceiling already recorded in `review-status.md`. Existing complete-save p95 measured 336.6 ms on the 10k fixture, above its 250 ms ceiling. New history retention also exceeds the earlier 250 ms checkpoint target. Functional suites ran with performance enforcement disabled; a passing test count does not imply these performance gates passed.

## Initialization and local-only audit

Search scanning and both presentation models are created only when their palette actions are invoked. Normal current-state startup does not enumerate or decode history revisions. Automatic retention deliberately initializes after the first edit and runs at idle/semantic/lifecycle boundaries; “lazy history” refers to browsing and comparison, not disabling the specified automatic checkpoint policy. Recovery/migration can verify preserved history as part of safeguarding the store.

The application sources contain no network client, external process runner, invocation parser, provider, agent, script runtime, capture integration, or connector. Revision data stays in the local SQLite store and diagnostic recovery material. Build/test scripts are not application execution capabilities.

## Remaining release gate

Task 5.2 remains open: resolve or explicitly qualify the baseline visual-test and performance failures, profile history retention/decoding on representative hardware, and complete user-run UI lifecycle, physical IME, and VoiceOver journeys. No release-readiness or archive claim is made.
