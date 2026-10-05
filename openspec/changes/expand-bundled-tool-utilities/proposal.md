## Why

Jort's bundled examples should support capturing and acting on a continuous train of thought, while providing useful, editable examples for user-authored tools. The agreed catalog also includes focused text transformations, and needs precise behavior plus explicit host support for actions that the sandbox cannot perform.

## What Changes

- Introduce the 40-command catalog described in the design: timestamps, daily landmarks, clipboard/export/reminder actions, generators, counts, Markdown utilities, whitespace, sorting, case, JSON, and language tools. Give every command a short name and a specific readable description.
- Make `/now`, `/today`, and `/time` use captured local time and clearly editable JavaScript format strings. Preserve `/count-characters`, `/count-words`, and `/count-lines` as explicitly requested names.
- Add optional structured arguments alongside exact contextual content, so commands such as `/remind 20` and `/join " · "` never consume note text as configuration. All argument controls support keyboard-only focus traversal, editing, submission, and return to the editor.
- Add bounded, app-mediated effects for clipboard, save-file, scheduled notification, read-only reports, and atomic daily landmark insertion. JavaScript remains without ambient I/O or credentials.
- Reuse the existing model executor and connection for `/summarize`, `/proof`, `/explain`, `/simplify`, and `/concise`.
- **BREAKING default behavior:** `/time` changes to `10:28am`. Keep old `/date`, `/uuid`, `/calc`, `/sort`, and `/dedupe` packages as compatibility tools; demote them from fresh-install defaults without deleting user overrides, explicit enablement, or saved results.

## Capabilities

### New Capabilities

- `bundled-note-utilities`: Complete command catalog, documented arguments, transformations, generators, counts, Markdown behavior, model prompts, and compatibility policy.
- `tool-host-actions`: Typed, bounded host actions with explicit execution, accurate completion, notification scheduling, and landmark transactions.

### Modified Capabilities

- `deterministic-builtins`: Updated bundled defaults and extensible execution inputs/results while retaining ordinary package overrides and legacy behavior.
- `inline-command-invocation`: Separate arguments from contextual content and support report/action completion without canonical result text.
- `sandboxed-javascript-execution`: Version the allowlisted protocol for captured local calendar/entropy inputs and declarative effect results without expanding worker privileges.

## Impact

Touches `Jort/Resources/Tools`, Contracts, Runtime/coordinator, Document effects, Settings/registry, AppKit invocation presentation, app composition, and the JavaScript client/broker/worker protocol. Introduces native clipboard/export/notification adapters. Requires package and invocation compatibility coverage, protocol/containment checks, and focused native verification through `./scripts/validate`. This proposal produces planning artifacts only; implementation follows separately.
