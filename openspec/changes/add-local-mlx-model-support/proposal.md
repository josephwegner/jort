## Why

Local testing with Qwen3-1.7B-4bit produced useful responses for Jort's small AI queries. Offering that model locally gives users an offline, credential-free alternative to OpenRouter without requiring a large installer or an always-resident model.

## What Changes

- Add native Apple-silicon MLX execution for `mlx-community/Qwen3-1.7B-4bit` alongside, not instead of, OpenRouter.
- Offer an explicit optional model download in Models Settings (approximately 984 MB); do not bundle weights in the app or DMG.
- Load the model only for an explicit execution, disable thinking mode, and release model, tokenizer, KV state, and reusable GPU allocations after each request completes, fails, or is cancelled. No prewarming or idle residency.
- Extend the curated model catalog and existing Tools Settings picker with an explicitly local model identity and provider-specific readiness. Preserve existing saved OpenRouter identities and bundled tool defaults; users select Qwen through ordinary custom-tool editing or Duplicate to Customize for `/ask` and `/rewrite`.
- Keep existing bounded input, cancellation, complete-output publication, Merge, Dismiss, and Undo semantics. Never silently substitute another local model or send a local invocation to the cloud.
- Expose accessible download, cancel, retry, remove, ready, unsupported-device, and failure states independently of OpenRouter connection state.

## Capabilities

### New Capabilities

- `local-mlx-models`: Optional verified model installation, local readiness, bounded native inference, per-request cold loading and cleanup, and model asset management.

### Modified Capabilities

- `bounded-agent-context`: Provider-aware stable catalog identities, local selection through existing tool configuration, and model-specific execution readiness without requiring OpenRouter for local tools.
- `asynchronous-agent-runs`: Lazy provider routing and provider-specific preflight, local failure isolation, and complete bounded local responses through the shared lifecycle while preserving OpenRouter security and behavior.

## Impact

- Model contracts/catalog, model readiness and failure types, Runtime dispatcher/provider composition, app wiring, Models Settings, and existing Tools Settings model picker.
- Add pinned MLX Swift language-model dependencies behind the Runtime boundary; verify supported Swift toolchain, macOS 14 baseline, Apple-silicon capability gating, release architectures, and signed distribution.
- Introduce a separate Jort-owned Application Support model directory with bounded installation manifests and explicit deletion; no model weights, prompts, KV caches, or inference state in documents/history/settings backups.
- Add deterministic fake-backed download/runtime/lifecycle tests and opt-in real-device latency, memory-cleanup, offline, and release-packaging checks. Preserve existing OpenRouter OAuth and Keychain contracts.
