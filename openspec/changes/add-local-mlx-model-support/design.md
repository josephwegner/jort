## Context

Jort already isolates model execution behind the Sendable `ModelProvider.execute` interface and publishes complete output through the shared tool lifecycle. Today `JortApp.swift` injects an OpenRouter provider and one OpenRouter availability closure. `ModelCatalog` contains cloud IDs, `ModelRequest` validates against that catalog, and bundled ask/rewrite templates explicitly select a cloud model. Tools Settings already supports saved per-tool model selection and Duplicate to Customize; invocation chrome intentionally has no model picker.

The user successfully tested Qwen3-1.7B-4bit and explicitly accepts cold loading instead of keeping the model hot. The initial model repository is approximately 984 MB. Jort targets macOS 14 with strict Swift concurrency; the exact MLX dependency release, toolchain compatibility, supported architectures, and signed distribution must be proven before broad integration.

## Goals / Non-Goals

**Goals:**
- Offer one curated, native, offline-capable model alongside existing OpenRouter models.
- Download weights only on explicit consent, outside the DMG.
- Start every request cold and release all request-owned MLX state after terminal cleanup.
- Preserve tool contracts, provider privacy, cancellation, complete-output publication, and the editor's responsiveness.
- Make installation and execution failures actionable without disturbing cloud or JavaScript tools.

**Non-Goals:**
- Replace OpenRouter, silently migrate tool selections, or add per-invocation model controls.
- Support arbitrary Hugging Face repositories, imported weights, a Python dependency, localhost inference servers, fine-tuning, vision, or model auto-updates.
- Prewarm, maintain an idle model, reuse KV/prompt caches, persist conversations, or stream partial text into the document.
- Guarantee latency, physical erasure, or a specific process RSS reduction after freeing allocations.

## Decisions

### 1. Explicit provider routing with compatible persisted identities

Add typed backend metadata to the curated catalog and use a stable namespaced local ID (for example `mlx/qwen3-1.7b-4bit`) mapped to a release-pinned Hugging Face revision. Existing OpenRouter IDs remain unchanged. Route by catalog metadata, never display labels or arbitrary ID prefixes supplied by a package. Capture the selected identity with the submitted generation.

Replace the global OpenRouter readiness check with readiness for the selected model: cloud credentials for cloud models; supported hardware/runtime and a verified installation for Qwen. Keep cloud OAuth/Keychain behavior independent. Missing local assets fail preflight without locking source or starting downloads.

Users configure Qwen through the existing Tools Settings picker. Bundled ask/rewrite remain unchanged; Duplicate to Customize creates an editable local variant using the existing command-conflict/enablement workflow. Documentation must show disabling or renaming a conflicting variant rather than adding duplicate executable commands. No new invocation chrome or global model override is needed.

Alternative: changing all bundled tools to local by default would surprise users and require a download before previously working tools could run.

### 2. Native dependency behind the model Runtime boundary

Use a pinned compatible release of `mlx-swift` and `mlx-swift-lm` language-model products, not moving main branches. Isolate MLX types and non-Sendable model state in the Runtime implementation; expose only bounded request, readiness, installation progress, and failure contracts to AppKit and Settings. Keep imports and implementation references out of JavaScript broker/worker targets and contract-only modules.

Gate local support by Apple-silicon and runtime capability, without removing cloud support on an otherwise supported build. Verify macOS 14, release architectures, toolchain, Metal resources, signing, and notarization compatibility in an early dependency spike. If the latest release is incompatible, select a compatible pinned release rather than implicitly raising Jort's OS baseline. Do not ship a feature that claims support before this check passes.

Alternative: Python or an external server accelerates experiments but adds installation, process, endpoint, and packaging complexity to production.

### 3. Explicit, verified, optional model installation

Models Settings gains separate Local and OpenRouter sections. Qwen displays its local/private nature, approximate download size, cold-load behavior, capability status, and Download/Cancel/Retry/Remove actions. Merely opening settings or selecting Qwen never loads weights or contacts a host.

Bundle an installation manifest pinned to an immutable repository revision with exact required file names, sizes, SHA-256 hashes, and a bounded total size. Record upstream license/attribution and redistribution terms. Download only those files over HTTPS from the approved Hugging Face delivery chain; validate redirect destinations and never attach OpenRouter credentials. Account explicitly for current CDN/Xet hosts in the release manifest/network policy rather than permitting arbitrary redirects.

Store verified assets under a separate Jort-owned Application Support Models root, outside the document store and general-purpose Hugging Face cache. Stage within that root, reject symlinks/path traversal/special files, enforce transfer/disk bounds, verify all files, then atomically publish the installed revision. Incomplete downloads never count as ready. Clean abandoned staging safely after interruption; retry can restart rather than implementing resumable transfer initially. Startup readiness uses validated installation metadata, with integrity revalidation before loading. Installation failure preserves any valid installation.

