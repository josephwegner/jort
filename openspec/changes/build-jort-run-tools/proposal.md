## Why

Jort's palette can navigate the app, but the document still cannot invoke small deterministic operations in place. This second Run slice establishes the inline invocation, asynchronous lifecycle, and atomic mutation contract with local built-ins before agents or providers add external authority risks.

## What Changes

- Recognize registered `/command` names at their actual character and logical-line position while leaving unmatched text ordinary.
- Add command-name completion through the palette-backed registry without treating Return as execution.
- Define one installable tool-package format containing a declarative `tool.json` manifest and sandboxed `tool.js` implementation.
- Ship `/date`, `/time`, `/uuid`, `/calc`, `/sort`, and `/dedupe` through the same registry, package format, runtime, validation, and lifecycle used by user-installed tools rather than privileged native executors.
- Let each tool declare exactly one input mode: contained canonical input, an adjustable contextual canonical range, or an ephemeral anchored prompt.
- Decorate canonical invocation and input text as one connected structure without adding rich content to the document, and require Shift-Return or an explicit Run action.
- Lock submitted invocation and input ranges through asynchronous processing, with delayed processing indication, cancellation, timeout, error, and Undo behavior.
- Add local deterministic `/date`, `/time`, `/uuid`, `/calc`, `/sort`, and `/dedupe` built-ins.
- Let tools choose a bounded output operation such as `replace-invocation`, `replace-context`, or `insert-at-invocation`, while keeping Merge confirmation mandatory.
- Publish successful output immediately after its owned invocation as ordinary canonical text in a pending-merge state; Merge applies the declared source replacement and Dismiss restores the pre-submit invocation.
- Persist bounded pending and completed provenance metadata while preserving canonical plain text and favoring canonical-content recovery when metadata is absent.
- Use connected presentation-only invocation and output regions with embedded processing, cancellation, Merge, and Dismiss controls.
- Expose one inspectable registry through which a later Settings change can install, edit, disable, restore, or remove tools; editing a bundled tool creates a user override without destroying its restorable bundled definition.

## Capabilities

### New Capabilities

- `inline-command-invocation`: Recognition, registry-backed completion, contained/contextual/ephemeral input, connected decoration, asynchronous lifecycle controls, cancellation, and keyboard/accessibility behavior.
- `deterministic-builtins`: Shared JavaScript tool-package and sandbox contract, bundled deterministic package definitions, user overrides, declared input and output modes, output limits, pending canonical results, atomic Merge/Dismiss mutation, errors, and provenance.

### Modified Capabilities

None. This change consumes the editor, metadata, storage, palette, history-boundary, and search foundations from prior archived changes.

## Impact

- Adds a lazy local command registry and invocation parser tied to stable logical-line identities and anchored ranges.
- Adds manifest validation, package discovery, user overrides, and an authority-free JavaScript execution boundary shared by bundled and user-installed tools.
- Adds TextKit range-union decorations and anchored overlay controls around canonical invocation, context, and pending-output text without changing copied or exported content.
- Extends document snapshots and persistence with bounded invocation lifecycle and provenance annotations.
- Adds a cancellable asynchronous coordinator and atomic document transaction APIs suitable for later agent execution.
- Gives tool scripts no ambient network, filesystem, process, shell, application-state, plugin, or external-executable authority; future capabilities require a separate permission design.
- Adds no model provider, network request, shell command, external executable, or background agent run.
