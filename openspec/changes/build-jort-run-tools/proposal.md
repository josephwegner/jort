## Why

Jort's palette can navigate the app, but the document still cannot invoke small deterministic operations in place. This second Run slice establishes the inline invocation and atomic mutation contract with local built-ins before asynchronous agents or providers add concurrency and authority risks.

## What Changes

- Recognize registered `/command` names at their actual character and logical-line position while leaving unmatched text ordinary.
- Add command-name completion through the palette-backed registry without treating Return as execution.
- Decorate a recognized invocation's actual line and require Shift-Return or an explicit Run action.
- Add local deterministic `/date`, `/time`, `/uuid`, `/calc`, `/sort`, and `/dedupe` built-ins.
- Make invocation input scope explicit and preview selected-range transformations before commit.
- Commit successful output or replacement as one ordinary, atomic, undoable text transaction with no network access.
- Persist completed command provenance as removable metadata while preserving canonical plain text.

## Capabilities

### New Capabilities

- `inline-command-invocation`: Recognition, completion, decoration, execution controls, cancellation, and keyboard/accessibility behavior for deterministic commands.
- `deterministic-builtins`: Built-in command definitions, parsing, explicit scope, preview, output limits, atomic mutation, errors, and provenance.

### Modified Capabilities

None. This change consumes the editor, metadata, storage, palette, history-boundary, and search foundations from prior archived changes.

## Impact

- Adds a lazy local command registry and invocation parser tied to stable logical-line identities and ranges.
- Adds TextKit decorations and overlay controls around the actual invocation line without changing canonical text.
- Extends document snapshots and persistence with bounded command provenance annotations.
- Adds atomic document transaction APIs suitable for later asynchronous agent insertion.
- Adds no model provider, network request, JavaScript runtime, shell command, external executable, or background agent run.
