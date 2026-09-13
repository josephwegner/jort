## Context

Jort now has a complete tool system covering registered slash-command completion, author-selected input modes, adjustable contextual ranges, explicit asynchronous execution, source locking, cancellation, canonical pending output, Merge and Dismiss transactions, persistence, history annotations, and accessible viewport-bounded presentation.

The earlier agents design predates that implementation and proposes parallel invocation, lifecycle, provenance, conflict, and persistence systems. This change instead adds model execution as another implementation type for ordinary tools. The existing change and capability identifiers retain "agent" terminology, but the product object delivered here is a one-shot model-backed tool.

Model-backed tools use OpenRouter exclusively in this first version. Users connect through OpenRouter OAuth PKCE and choose one model from a curated catalog bundled with Jort. Jort never asks users to enter or paste an API key.

## Goals / Non-Goals

**Goals:**

- Add `model` beside `javascript` as an author-selected tool executor type.
- Preserve the existing tool invocation and document-mutation contract for both executors.
- Keep input mode and output operation under tool-author control and inaccessible to the model.
- Let users author model-backed tools through editable instructions and a filterable model picker.
- Provide a trustworthy OAuth-only OpenRouter connection experience with useful status and recovery controls.
- Send only the tool's instructions and exact captured `content` to the selected model.
- Keep provider initialization, authentication checks, and model requests off launch and ordinary editing paths.
- Ship `/ask` and `/rewrite` as ordinary bundled model-backed definitions.

**Non-Goals:**

- `@agent` parsing or a separate agent registry, controller, annotation, or presentation system.
- User-entered API keys, arbitrary provider endpoints, or providers other than OpenRouter.
- Model selection at invocation time or provider/model labels in normal invocation chrome.
- Model access from JavaScript, arbitrary JavaScript network access, model tool-calling, autonomous loops, memory, or multi-step orchestration.
- Whole-document, history, filesystem, capture, connector, shell, process, or application-state context.
- Streaming output, background execution, separate agent-run history, automatic Retry, stale-target conflict UI, or `insert-after-line`.

## Decisions

### 1. Extend tool packages with an executor-discriminated implementation

A tool retains one shared manifest containing identity, version, display name, slash command, description, input mode, output operation, input/output limits, and compatibility metadata. The manifest additionally declares exactly one executor:

- `javascript` uses the existing bounded `tool.js` implementation.
- `model` uses bounded editable instructions and one model identifier from Jort's bundled catalog.

Model-backed packages contain an instructions resource rather than executable JavaScript. The in-memory package model represents implementation as a discriminated value rather than treating instructions as JavaScript source.

Existing package versions that lack an executor declaration decode as `javascript`. A newer schema version writes the executor explicitly. Existing bundled and custom JavaScript tools retain their current sandbox, validation, registry precedence, and execution behavior.

The tool author selects input mode, output operation, instructions, and model in Settings. These values are captured before execution. Neither the provider nor model response can request another input range, change output placement, bypass Merge, or invoke another tool.

Alternative considered: expose a model function inside `tool.js`. This is deferred because it would add asynchronous host bridging, multiple-call policy, cost authority, and orchestration semantics that are unnecessary for one-shot model tools.

### 2. Keep one invocation and lifecycle implementation

Model-backed definitions enter the same executable catalog and slash-command completion as JavaScript definitions. There is no `@agent` parser or second registry.

The existing invocation system continues to own:

- Contained, contextual, and ephemeral input
- Input focus and Shift-Return
- Contextual handles and exact content extraction
- Submitted-source locking
- Delayed processing indication and Cancel
- Validation and execution errors
- Canonical pending output
- Merge, Dismiss, Escape, deletion confirmation, Undo, and Redo
- Stable anchors, package-version recovery, persistence, and history decoration

The invocation controller dispatches through a shared executor boundary instead of calling the JavaScript runtime directly. JavaScript and model executors both accept one immutable captured `content` value and return one complete bounded output or structured failure.

Before locking source, model execution validates that the definition has nonempty bounded instructions, references a bundled model identifier, and has a locally available OpenRouter credential. Missing configuration remains an editable validation warning.

