## Why

Deterministic commands prove Jort's invocation and transaction model, but they do not validate the defining asynchronous workflow: an agent runs while the document remains editable, receives only visible bounded context, and commits safely against potentially changed text. This final Run slice adds that workflow behind narrow provider and consent boundaries.

## What Changes

- Recognize registered `@agent` invocations through the existing invocation registry and decorate the actual invocation line.
- Make prompt-only, full-line, and agent-declared bounded nearby context visible and editable before execution.
- Require explicit Run or Shift-Return and capture an immutable context manifest, document generation, anchors, hashes, agent identity, and provider identity.
- Add a fake delayed provider as the normative concurrency harness plus one simple lazily initialized provider implementation.
- Keep the document editable during runs; show bounded progress and support cancellation without streaming tokens into canonical text.
- Rebase safe insertions by stable line identity, detect material target changes, and require explicit conflict resolution instead of overwriting newer text.
- Insert complete successful output atomically after the invocation line with removable provenance; persist failed, cancelled, timed-out, and interrupted operational records without automatic retry.
- Enforce prompt-only default authority, declared network access, and fresh preview/confirmation for every whole-document or history request.

## Capabilities

### New Capabilities

- `bounded-agent-context`: Agent registration, invocation, visible context manifests, run-scoped consent, and whole-document/history confirmation.
- `asynchronous-agent-runs`: Provider boundary, run lifecycle, cancellation, persistence, stale-target handling, conflict resolution, atomic insertion, provenance, and failure isolation.

### Modified Capabilities

None. This change extends prior archived palette, invocation, transaction, history, and storage foundations without redefining their requirements.

## Impact

- Adds agent/provider registries, secure provider configuration, run and consent records, and a lazy provider client boundary.
- Extends invocation decoration with context controls, progress, cancellation, completion, and conflict states.
- Adds immutable context manifests and hash-checked asynchronous commit coordination.
- Introduces optional network access only after explicit invocation of a configured network provider.
- Adds no JavaScript runtime, external executable, arbitrary plugin/tool execution, capture, connector, or notification center.
