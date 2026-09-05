## Context

This change depends on completed Crawl, Walk, and Run history/search changes. Its purpose is to prove the invocation and mutation UX with synchronous deterministic code before introducing delayed agents. The invocation itself remains ordinary canonical text; pending controls and completed provenance are metadata decorations.

## Goals / Non-Goals

**Goals:**

- Recognize only registered slash commands without changing unmatched typing.
- Keep Return as newline insertion and make execution explicit.
- Make command input scope visible before any transformation.
- Commit outputs atomically through the same document transaction, undo, persistence, and history boundaries used by manual edits.
- Establish bounded provenance and error behavior reusable by agents.

**Non-Goals:**

- `@agent` recognition, model providers, network access, asynchronous runs, progress, cancellation after execution starts, or stale-target rebasing.
- JavaScriptCore, plugins, shell access, registered external commands, or arbitrary user scripts.
- Whole-document transformations in this slice.

## Decisions

### 1. Parse registered invocations as overlays on ordinary text

The command registry lazily exposes stable command IDs, slash names, aliases, descriptions, input modes, and executor closures. The parser observes committed text on the caret's logical line and recognizes a slash token only when it begins at the line start or after whitespace and exactly matches a registered name. Pending state stores `LineID` plus line-relative UTF-16 ranges, not global offsets. Unmatched or abandoned text has no metadata.

### 2. Separate completion, pending state, and execution

Typing `/` can open filtered command completion. Choosing a completion inserts ordinary command text but does not run it. A recognized line receives a fixed-height decoration and Run control. Return always remains the native newline action; Shift-Return and Run dispatch the same path. Escape dismisses completion or abandons pending decoration while retaining typed text.

### 3. Use explicit narrow scopes

Insertion commands consume only their argument text and insert one complete result immediately after the invocation line. Transform commands require a nonempty explicit selection contained in the current document; the selection is visibly highlighted and a preview shows the proposed replacement. `/sort` sorts selected logical lines using a stable literal ordering, and `/dedupe` retains the first exact occurrence of each selected logical line. No command reads the entire document implicitly.

### 4. Commit through one atomic document mutation

Executors receive immutable parsed input and injected clock/UUID sources. They return either a bounded UTF-8 text result or a structured error and never mutate the editor directly. The coordinator validates command identity, invocation anchor, and selected input immediately before commit. Insertion or replacement, line metadata updates, provenance annotation, undo registration, current-state persistence, and semantic history boundary form one transaction.

Completed provenance stores command ID, timestamp, invocation identity, input hash, output range anchor, and merged state. Merge removes provenance only; Delete remains ordinary text deletion. There is no Retry state for successful deterministic commands; rerunning creates a new execution.

### 5. Bound calculator grammar and command output

`/calc` uses a purpose-built expression parser for decimal numbers, parentheses, unary signs, and `+ - * / % ^`; it does not use JavaScript, `NSExpression`, locale-dependent parsing, or dynamic evaluation. Division by zero, invalid syntax, overflow/nonfinite results, and all command output over the configured byte/line cap fail without mutation.

## Risks / Trade-offs

- **Invocation parsing can consume ordinary punctuation** -> Require registry matches and token boundaries; Escape always returns text to ordinary state.
- **TextKit decorations can disturb layout** -> Use overlay/decoration geometry constrained to the invocation line and retain viewport tests.
- **Selection changes before a transform commits** -> Hash and revalidate the exact range immediately before commit; refuse stale input.
- **Calculator parsing creates security or correctness risk** -> Implement a small deterministic grammar with exhaustive parser and numeric-limit tests.
- **Commands can create huge output** -> Enforce byte and line caps before document mutation.

## Migration Plan

1. Add annotation schema support and an empty local command registry without enabling parsing.
2. Add invocation recognition/decorations and completion with executors disabled.
3. Enable insertion built-ins, then previewed selection transforms after transaction and undo tests pass.
4. Older builds preserve and refuse the newer annotation schema rather than dropping provenance.

## Open Questions

No blocking questions remain. Locale-aware sorting and configurable calculator precision are deferred.