The actual request does not perform a separate credential-validation round trip. Authentication failure during execution becomes an invocation-local error and updates the cached Models-pane status. This avoids doubling normal request traffic.

Alternative considered: permit submitted context to remain editable and add rebase/conflict resolution. The existing lock model is retained because it guarantees that output corresponds to visible submitted content and avoids duplicating a conflict subsystem. Unrelated document text remains editable throughout the run.

### 3. Make model requests native, narrow, and one-shot

`ModelProvider` is a dependency-injected asynchronous interface accepting one immutable request and cancellation signal and returning one complete response or typed failure.

A model request contains only:

- Captured tool identity and version for diagnostics
- Selected OpenRouter model identifier
- Tool-authored instructions
- Exact normalized invocation `content`
- A bounded output-token request derived from global, model-catalog, and tool limits
- A request identity used for cancellation and terminal-state coordination

It contains no document snapshot, document coordinator, line metadata, history, settings store, JavaScript runtime, filesystem reference, or application object.

`OpenRouterProvider` uses a fixed HTTPS OpenRouter origin and nonstreaming chat-completion request. It obtains its credential from Keychain only after explicit model-tool execution. Responses are subject to timeout, transport-size, decoded-text, line, and token limits before publication. Cancellation, timeout, and completion compete for one terminal transition; late responses are discarded.

A deterministic fake provider supports success, delay, cancellation, timeout, malformed responses, authentication failures, and limit violations without network access.

Alternative considered: a configurable OpenAI-compatible endpoint. OpenRouter-only routing avoids arbitrary endpoint authority and gives the bundled model catalog one stable identifier namespace.

### 4. Add an OAuth-only Models Settings pane

The existing Settings workspace registers a Models pane separate from the Tools pane. Its primary content is an OpenRouter connection card.

The pane exposes these states:

- Not connected
- Connecting
- Connected, with nonsecret key label and last successful verification
- Unable to verify because the network is unavailable
- Connection needs attention because the credential is invalid, expired, or rejected

The primary action when disconnected is **Connect with OpenRouter**. Jort opens an OpenRouter-hosted authorization page through the system authentication/browser experience and uses OAuth PKCE with an S256 challenge. A temporary callback accepts only the matching bounded authorization response and expires after a short timeout.

Jort exchanges the authorization code for a user-controlled OpenRouter API key, validates it through OpenRouter's current-key endpoint, and stores it as an app-scoped, nonsynchronizing Keychain secret. The PKCE verifier and authorization code remain in memory only for the connection attempt.

Jort stores only bounded nonsecret status metadata outside Keychain: connection presence, masked or server-provided key label, expiration when supplied, last verification time, and last bounded status category. It never stores or displays the full credential.

Connected state provides:

- **Check Connection**
- **Replace Connection**
- **Disconnect**
- A link to OpenRouter account key management

Check Connection performs an explicit current-key request and updates cached status. Opening Settings, opening the Models pane, editing tools, and browsing the bundled model list perform no network request.

Replace Connection completes and validates a new PKCE flow before atomically replacing the prior Keychain item. Cancellation or failure preserves the existing working credential.

Disconnect removes the local Keychain credential and cached connection metadata. Because local deletion does not guarantee remote revocation, the confirmation explains that the user can revoke the generated key through OpenRouter's account management.

There is no manual key-entry field, reveal action, clipboard import, or raw credential export.

Alternative considered: manual API-key entry. It is excluded because it creates an avoidably alarming secret-entry experience and additional validation, replacement, visibility, and clipboard risks.

### 5. Extend Tools Settings with executor-specific editing

The Tools pane retains the existing common fields, enablement, input-mode selector, output-operation selector, validation, drafts, revision checks, templates, and Duplicate to Customize behavior.

Custom tools gain an executor selector:

- JavaScript shows the existing JavaScript source editor.
- Model shows an instructions editor and model picker.

The model picker is a compact filterable popover backed entirely by a curated catalog bundled with the application. Rows show a friendly model name with restrained provider/family metadata and resolve to a stable OpenRouter model identifier. Model browsing works while disconnected.

The tool editor makes executor type, input mode, output operation, instructions, and selected model explicit. The invocation UI does not repeat provider or model identity.

