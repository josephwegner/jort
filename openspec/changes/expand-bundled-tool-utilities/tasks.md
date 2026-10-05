## 1. Contract and package compatibility

- [x] 1.1 Read the current jort-development skill and run `./scripts/validate changed --plan-only`; identify focused validation lanes for Contracts, Runtime, Document, AppKit and containment.
- [x] 1.2 Add schema 3 / entry contract 2 manifest fields for typed arguments, captured-data requests and declared actions; preserve schema 1/2 and contract 1 validation with compatibility fixtures.
- [x] 1.3 Add immutable argument values and parsing for integer/string/enum arguments, quoted empty strings, escaped delimiters, defaults and bounds; verify note content never becomes options.
- [x] 1.4 Add an exclusive text/report/action/error result union, bounded optional output landmark, and typed action payloads; reject unknown fields and mixed results.
- [x] 1.5 Extend invocation identity/hash capture and persistence reconciliation to include argument and result contracts; verify old inputting, pending and interrupted records retain source/output safely.

## 2. Captured data and sandbox protocol

- [x] 2.1 Capture local calendar components, time zone and locale once per submission; add a small JavaScript format helper supporting the documented editable timestamp tokens.
- [x] 2.2 Add bounded cryptographic entropy capture and unbiased JavaScript alphabet sampling; verify exact length, alphabet, deterministic injected fixtures and entropy exhaustion.
- [x] 2.3 Add bounded captured grapheme/word segmentation and locale collation data for exact context; qualify multilingual text, contractions, emoji, decomposed characters and stable comparison keys.
- [x] 2.4 Implement protocol 2 across client, broker and worker with a contract-1 adapter, explicit captured-data/action fields and independent/summed byte limits.
- [x] 2.5 Verify malformed frames, version mismatch, oversize metadata/results, late replies and resource failures; run the focused containment lane and confirm unchanged worker/broker entitlements.

## 3. Arguments and completion lifecycle

- [x] 3.1 Add contextual argument fields with descriptions/help, initial field focus, Tab/Shift-Tab traversal, visible focus, ordinary text editing, explicit Submit from every field, Escape back to the editor preserving values, keyboard re-entry and accessible invalid-field focus; preserve current scope handles and exact-content normalization for legacy commands.
- [x] 3.2 Extend the headless reducer/coordinator with report and action completion, host acknowledgement, cancellation and Done effects; verify validation/discovery never dispatch actions.
- [x] 3.3 Implement noncanonical count/status feedback and undoable invocation cleanup; verify no source replacement, no spurious empty Merge result, and no action replay through Undo/Redo or relaunch.
- [x] 3.4 Add bounded action receipts and interrupted/unknown-outcome recovery, including at-most-once dispatch per generation and explicit retry without automatic action replays.

## 4. App-mediated actions

- [x] 4.1 Define injected host service interfaces and app composition; validate package declarations, action kind, captured content and generation before dispatch for both bundled and custom tools.
- [x] 4.2 Select/reuse a bounded Markdown parsing policy shared by copy-rich, TOC and URL conversion; document supported syntax, raw HTML handling and no resource fetching.
- [x] 4.3 Implement rich clipboard publication with HTML/RTF/plain representations and readable fallbacks; verify native formatting round trips and failure before clipboard replacement.
- [x] 4.4 Implement UTF-8 Markdown/plain export with native save panel, sanitized filename, cancel/error handling and native overwrite confirmation; verify exact bytes.
- [x] 4.5 Implement OS notification permission, durable scheduling, bounded reminder receipts/details, activation and pending cancellation; verify denied permission, edited source, app exit and receipt cleanup.
- [x] 4.6 Implement bounded output-landmark attachment during daily Merge in JortDocument; verify stable heading LineID, atomic Undo/Redo, Dismiss and stale-anchor recovery.

## 5. Generators and note utilities

- [x] 5.1 Ship `/now`, `/today`, `/time` and `/daily` with obvious FORMAT/template/emoji constants; cover Sept spelling, midnight/noon, DST, year boundaries and user customization.
- [x] 5.2 Ship `/lorem` and `/random` with documented defaults/limits and generated-output-only behavior.
- [x] 5.3 Ship `/copy-rich`, `/export` and `/remind` packages with contextual content, clear action descriptions and typed validated requests.
- [x] 5.4 Ship `/count-characters`, `/count-words`, and `/count-lines` as reports; verify empty content, terminal newlines, CRLF and visual wrapping semantics.
- [x] 5.5 Ship `/toc` and `/url-md`; cover ATX/Setext hierarchy, fenced and inline code, duplicate/suffixed heading collisions, Markdown link preservation and URL punctuation.
- [x] 5.6 Ship `/split` and `/join`; verify literal separators, empty items, empty join separator, spaces/escapes and absent-versus-empty arguments.

## 6. Text transformations

- [x] 6.1 Ship `/tts`, `/stt`, `/trim`, `/trim-start`, `/trim-end`, `/strip-ws` and `/blank-lines`; verify indentation/interior-space distinctions, Unicode whitespace and valid empty results.
- [x] 6.2 Ship `/sort-az`, `/sort-za`, `/sort-09`, `/sort-90`; verify stable ties, negatives/decimals/exponents, non-numeric/blank placement, duplicates and final-newline preservation.
- [x] 6.3 Ship `/upper`, `/lower`, `/title`, `/sentence`; document raw-text effects and cover Unicode casing, acronyms, minor words, quotations and common abbreviation heuristics.
- [x] 6.4 Ship `/escape` and `/unescape`; verify one-pass entity handling, quotes, named/numeric references and invalid entity preservation.
- [x] 6.5 Ship `/json` and `/json-min` with value-preserving parsing/formatting or explicit refusal of precision-losing input; cover malformed JSON, huge numbers, nesting/output limits and indentation.

## 7. Language packages and catalog migration

- [x] 7.1 Ship editable model instructions for `/summarize`, `/proof`, `/explain`, `/simplify`, `/concise`; use the existing model catalog/connection and bounded captured content/arguments.
- [x] 7.2 Verify distinct prompt intent, summary length validation, embedded-instruction treatment, unavailable credentials, cancellation/late output and explicit Merge/Dismiss behavior.
- [x] 7.3 Add the 40-command catalog with names/descriptions/help and exactly one copy-rich entry; retain ask/rewrite and compatibility tools with stable IDs.
- [x] 7.4 Implement upgrade enablement preservation before changing fresh-install defaults; verify edited time/date overrides, explicit toggles, command collisions and older pending results.
- [x] 7.5 Update tool authoring documentation and examples for argument fields, editable date formats, captured data, typed actions, report results and model instructions.

## 8. Qualification and release readiness

- [x] 8.1 Run focused package fixtures for every catalog command and cross-cutting failure cases, verifying expected source preservation and output operation through the real registry/executor path.
- [ ] 8.2 Exercise native argument/report controls entirely by keyboard (including error correction and offscreen/re-mounted controls), clipboard paste, export cancel/overwrite, daily landmark navigation/Undo and reminder delivery with the signed app; record concrete evidence, argument-field usability feedback and environmental limits.
- [x] 8.3 Obtain independent review of contract migration, native action boundaries, lifecycle recovery and catalog behavior; resolve findings and keep specs/design coherent with implementation.
- [x] 8.4 Run `./scripts/validate gate` after final code changes and `openspec validate expand-bundled-tool-utilities --strict`; record results, remaining qualification gaps and rollback guidance before marking the change complete.
