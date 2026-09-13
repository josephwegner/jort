## Why

Jort's completed tool system already provides the invocation, input, asynchronous lifecycle, canonical output, Merge, persistence, history, and accessibility behavior originally planned for agents. The remaining opportunity is to let ordinary tool definitions use a bounded model executor without building a second invocation or run subsystem.

## What Changes

- Extend the existing tool-package contract with an author-selected executor type: the existing authority-free `javascript` executor or a new bounded `model` executor.
- Keep input mode and output operation declarative properties selected while designing a tool; neither the model nor its response can request or alter input ownership, context scope, placement, or Merge behavior.
- Invoke model-backed tools through ordinary registered slash commands and the existing completion, input, locking, processing, pending-output, Merge, Dismiss, Undo, persistence, history, and accessibility flows.
- Let users configure model-backed tools in Settings through editable instructions and a filterable picker backed by a curated model catalog bundled with Jort.
- Add a dedicated Models Settings pane with an OAuth-only OpenRouter connection flow, connection status, explicit verification, replacement, and disconnection controls.
- Use OpenRouter's OAuth PKCE flow to obtain a user-controlled credential without asking the user to enter or paste an API key, then store the resulting credential only in Keychain.
- Route model execution through OpenRouter using the model selected in that tool's saved settings.
- Treat explicit Run or Shift-Return on a configured model-backed tool as authorization to send only its captured input to OpenRouter; provider and model configuration remain in Settings rather than adding model-selection chrome to each invocation.
- Add a lazy, bounded, cancellable provider interface, a deterministic fake provider, and one OpenRouter implementation with request, response, timeout, and diagnostic limits.
- Ship `/ask` as an ordinary model-backed tool using `ephemeralMultiline` with `insert-at-invocation`, and `/rewrite` using `contextual` with `replace-context`.
- Lock submitted invocation source using the existing tool rules, publish only a complete canonical result, and preserve the existing failure, cancellation, pending-merge, recovery, and package-version behavior.
- Remove the earlier plans for `@agent` parsing, agent-controlled context, whole-document or history access, separate agent-run storage, stale-target conflict UI, and an agent-specific Retry lifecycle.
- Add no streaming, model tool-calling, JavaScript model API, autonomous loop, memory, background execution, arbitrary network access, user-entered provider credentials, or `insert-after-line` output mode.

## Capabilities

### New Capabilities

- `bounded-agent-context`: Model-backed tool declarations, author-controlled input contracts and instructions, bundled model selection, and the `/ask` and `/rewrite` definitions.
- `asynchronous-agent-runs`: OAuth-only OpenRouter configuration and status, lazy bounded provider execution, Keychain credentials, cancellation, failure isolation, and integration with the shared tool lifecycle.

### Modified Capabilities

- `deterministic-builtins`: Broaden the JavaScript-only tool-package contract into an executor-discriminated package contract while preserving the existing sandbox and behavior of JavaScript tools.
- `tool-configuration`: Add model-executor authoring, editable instructions, a filterable bundled model picker, and provider readiness to the existing Tools settings experience.

## Impact

- Extends tool manifests, package validation, registry projections, and Settings drafts with executor-specific configuration.
- Introduces a model-provider boundary, OpenRouter client, curated model catalog, and OAuth PKCE callback handling.
- Adds a registered Models Settings pane with cached nonsecret connection status, explicit credential verification, and Keychain-backed credential replacement and removal.
- Refactors tool dispatch behind a shared executor interface while retaining the existing invocation metadata, controller, presentation, transactions, persistence, and history behavior.
- Adds network activity only during explicit OpenRouter connection management or execution of a configured model-backed tool; application launch, ordinary editing, JavaScript tools, Settings navigation, and model-list browsing remain local.
- Requires delta specifications for the existing `deterministic-builtins` and `tool-configuration` capabilities in addition to rewriting this change's two existing capability specifications.