Remove targets only the known owned model revision/staging data and reports failure honestly. Reject removal while the model is in use and offer retry after cancellation/completion. No deletion follows links or touches external caches. History/recovery purge remains scoped to document data; it does not remove public weights. Never persist prompts, generated inference intermediates, or KV caches in the model directory.

### 4. One cold inference session at a time

An actor-owned local execution service serializes local admission. Only one local request may load/generate at a time; subsequent requests wait cancellation-aware without holding model allocations. Cloud and JavaScript execution remain independent.

For each admitted request:
1. Recheck cancellation, selected revision, installation integrity, and capability.
2. Load model/tokenizer from the verified directory with network access disabled.
3. Apply the model's chat template with `enable_thinking: false`, separating instructions from exact captured input. Use deterministic/low-variance generation suitable for text tools.
4. Check the tokenized prompt against a release-configured local budget (initially 4,096 prompt tokens and up to 1,024 generated tokens, within the model's total context capacity). Reject excess input; never silently truncate it.
5. Decode internally with cancellation checks and incremental token/byte/line bounds, but return only one complete plain-text result. Reaching the token cap without a normal stop is a limit failure, not successful partial output.
6. In terminal cleanup after success, error, timeout, or cancellation, await outstanding GPU work, discard model/tokenizer/iteration/KV references, and clear request-owned allocator caches using supported MLX APIs before admitting another load. Retain only lightweight catalog/installation metadata.

Use a monotonic 90-second execution deadline including queueing and loading, and check cancellation/deadline between safe load/decode stages. GPU work is cooperatively drained before freeing resources. Existing generation invalidation prevents late results from publishing even if cancellation is not instantaneous. Do not use an unsafe concurrent global cache clear while any local session remains active.

Alternative: an idle unload timer would improve repeated latency but contradicts the user's preference for no residency between requests.

### 5. Preserve complete-output lifecycle and privacy

Provider routing stays beneath the shared coordinator. Local results pass the same NUL, bytes, lines, and lifecycle validation as remote results. There is no host authority, tool calling, background conversation, or JavaScript bridge. Model text is inert output. Typed local failures cover unsupported capability, missing/corrupt assets, installation failure, insufficient resources, context limits, timeout, cancellation, and generation failure. Local failures do not alter cloud credential state.

A local request must perform no inference network request and no credential lookup, including cache misses or corruption. No automatic cloud fallback exists. Downloads are separate explicit network activity and send no document content. Production diagnostics contain only bounded categories and optional timings, not prompts/responses or raw paths/errors.

## Risks / Trade-offs

- [Cold latency on every request] → Accepted product trade-off; measure load/prefill/generation separately and retain ordinary delayed processing/cancel UI.
- [Allocator/RSS does not immediately return to baseline] → Assert absence of retained model/KV objects and reusable MLX cache allocations; inspect Metal/process memory over repeated real-device runs without promising OS page eviction.
- [Shared-process inference can still pressure the editor] → Serialize local sessions, cap prompt/output budgets, check capability, and test editor responsiveness. Consider process isolation later only if measurements require it.
- [Dependency/toolchain and universal-build incompatibility] → Resolve and validate the dependency/architecture spike first; do not silently drop supported cloud builds.
- [Download CDN topology changes] → Version the restricted delivery policy and report bounded retryable failures rather than relaxing arbitrary-host access.
- [Small-model quality limits] → Label local explicitly, disable thinking, preserve cloud choice, and test actual ask/rewrite prompts.
- [Concurrent removal/load or cancellation races] → Coordinate installation leases and terminal cleanup with actor state; inject failure/race tests.

## Migration Plan

1. Prove compatible pinned dependencies and release packaging without model weights.
2. Add catalog/backend metadata without rewriting existing IDs or defaults.
3. Add optional installation and per-model readiness, then cold local execution.
4. Release with explicit opt-in download and documentation for customizing tools. No automatic downloads or authentication.
5. Rollback disables local catalog support while preserving stored unknown IDs with an actionable unavailable diagnostic; cloud tools remain unchanged. Model deletion remains explicit through the owned storage manager.

## Open Questions

- Which exact compatible MLX release, model commit, hashes, license metadata, and approved delivery hosts should be pinned? Resolve in the first implementation tasks and record them in source-controlled manifests.
- Do real-device measurements justify lowering the initial prompt/output budgets or requiring additional minimum-memory guidance? Initial budgets are conservative policy, not a performance guarantee.
