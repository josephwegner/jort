## 1. Landmark model and migration

- [x] 1.1 Add typed `LandmarkID`, attached/detached landmark state, emoji grapheme validation, and document invariants including at most one attached landmark per `LineID`.
- [x] 1.2 Extend immutable snapshots and deterministic recovery envelopes with ordered landmarks and complete validation.
- [x] 1.3 Add a versioned SQLite migration from the Crawl schema that preserves document and line identities and valid prototype landmarks, defaulting to an empty collection only when absent.
- [x] 1.4 Persist, load, verify, retry, and recover landmarks atomically with text and line metadata; introduce two synced, verified rotating recovery slots and an atomic publication manifest while retaining failed-save semantics.
- [x] 1.5 Add migration, malformed-record, unsupported-schema, write-failure, checkpoint, and corruption-recovery tests for landmark state.

## 2. Landmark editing semantics

- [x] 2.1 Extend edit transactions and undo deltas to include landmark attachment and mutation state.
- [x] 2.2 Implement survival on edits above or within an attached line and leading-fragment inheritance on split.
- [x] 2.3 Implement direct-join transfer, two-landmark join detachment, and ambiguous-deletion detachment rules.
- [x] 2.4 Implement add, replace, move, clear, detach resolution, Undo, and Redo operations without modifying canonical text.
- [x] 2.5 Add deterministic and randomized tests for edits, split, join, replace, multiline paste, IME commit, undo, redo, duplicate emoji, and detached landmarks.

## 3. Gutter landmark interaction

- [x] 3.1 Add gutter hit testing and keyboard/menu actions that target a stable `LineID` rather than a displayed ordinal.
- [x] 3.2 Integrate native emoji selection and validate emoji, flags, skin tones, variation selectors, and ZWJ sequences.
- [x] 3.3 Render an attached emoji in place of its line number in normal mode without altering TextKit layout or canonical text.
- [x] 3.4 Add the fixed gutter mode control and render the top-aligned attached-landmark index in document order within the existing gutter width.
- [x] 3.5 Resolve landmark navigation by `LineID`, scroll the line into view, and restore editor focus without changing text or viewport width.
- [x] 3.6 Add visual, wrapping, resize, scrolling, duplicate-emoji, stale-entry, and large-document gutter tests.

## 4. Command palette

- [x] 4.1 Define a lightweight action registry with stable IDs, titles, keywords, enabled state, and execution behavior.
- [x] 4.2 Build the transient title-bar and Command-K palette with case/diacritic-insensitive filtering and an accessible empty state.
- [x] 4.3 Implement Arrow navigation, Return execution, Escape dismissal, disabled actions, and exact focus/selection/viewport restoration.
- [x] 4.4 Register Walk application and landmark actions without initializing commands, agents, history, or search.
- [x] 4.5 Prevent palette activation from committing or disrupting active IME marked text and test interaction with native Find and other transient responders.

## 5. Accessibility and release gates

- [x] 5.1 Expose landmark gutter controls, entries, detached-state actions, palette dialog, query, results, and action states through AppKit accessibility.
- [x] 5.2 Add keyboard-only, Full Keyboard Access, VoiceOver-style, Increase Contrast, Reduce Motion, scaling, and enlarged-font tests.
- [x] 5.3 Benchmark normal and landmark gutter scrolling and navigation with `CrawlLargeDocument` and verify no whole-document TextKit layout is forced.
- [x] 5.4 Re-run Crawl launch, typing, scrolling, persistence-latency, crash-loss, storage-growth, recovery, IME, and accessibility gates with landmarks enabled.
- [x] 5.5 Audit the finished Walk application to confirm canonical copy/find text excludes landmark metadata and no history, indexed search, command execution, agent, provider, script, capture, or connector subsystem is present.