Changing executor type in a dirty custom draft requires deliberate confirmation if it would discard executor-specific content. Saving remains the normal Save operation and does not execute JavaScript, call a model, validate the OpenRouter credential, or open OAuth.

If an application update removes a selected model from the curated catalog, Jort preserves the definition and selection identifier, marks the tool unavailable with an actionable diagnostic, and requires the user to select a supported model. It does not silently substitute another model.

Alternative considered: model selection at every invocation. Per-tool selection keeps slash commands predictable and prevents routine model infrastructure from dominating the writing interaction.

### 6. Ship `/ask` and `/rewrite` through the ordinary catalog

Jort ships two bundled model-backed templates:

- `/ask` uses `ephemeralMultiline` input and `insert-at-invocation`.
- `/rewrite` uses `contextual` input and `replace-context`.

Each template contains bounded visible instructions and a bundled default model selection. Like existing bundled tools, they use the ordinary registry, may be disabled, are inspectable, and can be duplicated into user-owned custom definitions. They receive no privileged provider or document access.

The tools remain discoverable while OpenRouter is disconnected. Attempting to run one presents an editable configuration warning directing the user to the Models pane rather than removing it from completion.

### 7. Reuse canonical output, failure, and recovery semantics

A successful model response enters the existing pending-merge state as canonical text. `/ask` removes its invocation and retains its response when merged. `/rewrite` replaces its exact locked contextual source and invocation when merged.

Cancel, failure, Dismiss, Escape, pending deletion, Merge, Undo, persistence, relaunch, and package-version mismatch use the existing tool semantics. No separate `AgentRun`, consent record, conflict object, or Retry state is persisted.

An in-flight model execution found after relaunch becomes the same interrupted execution error used by other asynchronous tools. Already published output remains canonical and is never re-requested from the model.

## Risks / Trade-offs

- **OAuth callback is intercepted or replayed** -> Use PKCE S256, a cryptographically random verifier, loopback-only callback binding, one accepted response, strict correlation, and a short expiration.
- **A credential leaks through storage or diagnostics** -> Store only in Keychain, redact request headers and errors, prohibit raw-key UI, and test snapshots, settings, history, recovery, and logs.
- **Cached connection status becomes stale** -> Label it with its last verification time, provide Check Connection, and update it after authentication failures.
- **The bundled model catalog becomes outdated** -> Update it through application releases and preserve unsupported selections without silent replacement.
- **Installed instructions attempt to obtain broader authority** -> Show instructions in Settings and pass only their exact invocation `content`; the provider receives no document or host capability.
- **Model latency exposes lifecycle races** -> Reuse generation-based cancellation and exactly-one-terminal-state handling with a delayed fake provider.
- **Generalizing dispatch regresses JavaScript tools** -> Keep the JavaScript executor contract intact and rerun all existing package, invocation, persistence, history, UI, IME, and accessibility tests against both executor paths.
- **OAuth-created keys remain active after local disconnect** -> Explain the distinction and provide direct access to OpenRouter account key management.

## Migration Plan

1. Add backward-compatible executor decoding, treating existing definitions as JavaScript.
2. Migrate Settings records without rewriting existing JavaScript source or enablement.
3. Add the bundled model catalog, Models pane, and OAuth credential store with disconnected defaults.
4. Refactor runtime dispatch behind the shared executor boundary and validate existing JavaScript behavior before enabling model execution.
5. Add the fake provider, then OpenRouter, then the bundled `/ask` and `/rewrite` definitions.
6. Preserve unsupported model definitions and newer package schemas on rollback rather than deleting or coercing them.

## Implementation selections

- Initial catalog: `openai/gpt-5.4-mini` (default for both templates), `openai/gpt-5.4`, and `anthropic/claude-sonnet-4.6`. Display friendly model names and provider names only. The user authorized a small current catalog with sensible defaults.
- Use an OS-selected localhost callback port with a random per-attempt route, bound to IPv4 loopback, and a three-minute expiry. OpenRouter documents arbitrary localhost ports; authorization attribution uses localhost and port. No public callback relay is introduced.
- Persist connection state and verification/expiration dates only. Display a generic connection label rather than persisting untrusted server strings that could reflect credentials.
