## Context

This change depends on all earlier slices, especially deterministic command invocation and atomic transactions. Unlike commands, an agent can finish after the user has edited its invocation line, context, or insertion neighborhood. The core design problem is preserving authority and user text across that delay.

## Goals / Non-Goals

**Goals:**

- Make exactly submitted agent context visible before execution.
- Keep consent run-scoped and provider/network identity explicit.
- Keep editing responsive during delayed execution and cancellation.
- Insert complete output atomically only when its anchor remains safe.
- Surface conflicts without overwriting newer text and persist operational outcomes for diagnosis.

**Non-Goals:**

- Streaming tokens into the editor, a chat transcript, autonomous background runs, scheduled runs, or automatic retry after relaunch.
- JavaScript tools, shell/external commands, plugins, arbitrary filesystem access, or agent-requested command execution.
- Permanent whole-document/history consent, multi-agent orchestration, connectors, capture, or notifications beyond inline run state.

## Decisions

### 1. Use immutable, visible context manifests

Each agent declares allowable context modes and whether it requires network access. Prompt-only is the default. Full-line and bounded before/after ranges are computed against stable `LineID` anchors and visibly shaded before Run. The displayed labels derive from the exact submitted ranges, not approximate prose.

Run captures an immutable `ContextManifest` containing invocation range, ordered submitted ranges and UTF-8 text, base generation, line anchors, SHA-256 hashes, agent ID/version, provider ID, capabilities, and consent records. Whole-document and exact-history-revision reads require a fresh preview and confirmation every run; no persistent allow option exists.

### 2. Keep provider interface small and lazy

`ModelProvider` reports availability and network identity, accepts one immutable request with bounded text and cancellation, and returns one complete text response or typed failure. A deterministic fake delayed provider is required for concurrency tests. The initial real provider is one OpenAI-compatible `URLSession` implementation with credentials in Keychain, explicit endpoint configuration, response and byte limits, timeout, and no tool-calling authority. It initializes only after Run.

### 3. Persist run records separately from canonical text

An `AgentRun` stores immutable manifest metadata, status, timestamps, provider identity, bounded diagnostics, and output hash. Sensitive submitted text and provider output are not duplicated into long-lived run records beyond what already exists in the document/history; exact manifest text exists in memory during execution and any required operational persistence is encrypted using platform protection and removed when the run reaches its retention boundary.

Pending and completed visual state is annotation metadata. Relaunch marks previously running records interrupted. Failed, timed-out, cancelled, and interrupted runs may expose manual Retry, which always creates a new run from newly previewed current context. Nothing retries automatically.

### 4. Validate and rebase only safe insertion anchors

The default mutation is insertion immediately after the invocation logical line. Completion first resolves the invocation `LineID`. If it survives and the invocation hash plus its trailing boundary still match, output inserts there even if unrelated text changed elsewhere. If unrelated edits only moved the line, the anchor rebases by identity. If the invocation text, selected context needed for placement, or boundary changed materially, no automatic mutation occurs.

A conflict UI previews the completed output and offers Insert at Current Resolved Boundary when unambiguous, Copy Output, or Discard. It never overwrites or silently replaces newer text. Output remains bounded and is committed through the existing atomic transaction with provenance and semantic history boundary.

### 5. Keep run UI fixed-height and viewport bounded

The invocation-line overlay transitions through pending, running, failure, conflict, and completed states. Running state exposes agent/provider, elapsed state, and Cancel within a bounded fixed-height attachment; output is not streamed into the text view. Offscreen runs remain model state and do not force TextKit layout. Background updates do not move selection or viewport.

## Risks / Trade-offs

- **Context labels diverge from submitted bytes** -> Generate labels and shading from the same immutable manifest and hash exact UTF-8 payloads.
- **Delayed completion overwrites user work** -> Permit insertion only after identity, hash, and boundary validation; otherwise require conflict resolution.
- **Cancellation races completion** -> Use one actor-owned terminal-state transition and reject late provider callbacks.
- **Provider configuration leaks credentials or initializes at launch** -> Store secrets in Keychain, redact diagnostics, and test lazy initialization/network isolation.
- **Run records duplicate sensitive text** -> Persist hashes, anchors, and bounded diagnostics by default, not complete prompts/responses.

## Migration Plan

1. Add agent, provider-configuration, run-record, consent, and annotation schemas with empty registries.
2. Ship the fake delayed provider and complete all concurrency/conflict tests before enabling a network provider.
3. Enable one configured OpenAI-compatible provider behind explicit setup and invocation.
4. On rollback, older builds preserve and refuse the newer schema rather than deleting run or provenance records.

## Open Questions

The preferred first local model provider remains platform-availability dependent and is deferred; the OpenAI-compatible provider is sufficient for the Run contract. Exact operational-record retention duration should be configurable before public distribution.
